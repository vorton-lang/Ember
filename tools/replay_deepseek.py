#!/usr/bin/env python3
"""Backward-compatible DeepSeek CLI; implementation lives in replay.py."""
from replay import main

if __name__ == "__main__":
    raise SystemExit(main(default_gateway="deepseek"))
