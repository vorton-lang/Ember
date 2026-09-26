#!/usr/bin/env python3
"""Interactive historical moment replay through DeepSeek's Anthropic API.

pip install -U anthropic
python tools/replay_deepseek.py --moment M03 --model deepseek-v4-pro --effort max
python tools/replay_deepseek.py --moment M05 --list-rounds
python tools/replay_deepseek.py --moment M06 --start-round 2 --dry-run

--start-round 1 begins at the packet anchor, including its pre-anchor context.
N>1 includes the historical prefix through the Nth direct human turn.
Frozen resources are exposed only via read-only tools. Historical answers and
provenance are not mounted. Ctrl+C saves the interaction and full tool trace.
The original complete Claude Code system prompt is not reconstructed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import sys
import traceback
from pathlib import Path
from typing import Any, Iterable

ADAPTER_VERSION = "moments-deepseek-anthropic-v2.0"
DEFAULT_BASE_URL = "https://api.deepseek.com/anthropic"

# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------

def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def json_dump(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def hash_tree(root: Path | None) -> str | None:
    if root is None or not root.exists():
        return None

    entries: list[tuple[str, str]] = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            rel = path.relative_to(root).as_posix()
            entries.append((rel, sha256_file(path)))

    return sha256_bytes((json_dump(entries) + "\n").encode("utf-8"))


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"{path}:{line_no}: invalid JSONL: {exc}") from exc
            if not isinstance(value, dict):
                raise RuntimeError(f"{path}:{line_no}: expected JSON object")
            out.append(value)
    return out


def block_to_dict(block: Any) -> dict[str, Any]:
    if isinstance(block, dict):
        return block

    if hasattr(block, "model_dump"):
        return block.model_dump(exclude_none=True)

    if hasattr(block, "dict"):
        return block.dict(exclude_none=True)

    # Last-resort extraction for SDK objects.
    result: dict[str, Any] = {}
    for name in ("type", "text", "thinking", "signature", "id", "name", "input"):
        if hasattr(block, name):
            value = getattr(block, name)
            if value is not None:
                result[name] = value
    return result


def message_to_dict(message: Any) -> dict[str, Any]:
    if hasattr(message, "model_dump"):
        return message.model_dump(exclude_none=True)
    if hasattr(message, "dict"):
        return message.dict(exclude_none=True)
    return {
        "id": getattr(message, "id", None),
        "model": getattr(message, "model", None),
        "role": getattr(message, "role", None),
        "content": [block_to_dict(x) for x in getattr(message, "content", [])],
        "stop_reason": getattr(message, "stop_reason", None),
    }


def text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content

    parts: list[str] = []
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                block = block_to_dict(block)
            if block.get("type") == "text":
                parts.append(str(block.get("text", "")))
    return "\n".join(x for x in parts if x)


# ---------------------------------------------------------------------------
# Canonical packet projection
# ---------------------------------------------------------------------------

def validate_packet_paths(packet_dir: Path, packet: dict[str, Any]) -> dict[str, Path]:
    components = packet.get("components")
    if not isinstance(components, dict):
        raise RuntimeError("packet.json has no components object")

    allowed: dict[str, Path] = {}
    root = packet_dir.resolve()

    for name, spec in components.items():
        if not isinstance(spec, dict):
            raise RuntimeError(f"component {name!r} is not an object")
        if spec.get("visibility") != "model_input":
            continue

        rel = spec.get("path")
        if not isinstance(rel, str) or not rel:
            raise RuntimeError(f"component {name!r} has invalid path")

        candidate = (packet_dir / rel).resolve()
        try:
            candidate.relative_to(root)
        except ValueError as exc:
            raise RuntimeError(f"component escapes packet directory: {rel}") from exc

        if not candidate.exists():
            raise RuntimeError(f"missing model_input component: {candidate}")

        allowed[name] = candidate

    return allowed


def extract_injected_system_context(
    conversation_events: list[dict[str, Any]],
    pre_response_events: list[dict[str, Any]],
) -> tuple[str, list[str]]:
    """
    Build a conservative leading system projection.

    We intentionally do not concatenate every overlapping component. For M01,
    conversation/pre_response already contain the observed injection events.
    The adapter prefers actual injected payloads and catalog text, while
    recording approximation warnings.
    """
    sections: list[str] = []
    warnings: list[str] = []

    seen: set[str] = set()

    def add(text: str) -> None:
        text = text.strip()
        if not text:
            return
        key = sha256_bytes(text.encode("utf-8"))
        if key in seen:
            return
        seen.add(key)
        sections.append(text)

    # Session-start injected context.
    for event in conversation_events:
        if event.get("kind") != "context_observation":
            continue
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue

        # Prefer the explicit hook_additional_context record over wrapper stdout.
        if payload.get("type") == "hook_additional_context":
            content = payload.get("content")
            if isinstance(content, list):
                for item in content:
                    if isinstance(item, str):
                        add(item)

    # Pre-response skill catalog is useful because the model may decide to call Skill.
    # Tool/agent catalogs are not injected verbatim because this replay exposes only
    # a small read-only subset; pretending unavailable tools exist would be worse.
    for event in conversation_events + pre_response_events:
        payload = event.get("payload")
        if not isinstance(payload, dict):
            continue

        if payload.get("type") == "skill_listing":
            content = payload.get("content")
            if isinstance(content, str):
                add("Available skills at this historical point:\n" + content)

    warnings.append(
        "Adapter uses a leading system projection for recovered harness injections; "
        "the original API request/rendering is not available."
    )
    warnings.append(
        "Only the replay's read-only tool subset is callable even if the historical "
        "catalog mentioned additional tools or agents."
    )

    return "\n\n".join(sections), warnings


def canonical_messages(conversation_events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Preserve pre-anchor text AND tool exchanges, without hidden thinking."""
    messages: list[dict[str, Any]] = []
    for event in conversation_events:
        if event.get("kind") == "context_observation":
            payload = event.get("payload", {})
            if payload.get("type") == "edited_text_file":
                text = ("<system-reminder>\nObserved file change: "
                        + str(payload.get("filename", "")) + "\n"
                        + str(payload.get("snippet", "")) + "\n</system-reminder>")
                messages.append({"role": "user", "content": [{"type": "text", "text": text}]})
            continue
        if event.get("kind") != "message" or event.get("speaker") not in ("user", "assistant"):
            continue
        clean = []
        for block in event.get("content", []):
            kind = block.get("kind") or block.get("type")
            if kind == "text":
                clean.append({"type": "text", "text": str(block.get("text", ""))})
            elif kind == "tool_call":
                clean.append({"type": "tool_use", "id": block["call_id"],
                              "name": block["name"], "input": block.get("arguments", {})})
            elif kind == "tool_result":
                result = block.get("content", "")
                if isinstance(result, list):
                    # Neutral canonical text blocks must be converted to API blocks.
                    result = [{"type": "text", "text": str(b.get("text", ""))}
                              for b in result if (b.get("kind") or b.get("type")) == "text"]
                clean.append({"type": "tool_result", "tool_use_id": block["call_id"],
                              "content": result, "is_error": bool(block.get("is_error", False))})
        if clean:
            messages.append({"role": event["speaker"], "content": clean})
    return merge_consecutive_roles(messages)


def repair_tool_exchanges(messages: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    """Close archive gaps explicitly; never invent the result of a missing tool."""
    import copy
    messages = copy.deepcopy(merge_consecutive_roles(messages))
    warnings = []
    out = []
    for index, message in enumerate(messages):
        if message["role"] == "assistant":
            calls = [b for b in message["content"] if b.get("type") == "tool_use"]
            if calls:
                if index + 1 >= len(messages) or messages[index + 1]["role"] != "user":
                    messages.insert(index + 1, {"role": "user", "content": []})
                following = messages[index + 1]["content"]
                returned = {b.get("tool_use_id") for b in following if b.get("type") == "tool_result"}
                for call in calls:
                    if call["id"] not in returned:
                        following.insert(0, {"type": "tool_result", "tool_use_id": call["id"],
                                             "content": "Historical tool result unavailable in the recovered record; no result is inferred.",
                                             "is_error": True})
                        warnings.append("Missing historical tool result: " + call["id"])
        else:
            expected = {b["id"] for b in out[-1]["content"] if b.get("type") == "tool_use"} if out and out[-1]["role"] == "assistant" else set()
            content = []
            for block in message["content"]:
                if block.get("type") == "tool_result" and block["tool_use_id"] not in expected:
                    # Preserve the observation, but don't send an invalid unpaired API block.
                    content.append({"type": "text", "text": "Historical unpaired tool result:\n" + json.dumps(block["content"], ensure_ascii=False)})
                    warnings.append("Unpaired historical tool result: " + block["tool_use_id"])
                else:
                    content.append(block)
            message["content"] = sorted(content, key=lambda b: b.get("type") != "tool_result")
        out.append(message)
    return out, warnings


# ---------------------------------------------------------------------------
# Historical prefix replay for --start-round N
# ---------------------------------------------------------------------------

def raw_record_message(record_wrapper: dict[str, Any]) -> dict[str, Any] | None:
    record = record_wrapper.get("record")
    if not isinstance(record, dict):
        return None
    message = record.get("message")
    if not isinstance(message, dict):
        return None
    return message


def is_direct_human_user(record_wrapper: dict[str, Any]) -> bool:
    """
    A new replay "round" means a direct top-level user message.

    Excludes:
    - tool_result records
    - Skill body injections / isMeta records
    - AskUserQuestion result records
    - attachments
    """
    record = record_wrapper.get("record")
    if not isinstance(record, dict):
        return False

    if record.get("type") != "user":
        return False
    if record.get("isMeta"):
        return False
    if record.get("sourceToolAssistantUUID") is not None:
        return False
    if record.get("sourceToolUseID") is not None:
        return False
    if record.get("toolUseResult") is not None:
        return False

    message = record.get("message")
    if not isinstance(message, dict):
        return False
    if message.get("role") != "user":
        return False

    content = message.get("content")
    if isinstance(content, str):
        return bool(content.strip())

    if not isinstance(content, list):
        return False

    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            if str(block.get("text", "")).strip():
                return True

    return False


def clean_historical_content(content: Any) -> list[dict[str, Any]]:
    """
    Convert historical Anthropic-like content to candidate-visible history.

    Deliberately removes historical hidden thinking/signatures.
    """
    if isinstance(content, str):
        return [{"type": "text", "text": content}]

    if not isinstance(content, list):
        return []

    out: list[dict[str, Any]] = []

    for raw in content:
        if not isinstance(raw, dict):
            continue

        typ = raw.get("type")
        if typ in ("thinking", "redacted_thinking"):
            continue

        if typ == "text":
            text = raw.get("text")
            if isinstance(text, str):
                out.append({"type": "text", "text": text})
            continue

        if typ == "tool_use":
            if all(k in raw for k in ("id", "name", "input")):
                out.append(
                    {
                        "type": "tool_use",
                        "id": raw["id"],
                        "name": raw["name"],
                        "input": raw["input"],
                    }
                )
            continue

        if typ == "tool_result":
            if "tool_use_id" in raw:
                block: dict[str, Any] = {
                    "type": "tool_result",
                    "tool_use_id": raw["tool_use_id"],
                    "content": raw.get("content", ""),
                }
                if "is_error" in raw:
                    block["is_error"] = raw["is_error"]
                out.append(block)
            continue

        # M01 is text/tool-centric. Ignore unsupported provider-specific blocks.

    return out


def historical_record_to_api_message(
    record_wrapper: dict[str, Any],
) -> dict[str, Any] | None:
    message = raw_record_message(record_wrapper)
    if message is None:
        return None

    role = message.get("role")
    if role not in ("user", "assistant"):
        return None

    content = clean_historical_content(message.get("content"))
    if not content:
        return None

    return {"role": role, "content": content}


def merge_consecutive_roles(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    for msg in messages:
        role = msg.get("role")
        content = msg.get("content")

        if role not in ("user", "assistant") or not isinstance(content, list):
            continue

        if out and out[-1]["role"] == role:
            out[-1]["content"].extend(content)
        else:
            out.append({"role": role, "content": list(content)})

    return out


def direct_user_text(record_wrapper: dict[str, Any]) -> str:
    message = raw_record_message(record_wrapper)
    if message is None:
        return ""
    return text_from_content(message.get("content"))


def list_replay_rounds(
    canonical: list[dict[str, Any]],
    historical_records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    rounds: list[dict[str, Any]] = []

    seed = ""
    for msg in reversed(canonical):
        if msg.get("role") == "user":
            seed = next((str(b.get("text", "")) for b in reversed(msg.get("content", []))
                         if b.get("type") == "text"), "")
            break

    rounds.append(
        {
            "round": 1,
            "source": "canonical_anchor",
            "text": seed,
            "timestamp": None,
        }
    )

    index = 2
    for wrapper in historical_records:
        if not is_direct_human_user(wrapper):
            continue

        record = wrapper["record"]
        rounds.append(
            {
                "round": index,
                "source": "historical_direct_user",
                "text": direct_user_text(wrapper),
                "timestamp": record.get("timestamp"),
            }
        )
        index += 1

    return rounds


def build_historical_prefix(
    historical_records: list[dict[str, Any]],
    start_round: int,
) -> tuple[list[dict[str, Any]], int]:
    if start_round <= 1:
        return [], 0

    target_direct_user_number = start_round - 1
    direct_seen = 0
    selected: list[dict[str, Any]] = []

    for wrapper in historical_records:
        selected.append(wrapper)

        if is_direct_human_user(wrapper):
            direct_seen += 1
            if direct_seen == target_direct_user_number:
                break

    if direct_seen != target_direct_user_number:
        raise RuntimeError(
            f"--start-round {start_round} does not exist in the historical trajectory"
        )

    messages: list[dict[str, Any]] = []
    for wrapper in selected:
        msg = historical_record_to_api_message(wrapper)
        if msg is not None:
            messages.append(msg)

    return merge_consecutive_roles(messages), len(selected)


# ---------------------------------------------------------------------------
# Frozen read-only environment
# ---------------------------------------------------------------------------

class FrozenEnvironment:
    def __init__(
        self,
        environment_dir: Path | None,
        fallback_virtual_cwd: str | None,
    ) -> None:
        self.environment_dir = environment_dir.resolve() if environment_dir else None
        self.available = bool(self.environment_dir and self.environment_dir.exists())

        self.manifest: dict[str, Any] = {}
        self.virtual_cwd = fallback_virtual_cwd or "."

        self.fs_root: Path | None = None
        self.skills_root: Path | None = None
        self.skill_index: dict[str, str] = {}

        if not self.available:
            return

        manifest_path = self.environment_dir / "manifest.json"
        if manifest_path.exists():
            self.manifest = load_json(manifest_path)

        virtual_cwd = self.manifest.get("virtual_cwd")
        if isinstance(virtual_cwd, str) and virtual_cwd:
            self.virtual_cwd = virtual_cwd

        fs_rel = self.manifest.get("fs_root", "fs")
        skills_rel = self.manifest.get("skills_root", "skills")

        self.fs_root = (self.environment_dir / fs_rel).resolve()
        self.skills_root = (self.environment_dir / skills_rel).resolve()
        for root in (self.fs_root, self.skills_root):
            if not root.is_relative_to(self.environment_dir) or root == self.environment_dir:
                raise RuntimeError("manifest roots must be subdirectories of environment")

        # Convenience fallback: if --environment points directly at a restored
        # historical repository rather than a packaged environment/ directory,
        # use that directory itself as the read-only filesystem root.
        if not self.fs_root.exists():
            if not manifest_path.exists():
                self.fs_root = self.environment_dir
            else:
                self.fs_root = None

        if not self.skills_root.exists():
            self.skills_root = None

        if self.skills_root is not None:
            index_path = self.skills_root / "index.json"
            if index_path.exists():
                raw = load_json(index_path)
                if isinstance(raw, dict):
                    for key, value in raw.items():
                        if isinstance(key, str) and isinstance(value, str):
                            self.skill_index[key] = value

    def environment_hash(self) -> str | None:
        return hash_tree(self.environment_dir)

    def _virtual_to_relative(self, raw_path: str) -> Path:
        path = raw_path.strip().replace("\\", "/")
        cwd = self.virtual_cwd.replace("\\", "/").rstrip("/")

        lower_path = path.lower()
        lower_cwd = cwd.lower()

        if lower_path == lower_cwd:
            path = ""
        elif lower_path.startswith(lower_cwd + "/"):
            path = path[len(cwd) + 1 :]
        elif re.match(r"^[A-Za-z]:/", path):
            raise RuntimeError(
                f"path {raw_path!r} is outside frozen virtual cwd {self.virtual_cwd!r}"
            )

        # Treat relative paths as relative to virtual cwd.
        parts = [p for p in path.split("/") if p not in ("", ".")]
        if any(p == ".." for p in parts):
            raise RuntimeError("parent traversal is not allowed")

        return Path(*parts)

    def _safe_fs_path(self, raw_path: str) -> Path:
        if self.fs_root is None:
            raise RuntimeError("frozen filesystem is unavailable")

        rel = self._virtual_to_relative(raw_path)
        candidate = (self.fs_root / rel).resolve()

        try:
            candidate.relative_to(self.fs_root)
        except ValueError as exc:
            raise RuntimeError("path escapes frozen filesystem") from exc

        return candidate

    def read(self, file_path: str, offset: int = 1, limit: int = 400) -> str:
        path = self._safe_fs_path(file_path)
        if not path.exists():
            raise RuntimeError(f"file not found in frozen environment: {file_path}")
        if not path.is_file():
            raise RuntimeError(f"not a file: {file_path}")
        if path.is_symlink():
            raise RuntimeError("symlink reads are disabled in replay")

        data = path.read_bytes()
        if b"\x00" in data[:8192]:
            raise RuntimeError("binary file read is disabled in this replay")

        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines()

        start = max(1, int(offset))
        count = max(1, min(int(limit), 2000))
        end = min(len(lines), start - 1 + count)

        rendered = []
        for idx in range(start - 1, end):
            rendered.append(f"{idx + 1:6d}\t{lines[idx]}")

        suffix = ""
        if end < len(lines):
            suffix = f"\n... ({len(lines) - end} more lines)"

        return "\n".join(rendered) + suffix

    def glob(self, pattern: str, path: str | None = None) -> str:
        if self.fs_root is None:
            raise RuntimeError("frozen filesystem is unavailable")

        base = self._safe_fs_path(path) if path else self.fs_root
        if not base.exists():
            raise RuntimeError(f"glob base does not exist: {path}")

        results: list[str] = []

        for candidate in base.rglob("*"):
            if len(results) >= 500:
                break
            if candidate.is_symlink():
                continue

            rel_from_base = candidate.relative_to(base).as_posix()
            rel_from_root = candidate.relative_to(self.fs_root).as_posix()

            patterns = [pattern]
            if pattern.startswith("**/"):
                patterns.append(pattern[3:])

            if any(
                fnmatch.fnmatch(rel_from_base, p) or fnmatch.fnmatch(rel_from_root, p)
                for p in patterns
            ):
                results.append(rel_from_root)

        return "\n".join(results) if results else "(no matches)"

    def grep(
        self,
        pattern: str,
        path: str | None = None,
        glob_pattern: str | None = None,
    ) -> str:
        if self.fs_root is None:
            raise RuntimeError("frozen filesystem is unavailable")

        regex = re.compile(pattern)
        base = self._safe_fs_path(path) if path else self.fs_root

        if not base.exists():
            raise RuntimeError(f"grep path does not exist: {path}")

        if base.is_file():
            files: Iterable[Path] = [base]
        else:
            files = base.rglob("*")

        hits: list[str] = []

        for file_path in files:
            if len(hits) >= 200:
                break
            if not file_path.is_file() or file_path.is_symlink():
                continue
            if file_path.stat().st_size > 4 * 1024 * 1024:
                continue

            rel = file_path.relative_to(self.fs_root).as_posix()
            if glob_pattern and not fnmatch.fnmatch(rel, glob_pattern):
                continue

            try:
                data = file_path.read_bytes()
                if b"\x00" in data[:8192]:
                    continue
                text = data.decode("utf-8", errors="replace")
            except OSError:
                continue

            for line_no, line in enumerate(text.splitlines(), 1):
                if regex.search(line):
                    hits.append(f"{rel}:{line_no}:{line}")
                    if len(hits) >= 200:
                        break

        return "\n".join(hits) if hits else "(no matches)"

    def _discover_skill(self, name: str) -> Path | None:
        if self.skills_root is None:
            return None

        if name in self.skill_index:
            path = (self.skills_root / self.skill_index[name]).resolve()
            try:
                path.relative_to(self.skills_root)
            except ValueError:
                return None
            return path if path.is_file() else None

        # Common direct layouts.
        candidates = [
            self.skills_root / name / "SKILL.md",
            self.skills_root / name / "skill.md",
            self.skills_root / (name.replace(":", "__")) / "SKILL.md",
            self.skills_root / (name.replace(":", "__") + ".md"),
        ]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.resolve()

        # Fallback: parse frontmatter name.
        for candidate in self.skills_root.rglob("*.md"):
            if candidate.is_symlink() or candidate.stat().st_size > 512 * 1024:
                continue
            try:
                text = candidate.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

            head = "\n".join(text.splitlines()[:30])
            match = re.search(r"(?m)^name:\s*[\"']?([^\"'\n]+)", head)
            if match and match.group(1).strip() == name:
                return candidate.resolve()

        return None

    def skill(self, name: str, args: str | None = None) -> str:
        if any(token in name for token in ("/", "\\", "..")):
            raise RuntimeError("invalid skill name")
        path = self._discover_skill(name)
        if path is None:
            raise RuntimeError(f"skill unavailable in frozen environment: {name}")

        try:
            path.relative_to(self.skills_root)
        except ValueError as exc:
            raise RuntimeError("skill path escapes frozen skills root") from exc

        text = path.read_text(encoding="utf-8", errors="replace")
        if args:
            text += f"\n\nARGUMENTS: {args}"
        return text


TOOLS = [
    {
        "name": "Read",
        "description": (
            "Read a text file from the frozen historical workspace. "
            "Paths are relative to the historical cwd unless absolute within that cwd."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string"},
                "offset": {"type": "integer", "minimum": 1},
                "limit": {"type": "integer", "minimum": 1, "maximum": 2000},
            },
            "required": ["file_path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "Glob",
        "description": "Find paths in the frozen historical workspace by glob pattern.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
            },
            "required": ["pattern"],
            "additionalProperties": False,
        },
    },
    {
        "name": "Grep",
        "description": "Regex search text files in the frozen historical workspace.",
        "input_schema": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
                "glob": {"type": "string"},
            },
            "required": ["pattern"],
            "additionalProperties": False,
        },
    },
    {
        "name": "Skill",
        "description": (
            "Load a skill body by name from the frozen historical skill environment. "
            "Use this when an available skill is relevant."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "skill": {"type": "string"},
                "args": {"type": "string"},
            },
            "required": ["skill"],
            "additionalProperties": False,
        },
    },
    {
        "name": "AskUserQuestion",
        "description": (
            "Ask the user one or more structured questions. The replay harness will "
            "present them in the terminal and return the original user's live answers."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "questions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "question": {"type": "string"},
                            "header": {"type": "string"},
                            "multiSelect": {"type": "boolean"},
                            "options": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": {"type": "string"},
                                        "description": {"type": "string"},
                                    },
                                    "required": ["label"],
                                },
                            },
                        },
                        "required": ["question"],
                    },
                    "minItems": 1,
                }
            },
            "required": ["questions"],
            "additionalProperties": False,
        },
    },
]


def execute_tool(
    name: str,
    tool_input: dict[str, Any],
    env: FrozenEnvironment,
) -> str:
    if name == "Read":
        return env.read(
            str(tool_input.get("file_path", "")),
            int(tool_input.get("offset", 1)),
            int(tool_input.get("limit", 400)),
        )

    if name == "Glob":
        return env.glob(
            str(tool_input.get("pattern", "")),
            tool_input.get("path"),
        )

    if name == "Grep":
        return env.grep(
            str(tool_input.get("pattern", "")),
            tool_input.get("path"),
            tool_input.get("glob"),
        )

    if name == "Skill":
        return env.skill(
            str(tool_input.get("skill", "")),
            tool_input.get("args"),
        )

    if name == "AskUserQuestion":
        questions = tool_input.get("questions")
        if not isinstance(questions, list):
            raise RuntimeError("AskUserQuestion.questions must be a list")

        answers: list[dict[str, str]] = []
        for idx, question in enumerate(questions, 1):
            if not isinstance(question, dict):
                continue

            header = question.get("header")
            prompt = str(question.get("question", "")).strip()
            options = question.get("options")

            print()
            print(f"[Question {idx}] {header or ''}".rstrip())
            print(prompt)

            if isinstance(options, list):
                for n, option in enumerate(options, 1):
                    if not isinstance(option, dict):
                        continue
                    label = option.get("label", "")
                    desc = option.get("description", "")
                    print(f"  {n}. {label}" + (f" — {desc}" if desc else ""))

            answer = input("you> ").strip()
            answers.append({"question": prompt, "answer": answer})

        return json.dumps({"answers": answers}, ensure_ascii=False)

    raise RuntimeError(f"unsupported tool: {name}")


# ---------------------------------------------------------------------------
# Run logging
# ---------------------------------------------------------------------------

class RunLog:
    def __init__(self, run_dir: Path, metadata: dict[str, Any]) -> None:
        self.run_dir = run_dir
        self.run_dir.mkdir(parents=True, exist_ok=False)

        self.metadata = metadata
        self.events: list[dict[str, Any]] = []
        self.visible_turns: list[tuple[str, str]] = []

    def event(self, kind: str, **payload: Any) -> None:
        item = {"timestamp": utc_now(), "kind": kind, **payload}
        self.events.append(item)
        self.flush()

    def visible(self, role: str, text: str) -> None:
        if text.strip():
            self.visible_turns.append((role, text))
            self.flush()

    def set(self, key: str, value: Any) -> None:
        self.metadata[key] = value
        self.flush()

    def flush(self) -> None:
        with (self.run_dir / "run.json").open("w", encoding="utf-8") as f:
            json.dump(self.metadata, f, ensure_ascii=False, indent=2)
            f.write("\n")

        with (self.run_dir / "transcript.jsonl").open("w", encoding="utf-8") as f:
            for item in self.events:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")

        with (self.run_dir / "conversation.md").open("w", encoding="utf-8") as f:
            f.write("# Replay conversation\n\n")
            for role, text in self.visible_turns:
                title = "User" if role == "user" else "Assistant"
                f.write(f"## {title}\n\n{text.strip()}\n\n")

    def finish(self, status: str, error: str | None = None) -> None:
        self.metadata["ended_at"] = utc_now()
        self.metadata["status"] = status
        if error:
            self.metadata["error"] = error
        self.flush()


# ---------------------------------------------------------------------------
# API loop
# ---------------------------------------------------------------------------

def assistant_visible_text(content_blocks: list[dict[str, Any]]) -> str:
    texts: list[str] = []
    for block in content_blocks:
        if block.get("type") == "text":
            text = block.get("text")
            if isinstance(text, str):
                texts.append(text)
    return "\n".join(texts)


def tool_uses(content_blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [x for x in content_blocks if x.get("type") == "tool_use"]


def make_system_prompt(
    recovered_context: str,
    env: FrozenEnvironment,
    environment_available: bool,
) -> str:
    adapter = f"""You are operating inside a Claude Code-like replay harness.

Historical virtual cwd: {env.virtual_cwd}

The workspace is read-only. Use Read, Glob, Grep, and Skill when useful.
AskUserQuestion is available when you genuinely need clarification from the user.
Do not assume file contents you have not read.

This is a normal working conversation. Respond to the user's actual task rather
than discussing the replay machinery unless the user asks about it.
"""

    if not environment_available:
        adapter += """
The frozen filesystem/skill bundle is not available in this run. Read/Glob/Grep/Skill
may therefore return an unavailable error. Do not invent missing file contents.
"""

    if recovered_context.strip():
        adapter += "\n\n--- Recovered harness context ---\n\n" + recovered_context.strip()

    return adapter


def api_turn(
    client: Any,
    args: argparse.Namespace,
    system: str,
    messages: list[dict[str, Any]],
    env: FrozenEnvironment,
    runlog: RunLog,
    actual_models: set[str],
) -> None:
    while True:
        request_kwargs: dict[str, Any] = {
            "model": args.model,
            "max_tokens": args.max_tokens,
            "system": system,
            "messages": messages,
            "tools": TOOLS,
            "tool_choice": {"type": "auto"},
            "output_config": {"effort": args.effort},
        }

        runlog.event(
            "api_request",
            model=args.model,
            effort=args.effort,
            message_count=len(messages),
            messages_sha256=sha256_bytes(json_dump(messages).encode("utf-8")),
        )

        try:
            response = client.messages.create(**request_kwargs)
        except TypeError as exc:
            # Older anthropic SDKs may not yet type output_config.
            # Retry through extra_body while keeping the same wire intent.
            if "output_config" not in str(exc):
                raise
            request_kwargs.pop("output_config", None)
            request_kwargs["extra_body"] = {"output_config": {"effort": args.effort}}
            response = client.messages.create(**request_kwargs)

        raw = message_to_dict(response)
        response_model = raw.get("model")
        if isinstance(response_model, str):
            actual_models.add(response_model)

        content = [block_to_dict(x) for x in getattr(response, "content", [])]
        messages.append({"role": "assistant", "content": content})

        runlog.event(
            "assistant_api_message",
            message=raw,
        )

        visible = assistant_visible_text(content)
        if visible.strip():
            print()
            print("assistant>")
            print(visible)
            runlog.visible("assistant", visible)

        calls = tool_uses(content)
        if not calls:
            return

        tool_results: list[dict[str, Any]] = []

        for call in calls:
            tool_name = str(call.get("name", ""))
            tool_input = call.get("input")
            if not isinstance(tool_input, dict):
                tool_input = {}

            print()
            print(f"[tool] {tool_name} {json.dumps(tool_input, ensure_ascii=False)}")
            runlog.event("tool_call", name=tool_name, input=tool_input, id=call.get("id"))

            try:
                result = execute_tool(tool_name, tool_input, env)
                is_error = False
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                result = f"ERROR: {exc}"
                is_error = True

            # Keep terminal output manageable while preserving full result in log.
            preview = result
            if len(preview) > 6000:
                preview = preview[:6000] + "\n... [tool output truncated in terminal]"
            print(preview)

            runlog.event(
                "tool_result",
                name=tool_name,
                id=call.get("id"),
                result=result,
                is_error=is_error,
            )

            tool_results.append(
                {
                    "type": "tool_result",
                    "tool_use_id": call.get("id"),
                    "content": result,
                    "is_error": is_error,
                }
            )

        messages.append({"role": "user", "content": tool_results})


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interactive moment replay against DeepSeek Anthropic-compatible API."
    )
    parser.add_argument("--moment", choices=tuple(f"M{i:02d}" for i in range(1, 7)), default="M01",
                        help="Historical fork to replay (default: M01)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Save the exact initial API payload for offline inspection; no API key needed")
    parser.add_argument(
        "--packet",
        type=Path,
        default=None,
        help="Explicit packet directory; overrides --moment",
    )
    parser.add_argument(
        "--environment",
        type=Path,
        default=None,
        help="Frozen environment directory (default: <packet>/environment)",
    )
    parser.add_argument(
        "--model",
        default="deepseek-flash",
        help="DeepSeek model id, e.g. deepseek-flash or deepseek-v4-pro",
    )
    parser.add_argument(
        "--base-url",
        default=DEFAULT_BASE_URL,
        help="Anthropic-compatible API base URL",
    )
    parser.add_argument(
        "--api-key-env",
        default="DEEPSEEK_API_KEY",
        help="Environment variable containing the API key",
    )
    parser.add_argument(
        "--start-round",
        type=int,
        default=1,
        help=(
            "1 = original seed; N>1 = replay historical prefix through the Nth "
            "direct human user message, then hand control to the candidate"
        ),
    )
    parser.add_argument(
        "--list-rounds",
        action="store_true",
        help="List detected direct-human replay points and exit without API calls",
    )
    parser.add_argument(
        "--check-environment",
        action="store_true",
        help="Verify frozen resources offline and exit without an API key",
    )
    parser.add_argument(
        "--effort",
        choices=("low", "high", "max"),
        default="high",
        help="DeepSeek thinking effort",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=32768,
        help="Maximum output tokens per API call",
    )
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=Path("runs"),
        help="Directory for run outputs",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.start_round < 1:
        raise RuntimeError("--start-round must be >= 1")

    packet_dir = (args.packet or Path("replay_packets/moments") / args.moment).resolve()
    packet_path = packet_dir / "packet.json"
    if not packet_path.exists():
        raise RuntimeError(f"packet not found: {packet_path}")

    packet = load_json(packet_path)

    moment_id = packet.get("moment_id")
    if moment_id not in {f"M{i:02d}" for i in range(1, 7)}:
        raise RuntimeError("unsupported moment_id")

    component_paths = validate_packet_paths(packet_dir, packet)

    conversation_events = load_jsonl(component_paths["conversation"])
    pre_response_events = load_jsonl(component_paths["pre_response"])
    base_messages = canonical_messages(conversation_events)

    if not base_messages or base_messages[-1].get("role") != "user":
        raise RuntimeError("canonical projection does not end in a user message")

    historical_records: list[dict[str, Any]] = []
    historical_path = packet_dir / "historical" / "continuation.jsonl"

    # Intentional exception to input isolation:
    # historical data is opened only for explicit round listing or N>1 replay.
    if args.list_rounds or args.start_round > 1:
        if not historical_path.exists():
            raise RuntimeError(
                "historical continuation is required for --list-rounds/--start-round > 1"
            )
        historical_records = load_jsonl(historical_path)

    if args.list_rounds:
        rounds = list_replay_rounds(base_messages, historical_records)
        for item in rounds:
            text = item["text"].replace("\n", " ").strip()
            if len(text) > 300:
                text = text[:300] + "..."
            when = f" [{item['timestamp']}]" if item["timestamp"] else ""
            print(f"{item['round']:>2}{when}: {text}")
        return 0

    history_prefix, selected_record_count = build_historical_prefix(
        historical_records,
        args.start_round,
    )

    messages, exchange_warnings = repair_tool_exchanges(base_messages + history_prefix)

    recovered_context, adapter_warnings = extract_injected_system_context(
        conversation_events,
        pre_response_events,
    )

    adapter_warnings.extend(exchange_warnings)
    workspace = load_json(component_paths["workspace"])
    fallback_cwd = None
    for obs in workspace.get("runtime_observations", []):
        if isinstance(obs, dict) and obs.get("name") == "cwd":
            details = obs.get("details")
            if isinstance(details, dict) and isinstance(details.get("value"), str):
                fallback_cwd = details["value"]

    env_dir = args.environment
    if env_dir is None:
        env_dir = packet_dir / "environment"

    env = FrozenEnvironment(
        env_dir if env_dir.exists() else None,
        fallback_cwd,
    )

    if not env.available:
        adapter_warnings.append(
            f"Frozen environment bundle not found at {env_dir}. "
            "Read/Glob/Grep/Skill are lower-fidelity/unavailable."
        )

    if env.available and env.manifest.get("resource_inventory_sha256"):
        from validate_replay_environment import validate
        environment_report = validate(env_dir, packet_dir)
        if args.check_environment:
            print(json.dumps(environment_report, ensure_ascii=False, indent=2))
            return 0
    elif args.check_environment:
        raise RuntimeError("No verifiable environment manifest found")

    system = make_system_prompt(recovered_context, env, env.available)

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    safe_model = re.sub(r"[^A-Za-z0-9_.-]+", "_", args.model)
    run_dir = args.runs_dir / moment_id / f"{timestamp}-{safe_model}-r{args.start_round}"

    script_hash = None
    try:
        script_hash = sha256_file(Path(__file__).resolve())
    except Exception:
        pass

    metadata = {
        "adapter_version": ADAPTER_VERSION,
        "moment_id": moment_id,
        "started_at": utc_now(),
        "status": "running",
        "packet_dir": str(packet_dir),
        "packet_sha256": packet.get("integrity", {}).get("packet_sha256"),
        "input_sha256": packet.get("integrity", {}).get("input_sha256"),
        "environment_dir": str(env_dir),
        "environment_available": env.available,
        "environment_sha256": env.environment_hash(),
        "environment_recovery": env.manifest.get("recovery"),
        "environment_commit": env.manifest.get("repository", {}).get("commit"),
        "resource_inventory_sha256": env.manifest.get("resource_inventory_sha256"),
        "historical_fidelity": packet.get("recovery", {}).get("status"),
        "start_round": args.start_round,
        "historical_prefix_records": selected_record_count,
        "historical_prefix_used": args.start_round > 1,
        "requested_model": args.model,
        "returned_models": [],
        "base_url": args.base_url,
        "effort": args.effort,
        "max_tokens": args.max_tokens,
        "script_sha256": script_hash,
        "warnings": adapter_warnings,
        "projection": "canonical text + tool exchanges; thinking removed; edited-file observations preserved",
    }

    runlog = RunLog(run_dir, metadata)
    actual_models: set[str] = set()
    initial_request = {
        "model": args.model, "max_tokens": args.max_tokens, "system": system,
        "messages": messages, "tools": TOOLS, "tool_choice": {"type": "auto"},
        "output_config": {"effort": args.effort},
    }
    request_bytes = (json.dumps(initial_request, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    (run_dir / "initial_request.json").write_bytes(request_bytes)
    runlog.set("initial_request_sha256", sha256_bytes(request_bytes))

    # Record fixed starting state separately from candidate-generated turns.
    runlog.event(
        "replay_start",
        start_round=args.start_round,
        canonical_message_count=len(base_messages),
        historical_prefix_message_count=len(history_prefix),
        effective_message_count=len(messages),
        system_projection=system,
    )

    # Add visible historical/user transcript for easier inspection.
    for msg in messages:
        visible = text_from_content(msg.get("content"))
        if visible.strip():
            runlog.visible(msg["role"], visible)

    print(f"Run: {run_dir}")
    print(f"Model requested: {args.model}")
    print(f"Start round: {args.start_round}")
    print(f"Frozen environment: {'yes' if env.available else 'NO'}")
    print("Ctrl+C to stop and save.")
    print()

    if args.model == "deepseek-v4-pro":
        print(
            "[note] Verify run.json returned_models: current DeepSeek routing may "
            "resolve a requested model differently."
        )
        print()

    if args.dry_run:
        runlog.finish("dry_run")
        print("Initial request saved (no API call):", run_dir / "initial_request.json")
        return 0

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        raise RuntimeError(
            f"API key not found. Set environment variable {args.api_key_env}."
        )

    try:
        import anthropic
    except ImportError as exc:
        raise RuntimeError(
            "Missing dependency: pip install -U anthropic"
        ) from exc

    client = anthropic.Anthropic(
        api_key=api_key,
        base_url=args.base_url,
        max_retries=2,
        timeout=600.0,
    )

    try:
        # Candidate begins immediately after the selected replay point.
        api_turn(
            client,
            args,
            system,
            messages,
            env,
            runlog,
            actual_models,
        )

        while True:
            print()
            user_text = input("you> ")
            if not user_text.strip():
                continue

            messages.append(
                {
                    "role": "user",
                    "content": [{"type": "text", "text": user_text}],
                }
            )
            runlog.event("live_user_message", text=user_text)
            runlog.visible("user", user_text)

            api_turn(
                client,
                args,
                system,
                messages,
                env,
                runlog,
                actual_models,
            )

    except KeyboardInterrupt:
        print()
        print("Interrupted. Saving run...")
        runlog.set("returned_models", sorted(actual_models))
        runlog.finish("interrupted")
        print(f"Saved: {run_dir}")
        return 130

    except Exception as exc:
        runlog.set("returned_models", sorted(actual_models))
        runlog.event(
            "runner_error",
            error=str(exc),
            traceback=traceback.format_exc(),
        )
        runlog.finish("error", str(exc))
        print()
        print(f"ERROR: {exc}", file=sys.stderr)
        print(f"Partial run saved: {run_dir}", file=sys.stderr)
        return 1

    finally:
        # If the process exits by EOF rather than Ctrl+C, preserve metadata.
        if runlog.metadata.get("status") == "running":
            runlog.set("returned_models", sorted(actual_models))
            runlog.finish("ended")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
