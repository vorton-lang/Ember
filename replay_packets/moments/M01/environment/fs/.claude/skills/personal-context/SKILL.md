---
name: personal-context
description: Use when answering questions about the user (Yufeng Ying / 应宇峰) — personal background, career history, tech skills, investment strategy, FIRE goals, or cross-project development context. Also use when user says "about me", references their profile, or asks anything requiring personal context about who they are.
---

# Personal Context Lookup

The user maintains a structured context repository. Read it to answer personal questions accurately.

## Repository Location

```
f:\Code\Context
```

If this path doesn't exist, check the `PERSONAL_CONTEXT_REPO` environment variable.

## Lookup Procedure

```dot
digraph lookup {
    "Personal question?" [shape=doublecircle];
    "Read profile.md" [shape=box, style=filled, fillcolor="#c8e6c9"];
    "Enough?" [shape=diamond];
    "Done" [shape=doublecircle];
    "Need tech details?" [shape=diamond];
    "Read VDB/ docs" [shape=box];
    "Need financial details?" [shape=diamond];
    "Read financial/ scripts" [shape=box];
    "Need project history?" [shape=diamond];
    "Browse memory/" [shape=box];

    "Personal question?" -> "Read profile.md";
    "Read profile.md" -> "Enough?";
    "Enough?" -> "Done" [label="yes"];
    "Enough?" -> "Need tech details?" [label="no"];
    "Need tech details?" -> "Read VDB/ docs" [label="yes"];
    "Need tech details?" -> "Need financial details?" [label="no"];
    "Read VDB/ docs" -> "Need financial details?";
    "Need financial details?" -> "Read financial/ scripts" [label="yes"];
    "Need financial details?" -> "Need project history?" [label="no"];
    "Read financial/ scripts" -> "Need project history?";
    "Need project history?" -> "Browse memory/" [label="yes"];
    "Need project history?" -> "Done" [label="no"];
    "Browse memory/" -> "Done";
}
```

1. **Always start**: Read `profile.md` — covers 80%+ of questions (background, career, tech stack, investments, personality)
2. **GPU/CUDA details**: Read `VDB/VDB.md` and files under `VDB/交接文档/`
3. **Investment/FIRE planning**: Read Python scripts under `financial/` for methodology and parameters
4. **Cross-project history**: Browse `memory/<project-name>/MEMORY.md` indices

## Source Index

| Source | Content |
|--------|---------|
| `profile.md` | Full profile: 硕士毕业、思看科技GPU实习、FIRE规划、永久投资组合、技术栈、性格特征 |
| `VDB/` | GPU VDB sparse volume, TSDF fusion system (DeepFusionPoints), CUDA optimization |
| `financial/` | 哈利·布朗永久投资组合回测、FIRE退休模拟、支付宝基金筛选 |
| `memory/` | Synced memory snapshots from all Claude Code projects |

## Common Mistakes

- Guessing personal details instead of reading `profile.md` — always read first
- Answering financial questions without checking the actual backtest parameters in `financial/`
- Assuming VDB project details from general knowledge — the implementation has specific constraints (laptop GPU, Windows-only, IO-bound at 10^10 voxels)
