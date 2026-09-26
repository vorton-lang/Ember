"""Contract tests for the delivered multi-moment runner (no network calls)."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import replay as r
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



if __name__ == "__main__":
    unittest.main()
