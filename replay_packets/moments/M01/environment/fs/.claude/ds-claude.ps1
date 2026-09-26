<#
.SYNOPSIS
    Spawn an isolated Claude Code session backed by DeepSeek API.
.DESCRIPTION
    Sets DeepSeek-specific env vars in a child process so the parent
    Claude Code session stays on pure Anthropic.  Requires
    DEEPSEEK_API_KEY to be set in the environment.
.PARAMETER Prompt
    The task prompt (must be self-contained — child has no parent context).
.PARAMETER ReadOnly
    Restrict tools to read-only (Read, Grep, Glob).
.PARAMETER WebOnly
    Restrict tools to web research (WebFetch, WebSearch).
.PARAMETER AllowedTools
    Override the tool allowlist (comma-separated).
.PARAMETER Model
    DeepSeek model to use. Default: deepseek-v4-pro.
#>
param(
    [Parameter(Mandatory)]
    [string]$Prompt,

    [switch]$ReadOnly,

    [switch]$WebOnly,

    [string]$AllowedTools,

    [string]$Model = "deepseek-v4-pro"
)

if (-not $env:DEEPSEEK_API_KEY) {
    Write-Error "DEEPSEEK_API_KEY is not set."
    exit 1
}

if ($AllowedTools) {
    $tools = $AllowedTools
} elseif ($ReadOnly) {
    $tools = "Read,Grep,Glob"
} elseif ($WebOnly) {
    $tools = "WebFetch,WebSearch"
} else {
    $tools = "Read,Grep,Glob,Edit,Write,Bash,PowerShell,WebFetch,WebSearch"
}

$envKeys = @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'CLAUDE_CODE_SUBAGENT_MODEL',
    'CLAUDE_CODE_EFFORT_LEVEL'
)
$saved = @{}
foreach ($k in $envKeys) {
    $saved[$k] = [System.Environment]::GetEnvironmentVariable($k, 'Process')
}

$modelWithCtx = "$Model[1m]"

$env:ANTHROPIC_BASE_URL            = "https://api.deepseek.com/anthropic"
$env:ANTHROPIC_AUTH_TOKEN           = $env:DEEPSEEK_API_KEY
$env:ANTHROPIC_MODEL                = $null
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $modelWithCtx
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $modelWithCtx
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = "deepseek-v4-flash"
$env:CLAUDE_CODE_SUBAGENT_MODEL     = "deepseek-v4-flash"
$env:CLAUDE_CODE_EFFORT_LEVEL       = "max"

try {
    "" | claude -p $Prompt --model $modelWithCtx --allowedTools $tools --output-format json
} finally {
    foreach ($k in $envKeys) {
        [System.Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
    }
}
