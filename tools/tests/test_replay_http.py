"""HTTP contract and lifecycle tests; all requests use an in-memory transport."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import replay as r

ROOT = Path(__file__).resolve().parents[2]
PACKET = ROOT / "replay_packets/moments/M03"


def arguments(*extra):
    args = r.parse_args(list(extra))
    args.session_id = "ember-offline-test"
    return args


def message(content=None, **extra):
    return {
        "id": "test-response", "model": "test/resolved-model", "role": "assistant",
        "type": "message", "stop_reason": "end_turn",
        "content": content or [{"type": "text", "text": "Done."}],
        **extra,
    }


class HTTPReplayTests(unittest.TestCase):
    def test_request_defaults_pinning_fallback_and_direct(self):
        args = arguments("--provider", "anthropic")
        body = r.build_request(args, "system", [])
        self.assertNotIn("output_config", body)
        self.assertNotIn("temperature", body)
        self.assertNotIn("cache_control", body)
        self.assertFalse(args.cache_input)
        self.assertEqual(body["provider"], {
            "only": ["anthropic"], "allow_fallbacks": False, "require_parameters": True,
        })
        self.assertEqual(body["session_id"], args.session_id)
        self.assertEqual(args.endpoint, "https://openrouter.ai/api/v1/messages")
        self.assertEqual(r.request_headers(args, "test-key")["X-OpenRouter-Metadata"], "enabled")
        args = arguments("--provider", "anthropic", "--allow-provider-fallbacks", "--effort", "xhigh")
        body = r.build_request(args, "", [])
        self.assertNotIn("only", body["provider"])
        self.assertEqual(body["provider"]["order"], ["anthropic"])
        self.assertTrue(body["provider"]["allow_fallbacks"])
        self.assertEqual(body["output_config"], {"effort": "xhigh"})
        args = arguments("--gateway", "deepseek")
        body = r.build_request(args, "", [])
        self.assertEqual(args.api_key_env, "DEEPSEEK_API_KEY")
        self.assertEqual(args.endpoint, "https://api.deepseek.com/anthropic/v1/messages")
        self.assertEqual(body["output_config"], {"effort": "high"})
        self.assertNotIn("provider", body)
        self.assertNotIn("session_id", body)
        self.assertNotIn("X-OpenRouter-Metadata", r.request_headers(args, "test-key"))
        for url in ("https://example.test/api", "https://example.test/api/v1", "https://example.test/api/v1/messages"):
            self.assertEqual(r.messages_endpoint(url), "https://example.test/api/v1/messages")

    def test_tool_loop_preserves_thinking_signatures_and_exact_wire_log(self):
        args = arguments("--provider", "anthropic", "--cache-input")
        calls = []
        thinking = {"type": "thinking", "thinking": "reasoning", "signature": "opaque-signature"}
        responses = [
            message([thinking, {"type": "tool_use", "id": "call-1", "name": "Read",
                                "input": {"file_path": "docs/philosophy.md"}}], stop_reason="tool_use",
                    openrouter_metadata={"endpoints": {"available": [
                        {"provider": "Anthropic", "selected": True},
                        {"provider": "Other", "selected": False}]}}, opaque_extension={"keep": True}),
            message(),
        ]
        originals = copy.deepcopy(responses)

        def handler(request):
            self.assertEqual(request.headers["authorization"], "Bearer offline-secret")
            calls.append(request.content)
            return httpx.Response(200, json=responses.pop(0))

        with tempfile.TemporaryDirectory() as directory:
            log = r.RunLog(Path(directory) / "run", {"status": "running"})
            with httpx.Client(transport=httpx.MockTransport(handler), headers=r.request_headers(args, "offline-secret")) as client:
                messages = [{"role": "user", "content": "Inspect philosophy."}]
                initial = r.encode_request(r.build_request(args, "system", messages))
                with contextlib.redirect_stdout(io.StringIO()):
                    r.api_turn(client, args, "system", messages, r.FrozenEnvironment(PACKET / "environment", None), log, set())
            self.assertEqual(len(calls), 2)
            for body in calls:
                self.assertEqual(json.loads(body)["cache_control"], {"type": "ephemeral", "ttl": "5m"})
            self.assertEqual(calls[0], initial)
            second = json.loads(calls[1])
            self.assertEqual(second["messages"][-2]["content"][0], thinking)
            self.assertIn("公理", second["messages"][-1]["content"][0]["content"])
            self.assertEqual(second["session_id"], json.loads(calls[0])["session_id"])
            requests = [event for event in log.events if event["kind"] == "api_request"]
            for request, body in zip(requests, calls):
                self.assertEqual(request["request"], json.loads(body))
                self.assertEqual(request["request_sha256"], hashlib.sha256(body).hexdigest())
            self.assertEqual(requests[0]["request"]["messages"], [{"role": "user", "content": "Inspect philosophy."}])
            self.assertEqual(json.loads((log.run_dir / "initial_response.json").read_bytes()), originals[0])
            self.assertEqual(log.metadata["resolved_providers"], ["Anthropic"])
            self.assertEqual(log.metadata["routing_observations"][1]["resolved_providers"], [])
            self.assertTrue(log.metadata["warnings"])
            self.assertNotIn("offline-secret", (log.run_dir / "transcript.jsonl").read_text())

    def test_cache_input_dry_run_records_condition_without_changing_context(self):
        requests = []
        for enabled in (False, True):
            with self.subTest(enabled=enabled), tempfile.TemporaryDirectory() as directory:
                cli = ["--moment", "M01", "--start-round", "2", "--dry-run", "--runs-dir", directory]
                if enabled:
                    cli.append("--cache-input")
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(r.main(cli), 0)
                run_path = next(Path(directory).rglob("run.json"))
                metadata = json.loads(run_path.read_text())
                self.assertEqual(metadata["cache_input"], enabled)
                self.assertEqual(metadata["cache_input_ttl"], "5m" if enabled else None)
                wire = (run_path.parent / "initial_request.json").read_bytes()
                self.assertEqual(metadata["initial_request_sha256"], hashlib.sha256(wire).hexdigest())
                request = json.loads(wire)
                if enabled:
                    self.assertEqual(request.pop("cache_control"), {"type": "ephemeral", "ttl": "5m"})
                else:
                    self.assertNotIn("cache_control", request)
                request.pop("session_id")
                requests.append(request)
        self.assertEqual(requests[0], requests[1])

    def test_cache_input_rejects_unsupported_gateways_and_models(self):
        for options in (("--gateway", "deepseek"), ("--model", "deepseek/deepseek-v4.1-flash")):
            with self.subTest(options=options), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    arguments("--cache-input", *options)
                self.assertEqual(result.exception.code, 2)

    def test_errors_logged_without_retries(self):
        cases = [
            httpx.Response(429, json={"error": {"message": "rate limited"}}),
            httpx.Response(200, json={"error": {"message": "upstream failed"}}),
            httpx.Response(200, text="not JSON"),
            httpx.Response(200, json=message(content=[{"type": "tool_use", "name": "Read", "input": {}}])),
        ]
        for response in cases:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as directory:
                seen = []
                def handler(request):
                    seen.append(request)
                    return response
                args = arguments()
                log = r.RunLog(Path(directory) / "run", {})
                with httpx.Client(transport=httpx.MockTransport(handler)) as client:
                    with self.assertRaises(RuntimeError):
                        r.send_request(client, args, r.build_request(args, "", []), log)
                self.assertEqual(len(seen), 1)
                self.assertEqual((log.run_dir / "responses/0001.body").read_bytes(), response.content)
                self.assertEqual(log.events[-1]["kind"], "api_response")

    def test_main_lifecycle_and_initial_request_identity(self):
        # Exercise setup failures, Ctrl+C during HTTP, EOF at the prompt, and truncation.
        real_client = httpx.Client
        for mode, code, status in [("interrupt", 130, "interrupted"), ("eof", 0, "ended"),
                                   ("missing-key", 1, "error"), ("truncated", 1, "error"),
                                   ("timeout", 1, "error"), ("question-eof", 0, "ended")]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                calls = []
                def handler(request):
                    calls.append(request.content)
                    if mode == "interrupt":
                        raise KeyboardInterrupt()
                    if mode == "timeout":
                        raise httpx.ReadTimeout("offline timeout")
                    if mode == "question-eof":
                        return httpx.Response(200, json=message([
                            {"type": "tool_use", "id": "q1", "name": "AskUserQuestion",
                             "input": {"questions": [{"question": "Which direction?"}]}}
                        ], stop_reason="tool_use"))
                    return httpx.Response(200, json=message(stop_reason="max_tokens" if mode == "truncated" else "end_turn"))
                def client_factory(**kwargs):
                    return real_client(transport=httpx.MockTransport(handler), **kwargs)
                env = {} if mode == "missing-key" else {"OPENROUTER_API_KEY": "offline-secret"}
                cli = ["--packet", str(PACKET), "--provider", "anthropic", "--runs-dir", directory]
                with patch("httpx.Client", side_effect=client_factory), patch.dict(r.os.environ, env, clear=True), \
                        patch("builtins.input", side_effect=EOFError), contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(r.main(cli), code)
                run = next(Path(directory).rglob("run.json"))
                self.assertEqual(json.loads(run.read_text())["status"], status)
                if calls:
                    self.assertEqual(calls[0], (run.parent / "initial_request.json").read_bytes())
                self.assertNotIn("offline-secret", (run.parent / "transcript.jsonl").read_text())

    def test_free_form_question_and_legacy_entrypoint(self):
        with patch("builtins.input", return_value="Your framing is wrong"), contextlib.redirect_stdout(io.StringIO()):
            result = r.execute_tool("AskUserQuestion", {"questions": [
                {"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]}]},
                r.FrozenEnvironment(None, None))
        self.assertEqual(json.loads(result)["answers"][0]["answer"], "Your framing is wrong")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / "tools/replay_deepseek.py"),
                                     "--packet", str(PACKET), "--dry-run", "--runs-dir", directory],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            body = json.loads(next(Path(directory).rglob("initial_request.json")).read_text())
            self.assertEqual(body["model"], "deepseek-flash")
            self.assertEqual(body["output_config"], {"effort": "high"})
            self.assertNotIn("provider", body)


if __name__ == "__main__":
    unittest.main()
