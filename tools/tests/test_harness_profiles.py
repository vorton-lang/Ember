"""Audit the actual wire requests, source reproducibility, and resource boundary."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import harness_profiles as h
import replay as r


class HarnessProfileTests(unittest.TestCase):
    def test_m03_wire_requests_only_change_system(self):
        baseline = None
        systems = {}
        with tempfile.TemporaryDirectory() as directory:
            for name in h.available_profiles():
                with contextlib.redirect_stdout(io.StringIO()):
                    result = r.main([
                        "--moment", "M03", "--model", "anthropic/claude-opus-4.8",
                        "--provider", "anthropic", "--effort", "high",
                        "--harness", name, "--dry-run", "--runs-dir", directory,
                    ])
                self.assertEqual(result, 0)
            for path in Path(directory).rglob("initial_request.json"):
                request = json.loads(path.read_text())
                metadata = json.loads((path.parent / "run.json").read_text())
                system = request.pop("system")
                request.pop("session_id")
                if baseline is None:
                    baseline = request
                self.assertEqual(request, baseline)
                self.assertEqual(len(request["messages"]), 1)
                self.assertEqual(request["messages"][0]["role"], "user")
                self.assertEqual(request["tools"], r.TOOLS)
                self.assertEqual(metadata["system_sha256"], hashlib.sha256(system.encode()).hexdigest())
                self.assertEqual(metadata["initial_request_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
                name = metadata["harness"]
                systems[name] = system
                for forbidden in (
                    "Piebald", "dfd03ea", "2.1.142", "2.1.162", "2.1.172",
                    "gpt-5.3-codex", "GPT-5", "base_instructions", "ccVersion:",
                    "IS_TEXT_OUTPUT_VISIBLE_TO_USER", "${", "{env.virtual_cwd}",
                    "manifest.json", "assembly_assumptions", "curated-behavior",
                    "master bundle", "ontology refactoring", "latent invariant",
                    "Superpowers", "M03", "historical/continuation.jsonl",
                    "multi_tool_use.parallel", "apply_patch", "user is on the same machine",
                ):
                    self.assertNotIn(forbidden, system)
                if name != "minimal":
                    self.assertIn("The workspace is read-only", system)
                    self.assertIn("There is no shell", system)
                    self.assertEqual(metadata["harness_provenance"]["build_version"], h.BUILD_VERSION)
                    self.assertIn("parts", metadata["harness_provenance"])
            self.assertEqual(len(systems), 5)
            self.assertEqual(len(set(systems.values())), 5)
        self.assertIn("End-of-turn summary: one or two sentences", systems["cc-2.1.142"])
        self.assertNotIn("For exploratory questions", systems["cc-2.1.142"])
        for name in ("cc-2.1.162", "cc-2.1.172"):
            self.assertIn("respond in 2-3 sentences", systems[name])
        self.assertNotIn("End-of-turn summary: one or two sentences", systems["cc-2.1.172"])
        self.assertIn("readable matters more", systems["cc-2.1.172"])

    def test_originals_build_outputs_and_crlf(self):
        for name in h.available_profiles()[1:]:
            h.load_profile(name)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "harnesses"
            shutil.copytree(h.HARNESS_ROOT, root)
            for path in root.rglob("*"):
                if path.is_file():
                    path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
            manifest = h.read_manifest(root)
            for name in manifest["profiles"]:
                self.assertEqual(h.render_profile(name, manifest, root), h.load_profile(name)[1])
            source = root / manifest["profiles"]["cc-2.1.142"]["parts"][0]["path"]
            source.write_text(source.read_text() + "changed")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                h.render_profile("cc-2.1.142", manifest, root)

    def test_stale_adaptation_and_edited_generated_profile_fail(self):
        manifest = copy.deepcopy(h.read_manifest())
        manifest["profiles"]["codex-5.3"]["parts"][0]["replacements"][0]["before"] = "missing marker"
        with self.assertRaisesRegex(ValueError, "Ambiguous or missing adaptation"):
            h.render_profile("codex-5.3", manifest)
        original_read = Path.read_text
        def changed_read(path, *args, **kwargs):
            value = original_read(path, *args, **kwargs)
            return value + "edit" if path.name == "codex-5.3.md" else value
        with patch.object(Path, "read_text", changed_read):
            with self.assertRaisesRegex(ValueError, "differs from pinned sources"):
                h.load_profile("codex-5.3")

    def test_cli_custom_and_listing(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            r.parse_args(["--harness", "codex-5.3", "--system-prompt-file", "custom.md"])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(r.main(["--list-harnesses"]), 0)
        self.assertIn("cc-2.1.172", output.getvalue())
        with tempfile.TemporaryDirectory() as directory:
            custom = Path(directory) / "custom.md"
            custom.write_text("custom prompt", encoding="utf-8")
            self.assertEqual(h.load_profile("minimal", custom), (custom, "custom prompt", None))

    def test_candidate_tools_cannot_read_research_or_prompt_sources(self):
        env = r.FrozenEnvironment(r.ROOT / "replay_packets/moments/M03/environment", None)
        for path in (h.HARNESS_ROOT / "manifest.json", h.HARNESS_ROOT / "codex-5.3.md",
                     r.ROOT / "replay_packets/moments/M03/historical/continuation.jsonl"):
            with self.assertRaises(RuntimeError):
                env.read(str(path))
        self.assertNotIn("harnesses/manifest.json", env.glob("**/manifest.json"))


if __name__ == "__main__":
    unittest.main()
