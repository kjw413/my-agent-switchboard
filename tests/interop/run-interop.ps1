<#
.SYNOPSIS
  업스트림 agent-switchboard 코드가 설치된 키트를 건드리지 않는지 확인하는 상호운용 오라클.

.DESCRIPTION
  %TEMP% 아래에 가짜 홈을 만들고 (tests\run-tests.ps1 의 New-FixtureHome 과 같은 방식),
  install.ps1 -HomeDir <가짜 홈> -SkipEnvVar 로 키트를 설치한 뒤,
  upstream_interop.py 로 업스트림의 실제 hierarchy_install / setup.refresh_hierarchy 를
  가짜 홈에 두 번 돌립니다. 업스트림 코드는 -UpstreamDir 에서 import 만 하고 복사하지 않습니다.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\interop\run-interop.ps1 -UpstreamDir C:\src\agent-switchboard-v1.0.47

.PARAMETER UpstreamDir
  업스트림 체크아웃 폴더 (hierarchy_install.py 가 있는 곳).

.PARAMETER Python
  사용할 python 실행 파일. 비우면 PATH 의 python / py 를 씁니다. (3.11 이상, tomllib 필요)

.PARAMETER KeepTemp
  성공해도 임시 폴더를 지우지 않습니다. (실패하면 항상 남깁니다)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$UpstreamDir,
  [string]$Python = '',
  [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ================================================================ setup
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$Install = Join-Path $RepoRoot 'install.ps1'
$Oracle = Join-Path $PSScriptRoot 'upstream_interop.py'
$HostExe = (Get-Process -Id $PID).Path
$TempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$RunRoot = Join-Path $TempRoot ('swkit-interop-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$UpEnd = '<!-- agent-switchboard:cost-routing:end -->'
$LegacyClaude = 'Require an approved work package stating Route, exact model/effort'

$UpstreamDir = [System.IO.Path]::GetFullPath($UpstreamDir).TrimEnd('\')
if (-not [System.IO.File]::Exists((Join-Path $UpstreamDir 'hierarchy_install.py'))) {
  Write-Host ('[FAIL] 업스트림 폴더에 hierarchy_install.py 가 없습니다: ' + $UpstreamDir)
  exit 2
}
if ($UpstreamDir.StartsWith($RepoRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $UpstreamDir -ieq $RepoRoot) {
  Write-Host '[FAIL] 업스트림 코드는 이 저장소 밖에 두어야 합니다 (PolyForm-Noncommercial).'
  exit 2
}

function Assert-UnderRun([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not $full.StartsWith($TempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("REFUSED: '{0}' 는 %TEMP% 밖입니다." -f $full)
  }
  if (-not $full.StartsWith($RunRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("REFUSED: '{0}' 는 이번 실행 폴더 밖입니다." -f $full)
  }
}

# ================================================================ fixtures (tests\run-tests.ps1 와 같은 방식)
function Write-Fixture([string]$Path, [string]$Text) {
  Assert-UnderRun $Path
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  [System.IO.File]::WriteAllBytes($Path, $Utf8NoBom.GetBytes($Text))
}

function Get-Sha256Hex([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash($Utf8NoBom.GetBytes($Text)) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertTo-Eol([string]$Text, [string]$Eol) {
  $t = $Text.Replace("`r`n", "`n")
  if ($Eol -eq "`r`n") { $t = $t.Replace("`n", "`r`n") }
  return $t
}

$UpstreamBody = "## Synthetic routing fixture`n`n- Fixture rule alpha: route bounded work to lane X.`n- Fixture rule beta: keep approvals with the brain.`n"

function New-UpstreamBlock([string]$Eol) {
  # 업스트림 _render_block 과 같은 모양 (체크섬이 맞는 = 업스트림이 덮어쓸 수 있는 블록)
  $canonical = $UpstreamBody.Trim() + "`n"
  $render = '<!-- agent-switchboard:cost-routing:begin sha256=' + (Get-Sha256Hex $canonical) + " -->`n" + $canonical + $UpEnd
  return (ConvertTo-Eol $render $Eol)
}

function New-ManagedFile([string]$Body, [string]$Kind, [string]$Eol) {
  # 업스트림 _render_managed_file 과 같은 모양
  $canonical = $Body.Replace("`r`n", "`n").Trim() + "`n"
  $marker = '# agent-switchboard:managed sha256=' + (Get-Sha256Hex $canonical)
  if ($Kind -eq 'md') { $render = "---`n" + $marker + "`n" + $canonical.Substring(4) }
  else { $render = $marker + "`n" + $canonical }
  return (ConvertTo-Eol $render $Eol)
}

$ExploreBody = "---`nname: Explore`ndescription: Cost-efficient synthetic reader for fixtures.`ntools: Read, Grep, Glob`nmodel: haiku`n---`n`nSynthetic reader body line.`n"
$WorkerMd = "---`nname: economy-worker`ndescription: Synthetic workhorse for fixtures.`nmodel: sonnet`neffort: medium`n---`n`n$LegacyClaude, deliverable, and verification.`n"
$ExplorerToml = "name = `"explorer`"`ndescription = `"Cost-efficient synthetic explorer.`"`nmodel = `"fixture-reader`"`nmodel_reasoning_effort = `"low`"`nsandbox_mode = `"read-only`"`ndeveloper_instructions = `"`"`"`nSynthetic explorer instructions.`n`"`"`"`n"
$WorkerToml = "name = `"worker`"`ndescription = `"Cost-efficient synthetic worker.`"`nmodel = `"fixture-worker`"`nmodel_reasoning_effort = `"medium`"`ndeveloper_instructions = `"`"`"`nSynthetic worker instructions.`n`"`"`"`n"

$SettingsFixture = @'
{
  "env": {
    "FIXTURE_FLAG": "1"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo foreign-session-start"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "C:\\fixture\\.agent-broker\\agent-switchboard.exe",
            "args": [
              "routing-hook",
              "PreToolUse",
              "agent-switchboard",
              "claude"
            ]
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "echo 한글 상태줄"
  }
}
'@

function New-FixtureHome([string]$Dir) {
  # 업스트림 v1.0.39 ~ v1.0.47 이 이미 설치되어 있던 홈 (세 호스트 모두 있음)
  Write-Fixture (Join-Path $Dir '.agent-broker\agent-switchboard.exe') 'MZ-fixture'
  Write-Fixture (Join-Path $Dir '.claude\CLAUDE.md') ("# 내 전역 메모`r`n`r`n사용자 텍스트 위쪽.`r`n`r`n" + (New-UpstreamBlock "`r`n") + "`r`n`r`n## 아래쪽 사용자 섹션`r`n- 항목 하나`r`n")
  Write-Fixture (Join-Path $Dir '.codex\AGENTS.md') ("codex 사용자 메모`n`n" + (New-UpstreamBlock "`n") + "`n`n## Codex 꼬리 섹션`n끝.`n")
  Write-Fixture (Join-Path $Dir '.gemini\GEMINI.md') ("# Gemini 메모`n`n" + (New-UpstreamBlock "`n") + "`n")
  Write-Fixture (Join-Path $Dir '.claude\agents\Explore.md') (New-ManagedFile $ExploreBody 'md' "`r`n")
  Write-Fixture (Join-Path $Dir '.claude\agents\economy-worker.md') $WorkerMd
  Write-Fixture (Join-Path $Dir '.codex\agents\explorer.toml') (New-ManagedFile $ExplorerToml 'toml' "`r`n")
  Write-Fixture (Join-Path $Dir '.codex\agents\worker.toml') (New-ManagedFile $WorkerToml 'toml' "`n")
  Write-Fixture (Join-Path $Dir '.claude\settings.json') (ConvertTo-Eol $SettingsFixture "`r`n")
}

function New-ClaudeOnlyHome([string]$Dir) {
  # tests\run-tests.ps1 의 New-FreshHome 과 같음: .claude 폴더와 exe 만 있음
  Write-Fixture (Join-Path $Dir '.agent-broker\agent-switchboard.exe') 'MZ-fixture'
  [void][System.IO.Directory]::CreateDirectory((Join-Path $Dir '.claude'))
}

function New-FreshHome([string]$Dir) {
  # 업스트림을 설치한 적 없는 홈 (세 호스트 폴더만 있음)
  Write-Fixture (Join-Path $Dir '.agent-broker\agent-switchboard.exe') 'MZ-fixture'
  foreach ($d in @('.claude', '.codex', '.gemini')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $Dir $d)) }
}

# ================================================================ safety snapshots
function Get-FileSha([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-UserEnvSnapshot {
  $h = [Environment]::GetEnvironmentVariables('User')
  $keys = @($h.Keys | ForEach-Object { [string]$_ } | Sort-Object)
  return (($keys | ForEach-Object { $_ + '=' + [string]$h[$_] }) -join "`n")
}

function Get-RealProfileSnapshot {
  $real = [System.IO.Path]::GetFullPath($env:USERPROFILE)
  $rels = @('.claude\CLAUDE.md', '.claude\settings.json', '.claude\agents\Explore.md', '.claude\agents\economy-worker.md',
    '.claude\agents\consultant.md', '.claude\orchestration\roles.json', '.codex\AGENTS.md', '.codex\hooks.json',
    '.codex\agents\explorer.toml', '.codex\agents\worker.toml', '.gemini\GEMINI.md')
  $lines = foreach ($r in $rels) {
    $p = Join-Path $real $r
    if ([System.IO.File]::Exists($p)) { $r + '=' + (Get-FileSha $p) } else { $r + '=<none>' }
  }
  return (@($lines) -join "`n")
}

function Find-Python {
  if ($Python) { return $Python }
  foreach ($n in @('python', 'py')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($null -ne $c) { return $c.Source }
  }
  throw 'python 을 찾지 못했습니다. -Python 으로 지정하세요.'
}

function Invoke-Child([string]$Exe, [string[]]$Argv) {
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Argv 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $saved }
  return [pscustomobject]@{ Exit = $code; Lines = @($out | ForEach-Object { [string]$_ }) }
}

# ================================================================ run
$PyExe = Find-Python
Write-Host ('업스트림: ' + $UpstreamDir)
Write-Host ('python: ' + $PyExe)
Write-Host ('임시 폴더: ' + $RunRoot)
[void][System.IO.Directory]::CreateDirectory($RunRoot)
$EnvBefore = Get-UserEnvSnapshot
$RealBefore = Get-RealProfileSnapshot

$Scenarios = @(
  [pscustomobject]@{ Name = 'fixture'; Builder = ${function:New-FixtureHome}; Label = '업스트림이 이미 설치된 홈' },
  [pscustomobject]@{ Name = 'fresh'; Builder = ${function:New-FreshHome}; Label = '업스트림을 설치한 적 없는 홈' },
  [pscustomobject]@{ Name = 'claude-only'; Builder = ${function:New-ClaudeOnlyHome}; Label = '.claude 만 있는 홈 (Codex/Gemini 미설치)' }
)
$Failed = New-Object System.Collections.Generic.List[string]

foreach ($s in $Scenarios) {
  $fake = Join-Path $RunRoot ('home-' + $s.Name)
  Assert-UnderRun (Join-Path $fake 'x')
  Write-Host ''
  Write-Host ('=== 시나리오 {0}: {1}' -f $s.Name, $s.Label)
  & $s.Builder $fake

  $inst = Invoke-Child $HostExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Install, '-HomeDir', $fake, '-SkipEnvVar')
  if ($inst.Exit -ne 0) {
    Write-Host ('[FAIL] install.ps1 종료 코드 {0}' -f $inst.Exit)
    $inst.Lines | Select-Object -Last 30 | ForEach-Object { Write-Host ('       ' + $_) }
    $Failed.Add($s.Name + ': install')
    continue
  }
  Write-Host '[PASS] install.ps1 -SkipEnvVar 종료 코드 0'
  $inst.Lines | Where-Object { $_ -match '\[(WARN|FAIL)\]' } | ForEach-Object { Write-Host ('[INFO] install: ' + $_.Trim()) }

  $py = Invoke-Child $PyExe @('-B', $Oracle, $UpstreamDir, $fake)
  $py.Lines | ForEach-Object { Write-Host $_ }
  if ($py.Exit -ne 0) {
    Write-Host ('[FAIL] 오라클 종료 코드 {0}' -f $py.Exit)
    $Failed.Add($s.Name + ': oracle')
  } else {
    Write-Host '[PASS] 오라클 종료 코드 0'
  }
}

Write-Host ''
if ((Get-UserEnvSnapshot) -cne $EnvBefore) { Write-Host '[FAIL] 사용자 환경 변수가 바뀌었습니다'; $Failed.Add('user-env') }
else { Write-Host '[PASS] 사용자 환경 변수 그대로' }
if ((Get-RealProfileSnapshot) -cne $RealBefore) { Write-Host '[FAIL] 실제 프로필 파일이 바뀌었습니다'; $Failed.Add('real-profile') }
else { Write-Host '[PASS] 실제 프로필 파일 그대로' }

if ($Failed.Count -gt 0) {
  Write-Host ('결과: 실패 {0} 건 ({1}). 임시 폴더를 남깁니다: {2}' -f $Failed.Count, ($Failed -join ', '), $RunRoot)
  exit 1
}
Write-Host '결과: 모두 통과'
if ($KeepTemp) { Write-Host ('임시 폴더를 남깁니다: ' + $RunRoot) }
else { Remove-Item -LiteralPath $RunRoot -Recurse -Force }
exit 0
