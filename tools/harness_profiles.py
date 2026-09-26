"""Build and verify behavior profiles from pinned, unmodified source excerpts.

Adaptations of OpenAI Codex and Piebald's Claude Code prompt archive are recorded
in harnesses/manifest.json. See harnesses/sources for originals and licenses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

HARNESS_ROOT = Path(__file__).resolve().parents[1] / "harnesses"
BUILD_VERSION = "behavior-profiles-v1"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_manifest(root: Path = HARNESS_ROOT) -> dict:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if manifest["schema_version"] != 1:
        raise ValueError("Unsupported harness manifest schema")
    return manifest


def available_profiles() -> tuple[str, ...]:
    return ("minimal", *read_manifest()["profiles"])


def verified_text(root: Path, entry: dict) -> str:
    path = (root / entry["path"]).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("Harness source path escapes harnesses directory")
    # Canonical LF allows Windows Git checkouts without changing prompt identity.
    text = path.read_text(encoding="utf-8")
    if digest(text.encode("utf-8")) != entry["sha256"]:
        raise ValueError(f"Harness source hash mismatch: {entry['path']}")
    return text


def render_profile(name: str, manifest: dict, root: Path = HARNESS_ROOT) -> str:
    sections = []
    for part in manifest["profiles"][name]["parts"]:
        text = verified_text(root, part)
        if part["strip_archive_header"]:
            text, count = re.subn(r"\A<!--.*?-->\s*", "", text, count=1, flags=re.S)
            if count != 1:
                raise ValueError(f"Missing archive header: {part['path']}")
        text = text.strip()
        for change in part["replacements"]:
            if text.count(change["before"]) != 1:
                raise ValueError(f"Ambiguous or missing adaptation in {part['path']}: {change['reason']}")
            text = text.replace(change["before"], change["after"], 1)
        if "${" in text:
            raise ValueError(f"Unresolved product template in {part['path']}")
        sections.append(text.strip())
    sections.append(verified_text(root, manifest["adapter"]).strip())
    return "\n\n".join(sections) + "\n"


def load_profile(name: str, custom_path: Path | None = None) -> tuple[Path, str, dict | None]:
    if custom_path is not None:
        return custom_path, custom_path.read_text(encoding="utf-8"), None
    path = HARNESS_ROOT / f"{name}.md"
    text = path.read_text(encoding="utf-8")
    if name == "minimal":
        return path, text, None
    manifest = read_manifest()
    expected = render_profile(name, manifest)
    if text != expected:
        raise ValueError(f"Built harness differs from pinned sources: {name}; run tools/harness_profiles.py --write")
    provenance = {
        "build_version": BUILD_VERSION,
        "manifest_sha256": digest((HARNESS_ROOT / "manifest.json").read_text(encoding="utf-8").encode("utf-8")),
        "adapter": manifest["adapter"],
        **manifest["profiles"][name],
    }
    return path, text, provenance


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--write", action="store_true", help="Rebuild generated profiles offline")
    action.add_argument("--check", action="store_true", help="Verify source hashes and generated profiles")
    args = parser.parse_args()
    manifest = read_manifest()
    for name in manifest["profiles"]:
        text = render_profile(name, manifest)
        if args.write:
            with (HARNESS_ROOT / f"{name}.md").open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(text)
        else:
            load_profile(name)
        print(f"{name}: {digest(text.encode('utf-8'))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
