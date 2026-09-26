---
name: AFF format reference implementations
description: Open-source projects that parse Arcaea .aff chart files, for cross-referencing during parser development
type: reference
originSessionId: a780326b-5d47-480b-a9d5-aa307232131a
---
Primary reference for AFF parsing:
- **ArcCreate** (github.com/Arcthesia/ArcCreate) — C#/Unity, most complete parser. Code at `Assets/Scripts/ChartFormat/Aff/`
- **vscode-arcaea-file-format** (github.com/yojohanshinwataikei/vscode-arcaea-file-format) — TypeScript, syntax + semantic validation
- **ArcaeaChartRender** (github.com/Arcaea-Infinity/ArcaeaChartRender) — Python parser/renderer
- **aff-compose** (github.com/Arcaea-Infinity/aff-compose) — Kotlin DSL

Full format spec saved in project at `docs/aff-format.md`.

AFF has version-dependent features (lanes 0/5, arctap width, smoothness param) — online docs may be outdated. ArcCreate parser and reverse engineering of the game binary are the most reliable sources.
