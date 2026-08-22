<#
.SYNOPSIS
    从 https://github.com/platonai/Browser4 的最新 release 标签拉取 SKILL 文件，覆盖本地 skills/。

.DESCRIPTION
    本项目是 Browser4 的 SKILL 拷贝（skills/）。
    本脚本：
      1. 用 git ls-remote 获取上游所有版本标签，取最新（vX.Y.Z 语义化版本）。
      2. 用 sparse checkout 浅克隆该标签到临时目录，只检出 skills/ 与两个 README
         （git 走本机已配置的代理，openssl 后端，绕开 schannel SSL 问题；
          sparse 方式也避免上游 WPT 测试资源超长路径在 Windows 上 checkout 失败）。
      3. 检查上游 README 与本地 README 是否有差异：有差异则提醒手动 merge（不自动覆盖）。
      4. 镜像覆盖本地：仅 skills/ 整目录（先删后拷，保证与上游完全一致，无残留旧文件）。
      5. 在项目根写入 SKILL_VERSION.txt 记录来源标签与同步时间。
      6. 清理临时目录。

    覆盖范围与本地 SKILL 拷贝保持一致：只同步 skills/。
    README.md / README.zh.md 仅用于差异检测，不会自动覆盖，
    以避免丢失本地 DSH 插件相关说明。

.PARAMETER RepoUrl
    上游仓库地址，默认 https://github.com/platonai/Browser4.git

.PARAMETER Tag
    指定要同步的标签（如 v4.13.3）。留空 = 自动取最新版本标签。

.PARAMETER DryRun
    只报告最新标签、同步计划与 README 差异，不实际写入任何文件。

.PARAMETER Push
    同步后自动提交，并推送到当前 git 仓库配置的全部 remote（platonai / omdsh / origin 等）。

.EXAMPLE
    .\update-skill.ps1 -DryRun          # 查看最新标签与同步计划
    .\update-skill.ps1                  # 用最新标签覆盖本地
    .\update-skill.ps1 -Tag v4.13.2     # 指定版本覆盖本地
    .\update-skill.ps1 -Push            # 同步后自动提交并推送到所有上游仓
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = 'https://github.com/platonai/Browser4.git',
    [string]$Tag = '',
    [switch]$DryRun,
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$ReadmeItems = @('README.md', 'README.zh.md')

# ---------- 0. 前置检查 ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '未找到 git 命令，请先安装 Git（https://git-scm.com/）。'
}
if (-not (Test-Path (Join-Path $ProjectRoot 'skills'))) {
    throw "未在 '$ProjectRoot' 下找到 skills/ 目录，请确认脚本放在 Browser4 SKILL 拷贝的项目根。"
}

# 与上游同步的文件/目录清单（相对项目根）
$SyncItems = @('skills')

# ---------- 1. 解析目标标签 ----------
$tagWasAutoResolved = $false
if ([string]::IsNullOrWhiteSpace($Tag)) {
    Write-Host '==> 查询上游最新版本标签 ...' -ForegroundColor Cyan
    $tagLines = & git ls-remote --tags $RepoUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ls-remote 失败：$($tagLines -join ' ')" }
    $latest = $tagLines |
        ForEach-Object { ($_ -split "`t")[1] } |
        Where-Object { $_ -match '^refs/tags/v\d+\.\d+\.\d+$' } |
        ForEach-Object { $_ -replace '^refs/tags/', '' } |
        Sort-Object { [version]($_ -replace '^v', '') } -Descending |
        Select-Object -First 1
    if (-not $latest) { throw '未在上游找到任何 vX.Y.Z 版本标签。' }
    $Tag = $latest
    $tagWasAutoResolved = $true
}
if ($Tag -notmatch '^v\d+\.\d+\.\d+$') {
    throw "标签格式不支持：'$Tag'（期望如 v4.13.3）。"
}
Write-Host "==> 目标标签：$Tag" -ForegroundColor Green

# 本地版本记录（用于判断是否可跳过 skills 覆盖）
$versionFile = Join-Path $ProjectRoot 'SKILL_VERSION.txt'
$currentTag = ''
if (Test-Path $versionFile) {
    $currentTag = (Get-Content $versionFile | Where-Object { $_ -match '^tag:\s*(.+)$' } | ForEach-Object { $matches[1] })
}
$isSameTagAsLocal = ($currentTag -eq $Tag)

# ---------- 2. 打印同步计划 ----------
Write-Host '==> 同步计划（覆盖本地）：' -ForegroundColor Cyan
foreach ($item in $SyncItems) {
    $dst = Join-Path $ProjectRoot $item
    $cur = if (Test-Path $dst) { '存在（将被覆盖）' } else { '不存在（将新建）' }
    Write-Host "    $item  [$cur]"
}

# ---------- 3. sparse 浅克隆目标标签 ----------
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("b4-skill-update-" + [guid]::NewGuid().ToString('N'))
Write-Host "==> sparse 浅克隆 $Tag 到临时目录 ..." -ForegroundColor Cyan
try {
    # --filter=blob:none 按需拉取文件内容；--sparse 只检出根级文件，
    # 随后用 --no-cone 精确限定检出 skills/ 与两个 README，避开上游超长路径资源。
    $cloneOut = & git clone --depth 1 --single-branch --branch $Tag --filter=blob:none --sparse $RepoUrl $tmpDir 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git clone 失败：$($cloneOut -join ' ')" }

    $sparseOut = & git -C $tmpDir sparse-checkout set --no-cone '/skills/*' '/README.md' '/README.zh.md' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sparse-checkout 失败：$($sparseOut -join ' ')" }

    # ---------- 4. README 差异检测（仅提醒，不覆盖） ----------
    $readmeDiffs = @()
    foreach ($readme in $ReadmeItems) {
        $srcReadme = Join-Path $tmpDir $readme
        $dstReadme = Join-Path $ProjectRoot $readme

        if (-not (Test-Path $srcReadme)) { continue }
        if (-not (Test-Path $dstReadme)) {
            $readmeDiffs += $readme
            continue
        }

        $srcHash = (Get-FileHash -Path $srcReadme -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -Path $dstReadme -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) {
            $readmeDiffs += $readme
        }
    }

    if ($readmeDiffs.Count -gt 0) {
        Write-Warning "检测到上游 README 与本地存在差异：$($readmeDiffs -join ', ')"
        Write-Warning '为避免覆盖本地 DSH 插件说明，本脚本不会自动拷贝 README。请手动 merge。'
    }
    else {
        Write-Host '    + README 与上游一致，无需 merge。' -ForegroundColor Green
    }

    if ($DryRun) {
        Write-Host '==> DryRun 模式：未写入任何文件。' -ForegroundColor Yellow
        exit 0
    }

    if ($isSameTagAsLocal) {
        Write-Host "==> 本地已是最新标签（$Tag），跳过 skills 覆盖与版本文件更新。" -ForegroundColor Yellow
        exit 0
    }

    # ---------- 5. 镜像覆盖本地（仅 skills/） ----------
    $updated = 0
    foreach ($item in $SyncItems) {
        $src = Join-Path $tmpDir $item
        $dst = Join-Path $ProjectRoot $item
        if (-not (Test-Path $src)) {
            Write-Warning "上游标签 $Tag 中没有 '$item'，跳过。"
            continue
        }
        if (Test-Path $dst) {
            Remove-Item $dst -Recurse -Force
        }
        Copy-Item $src $dst -Recurse -Force
        Write-Host "    + 已覆盖 $item" -ForegroundColor Green
        $updated++
    }

    # ---------- 6. 记录来源版本 ----------
    @(
        "source: $RepoUrl",
        "tag: $Tag",
        "synced_at: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))"
    ) | Set-Content -Path $versionFile -Encoding UTF8
    Write-Host "    + 已写入 $versionFile" -ForegroundColor Green

    Write-Host "==> 完成：$Tag 已同步覆盖本地（$updated 项）。" -ForegroundColor Green

    # ---------- 7. 可选：自动提交并推送到所有上游仓 ----------
    if ($Push) {
        Write-Host '==> 自动提交并推送到所有上游仓 ...' -ForegroundColor Cyan
        $commitMsg = "Sync Browser4 SKILL to upstream $Tag"
        $addOut = & git add -A 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git add 失败：$($addOut -join ' ')" }

        $staged = & git status --porcelain
        if (-not $staged) {
            Write-Host '==> 无任何文件变更，跳过提交。' -ForegroundColor Yellow
        }
        else {
            $commitOut = & git commit -m $commitMsg 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git commit 失败：$($commitOut -join ' ')" }
            Write-Host "    + 已提交：$commitMsg" -ForegroundColor Green
        }

        $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
        $remotes = (& git remote).Trim()
        if (-not $remotes) {
            Write-Warning '当前 git 仓库没有配置任何 remote，跳过推送。'
            return
        }
        foreach ($remote in $remotes) {
            $pushOut = & git push $remote $branch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "推送 $remote 失败：$($pushOut -join ' ')"
            }
            else {
                Write-Host "    + 已推送 $remote/$branch" -ForegroundColor Green
            }
        }
    }
}
finally {
    if (Test-Path $tmpDir) {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
