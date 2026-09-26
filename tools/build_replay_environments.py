#!/usr/bin/env python3
"""Build M02–M06 frozen source snapshots from archival Git objects.

Never use the current uploaded worktree, generated model answers, or a commit
later than the anchor. Omitted build artifacts remain explicitly unavailable.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def utc(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_oid(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def tree_entries(trees, tree, prefix=""):
    for mode, name, oid in trees[tree]:
        path = prefix + name
        if mode in ("40000", "040000"):
            yield from tree_entries(trees, oid, path + "/")
        else:
            yield path, mode, oid


def load_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def normalize(text):
    return text.replace("\r\n", "\n").rstrip("\n")


def build(moment_id, destination, commits, trees, blobs, repositories):
    packet_dir = ROOT / "replay_packets/moments" / moment_id
    packet = json.loads((packet_dir / "packet.json").read_bytes())
    anchor = utc(packet["anchor"]["timestamp"])
    head = repositories["Ring-lang"]["head"]
    while True:
        commit = commits[head]
        if utc(commit["committer_utc"]) < anchor:
            break
        if not commit["parents"]:
            raise ValueError("No pre-anchor mainline commit")
        head = commit["parents"][0]
    workspace = json.loads((packet_dir / "workspace/snapshot.json").read_bytes())
    cwd = next(o["details"]["value"] for o in workspace["runtime_observations"] if o["name"] == "cwd")
    if destination.exists():
        raise ValueError("Refusing to overwrite " + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        target = Path(temporary) / "environment"
        target.mkdir()
        entries, missing, restored = [], [], {}

        def write(path, data, evidence):
            relative = PurePosixPath(path)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unsafe path")
            output = target.joinpath(*relative.parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            entries.append({"path": path, "sha256": sha256(data),
                            "size_bytes": len(data), "evidence": evidence})

        tree_inventory = []
        for path, mode, oid in tree_entries(trees, commit["tree"]):
            tree_inventory.append({"path": path, "mode": mode, "git_blob": oid})
            blob = blobs.get(oid, {})
            if mode not in ("100644", "100755") or "file" not in blob:
                missing.append({"path": path, "git_blob": oid,
                                "reason": blob.get("excluded", "unsupported mode or absent object")})
                continue
            data = (ROOT / blob["file"]).read_bytes()
            if blob.get("gzip"):
                data = gzip.decompress(data)
            if git_oid(data) != oid:
                raise ValueError("Blob mismatch: " + path)
            # Session archives must never carry post-anchor observations.
            if path.endswith(".jsonl") and "sessions" in PurePosixPath(path).parts:
                for line in data.splitlines():
                    if not line.strip():
                        continue
                    record = json.loads(line)
                    if record.get("timestamp") and utc(record["timestamp"]) > anchor:
                        raise ValueError("Post-anchor session in selected tree")
            write("fs/" + path, data, {"kind": "git_tree", "commit": head,
                                      "git_blob": oid, "mode": mode})
            restored[path] = data

        # Repository skill files are fixed by the very same pre-anchor Git tree.
        skill_index = {}
        for path, data in restored.items():
            if path.startswith(".claude/skills/") and path.endswith("/SKILL.md"):
                name = path.split("/")[2]
                relative = name + "/SKILL.md"
                write("skills/" + relative, data, {"kind": "git_tree_skill_copy",
                      "commit": head, "source_path": path, "git_blob": git_oid(data)})
                skill_index[name] = relative
        write("skills/index.json", encoded(skill_index), {"kind": "adapter_index"})

        # Cross-check actual reads against the snapshot. Post-anchor observations
        # are evidence ONLY: never copied into the environment. Stop before the
        # first write-capable tool, even if it eventually failed.
        lines = gzip.decompress((packet_dir / "provenance/raw-session.jsonl.gz").read_bytes()).splitlines()
        read_checks = []
        for number, line in enumerate(lines, 1):
            if number <= packet["anchor"]["source_line"]:
                continue
            record = json.loads(line)
            content = record.get("message", {}).get("content", [])
            if (record.get("type") == "user" and not record.get("isMeta")
                    and not record.get("sourceToolAssistantUUID")
                    and not record.get("sourceToolUseID")
                    and record.get("toolUseResult") is None
                    and (isinstance(content, str) or any(b.get("type") == "text" for b in content if isinstance(b, dict)))):
                break
            if isinstance(content, list) and any(
                b.get("type") == "tool_use" and b.get("name") not in
                ("Read", "Glob", "Grep", "Skill", "AskUserQuestion", "ToolSearch")
                for b in content if isinstance(b, dict)
            ):
                break
            tool_result = record.get("toolUseResult")
            if not isinstance(tool_result, dict) or not isinstance(tool_result.get("file"), dict):
                continue
            f = tool_result["file"]
            path = str(f.get("filePath", "")).replace("\\", "/")
            prefix = cwd.replace("\\", "/").rstrip("/") + "/"
            if not path.lower().startswith(prefix.lower()):
                continue
            rel = path[len(prefix):]
            if rel not in restored:
                continue
            start, count = int(f.get("startLine", 1)), int(f.get("numLines", 0))
            expected = "\n".join(restored[rel].decode("utf-8", errors="replace").split("\n")[start-1:start-1+count])
            read_checks.append({"path": rel, "source_line": number, "observed_at": record.get("timestamp"),
                                "start_line": start, "num_lines": count,
                                "matches": normalize(expected) == normalize(f.get("content", "")),
                                "use": "crosscheck_only_not_a_resource_source"})

        names = set()
        for observation in json.loads((packet_dir / "context/skills.json").read_bytes())["observations"]:
            if observation.get("name") == "skill_listing":
                names.update(observation.get("details", {}).get("names", []))
        inventory = [{k: e[k] for k in ("path", "sha256", "size_bytes")}
                     for e in sorted(entries, key=lambda e: e["path"])]
        manifest = {
            "schema_version": 1, "moment_id": moment_id, "virtual_cwd": cwd,
            "fs_root": "fs", "skills_root": "skills", "visibility": "tool_access_only",
            "recovery": "partial", "anchor_timestamp": packet["anchor"]["timestamp"],
            "anchor_session_id": packet["anchor"]["session_id"],
            "input_sha256": packet["integrity"]["input_sha256"],
            "resource_inventory_sha256": sha256(encoded(inventory)),
            "repository": {"name": "Ring-lang", "commit": head, "tree": commit["tree"],
                           "committer_utc": commit["committer_utc"], "subject": commit["subject"],
                           "selection": "first pre-anchor commit on archived HEAD first-parent chain",
                           "archived_head": repositories["Ring-lang"]["head"],
                           "tracked_tree_complete": not missing, "tracked_files_total": len(tree_inventory),
                           "tracked_files_restored": len(restored), "dirty_state": "unknown"},
            "files": sorted(entries, key=lambda e: e["path"]), "missing_files": missing,
            "available_skills": sorted(skill_index), "unrecovered_skills": sorted(names - skill_index.keys()),
            "historical_read_crosschecks": read_checks,
            "limitations": [
                "Git tree reconstruction does not prove exact live HEAD or uncommitted/concurrent worker changes.",
                "Archived build outputs/binaries excluded from the archaeology repository remain absent.",
                "Global skills, full Claude Code system prompt, global memory and external worktrees are not recovered.",
                "Candidate tools are read-only; shell, edit, execution and worker dispatch are unavailable.",
                "Later replay rounds use the same anchor environment; historical writes in their prefix are not applied.",
                "Historical response and provenance remain outside all candidate filesystem roots."
            ]
        }
        (target / "manifest.json").write_bytes(encoded(manifest))
        target.rename(destination)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--moments", nargs="+", default=[f"M{i:02d}" for i in range(2, 7)])
    args = parser.parse_args()
    meta = {n: json.loads((ROOT / "metadata" / (n + ".json")).read_bytes())
            for n in ("commits", "trees", "blobs", "repositories")}
    for moment in args.moments:
        manifest = build(moment, ROOT / "replay_packets/moments" / moment / "environment", **meta)
        print(json.dumps({"moment": moment, "commit": manifest["repository"]["commit"],
                          "files": manifest["repository"]["tracked_files_restored"],
                          "missing": len(manifest["missing_files"]),
                          "skills": manifest["available_skills"],
                          "read_checks": manifest["historical_read_crosschecks"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
