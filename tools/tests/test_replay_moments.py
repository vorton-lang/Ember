"""Contract tests for the delivered multi-moment runner (no network calls)."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import replay_deepseek as r
from validate_replay_environment import validate

ROOT = Path(__file__).resolve().parents[2]
PACKETS = ROOT / "replay_packets/moments"


class ReplayMomentTests(unittest.TestCase):
    def test_all_bundles_and_api_tool_pairing(self):
        for i in range(2, 7):
            packet = PACKETS / f"M{i:02d}"
            with self.subTest(moment=packet.name):
                self.assertTrue(validate(packet / "environment", packet)["ok"])
                base = r.canonical_messages(r.load_jsonl(packet / "conversation.jsonl"))
                history = r.load_jsonl(packet / "historical/continuation.jsonl")
                rounds = r.list_replay_rounds(base, history)
                anchor = json.loads((packet / "historical/moment.json").read_text())["seed_verbatim"]
                self.assertEqual(rounds[0]["text"], anchor)
                for round_number in range(1, len(rounds) + 1):
                    prefix, _ = r.build_historical_prefix(history, round_number)
                    messages, warnings = r.repair_tool_exchanges(base + prefix)
                    self.assertEqual(messages[0]["role"], "user")
                    self.assertEqual(messages[-1]["role"], "user")
                    for index, message in enumerate(messages):
                        self.assertTrue(message["content"])
                        if index:
                            self.assertNotEqual(message["role"], messages[index-1]["role"])
                        self.assertTrue(all(b["type"] in ("text", "tool_use", "tool_result") for b in message["content"]))
                        if message["role"] == "assistant":
                            calls = {b["id"] for b in message["content"] if b["type"] == "tool_use"}
                            returned = {b["tool_use_id"] for b in messages[index+1]["content"] if b["type"] == "tool_result"}
                            self.assertEqual(calls, returned)
                    self.assertEqual(len(warnings), 1 if i == 5 else 0)

    def test_round_one_never_opens_researcher_files(self):
        original_open = Path.open
        def guarded_open(path, *args, **kwargs):
            if "historical" in path.parts or "provenance" in path.parts:
                raise AssertionError("Research file opened by round-one runner: " + str(path))
            return original_open(path, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            for i in range(2, 7):
                args = ["replay_deepseek.py", "--packet", str(PACKETS / f"M{i:02d}"),
                        "--dry-run", "--runs-dir", directory]
                with patch.object(sys, "argv", args), patch.object(Path, "open", guarded_open):
                    self.assertEqual(r.main(), 0)
            for request_path in Path(directory).rglob("initial_request.json"):
                request = json.loads(request_path.read_text())
                run = json.loads((request_path.parent / "run.json").read_text())
                self.assertEqual(run["status"], "dry_run")
                self.assertEqual(hashlib.sha256(request_path.read_bytes()).hexdigest(), run["initial_request_sha256"])
                self.assertNotIn("api_key", request)

    def test_lazy_tools_and_cross_moment_isolation(self):
        for i in range(2, 7):
            p = PACKETS / f"M{i:02d}"
            env = r.FrozenEnvironment(p / "environment", None)
            self.assertIn("Discussion", env.skill("discussion"))
            self.assertIn("公理", env.read("docs/philosophy.md"))
            context, _ = r.extract_injected_system_context(r.load_jsonl(p / "conversation.jsonl"), r.load_jsonl(p / "context/pre_response.jsonl"))
            system = r.make_system_prompt(context, env, True)
            self.assertIn("discussion:", system)
            self.assertNotIn((p / "environment/fs/docs/philosophy.md").read_text(), system)
            for path in ("../historical/response.json", "../../M03/historical/response.json", "../../packet.json",
                         "C:\\Users\\secret.txt", "../manifest.json", "historical/response.json"):
                with self.subTest(moment=i, path=path), self.assertRaises(RuntimeError):
                    env.read(path)
            self.assertEqual(env.glob("**/historical/*"), "(no matches)")
            self.assertEqual(env.grep("RESEARCHER_SENTINEL_FUTURE_97231"), "(no matches)")

    def test_round_two_stops_at_direct_human(self):
        p = PACKETS / "M05"
        history = r.load_jsonl(p / "historical/continuation.jsonl")
        prefix, cut = r.build_historical_prefix(history, 2)
        modified = copy.deepcopy(history)
        for wrapper in modified[cut:]:
            wrapper["record"]["message"] = {"role": "assistant", "content": "FUTURE_POISON"}
        self.assertEqual(prefix, r.build_historical_prefix(modified, 2)[0])
        self.assertNotIn("FUTURE_POISON", str(prefix))
        self.assertTrue(r.is_direct_human_user(history[cut-1]))

    def test_mock_api_tools_and_interrupt_logging(self):
        packet = PACKETS / "M03"
        args = SimpleNamespace(model="deepseek-v4-pro", max_tokens=1024, effort="max")
        calls = []
        responses = [SimpleNamespace(id="test-1", model=args.model, role="assistant", stop_reason="tool_use", content=[
            {"type": "tool_use", "id": "call-1", "name": "Read", "input": {"file_path": "docs/philosophy.md"}}]),
            SimpleNamespace(id="test-2", model=args.model, role="assistant", stop_reason="end_turn", content=[{"type": "text", "text": "Offline test complete."}])]
        def create(**kwargs):
            calls.append(copy.deepcopy(kwargs))
            return responses.pop(0)
        client = SimpleNamespace(messages=SimpleNamespace(create=create))
        with tempfile.TemporaryDirectory() as directory:
            log = r.RunLog(Path(directory) / "run", {"status": "running"})
            messages = [{"role": "user", "content": [{"type": "text", "text": "Inspect philosophy."}]}]
            r.api_turn(client, args, "Test", messages, r.FrozenEnvironment(packet / "environment", None), log, set())
            self.assertEqual(len(calls), 2)
            self.assertIn("公理", calls[1]["messages"][-1]["content"][0]["content"])
            self.assertEqual(calls[0]["model"], "deepseek-v4-pro")
            self.assertTrue(any(e["kind"] == "tool_result" for e in log.events))
        with tempfile.TemporaryDirectory() as directory:
            fake_client = SimpleNamespace(messages=SimpleNamespace(create=lambda **kwargs: (_ for _ in ()).throw(KeyboardInterrupt())))
            fake_sdk = SimpleNamespace(Anthropic=lambda **kwargs: fake_client)
            cli = ["replay_deepseek.py", "--packet", str(packet), "--runs-dir", directory]
            with patch.object(sys, "argv", cli), patch.dict(sys.modules, {"anthropic": fake_sdk}), patch.dict(r.os.environ, {"DEEPSEEK_API_KEY": "offline-test-only"}):
                self.assertEqual(r.main(), 130)
            run_path = next(Path(directory).rglob("run.json"))
            self.assertEqual(json.loads(run_path.read_text())["status"], "interrupted")
            self.assertTrue((run_path.parent / "initial_request.json").exists())
            self.assertNotIn("offline-test-only", (run_path.parent / "transcript.jsonl").read_text())


if __name__ == "__main__":
    unittest.main()
