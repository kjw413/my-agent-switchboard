<#
.SYNOPSIS
  switchboard-kit 테스트. Pester 없이 PowerShell assert 만 씁니다.

.DESCRIPTION
  %TEMP% 아래에 가짜 홈을 만들고 install.ps1 / uninstall.ps1 / sync-roles.ps1 을 자식
  프로세스로 실행합니다. 가짜 홈 밖의 -HomeDir 는 거부하고, install/uninstall 은 항상
  -SkipEnvVar 로 실행하므로 실제 프로필과 사용자 환경 변수는 바뀌지 않습니다.
  테스트는 이 스크립트를 실행한 PowerShell 과 같은 호스트로 돌아갑니다.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
    pwsh       -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1

.PARAMETER KeepTemp
  성공해도 임시 폴더를 지우지 않습니다. (실패하면 항상 남깁니다)
#>
[CmdletBinding()]
param([switch]$KeepTemp)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ================================================================ setup
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$Install = Join-Path $RepoRoot 'install.ps1'
$Uninstall = Join-Path $RepoRoot 'uninstall.ps1'
$SyncRepo = Join-Path $RepoRoot 'scripts\sync-roles.ps1'
$TemplatesDir = Join-Path $RepoRoot 'templates'
$HostExe = (Get-Process -Id $PID).Path
$HostLabel = 'PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, [System.IO.Path]::GetFileName($HostExe)
$TempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$RunRoot = Join-Path $TempRoot ('swkit-test-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$KitBegin = '<!-- switchboard-kit:policy:begin -->'
$KitEnd = '<!-- switchboard-kit:policy:end -->'
$UpBeginPattern = '<!-- agent-switchboard:cost-routing:begin sha256=([0-9a-f]{64}) -->'
$UpEnd = '<!-- agent-switchboard:cost-routing:end -->'
$Zeros = '0' * 64
$SentinelBegin = '<!-- agent-switchboard:cost-routing:begin sha256=' + $Zeros + ' -->'
$LegacyClaude = 'Require an approved work package stating Route, exact model/effort'
$Known = @('d3612ab90cd701c91ab254b0ea52841ba04e314a435992c829ed19207b737184')

$script:Results = New-Object System.Collections.Generic.List[object]

# ================================================================ harness
function Assert-UnderTemp([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not $full.StartsWith($TempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("REFUSED: -HomeDir '{0}' 는 %TEMP% 밖입니다." -f $full)
  }
  if (-not $full.StartsWith($RunRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("REFUSED: -HomeDir '{0}' 는 이번 테스트 폴더 밖입니다." -f $full)
  }
}

function Invoke-Kit([string]$Script, [string]$HomeDir, [string[]]$Extra = @()) {
  Assert-UnderTemp $HomeDir
  $name = [System.IO.Path]::GetFileName($Script)
  if ($name -ne 'sync-roles.ps1' -and -not ($Extra -contains '-SkipEnvVar')) {
    throw ("REFUSED: {0} 는 -SkipEnvVar 없이 실행하지 않습니다." -f $name)
  }
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-HomeDir', $HomeDir) + $Extra
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $HostExe @argv 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $saved }
  $lines = @($out | ForEach-Object { [string]$_ })
  return [pscustomobject]@{ Exit = $code; Output = ($lines -join "`n") }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    $script:Results.Add([pscustomobject]@{ Name = $Name; Pass = $true })
    Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
  } catch {
    $script:Results.Add([pscustomobject]@{ Name = $Name; Pass = $false })
    Write-Host ('[FAIL] ' + $Name) -ForegroundColor Red
    Write-Host ('       ' + $_.Exception.Message)
  }
}

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-Exit($Result, [int]$Expected, [string]$What) {
  if ($Result.Exit -ne $Expected) {
    $tail = $Result.Output
    if ($tail.Length -gt 3000) { $tail = $tail.Substring($tail.Length - 3000) }
    throw ("{0}: 종료 코드 {1} (기대 {2})`n{3}" -f $What, $Result.Exit, $Expected, $tail)
  }
}

function Assert-SameText([string]$Expected, [string]$Actual, [string]$What) {
  if ($Expected -cne $Actual) {
    $i = 0
    $max = [Math]::Min($Expected.Length, $Actual.Length)
    while ($i -lt $max -and $Expected[$i] -eq $Actual[$i]) { $i++ }
    $from = [Math]::Max(0, $i - 40)
    $e = $Expected.Substring($from, [Math]::Min(80, $Expected.Length - $from)).Replace("`r", '\r').Replace("`n", '\n')
    $a = $Actual.Substring($from, [Math]::Min(80, $Actual.Length - $from)).Replace("`r", '\r').Replace("`n", '\n')
    throw ("{0}: 위치 {1} 에서 다름`n       기대: {2}`n       실제: {3}" -f $What, $i, $e, $a)
  }
}

# ================================================================ file helpers
function Write-Fixture([string]$Path, [string]$Text, [switch]$Bom) {
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  $bytes = $Utf8NoBom.GetBytes($Text)
  if ($Bom) { $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes) }
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Read-Raw([string]$Path) {
  # BOM 을 벗기지 않는 UTF-8 해석 (Python read_text 와 같음)
  return $Utf8NoBom.GetString([System.IO.File]::ReadAllBytes($Path))
}

function ConvertTo-Eol([string]$Text, [string]$Eol) {
  $t = $Text.Replace("`r`n", "`n")
  if ($Eol -eq "`r`n") { $t = $t.Replace("`n", "`r`n") }
  return $t
}

function Get-Sha256Hex([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash($Utf8NoBom.GetBytes($Text)) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-FileSha([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-HasBom([string]$Path) {
  $b = [System.IO.File]::ReadAllBytes($Path)
  return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Get-TreeSnapshot([string]$Root) {
  # orchestration-backups 는 제외한 파일/폴더 목록과 해시
  $map = [ordered]@{}
  $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)
  foreach ($it in $items) {
    $rel = $it.FullName.Substring($Root.Length + 1)
    if ($rel -like '.claude\orchestration-backups*') { continue }
    if ($it.PSIsContainer) { $map[$rel] = '<dir>' } else { $map[$rel] = Get-FileSha $it.FullName }
  }
  return $map
}

function Compare-Snapshot($A, $B) {
  $diff = New-Object System.Collections.Generic.List[string]
  foreach ($k in $A.Keys) {
    if (-not $B.Contains($k)) { $diff.Add('없어짐: ' + $k) }
    elseif ($A[$k] -ne $B[$k]) { $diff.Add('바뀜: ' + $k) }
  }
  foreach ($k in $B.Keys) { if (-not $A.Contains($k)) { $diff.Add('생김: ' + $k) } }
  return ,$diff
}

function Assert-SameSnapshot($Before, $After, [string]$What) {
  $d = Compare-Snapshot $Before $After
  if ($d.Count -gt 0) { throw ("{0}: {1}" -f $What, ($d -join ', ')) }
}

function Copy-Tree([string]$From, [string]$To) {
  Assert-UnderTemp (Join-Path $To 'x')
  [void][System.IO.Directory]::CreateDirectory($To)
  foreach ($it in @(Get-ChildItem -LiteralPath $From -Recurse -Force)) {
    $rel = $it.FullName.Substring($From.Length + 1)
    $dst = Join-Path $To $rel
    if ($it.PSIsContainer) { [void][System.IO.Directory]::CreateDirectory($dst) }
    else {
      [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
      [System.IO.File]::Copy($it.FullName, $dst, $true)
    }
  }
}

# ================================================================ upstream ports (hierarchy_install.py v1.0.39 ~ v1.0.47)
function Get-UpstreamView([string]$Path) {
  # Path.read_text(encoding="utf-8"): BOM 유지, universal newline
  return (Read-Raw $Path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-UpstreamBlockAction([string]$Text) {
  $m = [regex]::Match($Text, $UpBeginPattern)
  if (-not $m.Success) {
    if ([regex]::IsMatch($Text, '(?im)^(#{1,2})\s+cost-aware model routing\s*$')) { return 'overwrite-legacy' }
    return 'append'
  }
  $bodyStart = $m.Index + $m.Length
  if ($bodyStart -lt $Text.Length -and $Text[$bodyStart] -eq [char]10) { $bodyStart++ }
  $end = $Text.IndexOf($UpEnd, $bodyStart, [System.StringComparison]::Ordinal)
  if ($end -lt 0) { return 'untouched' }
  $body = $Text.Substring($bodyStart, $end - $bodyStart)
  if ((Get-Sha256Hex $body) -ceq $m.Groups[1].Value) { return 'overwrite' }
  if ($Known -ccontains $m.Groups[1].Value) { return 'overwrite' }
  return 'untouched'
}

function Get-UpstreamRoleAction([string]$Text, [string]$Name, [string]$Kind) {
  if ($Text.Length -eq 0) { return 'overwrite' }
  $m = [regex]::Match($Text, '(?m)^# agent-switchboard:managed sha256=([0-9a-f]{64})\s*$')
  if ($m.Success) {
    $end = $m.Index + $m.Length
    if ($end -lt $Text.Length -and $Text[$end] -eq [char]10) { $end++ }
    $body = $Text.Substring(0, $m.Index) + $Text.Substring($end)
    if ((Get-Sha256Hex $body) -ceq $m.Groups[1].Value) { return 'overwrite' }
    return 'untouched'
  }
  if ($Kind -eq 'toml') {
    if ($Text.Contains('name = "' + $Name + '"') -and $Text.Contains('Cost-efficient')) { return 'overwrite' }
  } else {
    if ($Text.Contains('name: ' + $Name) -and ($Text.Contains('Cost-efficient') -or $Text.Contains($LegacyClaude))) { return 'overwrite' }
  }
  return 'untouched'
}

function Test-OwnedHook($Handler) {
  $parts = @([string]$Handler.command)
  if ($null -ne $Handler.PSObject.Properties['args']) { $parts += @($Handler.args | ForEach-Object { [string]$_ }) }
  $inv = $parts -join ' '
  return ($inv.Contains('agent-switchboard') -and $inv.Contains('routing-hook'))
}

# ================================================================ JSON compare (independent of the kit)
function Get-JsonDiff($A, $B, [string]$Where = '$') {
  if ($null -eq $A -or $null -eq $B) {
    if ($null -eq $A -and $null -eq $B) { return $null }
    return ($Where + ': null 차이')
  }
  if ($A -is [System.Management.Automation.PSCustomObject]) {
    if (-not ($B -is [System.Management.Automation.PSCustomObject])) { return ($Where + ': 객체가 아님') }
    $na = @($A.PSObject.Properties | ForEach-Object { $_.Name })
    $nb = @($B.PSObject.Properties | ForEach-Object { $_.Name })
    if (($na -join '|') -cne ($nb -join '|')) { return ('{0}: 키 차이 [{1}] vs [{2}]' -f $Where, ($na -join ','), ($nb -join ',')) }
    foreach ($n in $na) {
      $d = Get-JsonDiff $A.PSObject.Properties[$n].Value $B.PSObject.Properties[$n].Value ($Where + '.' + $n)
      if ($null -ne $d) { return $d }
    }
    return $null
  }
  if ($A -is [array]) {
    if (-not ($B -is [array])) { return ($Where + ': 배열이 아님 (단일 원소 배열이 풀렸을 수 있음)') }
    if ($A.Count -ne $B.Count) { return ('{0}: 배열 길이 {1} vs {2}' -f $Where, $A.Count, $B.Count) }
    for ($i = 0; $i -lt $A.Count; $i++) {
      $d = Get-JsonDiff $A[$i] $B[$i] ('{0}[{1}]' -f $Where, $i)
      if ($null -ne $d) { return $d }
    }
    return $null
  }
  if ($B -is [System.Management.Automation.PSCustomObject] -or $B -is [array]) { return ($Where + ': 형태 차이') }
  if ($A.GetType().Name -eq 'String' -or $B.GetType().Name -eq 'String') {
    if (($A -is [string]) -and ($B -is [string]) -and ($A -ceq $B)) { return $null }
    return ('{0}: "{1}" vs "{2}"' -f $Where, $A, $B)
  }
  $sa = [System.Convert]::ToString($A, [System.Globalization.CultureInfo]::InvariantCulture)
  $sb = [System.Convert]::ToString($B, [System.Globalization.CultureInfo]::InvariantCulture)
  if ($sa -cne $sb) { return ('{0}: {1} vs {2}' -f $Where, $sa, $sb) }
  return $null
}

function Read-Json([string]$Path) {
  return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)))
}

function ConvertTo-UpstreamStyleJson($Object) {
  # agent-switchboard 의 json.dumps(indent=2, ensure_ascii=True) 흉내: 다른 서식 + 비ASCII 이스케이프
  $j = ConvertTo-Json -InputObject $Object -Depth 100
  $j = [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
  return ($j.Replace("`r`n", "`n") + "`n")
}

# ================================================================ fixtures
$UpstreamBody = @'
## Synthetic routing fixture

- Fixture rule alpha: route bounded work to lane X.
- Fixture rule beta: keep approvals with the brain.
'@

function New-UpstreamBlock([string]$Eol) {
  $canonical = $UpstreamBody.Replace("`r`n", "`n").Trim() + "`n"
  $render = '<!-- agent-switchboard:cost-routing:begin sha256=' + (Get-Sha256Hex $canonical) + " -->`n" + $canonical + $UpEnd
  return (ConvertTo-Eol $render $Eol)
}

function New-ManagedFile([string]$Body, [string]$Kind, [string]$Eol) {
  $canonical = $Body.Replace("`r`n", "`n").Trim() + "`n"
  $marker = '# agent-switchboard:managed sha256=' + (Get-Sha256Hex $canonical)
  if ($Kind -eq 'md') { $render = "---`n" + $marker + "`n" + $canonical.Substring(4) }
  else { $render = $marker + "`n" + $canonical }
  return (ConvertTo-Eol $render $Eol)
}

$ExploreBody = "---`nname: Explore`ndescription: Cost-efficient synthetic reader for fixtures.`ntools: Read, Grep, Glob`nmodel: haiku`n---`n`nSynthetic reader body line.`n"
$WorkerMd = "---`nname: economy-worker`ndescription: Synthetic workhorse for fixtures.`nmodel: sonnet`neffort: medium`n---`n`n$LegacyClaude, deliverable, and verification.`n"
# 여러 줄 문자열 안의 "model = ..." 줄을 진짜 키보다 앞에 두어 TOML 파싱 실수를 잡습니다.
$ExplorerToml = "name = `"explorer`"`ndescription = `"Cost-efficient synthetic explorer.`"`ndeveloper_instructions = `"`"`"`nSynthetic explorer instructions.`nmodel = `"trap-inside-multiline`"`nmodel_reasoning_effort = `"trap-effort`"`n`"`"`"`nmodel = `"fixture-reader`"`nmodel_reasoning_effort = `"low`"`nsandbox_mode = `"read-only`"`n"
$WorkerToml = "name = `"worker`"`ndescription = `"Cost-efficient synthetic worker.`"`nmodel = `"fixture-worker`"`nmodel_reasoning_effort = `"medium`"`ndeveloper_instructions = `"`"`"`nSynthetic worker instructions.`n`"`"`"`n"

$ClaudeAbove = "# 내 전역 메모`r`n`r`n사용자 텍스트 위쪽.`r`n여러 줄입니다.`r`n`r`n"
$ClaudeBelow = "`r`n`r`n## 아래쪽 사용자 섹션`r`n- 항목 하나`r`n"
$AgentsAbove = "codex 사용자 메모`n`n"
$AgentsBelow = "`n`n## Codex 꼬리 섹션`n끝.`n"
$GeminiOriginal = "# Gemini 메모`n`n마지막 줄에 줄바꿈 없음"

$SettingsFixture = @'
{
  "env": {
    "FIXTURE_FLAG": "1"
  },
  "permissions": {
    "allow": [
      "Bash(git status)"
    ],
    "deny": []
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
  },
  "nested": {
    "empty": [],
    "single": [
      "only"
    ],
    "deep": [
      []
    ],
    "deepSingle": [
      [
        "x"
      ]
    ],
    "emptyObj": {},
    "num": 1.5,
    "int": 42,
    "flag": true,
    "nothing": null
  }
}
'@

function New-FixtureHome([string]$Dir) {
  Assert-UnderTemp (Join-Path $Dir 'x')
  Write-Fixture (Join-Path $Dir '.agent-broker\agent-switchboard.exe') 'MZ-fixture'
  Write-Fixture (Join-Path $Dir '.claude\CLAUDE.md') ($ClaudeAbove + (New-UpstreamBlock "`r`n") + $ClaudeBelow)
  Write-Fixture (Join-Path $Dir '.codex\AGENTS.md') ($AgentsAbove + (New-UpstreamBlock "`n") + $AgentsBelow)
  Write-Fixture (Join-Path $Dir '.gemini\GEMINI.md') $GeminiOriginal
  Write-Fixture (Join-Path $Dir '.claude\agents\Explore.md') (New-ManagedFile $ExploreBody 'md' "`r`n")
  Write-Fixture (Join-Path $Dir '.claude\agents\economy-worker.md') $WorkerMd
  Write-Fixture (Join-Path $Dir '.codex\agents\explorer.toml') (New-ManagedFile $ExplorerToml 'toml' "`r`n")
  Write-Fixture (Join-Path $Dir '.codex\agents\worker.toml') (New-ManagedFile $WorkerToml 'toml' "`n")
  Write-Fixture (Join-Path $Dir '.claude\settings.json') (ConvertTo-Eol $SettingsFixture "`r`n")
}

function New-FreshHome([string]$Dir) {
  Assert-UnderTemp (Join-Path $Dir 'x')
  [void][System.IO.Directory]::CreateDirectory((Join-Path $Dir '.claude'))
  Write-Fixture (Join-Path $Dir '.agent-broker\agent-switchboard.exe') 'MZ-fixture'
}

function Get-ExpectedKitBlock([string]$Template, [string]$Eol) {
  $body = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir $Template)).Replace("`r`n", "`n").Trim()
  return (ConvertTo-Eol ($KitBegin + "`n" + $body + "`n" + $KitEnd) $Eol)
}

function Get-ExpectedNeutral([string]$Eol) {
  $body = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'neutralized-block.md')).Replace("`r`n", "`n").Trim()
  return (ConvertTo-Eol ($SentinelBegin + "`n" + $body + "`n" + $UpEnd) $Eol)
}

function Get-UserEnvSnapshot {
  $h = [Environment]::GetEnvironmentVariables('User')
  $keys = @($h.Keys | ForEach-Object { [string]$_ } | Sort-Object)
  return (($keys | ForEach-Object { $_ + '=' + [string]$h[$_] }) -join "`n")
}

function Get-RealProfileSnapshot {
  $real = [System.IO.Path]::GetFullPath($env:USERPROFILE)
  $rels = @('.claude\CLAUDE.md', '.claude\settings.json', '.claude\agents\Explore.md', '.claude\agents\economy-worker.md',
    '.claude\agents\consultant.md', '.claude\orchestration\roles.json', '.claude\orchestration\sync-roles.ps1',
    '.claude\orchestration\install-state.json', '.codex\AGENTS.md', '.codex\agents\explorer.toml',
    '.codex\agents\worker.toml', '.gemini\GEMINI.md')
  $lines = foreach ($r in $rels) {
    $p = Join-Path $real $r
    if ([System.IO.File]::Exists($p)) { $r + '=' + (Get-FileSha $p) } else { $r + '=<none>' }
  }
  $bk = Join-Path $real '.claude\orchestration-backups'
  $n = 0
  if ([System.IO.Directory]::Exists($bk)) { $n = @([System.IO.Directory]::GetDirectories($bk)).Count }
  return (@($lines) + ('backups=' + $n)) -join "`n"
}

# ================================================================ run
Write-Host ('switchboard-kit 테스트: ' + $HostLabel)
Write-Host ('임시 폴더: ' + $RunRoot)
[void][System.IO.Directory]::CreateDirectory($RunRoot)
$EnvBefore = Get-UserEnvSnapshot
$RealBefore = Get-RealProfileSnapshot

$HomeA = Join-Path $RunRoot 'homeA'   # 전체 흐름 + 바이트 복원
$HomeB = Join-Path $RunRoot 'homeB'   # 사용자 수정 뒤 제거
$HomeC = Join-Path $RunRoot 'homeC'   # 빈 홈
$HomeD = Join-Path $RunRoot 'homeD'   # 잘못된 settings.json
$HomeE = Join-Path $RunRoot 'homeE'   # 끝 표식 없는 블록
$HomeF = Join-Path $RunRoot 'homeF'   # agent-switchboard.exe 없음
$HomeG = Join-Path $RunRoot 'homeG'   # 매니페스트 없음
$HomeH = Join-Path $RunRoot 'homeH'   # 수동 설정에서 업그레이드
$Pristine = Join-Path $RunRoot 'pristine'
$ProjEmpty = Join-Path $RunRoot 'project-empty'
[void][System.IO.Directory]::CreateDirectory($ProjEmpty)
New-FixtureHome $Pristine
$PristineSnap = Get-TreeSnapshot $Pristine

# ---------------------------------------------------------------- static checks
Test-Case '하네스: %TEMP% 밖의 -HomeDir 와 -SkipEnvVar 없는 실행을 거부' {
  $threw = $false
  try { Assert-UnderTemp 'C:\Windows' } catch { $threw = $true }
  Assert-True $threw 'C:\Windows 를 거부하지 않음'
  $threw = $false
  try { [void](Invoke-Kit $Install $env:USERPROFILE @('-SkipEnvVar', '-DryRun')) } catch { $threw = $true }
  Assert-True $threw '실제 프로필을 거부하지 않음'
  $threw = $false
  try { [void](Invoke-Kit $Install (Join-Path $RunRoot 'nohome') @('-DryRun')) } catch { $threw = $true }
  Assert-True $threw '-SkipEnvVar 없는 install 을 거부하지 않음'
}

Test-Case '모든 .ps1 이 UTF-8 BOM 을 갖고 파서 오류가 없음' {
  $files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File)
  Assert-True ($files.Count -ge 4) ('.ps1 수가 이상함: {0}' -f $files.Count)
  foreach ($f in $files) {
    Assert-True (Test-HasBom $f.FullName) ('BOM 없음: ' + $f.FullName)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ('파서 오류: {0}: {1}' -f $f.Name, (@($errors) | ForEach-Object { $_.Message }) -join '; ')
  }
}

Test-Case '모든 템플릿에 BOM 이 없음' {
  $files = @(Get-ChildItem -LiteralPath $TemplatesDir -Recurse -File)
  Assert-True ($files.Count -eq 5) ('템플릿 수가 5 가 아님: {0}' -f $files.Count)
  foreach ($f in $files) { Assert-True (-not (Test-HasBom $f.FullName)) ('BOM 있음: ' + $f.FullName) }
}

Test-Case '.ps1 과 템플릿이 cp949 로 왕복해도 그대로 (콘솔 안전)' {
  try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
  $enc = [System.Text.Encoding]::GetEncoding(949, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
  $files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.md', '.json') })
  foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    try { $back = $enc.GetString($enc.GetBytes($text)) } catch { throw ('cp949 로 표현할 수 없는 문자: {0} ({1})' -f $f.Name, $_.Exception.Message) }
    Assert-True ($back -ceq $text) ('cp949 왕복 불일치: ' + $f.Name)
  }
}

Test-Case '템플릿 내용 규칙' {
  $neutral = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'neutralized-block.md'))
  Assert-True (-not $neutral.Contains('DEFAULT WORKHORSE')) 'neutralized-block.md 에 DEFAULT WORKHORSE'
  foreach ($name in @('claude-policy.md', 'codex-policy.md', 'neutralized-block.md', 'agents\consultant.md', 'roles.json')) {
    $t = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir $name))
    Assert-True (-not [regex]::IsMatch($t, '(?im)^(#{1,2})\s+cost-aware model routing\s*$')) ('레거시 제목: ' + $name)
    Assert-True (-not $t.Contains('agent-switchboard:cost-routing')) ('upstream 표식 문자열: ' + $name)
    Assert-True (-not $t.Contains('switchboard-kit:policy')) ('키트 표식 문자열: ' + $name)
    Assert-True (-not $t.Contains('Cost-efficient')) ('Cost-efficient: ' + $name)
    Assert-True (-not $t.Contains($LegacyClaude)) ('레거시 문구: ' + $name)
    Assert-True (-not [regex]::IsMatch($t, '(?i)[a-z]:[\\/]+users[\\/]')) ('개인 경로: ' + $name)
  }
  $cp = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'claude-policy.md'))
  Assert-True ($cp.Contains('.orchestration\roles.json') -and $cp.Contains('.claude\orchestration\roles.json')) 'claude-policy: 두 단계 매니페스트'
  Assert-True ($cp.Contains('Same-vendor claude') -and $cp.Contains('native_subagent')) 'claude-policy: 같은 벤더 규칙'
  Assert-True ($cp.Contains('sync-roles.ps1') -and $cp.Contains('frontmatter')) 'claude-policy: frontmatter 동기화'
  Assert-True ($cp.Contains('1.0.39~1.0.47') -and $cp.Contains('claude-only')) 'claude-policy: receipt / 레인 장애'
  $xp = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'codex-policy.md'))
  Assert-True ($xp.Contains('native_unavailable_reason') -and $xp.Contains('12')) 'codex-policy: native_unavailable_reason 12자'
  Assert-True ($xp.Contains('explorer') -and $xp.Contains('worker') -and $xp.Contains('target_agent="claude"')) 'codex-policy: codex 네이티브, claude route'
  Assert-True ($xp.Contains('1.0.39~1.0.47')) 'codex-policy: receipt'
  $roles = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'roles.json')))
  Assert-True ($roles.active_profile -eq 'claude-lead') 'roles.json 기본 프로필'
  $names = @($roles.profiles.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
  Assert-True ($names -eq 'claude-lead,codex-lead,claude-only,codex-only') ('프로필 목록: ' + $names)
  foreach ($pp in $roles.profiles.PSObject.Properties) {
    foreach ($rp in $pp.Value.roles.PSObject.Properties) {
      $r = $rp.Value
      Assert-True ($roles._valid_values.($r.vendor + '_model') -ccontains $r.model) ('_valid_values 에 없는 model: {0}.{1}' -f $pp.Name, $rp.Name)
      if ($null -ne $r.effort) { Assert-True ($roles._valid_values.($r.vendor + '_effort') -ccontains $r.effort) ('_valid_values 에 없는 effort: {0}.{1}' -f $pp.Name, $rp.Name) }
    }
  }
  $cm = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'agents\consultant.md'))
  Assert-True ($cm.StartsWith("---`n") -and $cm.Contains("`nmodel: opus`n") -and $cm.Contains("`neffort: max`n") -and $cm.Contains("`nname: consultant`n")) 'consultant.md frontmatter'
  Assert-True (-not $cm.Contains('agent-switchboard:managed')) 'consultant.md 관리 표식'
}

Test-Case '픽스처 확인: 설치 전에는 agent-switchboard 가 모두 덮어쓸 상태' {
  Assert-True ((Get-UpstreamBlockAction (Get-UpstreamView (Join-Path $Pristine '.claude\CLAUDE.md'))) -eq 'overwrite') 'CLAUDE.md 블록이 자기 일관적이지 않음'
  Assert-True ((Get-UpstreamBlockAction (Get-UpstreamView (Join-Path $Pristine '.codex\AGENTS.md'))) -eq 'overwrite') 'AGENTS.md 블록'
  Assert-True ((Get-UpstreamBlockAction (Get-UpstreamView (Join-Path $Pristine '.gemini\GEMINI.md'))) -eq 'append') 'GEMINI.md 는 추가 대상이어야 함'
  Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $Pristine '.claude\agents\Explore.md')) 'Explore' 'md') -eq 'overwrite') 'Explore.md'
  Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $Pristine '.claude\agents\economy-worker.md')) 'economy-worker' 'md') -eq 'overwrite') 'economy-worker.md (레거시 문구)'
  Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $Pristine '.codex\agents\explorer.toml')) 'explorer' 'toml') -eq 'overwrite') 'explorer.toml'
  Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $Pristine '.codex\agents\worker.toml')) 'worker' 'toml') -eq 'overwrite') 'worker.toml'
  $ex = Read-Raw (Join-Path $Pristine '.claude\agents\Explore.md')
  Assert-True ($ex.Split("`n")[1].StartsWith('# agent-switchboard:managed sha256=')) 'md 표식이 2번째 줄이 아님'
  $tm = Read-Raw (Join-Path $Pristine '.codex\agents\worker.toml')
  Assert-True ($tm.StartsWith('# agent-switchboard:managed sha256=')) 'toml 표식이 1번째 줄이 아님'
}

# ---------------------------------------------------------------- home A: full flow
Copy-Tree $Pristine $HomeA
$script:SnapA0 = Get-TreeSnapshot $HomeA

Test-Case 'DryRun 은 아무것도 바꾸지 않음' {
  $r = Invoke-Kit $Install $HomeA @('-SkipEnvVar', '-DryRun')
  Assert-Exit $r 0 'install -DryRun'
  Assert-SameSnapshot $script:SnapA0 (Get-TreeSnapshot $HomeA) 'DryRun 뒤 홈'
  Assert-True (-not [System.IO.Directory]::Exists((Join-Path $HomeA '.claude\orchestration-backups'))) '백업 폴더가 생김'
  Assert-True ($r.Output.Contains('[DRY]')) 'DryRun 출력 없음'
}

Test-Case 'agent-switchboard.exe 가 없으면 중단하고 아무것도 바꾸지 않음' {
  Copy-Tree $Pristine $HomeF
  [System.IO.File]::Delete((Join-Path $HomeF '.agent-broker\agent-switchboard.exe'))
  $before = Get-TreeSnapshot $HomeF
  $r = Invoke-Kit $Install $HomeF @('-SkipEnvVar')
  Assert-Exit $r 1 'install (exe 없음)'
  Assert-SameSnapshot $before (Get-TreeSnapshot $HomeF) 'exe 없음 설치 뒤 홈'
  Assert-True (-not [System.IO.Directory]::Exists((Join-Path $HomeF '.claude\orchestration-backups'))) '백업 폴더가 생김'
}

Test-Case '설치 성공 (종료 코드 0, [FAIL] 없음)' {
  $r = Invoke-Kit $Install $HomeA @('-SkipEnvVar')
  Assert-Exit $r 0 'install'
  Assert-True (-not $r.Output.Contains('[FAIL]')) ("[FAIL] 출력:`n" + $r.Output)
  $script:InstallOutputA = $r.Output
}

Test-Case '사용자 텍스트가 바이트 단위로 보존되고 블록 배치가 정확함' {
  $claude = Read-Raw (Join-Path $HomeA '.claude\CLAUDE.md')
  $expected = (Get-ExpectedKitBlock 'claude-policy.md' "`r`n") + "`r`n`r`n" + $ClaudeAbove + (Get-ExpectedNeutral "`r`n") + $ClaudeBelow
  Assert-SameText $expected $claude 'CLAUDE.md'
  $agents = Read-Raw (Join-Path $HomeA '.codex\AGENTS.md')
  $expected = (Get-ExpectedKitBlock 'codex-policy.md' "`n") + "`n`n" + $AgentsAbove + (Get-ExpectedNeutral "`n") + $AgentsBelow
  Assert-SameText $expected $agents 'AGENTS.md'
  $gemini = Read-Raw (Join-Path $HomeA '.gemini\GEMINI.md')
  $expected = $GeminiOriginal + "`n`n" + (Get-ExpectedNeutral "`n") + "`n"
  Assert-SameText $expected $gemini 'GEMINI.md'
}

Test-Case '키트 정책 블록이 맨 위에 딱 한 번' {
  foreach ($rel in @('.claude\CLAUDE.md', '.codex\AGENTS.md')) {
    $t = Read-Raw (Join-Path $HomeA $rel)
    Assert-True ($t.StartsWith($KitBegin)) ('맨 위가 아님: ' + $rel)
    Assert-True (([regex]::Matches($t, [regex]::Escape($KitBegin))).Count -eq 1) ('시작 표식 수: ' + $rel)
    Assert-True (([regex]::Matches($t, [regex]::Escape($KitEnd))).Count -eq 1) ('끝 표식 수: ' + $rel)
  }
  Assert-True (-not (Read-Raw (Join-Path $HomeA '.gemini\GEMINI.md')).Contains($KitBegin)) 'GEMINI.md 에 정책 블록'
}

Test-Case '센티널 체크섬(0 x 64) 블록이 세 파일에 있음' {
  foreach ($rel in @('.claude\CLAUDE.md', '.codex\AGENTS.md', '.gemini\GEMINI.md')) {
    $t = Read-Raw (Join-Path $HomeA $rel)
    Assert-True (([regex]::Matches($t, [regex]::Escape($SentinelBegin))).Count -eq 1) ('센티널: ' + $rel)
    Assert-True (([regex]::Matches($t, $UpBeginPattern)).Count -eq 1) ('upstream 시작 표식 수: ' + $rel)
  }
}

Test-Case '줄바꿈 방식 보존 (CRLF / LF)' {
  $crlfFiles = @('.claude\CLAUDE.md', '.claude\agents\Explore.md', '.codex\agents\explorer.toml')
  $lfFiles = @('.codex\AGENTS.md', '.gemini\GEMINI.md', '.claude\agents\economy-worker.md', '.codex\agents\worker.toml')
  foreach ($rel in $crlfFiles) {
    $t = Read-Raw (Join-Path $HomeA $rel)
    Assert-True (-not [regex]::IsMatch($t, '(?<!\r)\n')) ('CRLF 파일에 LF 단독: ' + $rel)
  }
  foreach ($rel in $lfFiles) {
    $t = Read-Raw (Join-Path $HomeA $rel)
    Assert-True (-not $t.Contains("`r")) ('LF 파일에 CR: ' + $rel)
  }
}

Test-Case 'agent-switchboard 판정 이식: 설치 뒤에는 모두 "건드리지 않음"' {
  foreach ($rel in @('.claude\CLAUDE.md', '.codex\AGENTS.md', '.gemini\GEMINI.md')) {
    $a = Get-UpstreamBlockAction (Get-UpstreamView (Join-Path $HomeA $rel))
    Assert-True ($a -eq 'untouched') ('{0}: {1}' -f $rel, $a)
  }
  $roles = @(@('.claude\agents\Explore.md', 'Explore', 'md'), @('.claude\agents\economy-worker.md', 'economy-worker', 'md'),
    @('.codex\agents\explorer.toml', 'explorer', 'toml'), @('.codex\agents\worker.toml', 'worker', 'toml'))
  foreach ($x in $roles) {
    $a = Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $HomeA $x[0])) $x[1] $x[2]
    Assert-True ($a -eq 'untouched') ('{0}: {1}' -f $x[0], $a)
  }
  $s = Read-Json (Join-Path $HomeA '.claude\settings.json')
  foreach ($grp in @($s.hooks.SessionStart)) { foreach ($h in @($grp.hooks)) { Assert-True (-not (Test-OwnedHook $h)) 'SessionStart 훅이 agent-switchboard 소유로 판정됨' } }
  $upHook = @(@($s.hooks.PreToolUse)[0].hooks)[0]
  Assert-True (Test-OwnedHook $upHook) '이식한 소유 판정이 upstream 훅을 못 알아봄'
  $explore = Read-Raw (Join-Path $HomeA '.claude\agents\Explore.md')
  Assert-True ($explore.Contains('Low-cost') -and -not $explore.Contains('agent-switchboard:managed')) 'Explore.md 정리 안 됨'
  Assert-True (-not (Read-Raw (Join-Path $HomeA '.claude\agents\economy-worker.md')).Contains($LegacyClaude)) 'economy-worker.md 레거시 문구'
}

Test-Case 'settings.json: 키트 훅 하나 말고는 원본과 완전히 같음' {
  $orig = ConvertFrom-Json -InputObject $SettingsFixture
  $after = Read-Json (Join-Path $HomeA '.claude\settings.json')
  $ss = @($after.hooks.SessionStart)
  Assert-True ($ss.Count -eq 2) ('SessionStart 그룹 수: {0}' -f $ss.Count)
  $grp = $ss[1]
  Assert-True ((@($grp.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq 'hooks') '그룹 키'
  Assert-True (@($grp.hooks).Count -eq 1) '핸들러 수'
  $h = @($grp.hooks)[0]
  Assert-True ($h.type -ceq 'command') 'type'
  Assert-True ($h.command -ceq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) ('command: ' + $h.command)
  $expArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $HomeA '.claude\orchestration\sync-roles.ps1'), '-Quiet')
  Assert-True ((@($h.args) -join '|') -ceq ($expArgs -join '|')) ('args: ' + (@($h.args) -join ' '))
  Assert-True ([int]$h.timeout -eq 30) 'timeout'
  $after.hooks.SessionStart = [object[]]@($ss[0])
  $d = Get-JsonDiff $orig $after
  Assert-True ($null -eq $d) ('원본과 다름: ' + $d)
  Assert-True ($after.statusLine.command -ceq 'echo 한글 상태줄') '한글 값'
}

Test-Case '두 번째 설치는 멱등 (대상 파일 해시 동일)' {
  $before = Get-TreeSnapshot $HomeA
  $state = Read-Json (Join-Path $HomeA '.claude\orchestration\install-state.json')
  $r = Invoke-Kit $Install $HomeA @('-SkipEnvVar')
  Assert-Exit $r 0 'install #2'
  Assert-SameSnapshot $before (Get-TreeSnapshot $HomeA) '두 번째 설치 뒤'
  $state2 = Read-Json (Join-Path $HomeA '.claude\orchestration\install-state.json')
  Assert-True ($state.original_backup_dir -ceq $state2.original_backup_dir) '원본 백업 포인터가 바뀜'
  $bks = @([System.IO.Directory]::GetDirectories((Join-Path $HomeA '.claude\orchestration-backups')))
  Assert-True ($bks.Count -eq 2) ('백업 폴더 수: {0}' -f $bks.Count)
  $orig = $state.original_backup_dir
  Assert-True ((Get-FileSha (Join-Path $orig '.claude\CLAUDE.md')) -eq $script:SnapA0['.claude\CLAUDE.md']) '원본 백업의 CLAUDE.md 가 설치 전과 다름'
  Assert-True ($state.gate_mode_previous -eq $null -or $state.gate_mode_previous -is [string]) 'gate_mode_previous 기록'
  Assert-True ($state.settings.existed -eq $true -and $state.settings.session_start_existed -eq $true) 'settings 기록'
}

Test-Case 'sync-roles: roles.json 수정 반영과 다시 관리된 Explore.md 정리' {
  $kitRoles = Join-Path $HomeA '.claude\orchestration\roles.json'
  $kitSync = Join-Path $HomeA '.claude\orchestration\sync-roles.ps1'
  Assert-True (Test-HasBom $kitSync) '설치된 sync-roles.ps1 에 BOM 없음'
  $cfg = Read-Json $kitRoles
  $cfg.active_profile = 'claude-lead'
  $cfg.profiles.'claude-lead'.roles.reader.model = 'sonnet'
  $cfg.profiles.'claude-lead'.roles.reader.effort = 'low'
  $cfg.profiles.'claude-lead'.roles.implementer.effort = 'high'
  Write-Fixture $kitRoles (ConvertTo-Json -InputObject $cfg -Depth 100)
  # agent-switchboard 가 Explore.md 를 다시 만든 상황 (유효한 관리 표식)
  Write-Fixture (Join-Path $HomeA '.claude\agents\Explore.md') (New-ManagedFile $ExploreBody 'md' "`r`n")
  $r = Invoke-Kit $kitSync $HomeA @('-ProjectRoot', $ProjEmpty, '-Quiet')
  Assert-Exit $r 0 'sync -Quiet'
  Assert-True ($r.Output.Trim().Length -eq 0) ('-Quiet 인데 출력이 있음: ' + $r.Output)
  $ex = Read-Raw (Join-Path $HomeA '.claude\agents\Explore.md')
  Assert-True ($ex.Contains("`r`nmodel: sonnet`r`n") -and $ex.Contains("`r`neffort: low`r`n")) ('Explore.md 값: ' + $ex)
  Assert-True (-not $ex.Contains('agent-switchboard:managed') -and -not $ex.Contains('Cost-efficient')) 'Explore.md 정리 안 됨'
  Assert-True (-not [regex]::IsMatch($ex, '(?<!\r)\n')) 'Explore.md 줄바꿈이 바뀜'
  Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $HomeA '.claude\agents\Explore.md')) 'Explore' 'md') -eq 'untouched') 'Explore.md 판정'
  $ew = Read-Raw (Join-Path $HomeA '.claude\agents\economy-worker.md')
  Assert-True ($ew.Contains("`nmodel: sonnet`n") -and $ew.Contains("`neffort: high`n")) ('economy-worker.md 값: ' + $ew)

  # effort null 이면 effort 줄 삭제
  $cfg.profiles.'claude-lead'.roles.reader.effort = $null
  Write-Fixture $kitRoles (ConvertTo-Json -InputObject $cfg -Depth 100)
  $r = Invoke-Kit $kitSync $HomeA @('-ProjectRoot', $ProjEmpty, '-Quiet')
  Assert-Exit $r 0 'sync (effort null)'
  $ex = Read-Raw (Join-Path $HomeA '.claude\agents\Explore.md')
  Assert-True (-not $ex.Contains('effort:') -and $ex.Contains("`r`nmodel: sonnet`r`n")) ('effort 줄이 남음: ' + $ex)

  # Codex 쪽: codex-lead 는 reader/implementer 가 codex
  $cfg.active_profile = 'codex-lead'
  Write-Fixture $kitRoles (ConvertTo-Json -InputObject $cfg -Depth 100)
  $r = Invoke-Kit $kitSync $HomeA @('-ProjectRoot', $ProjEmpty, '-Quiet')
  Assert-Exit $r 0 'sync (codex-lead)'
  $et = Read-Raw (Join-Path $HomeA '.codex\agents\explorer.toml')
  Assert-True ($et.Contains("`r`nmodel = `"gpt-5.6-terra`"`r`nmodel_reasoning_effort = `"medium`"`r`n")) ('explorer.toml: ' + $et)
  Assert-True ($et.Contains("`r`nmodel = `"trap-inside-multiline`"`r`nmodel_reasoning_effort = `"trap-effort`"`r`n")) 'explorer.toml 여러 줄 문자열 안이 바뀜'
  $wt = Read-Raw (Join-Path $HomeA '.codex\agents\worker.toml')
  Assert-True ($wt.Contains("`nmodel = `"gpt-5.6-sol`"`nmodel_reasoning_effort = `"high`"`n")) ('worker.toml: ' + $wt)
  $cm = Read-Raw (Join-Path $HomeA '.claude\agents\consultant.md')
  Assert-True ($cm.Contains("`nmodel: opus`n") -and $cm.Contains("`neffort: max`n")) 'consultant.md'
  foreach ($x in @(@('.codex\agents\explorer.toml', 'explorer'), @('.codex\agents\worker.toml', 'worker'))) {
    Assert-True ((Get-UpstreamRoleAction (Get-UpstreamView (Join-Path $HomeA $x[0])) $x[1] 'toml') -eq 'untouched') ('판정: ' + $x[0])
  }

  # 프로젝트 매니페스트가 전역보다 우선, 목록에 없는 값은 경고
  $proj = Join-Path $RunRoot 'project-override'
  $pcfg = Read-Json (Join-Path $TemplatesDir 'roles.json')
  $pcfg.active_profile = 'claude-only'
  $pcfg.profiles.'claude-only'.roles.reader.model = 'haiku'
  $pcfg.profiles.'claude-only'.roles.reader.effort = 'medium'
  $pcfg.profiles.'claude-only'.roles.implementer.effort = 'extra high'
  Write-Fixture (Join-Path $proj '.orchestration\roles.json') (ConvertTo-Json -InputObject $pcfg -Depth 100)
  $r = Invoke-Kit $kitSync $HomeA @('-ProjectRoot', $proj)
  Assert-Exit $r 0 'sync (프로젝트)'
  Assert-True ($r.Output.Contains('[WARN]') -and $r.Output.Contains('extra high')) ('경고 없음: ' + $r.Output)
  $ex = Read-Raw (Join-Path $HomeA '.claude\agents\Explore.md')
  Assert-True ($ex.Contains("`r`nmodel: haiku`r`n") -and $ex.Contains("`r`neffort: medium`r`n")) ('프로젝트 값 미반영: ' + $ex)
  $ew = Read-Raw (Join-Path $HomeA '.claude\agents\economy-worker.md')
  Assert-True ($ew.Contains("`neffort: `"extra high`"`n")) ('따옴표 처리: ' + $ew)
}

Test-Case 'sync-roles: 매니페스트가 없으면 0, 잘못된 매니페스트면 1' {
  New-FreshHome $HomeG
  $r = Invoke-Kit $SyncRepo $HomeG @('-ProjectRoot', $ProjEmpty, '-Quiet')
  Assert-Exit $r 0 'sync (매니페스트 없음)'
  Assert-True ($r.Output.Trim().Length -eq 0) ('-Quiet 출력: ' + $r.Output)
  $bad = Join-Path $RunRoot 'bad-roles.json'
  Write-Fixture $bad '{ "active_profile": "x", '
  $r = Invoke-Kit $SyncRepo $HomeG @('-ProjectRoot', $ProjEmpty, '-ManifestPath', $bad, '-Quiet')
  Assert-Exit $r 1 'sync (잘못된 JSON)'
  Assert-True ($r.Output.Contains('[FAIL]')) '오류 메시지 없음'
}

Test-Case '제거: 다른 변경이 없으면 설치 전과 바이트 단위로 같음' {
  # agent-switchboard 가 settings.json 을 다시 직렬화한 상황도 흉내 냅니다 (서식만 바뀜)
  $sp = Join-Path $HomeA '.claude\settings.json'
  Write-Fixture $sp (ConvertTo-UpstreamStyleJson (Read-Json $sp))
  $r = Invoke-Kit $Uninstall $HomeA @('-SkipEnvVar')
  Assert-Exit $r 0 'uninstall'
  Assert-True (-not $r.Output.Contains('[FAIL]')) ("[FAIL] 출력:`n" + $r.Output)
  Assert-SameSnapshot $script:SnapA0 (Get-TreeSnapshot $HomeA) '제거 뒤 홈'
  $moved = @(Get-ChildItem -LiteralPath (Join-Path $HomeA '.claude\orchestration-backups') -Recurse -File -Filter 'install-state.json')
  Assert-True ($moved.Count -eq 1) 'install-state.json 이 백업 폴더로 옮겨지지 않음'
  $movedRoles = Join-Path $moved[0].DirectoryName 'roles.json'
  Assert-True ([System.IO.File]::Exists($movedRoles)) 'roles.json 이 백업 폴더로 옮겨지지 않음'
}

# ---------------------------------------------------------------- home B: user edits between install and uninstall
Test-Case '제거는 외과적: 설치 뒤 사용자가 고친 CLAUDE.md / settings.json 유지' {
  Copy-Tree $Pristine $HomeB
  $r = Invoke-Kit $Install $HomeB @('-SkipEnvVar')
  Assert-Exit $r 0 'install'
  $cp = Join-Path $HomeB '.claude\CLAUDE.md'
  $t = Read-Raw $cp
  $t = $t.Replace("사용자 텍스트 위쪽.`r`n", "사용자 텍스트 위쪽.`r`n나중에 추가한 줄.`r`n") + "끝에 추가한 줄.`r`n"
  Write-Fixture $cp $t
  $sp = Join-Path $HomeB '.claude\settings.json'
  $s = Read-Json $sp
  $s | Add-Member -NotePropertyName 'userAdded' -NotePropertyValue 7
  $post = ConvertFrom-Json -InputObject '{"hooks":[{"type":"command","command":"echo user-post"}]}'
  $s.hooks | Add-Member -NotePropertyName 'PostToolUse' -NotePropertyValue ([object[]]@($post))
  Write-Fixture $sp (ConvertTo-UpstreamStyleJson $s)

  $r = Invoke-Kit $Uninstall $HomeB @('-SkipEnvVar')
  Assert-Exit $r 0 'uninstall'
  $expected = ($ClaudeAbove + (New-UpstreamBlock "`r`n") + $ClaudeBelow).Replace("사용자 텍스트 위쪽.`r`n", "사용자 텍스트 위쪽.`r`n나중에 추가한 줄.`r`n") + "끝에 추가한 줄.`r`n"
  Assert-SameText $expected (Read-Raw $cp) 'CLAUDE.md'
  Assert-True ((Get-FileSha (Join-Path $HomeB '.codex\AGENTS.md')) -eq $PristineSnap['.codex\AGENTS.md']) 'AGENTS.md'
  Assert-True ((Get-FileSha (Join-Path $HomeB '.gemini\GEMINI.md')) -eq $PristineSnap['.gemini\GEMINI.md']) 'GEMINI.md'

  $after = Read-Json $sp
  Assert-True ($after.userAdded -eq 7) 'userAdded 유지 안 됨'
  Assert-True (@($after.hooks.PostToolUse).Count -eq 1 -and @($after.hooks.PostToolUse)[0].hooks[0].command -eq 'echo user-post') 'PostToolUse 유지 안 됨'
  $after.PSObject.Properties.Remove('userAdded')
  $after.hooks.PSObject.Properties.Remove('PostToolUse')
  $d = Get-JsonDiff (ConvertFrom-Json -InputObject $SettingsFixture) $after
  Assert-True ($null -eq $d) ('settings.json 차이: ' + $d)
  foreach ($rel in @('.claude\agents\Explore.md', '.claude\agents\economy-worker.md', '.codex\agents\explorer.toml', '.codex\agents\worker.toml')) {
    Assert-True ((Get-FileSha (Join-Path $HomeB $rel)) -eq $PristineSnap[$rel]) ('롤 파일 복원: ' + $rel)
  }
  Assert-True (-not [System.IO.File]::Exists((Join-Path $HomeB '.claude\agents\consultant.md'))) 'consultant.md 가 남음'
  Assert-True (-not [System.IO.Directory]::Exists((Join-Path $HomeB '.claude\orchestration'))) '키트 폴더가 남음'
}

# ---------------------------------------------------------------- home C: fresh home
Test-Case '빈 홈: 설치 후 제거하면 원래대로' {
  New-FreshHome $HomeC
  $before = Get-TreeSnapshot $HomeC
  $r = Invoke-Kit $Install $HomeC @('-SkipEnvVar')
  Assert-Exit $r 0 'install'
  $cp = Join-Path $HomeC '.claude\CLAUDE.md'
  $expected = (Get-ExpectedKitBlock 'claude-policy.md' "`r`n") + "`r`n`r`n" + (Get-ExpectedNeutral "`r`n") + "`r`n"
  Assert-SameText $expected (Read-Raw $cp) '새 CLAUDE.md'
  Assert-True ((Get-UpstreamBlockAction (Get-UpstreamView $cp)) -eq 'untouched') 'CLAUDE.md 판정'
  $s = Read-Json (Join-Path $HomeC '.claude\settings.json')
  Assert-True ((@($s.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq 'hooks') 'settings.json 최상위 키'
  Assert-True ((@($s.hooks.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq 'SessionStart') 'hooks 키'
  Assert-True ($s.hooks.SessionStart -is [array] -and @($s.hooks.SessionStart).Count -eq 1) 'SessionStart 가 단일 원소 배열이 아님'
  Assert-True (@($s.hooks.SessionStart)[0].hooks -is [array]) 'hooks 가 배열이 아님'
  Assert-True (@($s.hooks.SessionStart)[0].hooks[0].args -is [array]) 'args 가 배열이 아님'
  Assert-True ([System.IO.File]::Exists((Join-Path $HomeC '.claude\agents\consultant.md'))) 'consultant.md 없음'
  Assert-True (-not [System.IO.Directory]::Exists((Join-Path $HomeC '.codex')) -and -not [System.IO.Directory]::Exists((Join-Path $HomeC '.gemini'))) '.codex/.gemini 가 생김'
  $r = Invoke-Kit $Uninstall $HomeC @('-SkipEnvVar')
  Assert-Exit $r 0 'uninstall'
  Assert-SameSnapshot $before (Get-TreeSnapshot $HomeC) '빈 홈 제거 뒤'
  # 두 번째 제거는 설치 기록이 없으므로 아무것도 바꾸지 않고 실패
  $r = Invoke-Kit $Uninstall $HomeC @('-SkipEnvVar')
  Assert-Exit $r 1 'uninstall #2'
  Assert-SameSnapshot $before (Get-TreeSnapshot $HomeC) '두 번째 제거 뒤'
}

# ---------------------------------------------------------------- home D: invalid settings.json
Test-Case '잘못된 settings.json: 건드리지 않고 [FAIL], 종료 코드 1, 나머지는 적용' {
  Copy-Tree $Pristine $HomeD
  $sp = Join-Path $HomeD '.claude\settings.json'
  Write-Fixture $sp "{ `"hooks`": { invalid json"
  $sha = Get-FileSha $sp
  $r = Invoke-Kit $Install $HomeD @('-SkipEnvVar')
  Assert-Exit $r 1 'install'
  Assert-True ($r.Output.Contains('[FAIL] settings.json')) ('settings [FAIL] 없음: ' + $r.Output)
  Assert-True ((Get-FileSha $sp) -eq $sha) 'settings.json 이 바뀜'
  Assert-True ((Read-Raw (Join-Path $HomeD '.claude\CLAUDE.md')).StartsWith($KitBegin)) 'CLAUDE.md 가 적용되지 않음'
  $r = Invoke-Kit $Uninstall $HomeD @('-SkipEnvVar')
  Assert-True ((Get-FileSha (Join-Path $HomeD '.claude\CLAUDE.md')) -eq $PristineSnap['.claude\CLAUDE.md']) 'CLAUDE.md 복원'
  Assert-True ((Get-FileSha $sp) -eq $sha) '제거 뒤 settings.json 이 바뀜'
}

# ---------------------------------------------------------------- home E: begin without end
Test-Case '끝 표식 없는 upstream 블록: 파일을 건드리지 않고 [WARN]' {
  Copy-Tree $Pristine $HomeE
  $cp = Join-Path $HomeE '.claude\CLAUDE.md'
  $broken = "위쪽`r`n" + (New-UpstreamBlock "`r`n").Replace($UpEnd, '') + "`r`n아래쪽`r`n"
  Write-Fixture $cp $broken
  $sha = Get-FileSha $cp
  $r = Invoke-Kit $Install $HomeE @('-SkipEnvVar')
  Assert-Exit $r 0 'install'
  Assert-True ($r.Output.Contains('[WARN]')) '[WARN] 없음'
  Assert-True ((Get-FileSha $cp) -eq $sha) 'CLAUDE.md 가 바뀜'
}

# ---------------------------------------------------------------- home H: upgrade from a hand-made setup
Test-Case '수동 설정이 있던 홈: 중복 훅 없음, roles.json 유지, 제거하면 원래대로' {
  Copy-Tree $Pristine $HomeH
  $cp = Join-Path $HomeH '.claude\CLAUDE.md'
  Write-Fixture $cp ($ClaudeAbove + $SentinelBegin + "`r`n`r`n직접 비워 둔 블록입니다.`r`n`r`n" + $UpEnd + $ClaudeBelow)
  $rolesText = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir 'roles.json')).Replace('"active_profile": "claude-lead"', '"active_profile": "codex-lead"')
  Assert-True ($rolesText.Contains('"active_profile": "codex-lead"')) '픽스처 roles.json 준비 실패'
  $kitRoles = Join-Path $HomeH '.claude\orchestration\roles.json'
  $kitSync = Join-Path $HomeH '.claude\orchestration\sync-roles.ps1'
  Write-Fixture $kitRoles $rolesText
  Write-Fixture $kitSync "# 예전 수동 동기화 스크립트`r`nexit 0`r`n" -Bom
  [System.IO.File]::Copy((Join-Path $TemplatesDir 'agents\consultant.md'), (Join-Path $HomeH '.claude\agents\consultant.md'))
  $sp = Join-Path $HomeH '.claude\settings.json'
  $s = ConvertFrom-Json -InputObject $SettingsFixture
  $hand = ConvertFrom-Json -InputObject '{"hooks":[{"type":"command","command":"C:/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe","args":["-NoProfile","-ExecutionPolicy","Bypass","-Command","x"],"timeout":20}]}'
  $handHook = @($hand.hooks)[0]
  $handHook.args[4] = "& '" + $kitSync + "' *> `$null"
  $s.hooks.SessionStart = [object[]]@(@($s.hooks.SessionStart)[0], $hand)
  Write-Fixture $sp (ConvertTo-UpstreamStyleJson $s)
  $before = Get-TreeSnapshot $HomeH

  $r = Invoke-Kit $Install $HomeH @('-SkipEnvVar')
  Assert-Exit $r 0 'install'
  Assert-True ((Get-FileSha $sp) -eq $before['.claude\settings.json']) 'settings.json 이 바뀜 (훅 중복 추가?)'
  Assert-True ((Get-FileSha $kitRoles) -eq $before['.claude\orchestration\roles.json']) '기존 roles.json 이 바뀜'
  Assert-True ((Get-FileSha $kitSync) -eq (Get-FileSha $SyncRepo)) 'sync-roles.ps1 이 키트 버전으로 갱신되지 않음'
  $t = Read-Raw $cp
  $expected = (Get-ExpectedKitBlock 'claude-policy.md' "`r`n") + "`r`n`r`n" + $ClaudeAbove + (Get-ExpectedNeutral "`r`n") + $ClaudeBelow
  Assert-SameText $expected $t 'CLAUDE.md'
  $wt = Read-Raw (Join-Path $HomeH '.codex\agents\worker.toml')
  Assert-True ($wt.Contains("`nmodel = `"gpt-5.6-sol`"`nmodel_reasoning_effort = `"high`"`n")) ('기존 roles.json(codex-lead) 이 적용되지 않음: ' + $wt)

  $r = Invoke-Kit $Uninstall $HomeH @('-SkipEnvVar')
  Assert-Exit $r 0 'uninstall'
  Assert-True (-not $r.Output.Contains('[FAIL]') -and -not $r.Output.Contains('[WARN]')) ("[FAIL]/[WARN] 출력:`n" + $r.Output)
  Assert-SameSnapshot $before (Get-TreeSnapshot $HomeH) '제거 뒤 홈'
}

# ---------------------------------------------------------------- global invariants
Test-Case '사용자 환경 변수가 전체 실행 전후로 같음' {
  Assert-True ((Get-UserEnvSnapshot) -ceq $EnvBefore) '사용자 환경 변수가 바뀜'
}

Test-Case '실제 프로필 대상 파일이 전후로 같음' {
  Assert-True ((Get-RealProfileSnapshot) -ceq $RealBefore) '실제 프로필이 바뀜'
}

# ================================================================ summary
$pass = @($script:Results | Where-Object { $_.Pass }).Count
$fail = @($script:Results | Where-Object { -not $_.Pass }).Count
Write-Host ''
Write-Host ('결과 [{0}]: PASS {1} / FAIL {2}' -f $HostLabel, $pass, $fail)
if ($fail -gt 0) {
  Write-Host ('실패. 임시 폴더를 남겼습니다: ' + $RunRoot) -ForegroundColor Red
  exit 1
}
if ($KeepTemp) { Write-Host ('임시 폴더: ' + $RunRoot) }
else {
  Assert-UnderTemp (Join-Path $RunRoot 'x')
  Remove-Item -LiteralPath $RunRoot -Recurse -Force
}
exit 0
