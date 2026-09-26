<#
.SYNOPSIS
    Register the personal-context skill globally for all Claude Code projects.
.DESCRIPTION
    Copies the personal-context skill to ~/.claude/skills/ so any Claude Code
    project can look up the user's personal context repository.

    Run this script on each new machine after cloning the repo.
.PARAMETER Unregister
    Remove the globally registered skill.
#>
param(
    [switch]$Unregister
)

$globalSkillDir = Join-Path $env:USERPROFILE ".claude\skills\personal-context"

if ($Unregister) {
    if (Test-Path $globalSkillDir) {
        Remove-Item -Recurse -Force $globalSkillDir
        Write-Host "Removed global skill from: $globalSkillDir" -ForegroundColor Yellow
    } else {
        Write-Host "Global skill not found, nothing to remove." -ForegroundColor Gray
    }
    return
}

$repoRoot = $PSScriptRoot
if (-not $repoRoot) {
    $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$profilePath = Join-Path $repoRoot "profile.md"
if (-not (Test-Path $profilePath)) {
    Write-Error "Cannot find profile.md at $repoRoot — run this script from the Context repo."
    exit 1
}

if (-not (Test-Path $globalSkillDir)) {
    New-Item -ItemType Directory -Force -Path $globalSkillDir | Out-Null
}

$skillContent = @"
---
name: personal-context
description: Use when answering questions about the user (Yufeng Ying / 应宇峰) — personal background, career history, tech skills, investment strategy, FIRE goals, or cross-project development context. Also use when user says "about me", references their profile, or asks anything requiring personal context about who they are.
---

# Personal Context Lookup

The user maintains a structured context repository. Read it to answer personal questions accurately.

## Repository Location

``````
$repoRoot
``````

If this path doesn't exist, check the ``PERSONAL_CONTEXT_REPO`` environment variable.

## Lookup Procedure

1. **Always start**: Read ``profile.md`` — covers 80%+ of questions (background, career, tech stack, investments, personality)
2. **GPU/CUDA details**: Read ``VDB/VDB.md`` and files under ``VDB/交接文档/``
3. **Investment/FIRE planning**: Read Python scripts under ``financial/`` for methodology and parameters
4. **Cross-project history**: Browse ``memory/<project-name>/MEMORY.md`` indices

## Source Index

| Source | Content |
|--------|---------|
| ``profile.md`` | Full profile: 硕士毕业、思看科技GPU实习、FIRE规划、永久投资组合、技术栈、性格特征 |
| ``VDB/`` | GPU VDB sparse volume, TSDF fusion system (DeepFusionPoints), CUDA optimization |
| ``financial/`` | 哈利·布朗永久投资组合回测、FIRE退休模拟、支付宝基金筛选 |
| ``memory/`` | Synced memory snapshots from all Claude Code projects |

## Common Mistakes

- Guessing personal details instead of reading ``profile.md`` — always read first
- Answering financial questions without checking the actual backtest parameters in ``financial/``
- Assuming VDB project details from general knowledge — the implementation has specific constraints (laptop GPU, Windows-only, IO-bound at 10^10 voxels)

## Profile Update Protocol

When a conversation reveals **significant** changes to the user's personal information, propose writing an update to the profile inbox.

### What counts as significant

Typical categories:
- 换工作、收入变化
- 搬家、城市变更
- 投资策略调整
- 新增或放弃技术栈
- 生活规划变更（FIRE 目标、婚育态度等）
- 学历、教育变化

Fallback rule: any information that would make an existing entry in ``profile.md`` inaccurate.

### What does NOT count

- Temporary states ("今天在调一个 bug")
- Information already in ``profile.md`` being mentioned again
- Speculative or uncertain information ("可能会换工作")

### How to write an update

1. Confirm with the user before writing
2. Append one entry to ``$repoRoot/profile-inbox.md`` in this format:

``````markdown
---
date: YYYY-MM-DD
source: <current project directory name>
---
<what changed, in natural language>
``````

3. Do NOT read or modify ``profile.md`` directly — the Context repo agent handles merging
"@

$skillContent | Out-File -FilePath (Join-Path $globalSkillDir "SKILL.md") -Encoding utf8 -Force

Write-Host "Registered personal-context skill globally." -ForegroundColor Green
Write-Host "  Skill:  $globalSkillDir\SKILL.md" -ForegroundColor Cyan
Write-Host "  Repo:   $repoRoot" -ForegroundColor Cyan
Write-Host ""
Write-Host "The skill is now available in all Claude Code projects." -ForegroundColor Gray
Write-Host "To unregister: .\register-skill.ps1 -Unregister" -ForegroundColor Gray
