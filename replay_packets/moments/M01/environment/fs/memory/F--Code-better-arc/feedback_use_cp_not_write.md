---
name: Use cp for files with a source origin
description: Any file that has an existing source (ArcCreate repo, etc.) must be copied with bash cp, never recreated via Write tool
type: feedback
originSessionId: 98c699ae-3974-485f-b247-9fbb1e970456
---
Files with an existing source must be copied with `cp`, never recreated with the Write tool.

**Why:** Using Write to recreate a file that has a source means the agent is "understanding and rewriting" rather than truly copying. Only `cp` guarantees byte-identical results.

**How to apply:** ArcCreate source files → always `cp` from `ArcCreate/Assets/Scripts/`. Shim files (new code with no source) → Write/Edit tools are fine.
