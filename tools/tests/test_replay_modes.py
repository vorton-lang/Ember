"""Regression checks for workflow removal, human choices, and replay boundaries."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import replay as r

PACKETS = r.ROOT / "replay_packets/moments"


def project(packet, round_number, mode):
    events = r.load_jsonl(packet / "conversation.jsonl")
    history = r.load_jsonl(packet / "historical/continuation.jsonl")
    base = r.canonical_messages(events, mode)
    prefix, cut = r.build_historical_prefix(history, round_number, mode)
    messages = base + prefix
    if mode == "semantic":
        messages, _ = r.semantic_messages(messages)
    return r.repair_tool_exchanges(messages)[0], cut


class ReplayModeTests(unittest.TestCase):
    def test_m01_removes_workflow_but_preserves_facts_and_human_answers(self):
        packet = PACKETS / "M01"
        semantic, cut = project(packet, 2, "semantic")
        faithful, faithful_cut = project(packet, 2, "faithful")
        self.assertEqual(cut, faithful_cut)
        clean = json.dumps(semantic, ensure_ascii=False)
        original = json.dumps(faithful, ensure_ascii=False)
        for body in ("# Brainstorming Ideas Into Designs", "Base directory for this skill:",
                     "<HARD-GATE>", "Launching skill:", "You can now continue"):
            self.assertIn(body, original)
            self.assertNotIn(body, clean)
        for fact in ("Personal Profile", "良好的工程scalability", "错误即类型, 不可变优先",
                     "Web + 移动 + 桌面", "强力但是不鼓励类型体操", "Safe Imperative"):
            self.assertIn(fact, clean)
        self.assertEqual(semantic[-1], faithful[-1])
        names = [b.get("name") for m in semantic for b in m["content"] if b["type"] == "tool_use"]
        self.assertEqual(names, ["Read", "Agent"])
        self.assertIn("这门语言的核心定位是什么？", clean)
        self.assertIn("GPU/系统为主", clean)

    def test_default_and_faithful_wire_inputs_and_metadata(self):
        self.assertEqual(r.parse_args([]).replay_mode, "semantic")
        self.assertEqual(r.parse_args([], default_gateway="deepseek").replay_mode, "semantic")
        with tempfile.TemporaryDirectory() as directory:
            for mode in ("semantic", "faithful"):
                for round_number in (1, 2):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(r.main([
                            "--packet", str(PACKETS / "M01"), "--start-round", str(round_number),
                            "--replay-mode", mode, "--dry-run", "--runs-dir", directory,
                        ]), 0)
            for path in Path(directory).rglob("initial_request.json"):
                request = json.loads(path.read_text())
                meta = json.loads((path.parent / "run.json").read_text())
                semantic = meta["replay_mode"] == "semantic"
                self.assertEqual("You have superpowers." in request["system"], not semantic)
                self.assertEqual("You MUST use this before any creative work" in request["system"], not semantic)
                self.assertIn("personal-context", request["system"])
                self.assertIn("superpowers:brainstorming", request["system"])
                self.assertEqual(request["tools"], r.TOOLS)
                mode_tag = "sem" if semantic else "faith"
                self.assertIn(f"__r{meta['start_round']}-{mode_tag}__", path.parent.name)
                self.assertEqual(meta["projection_version"], "semantic-v1" if semantic else "faithful-v1")
                if semantic and meta["start_round"] == 2:
                    self.assertEqual(meta["projection_stats"]["removed_meta_records"], 2)
                    self.assertEqual(meta["projection_stats"]["question_blocks_to_text"], 8)
        # Optional live skill loading is deliberately unchanged.
        env = r.FrozenEnvironment(PACKETS / "M01/environment", None)
        self.assertIn("# Brainstorming Ideas Into Designs", env.skill("superpowers:brainstorming"))

    def test_all_moments_and_rounds_keep_valid_exchanges_and_anchor(self):
        for packet in sorted(PACKETS.iterdir()):
            history = r.load_jsonl(packet / "historical/continuation.jsonl")
            base = r.canonical_messages(r.load_jsonl(packet / "conversation.jsonl"))
            for anchor in r.list_replay_rounds(base, history):
                with self.subTest(moment=packet.name, round=anchor["round"]):
                    messages, _ = project(packet, anchor["round"], "semantic")
                    self.assertEqual(messages[0]["role"], "user")
                    self.assertEqual(messages[-1]["role"], "user")
                    self.assertIn(anchor["text"], r.text_from_content(messages[-1]["content"]))
                    for index, message in enumerate(messages):
                        self.assertTrue(message["content"])
                        if index:
                            self.assertNotEqual(message["role"], messages[index - 1]["role"])
                        if message["role"] == "assistant":
                            calls = {b["id"] for b in message["content"] if b["type"] == "tool_use"}
                            results = {b["tool_use_id"] for b in messages[index + 1]["content"] if b["type"] == "tool_result"}
                            self.assertEqual(calls, results)
                            self.assertFalse(any(b.get("name") in r.PROCESS_TOOLS | {"AskUserQuestion"}
                                                 for b in message["content"]))
                    self.assertNotIn("Base directory for this skill:", json.dumps(messages))

    def test_semantic_prefix_never_uses_future_response(self):
        for name in ("M01", "M05"):
            history = r.load_jsonl(PACKETS / name / "historical/continuation.jsonl")
            prefix, cut = r.build_historical_prefix(history, 2, "semantic")
            poisoned = copy.deepcopy(history)
            for wrapper in poisoned[cut:]:
                wrapper["record"]["message"] = {"role": "assistant", "content": "FUTURE_POISON"}
            self.assertEqual((prefix, cut), r.build_historical_prefix(poisoned, 2, "semantic"))
            self.assertTrue(r.is_direct_human_user(history[cut - 1]))

    def test_process_pairs_and_reminders_removed_without_rewriting_dialogue(self):
        messages = [
            {"role": "user", "content": [{"type": "text", "text": "Discuss Skill and TodoWrite.\n<system-reminder>MANDATORY</system-reminder>"}]},
            {"role": "assistant", "content": [
                {"type": "text", "text": "I will inspect this."},
                {"type": "tool_use", "id": "todo", "name": "TodoWrite", "input": {"todos": []}},
                {"type": "tool_use", "id": "skill", "name": "Read", "input": {"file_path": r"C:\skills\x\SKILL.md"}},
                {"type": "tool_use", "id": "facts", "name": "Read", "input": {"file_path": "profile.md"}},
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "todo", "content": "WORKFLOW"},
                {"type": "tool_result", "tool_use_id": "skill", "content": "SKILL_BODY"},
                {"type": "tool_result", "tool_use_id": "facts", "content": "FACTS"},
                {"type": "text", "text": "Continue."},
            ]},
        ]
        before = copy.deepcopy(messages)
        projected, _ = r.semantic_messages(messages)
        self.assertEqual(messages, before)
        self.assertEqual(projected[0]["content"][0]["text"], "Discuss Skill and TodoWrite.\n")
        self.assertEqual(projected[1]["content"], [messages[1]["content"][0], messages[1]["content"][3]])
        self.assertEqual(projected[2]["content"], messages[2]["content"][2:])
        self.assertEqual(r.repair_tool_exchanges(projected)[1], [])


if __name__ == "__main__":
    unittest.main()
