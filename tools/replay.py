#!/usr/bin/env python3
"""Interactive historical replay through OpenRouter or DeepSeek Messages HTTP.

python tools/replay.py --moment M01 --model anthropic/claude-opus-4.6 --provider anthropic
python tools/replay.py --moment M05 --start-round 2 --dry-run

Frozen resources are read-only; research answers/provenance are not mounted.
Ctrl+C saves the interaction and full tool trace. No automatic retries.
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
import uuid
from urllib.parse import urlsplit
from pathlib import Path
from typing import Any, Iterable
from harness_profiles import available_profiles, load_profile, read_manifest

ADAPTER_VERSION = "ember-messages-http-v3.3.1"
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASE_URL = "https://openrouter.ai/api"
GATEWAYS = {
    "openrouter": (DEFAULT_BASE_URL, "OPENROUTER_API_KEY", "anthropic/claude-opus-4.6"),
    "deepseek": ("https://api.deepseek.com/anthropic", "DEEPSEEK_API_KEY", "deepseek-flash"),
}

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


def replace_last_user_text(messages: list[dict[str, Any]], text: str) -> None:
    """Replace the anchor text, preserving observations merged into the user turn."""
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if not isinstance(content, list):
            raise RuntimeError("final user message has invalid content")
        for index in range(len(content) - 1, -1, -1):
            if content[index].get("type") == "text":
                content[index] = {"type": "text", "text": text}
                return
        raise RuntimeError("final user message has no anchor text to override")
    raise RuntimeError("replay has no user message to override")


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


def canonical_messages(
    conversation_events: list[dict[str, Any]], replay_mode: str = "faithful",
) -> list[dict[str, Any]]:
    """Preserve pre-anchor text AND tool exchanges, without hidden thinking."""
    messages: list[dict[str, Any]] = []
    for event in conversation_events:
        if event.get("kind") == "context_observation":
            payload = event.get("payload", {})
            if payload.get("type") == "edited_text_file":
                text = ("<system-reminder>\nObserved file change: "
                        + str(payload.get("filename", "")) + "\n"
                        + str(payload.get("snippet", "")) + "\n</system-reminder>")
                if replay_mode == "semantic":
                    text = text.replace("<system-reminder>\n", "").replace("\n</system-reminder>", "")
                messages.append({"role": "user", "content": [{"type": "text", "text": text}]})
            continue
        if event.get("kind") != "message" or event.get("speaker") not in ("user", "assistant"):
            continue
        if replay_mode == "semantic" and event.get("is_meta"):
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
    replay_mode: str = "faithful",
) -> dict[str, Any] | None:
    record = record_wrapper.get("record", {})
    if replay_mode == "semantic" and (
        record.get("isMeta") or record.get("sourceToolUseID") is not None
    ):
        return None
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
    replay_mode: str = "faithful",
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
        msg = historical_record_to_api_message(wrapper, replay_mode)
        if msg is not None:
            messages.append(msg)

    return merge_consecutive_roles(messages), len(selected)


# Version this policy separately from transport: projection changes affect experiments.
SEMANTIC_PROJECTION_VERSION = "semantic-v1"
PROCESS_TOOLS = {
    "Skill", "TodoWrite", "TodoRead", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
    "ToolSearch", "EnterPlanMode", "ExitPlanMode",
}


def is_skill_read(call: dict[str, Any]) -> bool:
    if call.get("name") != "Read":
        return False
    path = str(call.get("input", {}).get("file_path", "")).replace("\\", "/").lower()
    return path.endswith("/skill.md") or path == "skill.md" or "/skills/" in path


def strip_process_reminders(text: str) -> str:
    """Remove harness-tagged reminders, not ordinary prose mentioning skills."""
    return re.sub(r"<system-reminder\b[^>]*>.*?</system-reminder>", "", text,
                  flags=re.DOTALL | re.IGNORECASE)


def question_text(call: dict[str, Any]) -> str:
    """Retain what the human saw, including choices needed to interpret short answers."""
    parts = []
    for question in call.get("input", {}).get("questions", []):
        parts.append(str(question.get("question", "")))
        for index, option in enumerate(question.get("options", []), 1):
            label = str(option.get("label", ""))
            description = str(option.get("description", ""))
            parts.append(f"{index}. {label}" + (f" — {description}" if description else ""))
    return "\n".join(parts)


def answer_text(content: Any) -> str:
    text = text_from_content(content)
    # These are transport wrappers; the quoted question/answer pairs remain verbatim.
    text = re.sub(r"^(?:User has answered your questions|Your questions have been answered):\s*", "", text)
    text = re.sub(r"\. You can now continue with (?:the user's|these) answers in mind\.$", "", text)
    return text


def semantic_messages(messages: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """Remove historical workflow instructions; preserve task evidence and human choices.

    Factual tool exchanges remain paired, with their original payloads. This is an
    explicit projection, not a paraphrase or an assertion that the old dialogue was
    generated without skills. Live tools and frozen resources are unchanged.
    """
    calls = {b["id"]: b for m in messages for b in m["content"] if b.get("type") == "tool_use"}
    removed = {key for key, call in calls.items()
               if call.get("name") in PROCESS_TOOLS or is_skill_read(call)}
    stats = {"removed_process_blocks": 0, "removed_reminders": 0, "question_blocks_to_text": 0}
    projected = []
    for message in messages:
        blocks = []
        for block in message["content"]:
            kind = block.get("type")
            call_id = block.get("id") if kind == "tool_use" else block.get("tool_use_id")
            if kind in ("tool_use", "tool_result") and call_id in removed:
                stats["removed_process_blocks"] += 1
                continue
            if kind == "tool_use" and block.get("name") == "AskUserQuestion":
                text = question_text(block)
                stats["question_blocks_to_text"] += 1
            elif kind == "tool_result" and (
                calls.get(call_id, {}).get("name") == "AskUserQuestion"
                or text_from_content(block.get("content")).startswith((
                    "User has answered your questions:", "Your questions have been answered:",
                ))
            ):
                text = answer_text(block.get("content"))
                stats["question_blocks_to_text"] += 1
            elif kind == "text":
                text = str(block.get("text", ""))
                if message["role"] == "user":
                    cleaned = strip_process_reminders(text)
                    stats["removed_reminders"] += int(cleaned != text)
                    text = cleaned
            elif kind == "tool_result":
                # Handle orphan skill results from incomplete archives as well.
                text = text_from_content(block.get("content"))
                if text.startswith(("Launching skill:", "Base directory for this skill:")):
                    stats["removed_process_blocks"] += 1
                    continue
                blocks.append(block)
                continue
            else:
                blocks.append(block)
                continue
            if text.strip():
                blocks.append({"type": "text", "text": text})
        if blocks:
            projected.append({"role": message["role"], "content": blocks})
    return merge_consecutive_roles(projected), stats


def semantic_catalog(env: FrozenEnvironment) -> str:
    # Historical descriptions contain commands (including MUST). Expose resource
    # names only, and let the candidate choose whether to load a skill at runtime.
    if not env.skill_index:
        return ""
    return "Optional skill resources (load by name with Skill when useful):\n" + "\n".join(
        "- " + name for name in sorted(env.skill_index)
    )


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


def tools_for_profile(profile: str) -> list[dict[str, Any]]:
    if profile == "full":
        return TOOLS
    if profile == "files-only":
        allowed = {"Read", "Glob", "Grep"}
        return [tool for tool in TOOLS if tool["name"] in allowed]
    raise RuntimeError(f"unknown tool profile: {profile}")


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
    profile_text: str | None = None,
    tool_profile: str = "full",
) -> str:
    if profile_text is None:
        profile_text = (ROOT / "harnesses/minimal.md").read_text(encoding="utf-8")
    adapter = profile_text.replace("{env.virtual_cwd}", env.virtual_cwd)

    if tool_profile == "files-only":
        adapter = adapter.replace(
            "Use Read, Glob, Grep, and Skill when useful.",
            "Use Read, Glob, and Grep when useful.",
        )
        adapter = adapter.replace(
            "AskUserQuestion is available when you genuinely need clarification from the user.\n",
            "",
        )
        # Named profiles share this runtime paragraph. Adapt the rendered prompt,
        # leaving the pinned source files and their provenance untouched.
        adapter = adapter.replace(
            "The workspace is read-only. The only callable tools are Read, Glob, Grep, Skill,\n"
            "and AskUserQuestion, with the schemas supplied in this session. Read opens files;\n"
            "Glob finds paths; Grep searches file contents. Skill loads optional skill resources.\n"
            "AskUserQuestion obtains live answers from the user.",
            "The workspace is read-only. The only callable tools are Read, Glob, and Grep,\n"
            "with the schemas supplied in this session. Read opens files; Glob finds paths;\n"
            "Grep searches file contents.",
        )
        adapter += (
            "\n\nTool boundary for this run: only Read, Glob, and Grep are available. "
            "Do not assume Skill, AskUserQuestion, shell, or write tools exist."
        )

    if not environment_available:
        adapter += """
The frozen filesystem/skill bundle is not available in this run. Read/Glob/Grep/Skill
may therefore return an unavailable error. Do not invent missing file contents.
"""

    if recovered_context.strip():
        adapter += "\n\n--- Recovered harness context ---\n\n" + recovered_context.strip()

    return adapter


def messages_endpoint(base_url: str) -> str:
    if base_url.endswith("/messages"):
        return base_url
    if base_url.endswith("/v1"):
        return base_url + "/messages"
    return base_url + "/v1/messages"


def request_headers(args: argparse.Namespace, api_key: str) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    if args.gateway == "openrouter":
        headers["X-OpenRouter-Metadata"] = "enabled"
    else:
        headers["anthropic-version"] = "2023-06-01"
    return headers


def encode_request(request: dict[str, Any]) -> bytes:
    return (json.dumps(request, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def build_request(args: argparse.Namespace, system: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    request = {
        "model": args.model,
        "max_tokens": args.max_tokens,
        "system": system,
        "messages": messages,
        "tools": tools_for_profile(args.tool_profile),
        "tool_choice": {"type": "auto"},
    }
    if args.effort != "default":
        request["output_config"] = {"effort": args.effort}
    if args.temperature is not None:
        request["temperature"] = args.temperature
    if args.top_p is not None:
        request["top_p"] = args.top_p
    if args.cache_input:
        # Automatic caching advances the breakpoint as the conversation grows.
        request["cache_control"] = {"type": "ephemeral", "ttl": "5m"}
    if args.gateway == "openrouter":
        provider = {"allow_fallbacks": args.allow_provider_fallbacks, "require_parameters": True}
        if args.provider:
            # An allow-list would prevent fallback even if allow_fallbacks=True.
            key = "order" if args.allow_provider_fallbacks else "only"
            provider[key] = [args.provider]
        request["provider"] = provider
        request["session_id"] = args.session_id
    return request


def send_request(client: Any, args: argparse.Namespace, request: dict[str, Any], runlog: RunLog) -> dict[str, Any]:
    body = encode_request(request)
    call_number = runlog.metadata.get("api_call_count", 0) + 1
    runlog.metadata["api_call_count"] = call_number
    # Snapshot the body: messages will be mutated by the subsequent tool loop.
    runlog.event("api_request", call=call_number, endpoint=args.endpoint,
                 request=json.loads(body), request_sha256=sha256_bytes(body))
    response = client.post(args.endpoint, content=body)
    response_bytes = response.content
    response_dir = runlog.run_dir / "responses"
    response_dir.mkdir(exist_ok=True)
    response_path = response_dir / f"{call_number:04d}.body"
    response_path.write_bytes(response_bytes)
    try:
        raw = response.json()
    except ValueError:
        raw = None
    if call_number == 1 and raw is not None:
        (runlog.run_dir / "initial_response.json").write_bytes(response_bytes)
    runlog.event("api_response", call=call_number, status_code=response.status_code,
                 body_file=response_path.relative_to(runlog.run_dir).as_posix(),
                 body_sha256=sha256_bytes(response_bytes), response=raw)
    if response.status_code < 200 or response.status_code >= 300:
        raise RuntimeError(f"Messages API HTTP {response.status_code}; see responses/{call_number:04d}.body")
    if not isinstance(raw, dict) or raw.get("error") or raw.get("type") == "error":
        raise RuntimeError("Messages API returned an error or non-object JSON; see saved response")
    content = raw.get("content")
    if raw.get("role") != "assistant" or not isinstance(content, list) or not content:
        raise RuntimeError("Invalid Messages response: expected assistant content blocks")
    if any(not isinstance(block, dict) or not isinstance(block.get("type"), str) for block in content):
        raise RuntimeError("Invalid Messages response: malformed content block")
    calls = tool_uses(content)
    ids = [call.get("id") for call in calls]
    if any(not isinstance(value, str) or not value for value in ids) or len(set(ids)) != len(ids):
        raise RuntimeError("Invalid Messages response: missing or duplicate tool IDs")
    if any(not isinstance(call.get("name"), str) or not isinstance(call.get("input"), dict) for call in calls):
        raise RuntimeError("Invalid Messages response: malformed tool call")
    if raw.get("stop_reason") == "tool_use" and not calls:
        raise RuntimeError("Invalid Messages response: tool_use stop without tools")
    return raw


def record_routing(raw: dict[str, Any], args: argparse.Namespace, runlog: RunLog) -> None:
    metadata = raw.get("openrouter_metadata")
    metadata = metadata if isinstance(metadata, dict) else {}
    endpoints = metadata.get("endpoints")
    endpoints = endpoints if isinstance(endpoints, dict) else {}
    available = endpoints.get("available", [])
    available = available if isinstance(available, list) else []
    selected = [item for item in available if isinstance(item, dict) and item.get("selected") is True]
    providers = {item["provider"] for item in selected if isinstance(item.get("provider"), str)}
    if isinstance(raw.get("provider"), str):
        providers.add(raw["provider"])
    observation = {
        "call": runlog.metadata["api_call_count"],
        "response_id": raw.get("id"),
        "returned_model": raw.get("model"),
        "resolved_providers": sorted(providers),
        "metadata_present": bool(metadata),
        "pipeline": metadata.get("pipeline", []),
    }
    runlog.metadata.setdefault("routing_observations", []).append(observation)
    previous = set(runlog.metadata.get("resolved_providers", []))
    runlog.metadata["resolved_providers"] = sorted(previous | providers)
    if args.gateway == "openrouter" and not providers:
        warning = "Actual provider unavailable in at least one response; requested routing is not verification."
        warnings = runlog.metadata.setdefault("warnings", [])
        if warning not in warnings:
            warnings.append(warning)
            print(f"[warning] {warning}")
    if metadata.get("pipeline"):
        warning = "Router pipeline stages reported; review routing_observations before comparing this run."
        warnings = runlog.metadata.setdefault("warnings", [])
        if warning not in warnings:
            warnings.append(warning)
            print(f"[warning] {warning}")
    runlog.flush()


def api_turn(
    client: Any,
    args: argparse.Namespace,
    system: str,
    messages: list[dict[str, Any]],
    env: FrozenEnvironment,
    runlog: RunLog,
    actual_models: set[str],
) -> None:
    allowed_tools = {tool["name"] for tool in tools_for_profile(args.tool_profile)}
    while True:
        request = build_request(args, system, messages)
        raw = send_request(client, args, request, runlog)
        response_model = raw.get("model")
        if isinstance(response_model, str):
            actual_models.add(response_model)
        runlog.set("returned_models", sorted(actual_models))
        record_routing(raw, args, runlog)

        content = raw["content"]
        messages.append({"role": "assistant", "content": content})
        runlog.event("assistant_api_message", message=raw)

        visible = assistant_visible_text(content)
        if visible.strip():
            print()
            print("assistant>")
            print(visible)
            runlog.visible("assistant", visible)

        if raw.get("stop_reason") in {"max_tokens", "model_context_window_exceeded"}:
            raise RuntimeError(f"Incomplete assistant response: {raw['stop_reason']}; saved without executing tools")
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
                if tool_name not in allowed_tools:
                    raise RuntimeError(
                        f"tool {tool_name!r} is unavailable in tool profile {args.tool_profile!r}"
                    )
                result = execute_tool(tool_name, tool_input, env)
                is_error = False
            except (KeyboardInterrupt, EOFError):
                raise
            except Exception as exc:
                result = f"ERROR: {exc}"
                is_error = True

            # Limit terminal previews by both lines and characters; keep the
            # full result for the model and the archived transcript.
            preview = "".join(result.splitlines(keepends=True)[:8])[:800]
            if len(preview) < len(result):
                preview = preview.rstrip() + "\n... [tool output truncated in terminal]"
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

def parse_args(argv: list[str] | None = None, default_gateway: str = "openrouter") -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interactive moment replay through an Anthropic Messages HTTP endpoint."
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
        default=None,
        help="Model ID (OpenRouter: vendor/model slug)",
    )
    parser.add_argument(
        "--base-url",
        default=None,
        help="API base URL (appends /v1/messages), or full /messages endpoint",
    )
    parser.add_argument(
        "--api-key-env",
        default=None,
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
        choices=("default", "low", "medium", "high", "max", "xhigh"),
        default=None,
        help="default omits output_config entirely; other values depend on model support",
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
    parser.add_argument("--gateway", choices=tuple(GATEWAYS), default=default_gateway)
    parser.add_argument("--provider", help="OpenRouter provider slug to pin (e.g. anthropic)")
    parser.add_argument("--allow-provider-fallbacks", action="store_true",
                        help="Use provider as a preference instead of an allow-list; exploratory runs only")
    profiles = parser.add_mutually_exclusive_group()
    profiles.add_argument("--harness", choices=available_profiles(), default="minimal",
                          help="Select a pinned behavior profile (default: minimal)")
    profiles.add_argument("--system-prompt-file", type=Path,
                          help="Replace the harness scaffold; recovered context is still appended")
    parser.add_argument("--list-harnesses", action="store_true",
                        help="List built-in profiles and exit without API calls")
    parser.add_argument("--replay-mode", choices=("semantic", "faithful"), default="semantic",
                        help="semantic removes historical workflow injections (default); faithful preserves the previous projection")
    parser.add_argument("--temperature", type=float, default=None)
    parser.add_argument("--top-p", type=float, default=None,
                        help="Nucleus sampling probability; default uses provider/model configuration")
    parser.add_argument("--tool-profile", choices=("full", "files-only"), default="full",
                        help="Candidate tool surface: full (default) or read-only files-only")
    parser.add_argument("--user-prompt-file", type=Path,
                        help="Replace the final replay user turn with UTF-8 text from this file")
    parser.add_argument("--run-label",
                        help="Short experiment condition label included in the run directory name")
    parser.add_argument("--cache-input", action="store_true",
                        help="Enable 5-minute input caching for Claude via OpenRouter (default: off)")
    parser.add_argument("--timeout", type=float, default=600.0, help="HTTP timeout in seconds")
    args = parser.parse_args(argv)
    base_url, key_env, model = GATEWAYS[args.gateway]
    args.base_url = (args.base_url or base_url).rstrip("/")
    args.api_key_env = args.api_key_env or key_env
    args.model = args.model or model
    args.effort = args.effort or ("high" if args.gateway == "deepseek" else "default")
    if args.start_round < 1 or args.max_tokens < 1 or not (0 < args.timeout < float("inf")):
        parser.error("start-round, max-tokens and timeout must be positive")
    if args.temperature is not None and not 0 <= args.temperature <= 1:
        parser.error("Messages API temperature must be between 0 and 1")
    if args.top_p is not None and not 0 < args.top_p <= 1:
        parser.error("top-p must be greater than 0 and at most 1")
    if args.user_prompt_file is not None and not args.user_prompt_file.is_file():
        parser.error("user-prompt-file must point to an existing file")
    if args.run_label is not None and not args.run_label.strip():
        parser.error("run-label cannot be empty")
    if args.gateway != "openrouter" and (args.provider or args.allow_provider_fallbacks):
        parser.error("provider routing options require --gateway openrouter")
    if args.cache_input and (args.gateway != "openrouter" or not args.model.startswith("anthropic/")):
        parser.error("--cache-input requires a Claude model (anthropic/...) via --gateway openrouter")
    if args.provider is not None and not args.provider.strip():
        parser.error("provider cannot be empty")
    parsed = urlsplit(args.base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        parser.error("base-url must be an HTTP(S) URL without credentials, query or fragment")
    args.endpoint = messages_endpoint(args.base_url)
    return args


def _run_slug(value: str, limit: int = 48) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip()).strip("-._")
    return (value or "none")[:limit]


def _sampling_tag(value: float | None) -> str:
    if value is None:
        return "def"
    return f"{value:g}".replace(".", "p")


def run_directory_name(args: argparse.Namespace, timestamp: str) -> str:
    model = _run_slug(args.model.split("/")[-1])
    label_source = args.run_label
    if label_source is None and args.user_prompt_file is not None:
        label_source = args.user_prompt_file.stem
    label = _run_slug(label_source, 32) if label_source else None

    if args.gateway == "openrouter":
        if args.provider:
            route = _run_slug(args.provider, 24)
            if args.allow_provider_fallbacks:
                route += "-fallback"
            else:
                route += "-strict"
        else:
            route = "auto"
    else:
        route = _run_slug(args.gateway, 24)

    harness = "custom" if args.system_prompt_file else _run_slug(args.harness, 32)
    mode = "sem" if args.replay_mode == "semantic" else "faith"
    tools = "files" if args.tool_profile == "files-only" else "full"

    parts = [timestamp]
    if label:
        parts.append(label)
    parts.extend([
        model,
        route,
        harness,
        f"r{args.start_round}-{mode}",
        f"e-{_run_slug(args.effort, 12)}",
        f"t-{_sampling_tag(args.temperature)}",
        f"p-{_sampling_tag(args.top_p)}",
        f"tools-{tools}",
    ])
    return "__".join(parts)


def main(argv: list[str] | None = None, default_gateway: str = "openrouter") -> int:
    args = parse_args(argv, default_gateway)

    if args.list_harnesses:
        print("minimal: original EMBER baseline (default)")
        for name, profile in read_manifest()["profiles"].items():
            print(f"{name}: {profile['description']}")
        return 0

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
    base_messages = canonical_messages(conversation_events, args.replay_mode)

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
        args.replay_mode,
    )

    messages = base_messages + history_prefix
    projection_stats = {}
    if args.replay_mode == "semantic":
        messages, projection_stats = semantic_messages(messages)
        projection_stats["removed_meta_records"] = (
            sum(bool(event.get("is_meta")) for event in conversation_events)
            + sum(bool(wrapper["record"].get("isMeta") or wrapper["record"].get("sourceToolUseID"))
                  for wrapper in historical_records[:selected_record_count])
        )
        recovered_context = ""
        adapter_warnings = [
            "Semantic projection removes historical workflow instructions, but visible historical "
            "dialogue may already reflect those workflows. Skills remain optional live resources."
        ]
    else:
        recovered_context, adapter_warnings = extract_injected_system_context(
            conversation_events, pre_response_events,
        )

    messages, exchange_warnings = repair_tool_exchanges(messages)

    user_prompt_text = None
    if args.user_prompt_file is not None:
        user_prompt_text = args.user_prompt_file.read_text(encoding="utf-8").strip()
        if not user_prompt_text:
            raise RuntimeError("user prompt override is empty")
        replace_last_user_text(messages, user_prompt_text)

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

    profile_path, profile_text, harness_provenance = load_profile(args.harness, args.system_prompt_file)
    if harness_provenance is not None and args.replay_mode == "faithful":
        adapter_warnings.append("Named behavior profile is mixed with recovered historical harness injections; use semantic for prompt-only comparisons.")
    if args.replay_mode == "semantic":
        recovered_context = semantic_catalog(env) if args.tool_profile == "full" else ""
    system = make_system_prompt(
        recovered_context,
        env,
        env.available,
        profile_text,
        tool_profile=args.tool_profile,
    )
    args.session_id = f"ember-{moment_id}-{uuid.uuid4().hex}"
    if args.gateway == "openrouter" and not (args.provider and not args.allow_provider_fallbacks):
        adapter_warnings.append("Provider is not pinned: exploratory routing, not a strict comparison.")

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    run_dir = args.runs_dir / moment_id / run_directory_name(args, timestamp)

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
        "replay_mode": args.replay_mode,
        "projection_version": SEMANTIC_PROJECTION_VERSION if args.replay_mode == "semantic" else "faithful-v1",
        "projection_stats": projection_stats,
        "historical_prefix_records": selected_record_count,
        "historical_prefix_used": args.start_round > 1,
        "requested_model": args.model,
        "returned_models": [],
        "base_url": args.base_url,
        "endpoint": args.endpoint,
        "gateway": args.gateway,
        "session_id": args.session_id,
        "requested_provider": args.provider,
        "resolved_providers": [],
        "routing_strict": bool(args.gateway == "openrouter" and args.provider and not args.allow_provider_fallbacks),
        "routing_observations": [],
        "provider_fallbacks": args.allow_provider_fallbacks if args.gateway == "openrouter" else None,
        "harness": "custom" if args.system_prompt_file else args.harness,
        "harness_file": str(profile_path.resolve()),
        "harness_sha256": sha256_bytes(profile_text.encode("utf-8")),
        "harness_provenance": harness_provenance,
        "system_sha256": sha256_bytes(system.encode("utf-8")),
        "tool_profile": args.tool_profile,
        "tool_names": [tool["name"] for tool in tools_for_profile(args.tool_profile)],
        "tools_sha256": sha256_bytes(json_dump(tools_for_profile(args.tool_profile)).encode("utf-8")),
        "temperature": args.temperature,
        "top_p": args.top_p,
        "run_label": args.run_label,
        "user_prompt_file": str(args.user_prompt_file.resolve()) if args.user_prompt_file else None,
        "user_prompt_sha256": (
            sha256_bytes(user_prompt_text.encode("utf-8")) if user_prompt_text is not None else None
        ),
        "timeout_seconds": args.timeout,
        "automatic_retries": 0,
        "effort": args.effort,
        "cache_input": args.cache_input,
        "cache_input_ttl": "5m" if args.cache_input else None,
        "max_tokens": args.max_tokens,
        "script_sha256": script_hash,
        "warnings": adapter_warnings,
        "projection": (
            "task dialogue + factual tool exchanges; workflow/meta injections removed; historical questions rendered as text"
            if args.replay_mode == "semantic" else
            "canonical text + tool exchanges; thinking removed; edited-file observations preserved"
        ),
    }

    runlog = RunLog(run_dir, metadata)
    if user_prompt_text is not None:
        # Store exactly the bytes hashed above and sent as the replacement text,
        # without platform newline translation or an extra trailing newline.
        (run_dir / "user_prompt.txt").write_bytes(user_prompt_text.encode("utf-8"))
    actual_models: set[str] = set()
    initial_request = build_request(args, system, messages)
    request_bytes = encode_request(initial_request)
    (run_dir / "initial_request.json").write_bytes(request_bytes)
    runlog.set("initial_request_sha256", sha256_bytes(request_bytes))

    # Record fixed starting state separately from candidate-generated turns.
    runlog.event(
        "replay_start",
        replay_mode=args.replay_mode,
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
    print(f"Replay mode: {args.replay_mode}")
    print(f"Harness: {metadata['harness']}")
    print(f"Tool profile: {args.tool_profile}")
    print(f"Sampling: effort={args.effort}, temperature={args.temperature}, top_p={args.top_p}")
    if args.run_label:
        print(f"Run label: {args.run_label}")
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

    client = None
    try:
        api_key = os.environ.get(args.api_key_env)
        if not api_key:
            raise RuntimeError(f"API key not found. Set environment variable {args.api_key_env}.")
        try:
            import httpx
        except ImportError as exc:
            raise RuntimeError("Missing dependency: pip install -r requirements-replay.txt") from exc
        client = httpx.Client(timeout=args.timeout, follow_redirects=False,
                              headers=request_headers(args, api_key))
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

    except EOFError:
        runlog.finish("ended")
        print(f"Saved: {run_dir}")
        return 0

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
        if client is not None:
            client.close()
        # If the process exits by EOF rather than Ctrl+C, preserve metadata.
        if runlog.metadata.get("status") == "running":
            runlog.set("returned_models", sorted(actual_models))
            runlog.finish("ended")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
