#!/usr/bin/env python3
"""Verify model-input hashes, resource inventory, Git blobs and temporal bounds."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path, PurePosixPath


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def utc(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate(environment, packet_dir=None):
    environment = Path(environment).resolve()
    manifest = json.loads((environment / "manifest.json").read_bytes())
    anchor = utc(manifest["anchor_timestamp"])
    repository = manifest["repository"]
    if utc(repository["committer_utc"]) >= anchor:
        raise ValueError("Repository snapshot is not pre-anchor")
    for root_name in ("fs_root", "skills_root"):
        root = (environment / manifest[root_name]).resolve()
        if not root.is_relative_to(environment) or root == environment:
            raise ValueError("Root escapes environment")
    packet = None
    if packet_dir is not None:
        packet_dir = Path(packet_dir).resolve()
        packet = json.loads((packet_dir / "packet.json").read_bytes())
        if packet["moment_id"] != manifest["moment_id"] or packet["anchor"]["timestamp"] != manifest["anchor_timestamp"]:
            raise ValueError("Environment belongs to a different anchor")
        if packet["integrity"]["input_sha256"] != manifest["input_sha256"]:
            raise ValueError("Environment/input hash mismatch")
        for spec in packet["components"].values():
            if spec.get("visibility") != "model_input":
                continue
            path = (packet_dir / spec["path"]).resolve()
            if not path.is_relative_to(packet_dir):
                raise ValueError("Model input escapes packet")
            if hashlib.sha256(path.read_bytes()).hexdigest() != packet["integrity"]["files"][spec["path"]]:
                raise ValueError("Model input changed: " + spec["path"])
    expected, inventory = {"manifest.json"}, []
    resource_errors = []
    for entry in manifest["files"]:
        relative = PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or entry["path"] in expected:
            raise ValueError("Unsafe/duplicate resource path")
        expected.add(entry["path"])
        path = environment.joinpath(*relative.parts)
        if path.is_symlink() or not path.resolve().is_relative_to(environment):
            raise ValueError("Resource escapes bundle")
        if not path.is_file():
            resource_errors.append("Missing resource: " + entry["path"])
            continue
        data = path.read_bytes()
        if len(data) != entry["size_bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            resource_errors.append("Resource hash mismatch: " + entry["path"])
            continue
        evidence = entry["evidence"]
        if evidence["kind"] == "git_tree":
            if evidence["commit"] != repository["commit"]:
                raise ValueError("Resource belongs to another commit")
            oid = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            if oid != evidence["git_blob"]:
                raise ValueError("Source blob mismatch")
        if "sessions" in relative.parts and path.suffix == ".jsonl":
            for line in data.splitlines():
                if not line.strip():
                    continue
                record = json.loads(line)
                if record.get("timestamp") and utc(record["timestamp"]) > anchor:
                    raise ValueError("Future session record")
        inventory.append({k: entry[k] for k in ("path", "sha256", "size_bytes")})
    if resource_errors:
        raise ValueError("Frozen environment integrity failed:\n" + "\n".join(resource_errors))
    actual = set()
    for path in environment.rglob("*"):
        if path.is_symlink():
            raise ValueError("Symlinks are forbidden")
        if path.is_file():
            actual.add(path.relative_to(environment).as_posix())
    if actual != expected:
        raise ValueError("Unlisted or missing resources: " + str(sorted(actual ^ expected)))
    inventory.sort(key=lambda e: e["path"])
    digest = hashlib.sha256(encoded(inventory)).hexdigest()
    if digest != manifest["resource_inventory_sha256"]:
        raise ValueError("Inventory hash mismatch")
    fs_count = sum(e["path"].startswith(manifest["fs_root"] + "/") for e in manifest["files"])
    if fs_count != repository["tracked_files_restored"]:
        raise ValueError("Restored file count mismatch")
    if repository.get("tracked_files_total") is not None:
        if fs_count + len(manifest["missing_files"]) != repository["tracked_files_total"]:
            raise ValueError("Tracked inventory incomplete")
    return {"ok": True, "moment_id": manifest["moment_id"], "resource_files": len(inventory),
            "tracked_files": fs_count, "omitted_files": len(manifest["missing_files"]),
            "tracked_tree_complete": repository["tracked_tree_complete"], "recovery": manifest["recovery"],
            "commit": repository["commit"], "resource_inventory_sha256": digest}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet", type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.packet / "environment", args.packet), indent=2))
