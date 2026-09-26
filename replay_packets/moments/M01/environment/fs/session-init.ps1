<#
.SYNOPSIS
    本仓库 SessionStart 初始化脚本。
.DESCRIPTION
    1. 双向同步所有 Claude Code 项目的 memory 和 session JSONL 到本仓库（含删除检测）
    2. 清理源头已不存在的项目目录
    3. 检查 profile-inbox.md 是否有待处理的用户画像更新
#>

$claudeProjects = Join-Path $env:USERPROFILE ".claude\projects"
$memoryRoot = Join-Path $PSScriptRoot "memory"
$sessionsRoot = Join-Path $PSScriptRoot "sessions"

if (-not (Test-Path $memoryRoot)) {
    New-Item -ItemType Directory -Force $memoryRoot | Out-Null
}
if (-not (Test-Path $sessionsRoot)) {
    New-Item -ItemType Directory -Force $sessionsRoot | Out-Null
}

function Copy-IfChanged {
    param([string]$SrcFile, [string]$DstDir)
    $dstFile = Join-Path $DstDir (Split-Path $SrcFile -Leaf)
    if (Test-Path $dstFile) {
        $src = Get-Item $SrcFile
        $dst = Get-Item $dstFile
        if ($src.LastWriteTime -eq $dst.LastWriteTime -and $src.Length -eq $dst.Length) {
            return $false
        }
    }
    Copy-Item $SrcFile $DstDir -Force
    return $true
}

function Sync-Directory {
    param(
        [string]$SrcDir,
        [string]$DstDir,
        [string]$Filter = "*",
        [string]$Label,
        [string]$ProjName
    )
    if (-not (Test-Path $SrcDir)) { return }
    $srcFiles = Get-ChildItem $SrcDir -Filter $Filter -File
    if ($srcFiles.Count -eq 0 -and -not (Test-Path $DstDir)) { return }

    if (-not (Test-Path $DstDir)) {
        New-Item -ItemType Directory -Force $DstDir | Out-Null
    }

    $copied = 0
    foreach ($f in $srcFiles) {
        if (Copy-IfChanged $f.FullName $DstDir) { $copied++ }
    }

    $deleted = 0
    $srcNames = @($srcFiles | ForEach-Object { $_.Name })
    $dstFiles = Get-ChildItem $DstDir -Filter $Filter -File
    foreach ($f in $dstFiles) {
        if ($f.Name -notin $srcNames) {
            Remove-Item $f.FullName -Force
            $deleted++
        }
    }

    if ($copied -gt 0 -or $deleted -gt 0) {
        $parts = @()
        if ($copied -gt 0) { $parts += "$copied updated" }
        if ($deleted -gt 0) { $parts += "$deleted deleted" }
        Write-Output "${Label}: $ProjName ($($parts -join ', '))"
    }
}

Get-ChildItem $claudeProjects -Directory | ForEach-Object {
    $projName = $_.Name

    Sync-Directory `
        -SrcDir (Join-Path $_.FullName "memory") `
        -DstDir (Join-Path $memoryRoot $projName) `
        -Label "Memory" -ProjName $projName

    Sync-Directory `
        -SrcDir $_.FullName `
        -DstDir (Join-Path $sessionsRoot $projName) `
        -Filter "*.jsonl" `
        -Label "Sessions" -ProjName $projName
}

# --- Clean up repo dirs whose source project no longer exists ---
$srcProjNames = @(Get-ChildItem $claudeProjects -Directory | ForEach-Object { $_.Name })
foreach ($root in @($memoryRoot, $sessionsRoot)) {
    Get-ChildItem $root -Directory | ForEach-Object {
        if ($_.Name -notin $srcProjNames) {
            Remove-Item $_.FullName -Recurse -Force
            Write-Output "Cleanup: removed $($_.Name) from $(Split-Path $root -Leaf)/"
        }
    }
}

# --- Profile inbox check ---
$inbox = Join-Path $PSScriptRoot "profile-inbox.md"
if (Test-Path $inbox) {
    $lines = (Get-Content $inbox | Where-Object { $_.Trim() -ne "" }).Count
    if ($lines -gt 0) {
        Write-Output "PROFILE_INBOX: profile-inbox.md has pending updates, please process."
    }
}

Write-Output "Done."
