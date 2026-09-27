<#
.SYNOPSIS
  switchboard-kit 제거. 키트가 넣은 것만 골라서 되돌립니다.

.DESCRIPTION
  설치 뒤에 사용자가 고친 내용을 지우지 않도록 파일을 통째로 되돌리지 않고 키트가 넣은
  부분만 걷어 냅니다.
    - CLAUDE.md / AGENTS.md: 키트 정책 블록과 설치 때 넣은 빈 줄을 지웁니다.
    - CLAUDE.md / AGENTS.md / GEMINI.md: 무력화한 agent-switchboard 블록을 설치 전 백업의
      원래 블록으로 바꿉니다. 원래 블록이 없었다면 키트가 넣은 블록과 구분 줄을 지웁니다.
    - agent-switchboard 롤 파일 4개(Explore.md, economy-worker.md, explorer.toml,
      worker.toml)는 설치 전 백업으로 되돌리고, 설치 전에 없던 파일은 지웁니다.
    - consultant.md 는 설치 전에 없었다면 지웁니다.
    - settings.json 에서는 키트의 SessionStart 훅만 지웁니다.
    - AGENT_BROKER_GATE_MODE 를 설치 전 값으로 되돌립니다. (-SkipEnvVar 로 생략)
    - roles.json 과 install-state.json 은 백업 폴더로 옮기고 키트 폴더를 지웁니다.
  바꾸기 전 현재 파일은 <BackupDir>\kit-removed-<시각>\ 에 남깁니다.

.PARAMETER HomeDir
  대상 사용자 홈. 기본값은 %USERPROFILE% 입니다.
.PARAMETER BackupDir
  설치 전 백업 폴더. 기본값은 install-state.json 에 기록된 최초 설치 백업입니다.
.PARAMETER SkipEnvVar
  사용자 환경 변수를 건드리지 않습니다.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
  [string]$HomeDir = $env:USERPROFILE,
  [string]$BackupDir = '',
  [switch]$SkipEnvVar
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ================================================================ constants
$GateVar = 'AGENT_BROKER_GATE_MODE'
$KitBegin = '<!-- switchboard-kit:policy:begin -->'
$KitEnd = '<!-- switchboard-kit:policy:end -->'
$UpBeginRe = New-Object System.Text.RegularExpressions.Regex '<!-- agent-switchboard:cost-routing:begin sha256=([0-9a-f]{64}) -->'
$UpEnd = '<!-- agent-switchboard:cost-routing:end -->'
$Sentinel = '0' * 64

$TargetRel = @(
  '.claude\CLAUDE.md',
  '.claude\settings.json',
  '.claude\agents\Explore.md',
  '.claude\agents\economy-worker.md',
  '.claude\agents\consultant.md',
  '.claude\orchestration\roles.json',
  '.claude\orchestration\sync-roles.ps1',
  '.claude\orchestration\install-state.json',
  '.codex\AGENTS.md',
  '.codex\agents\explorer.toml',
  '.codex\agents\worker.toml',
  '.gemini\GEMINI.md'
)
$UpstreamRoleRel = @(
  '.claude\agents\Explore.md',
  '.claude\agents\economy-worker.md',
  '.codex\agents\explorer.toml',
  '.codex\agents\worker.toml'
)

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:FailCount = 0
$script:WarnCount = 0

# ================================================================ output
function Write-Status([string]$Status, [string]$Message) {
  $color = 'Gray'
  switch ($Status) {
    'OK' { $color = 'Green' }
    'FAIL' { $color = 'Red'; $script:FailCount++ }
    'WARN' { $color = 'Yellow'; $script:WarnCount++ }
    'SKIP' { $color = 'DarkGray' }
  }
  Write-Host ('[{0}] {1}' -f $Status, $Message) -ForegroundColor $color
}

function Write-Section([string]$Title) {
  Write-Host ''
  Write-Host ('== ' + $Title)
}

# ================================================================ text helpers
function Read-TextFile([string]$Path) {
  if (-not [System.IO.File]::Exists($Path)) {
    return [pscustomobject]@{ Exists = $false; Text = ''; Bom = $false; Eol = $null }
  }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $offset = 0
  if ($bom) { $offset = 3 }
  $text = $script:Utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
  return [pscustomobject]@{ Exists = $true; Text = $text; Bom = $bom; Eol = (Get-Eol $text) }
}

function Write-TextFile([string]$Path, [string]$Text, [bool]$Bom) {
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  $body = $script:Utf8NoBom.GetBytes($Text)
  if ($Bom) {
    $all = New-Object byte[] ($body.Length + 3)
    $all[0] = 0xEF; $all[1] = 0xBB; $all[2] = 0xBF
    [System.Array]::Copy($body, 0, $all, 3, $body.Length)
    $body = $all
  }
  [System.IO.File]::WriteAllBytes($Path, $body)
}

function Get-Eol([string]$Text) {
  $crlf = 0; $lf = 0
  for ($i = 0; $i -lt $Text.Length; $i++) {
    if ($Text[$i] -eq [char]10) {
      if ($i -gt 0 -and $Text[$i - 1] -eq [char]13) { $crlf++ } else { $lf++ }
    }
  }
  if ($crlf -eq 0 -and $lf -eq 0) { return $null }
  if ($crlf -ge $lf) { return "`r`n" }
  return "`n"
}

function Convert-Eol([string]$Text, [string]$Eol) {
  $t = $Text.Replace("`r`n", "`n")
  if ($Eol -eq "`r`n") { $t = $t.Replace("`n", "`r`n") }
  return $t
}

function Skip-EolForward([string]$Text, [int]$Index) {
  if ($Index + 1 -lt $Text.Length -and $Text[$Index] -eq [char]13 -and $Text[$Index + 1] -eq [char]10) { return $Index + 2 }
  if ($Index -lt $Text.Length -and $Text[$Index] -eq [char]10) { return $Index + 1 }
  return $Index
}

function Skip-EolBackward([string]$Text, [int]$Index) {
  if ($Index -ge 2 -and $Text[$Index - 2] -eq [char]13 -and $Text[$Index - 1] -eq [char]10) { return $Index - 2 }
  if ($Index -ge 1 -and $Text[$Index - 1] -eq [char]10) { return $Index - 1 }
  return $Index
}

function Test-SameBytes([string]$PathA, [string]$PathB) {
  $a = [System.IO.File]::ReadAllBytes($PathA)
  $b = [System.IO.File]::ReadAllBytes($PathB)
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
  return $true
}

# ================================================================ block helpers
function Find-UpstreamBlock([string]$Text) {
  $m = $UpBeginRe.Match($Text)
  if (-not $m.Success) { return $null }
  $end = $Text.IndexOf($UpEnd, $m.Index + $m.Length, [System.StringComparison]::Ordinal)
  if ($end -lt 0) { return [pscustomobject]@{ Start = $m.Index; End = -1; Hex = $m.Groups[1].Value; Broken = $true } }
  return [pscustomobject]@{ Start = $m.Index; End = ($end + $UpEnd.Length); Hex = $m.Groups[1].Value; Broken = $false }
}

function Find-KitBlock([string]$Text) {
  $b = $Text.IndexOf($KitBegin, [System.StringComparison]::Ordinal)
  if ($b -lt 0) { return $null }
  $e = $Text.IndexOf($KitEnd, $b + $KitBegin.Length, [System.StringComparison]::Ordinal)
  if ($e -lt 0) { return [pscustomobject]@{ Start = $b; End = -1; Broken = $true } }
  return [pscustomobject]@{ Start = $b; End = ($e + $KitEnd.Length); Broken = $false }
}

# ================================================================ JSON helpers
function ConvertFrom-JsonText([string]$Text) {
  if (-not $Text.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) {
    throw '최상위 값이 JSON 객체가 아닙니다.'
  }
  $cmd = Get-Command ConvertFrom-Json
  if ($cmd.Parameters.ContainsKey('DateKind')) {
    return (ConvertFrom-Json -InputObject $Text -DateKind String)
  }
  return (ConvertFrom-Json -InputObject $Text)
}

function Get-ExactProp($Object, [string]$Name) {
  if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $null }
  foreach ($p in $Object.PSObject.Properties) {
    if ($p.Name -ceq $Name) { return $p }
  }
  return $null
}

function Format-JsonScalar($Value) {
  if ($Value -is [datetime]) { return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
  return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-JsonEqual($A, $B) {
  if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
  if ($A -is [System.Management.Automation.PSCustomObject]) {
    if (-not ($B -is [System.Management.Automation.PSCustomObject])) { return $false }
    $pa = @($A.PSObject.Properties); $pb = @($B.PSObject.Properties)
    if ($pa.Count -ne $pb.Count) { return $false }
    for ($i = 0; $i -lt $pa.Count; $i++) {
      if ($pa[$i].Name -cne $pb[$i].Name) { return $false }
      if (-not (Test-JsonEqual $pa[$i].Value $pb[$i].Value)) { return $false }
    }
    return $true
  }
  if ($A -is [array]) {
    if (-not ($B -is [array])) { return $false }
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) {
      if (-not (Test-JsonEqual $A[$i] $B[$i])) { return $false }
    }
    return $true
  }
  if ($B -is [System.Management.Automation.PSCustomObject] -or $B -is [array]) { return $false }
  if ($A -is [string] -or $B -is [string]) { return (($A -is [string]) -and ($B -is [string]) -and ($A -ceq $B)) }
  if ($A -is [bool] -or $B -is [bool]) { return (($A -is [bool]) -and ($B -is [bool]) -and ($A -eq $B)) }
  return ((Format-JsonScalar $A) -ceq (Format-JsonScalar $B))
}

function Get-KitHookSpec([string]$HomePath) {
  $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $sync = Join-Path $HomePath '.claude\orchestration\sync-roles.ps1'
  return [pscustomobject]@{
    Command = $exe
    Arguments = [object[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sync, '-Quiet')
  }
}

function Test-KitHandler($Handler, $Spec) {
  $c = Get-ExactProp $Handler 'command'
  $a = Get-ExactProp $Handler 'args'
  if ($null -eq $c -or $null -eq $a -or -not ($a.Value -is [array])) { return $false }
  if (-not ([string]$c.Value).Equals($Spec.Command, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $arr = $a.Value
  if ($arr.Count -ne $Spec.Arguments.Count) { return $false }
  for ($i = 0; $i -lt $arr.Count; $i++) {
    if (-not ([string]$arr[$i]).Equals([string]$Spec.Arguments[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Get-SessionStartGroups($Root) {
  $hp = Get-ExactProp $Root 'hooks'
  if ($null -eq $hp) { return [pscustomobject]@{ Hooks = $null; SessionStart = $null } }
  if (-not ($hp.Value -is [System.Management.Automation.PSCustomObject])) { throw "'hooks' 가 JSON 객체가 아닙니다." }
  $sp = Get-ExactProp $hp.Value 'SessionStart'
  if ($null -ne $sp -and -not ($sp.Value -is [array])) { throw "'hooks.SessionStart' 가 JSON 배열이 아닙니다." }
  return [pscustomobject]@{ Hooks = $hp; SessionStart = $sp }
}

function Get-KitHandlerCount($Root, $Spec) {
  $g = Get-SessionStartGroups $Root
  if ($null -eq $g.SessionStart) { return 0 }
  $n = 0
  foreach ($grp in $g.SessionStart.Value) {
    $gh = Get-ExactProp $grp 'hooks'
    if ($null -eq $gh -or -not ($gh.Value -is [array])) { continue }
    foreach ($h in $gh.Value) { if (Test-KitHandler $h $Spec) { $n++ } }
  }
  return $n
}

function Remove-KitHandlers($Root, $Spec, [bool]$DropSessionStartIfEmpty, [bool]$DropHooksIfEmpty) {
  $g = Get-SessionStartGroups $Root
  if ($null -eq $g.SessionStart) { return 0 }
  $removed = 0
  $groups = New-Object System.Collections.Generic.List[object]
  foreach ($grp in $g.SessionStart.Value) {
    $gh = Get-ExactProp $grp 'hooks'
    if ($null -ne $gh -and $gh.Value -is [array]) {
      $kept = New-Object System.Collections.Generic.List[object]
      $hit = 0
      foreach ($h in $gh.Value) { if (Test-KitHandler $h $Spec) { $hit++ } else { $kept.Add($h) } }
      if ($hit -gt 0) {
        $removed += $hit
        if ($kept.Count -gt 0) { $gh.Value = $kept.ToArray(); $groups.Add($grp) }
        continue
      }
    }
    $groups.Add($grp)
  }
  if ($removed -eq 0) { return 0 }
  if ($groups.Count -eq 0 -and $DropSessionStartIfEmpty) { [void]$g.Hooks.Value.PSObject.Properties.Remove('SessionStart') }
  else { $g.SessionStart.Value = $groups.ToArray() }
  if ($DropHooksIfEmpty -and @($g.Hooks.Value.PSObject.Properties).Count -eq 0) { [void]$Root.PSObject.Properties.Remove('hooks') }
  return $removed
}

function ConvertTo-JsonText($Root, [string]$Eol) {
  $json = ConvertTo-Json -InputObject $Root -Depth 100
  return (Convert-Eol $json $Eol) + $Eol
}

function Get-StateValue($Object, [string]$Name) {
  if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Test-StateHas($Object, [string]$Name) {
  if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $false }
  return ($null -ne $Object.PSObject.Properties[$Name])
}

# ================================================================ main
Write-Host ''
Write-Host 'switchboard-kit 제거'

if ([string]::IsNullOrWhiteSpace($HomeDir)) { Write-Status 'FAIL' '홈 폴더를 알 수 없습니다. -HomeDir 를 지정하세요.'; exit 1 }
$HomeDir = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HomeDir)).TrimEnd('\')
$ClaudeDir = Join-Path $HomeDir '.claude'
$KitDir = Join-Path $ClaudeDir 'orchestration'
$StatePath = Join-Path $KitDir 'install-state.json'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$AgentsDir = Join-Path $ClaudeDir 'agents'
Write-Host ('  홈   : {0}' -f $HomeDir)

# ---------------------------------------------------------------- state + backup dir
Write-Section '설치 기록'
$state = $null
if ([System.IO.File]::Exists($StatePath)) {
  try {
    $state = ConvertFrom-JsonText (Read-TextFile $StatePath).Text
    Write-Status 'OK' ('설치 기록: {0}' -f $StatePath)
  } catch {
    Write-Status 'WARN' ('설치 기록을 읽을 수 없습니다. 백업 폴더 내용으로 판단합니다 ({0})' -f $_.Exception.Message)
  }
} else {
  Write-Status 'WARN' ('설치 기록이 없습니다: {0}. 백업 폴더 내용으로 판단합니다.' -f $StatePath)
}
if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = [string](Get-StateValue $state 'original_backup_dir') }
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
  Write-Status 'FAIL' '설치 전 백업 폴더를 알 수 없습니다. 이미 제거되었거나 설치된 적이 없을 수 있습니다. 특정 백업을 기준으로 되돌리려면 -BackupDir 로 지정하세요.'
  exit 1
}
$BackupDir = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDir)).TrimEnd('\')
if (-not [System.IO.Directory]::Exists($BackupDir)) {
  Write-Status 'FAIL' ('설치 전 백업 폴더가 없습니다: {0}' -f $BackupDir)
  exit 1
}
Write-Status 'OK' ('설치 전 백업: {0}' -f $BackupDir)

$originalFiles = Get-StateValue $state 'original_files'
function Test-ExistedBefore([string]$Rel) {
  if (Test-StateHas $originalFiles $Rel) { return [bool](Get-StateValue $originalFiles $Rel) }
  return [System.IO.File]::Exists((Join-Path $BackupDir $Rel))
}

# ---------------------------------------------------------------- snapshot of current files
try {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $Snapshot = Join-Path $BackupDir ('kit-removed-' + $stamp)
  $n = 1
  while (Test-Path -LiteralPath $Snapshot) { $Snapshot = Join-Path $BackupDir ('kit-removed-{0}-{1}' -f $stamp, $n); $n++ }
  [void][System.IO.Directory]::CreateDirectory($Snapshot)
  $copied = 0
  foreach ($rel in $TargetRel) {
    $src = Join-Path $HomeDir $rel
    if (-not [System.IO.File]::Exists($src)) { continue }
    $dst = Join-Path $Snapshot $rel
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
    [System.IO.File]::Copy($src, $dst, $true)
    $copied++
  }
  Write-Status 'OK' ('제거 전 현재 파일 보관: {0} (파일 {1}개)' -f $Snapshot, $copied)
} catch {
  Write-Status 'FAIL' ('제거 전 보관 실패. 아무것도 바꾸지 않고 중단합니다 ({0})' -f $_.Exception.Message)
  exit 1
}

# ---------------------------------------------------------------- instruction files
Write-Section '지침 파일'
$instructionRel = @('.claude\CLAUDE.md', '.codex\AGENTS.md', '.gemini\GEMINI.md')
foreach ($rel in $instructionRel) {
  $path = Join-Path $HomeDir $rel
  $existedBefore = Test-ExistedBefore $rel
  if (-not [System.IO.File]::Exists($path)) {
    if ($existedBefore) { Write-Status 'WARN' ('{0}: 설치 전에는 있었지만 지금은 없습니다. 복원하지 않습니다.' -f $rel) }
    else { Write-Status 'SKIP' ('{0}: 없음' -f $rel) }
    continue
  }
  try {
    $f = Read-TextFile $path
    $text = $f.Text

    $kit = Find-KitBlock $text
    if ($null -ne $kit -and $kit.Broken) {
      Write-Status 'WARN' ('{0}: 키트 정책 블록의 끝 표식이 없습니다. 파일을 건드리지 않았습니다.' -f $rel)
      continue
    }
    if ($null -ne $kit) {
      $end = Skip-EolForward $text $kit.End
      $end = Skip-EolForward $text $end
      $text = $text.Substring(0, $kit.Start) + $text.Substring($end)
    }

    $up = Find-UpstreamBlock $text
    if ($null -ne $up -and $up.Broken) {
      Write-Status 'WARN' ('{0}: agent-switchboard 블록의 끝 표식이 없습니다. 파일을 건드리지 않았습니다.' -f $rel)
      continue
    }
    $origText = ''
    if ($existedBefore) {
      $bk = Join-Path $BackupDir $rel
      if (-not [System.IO.File]::Exists($bk)) { throw ('설치 전 백업 파일이 없습니다: {0}' -f $bk) }
      $origText = (Read-TextFile $bk).Text
    }
    $note = ''
    if ($null -ne $up -and $up.Hex -ceq $Sentinel) {
      $orig = Find-UpstreamBlock $origText
      if ($null -ne $orig -and -not $orig.Broken) {
        $span = $origText.Substring($orig.Start, $orig.End - $orig.Start)
        $text = $text.Substring(0, $up.Start) + $span + $text.Substring($up.End)
        $note = '원래 agent-switchboard 블록 복원'
      } else {
        $sepCount = 0
        if ($origText.Length -gt 0) {
          if ($origText.EndsWith("`n", [System.StringComparison]::Ordinal)) { $sepCount = 1 } else { $sepCount = 2 }
        }
        $start = $up.Start
        for ($i = 0; $i -lt $sepCount; $i++) { $start = Skip-EolBackward $text $start }
        $end = Skip-EolForward $text $up.End
        $text = $text.Substring(0, $start) + $text.Substring($end)
        $note = '키트가 추가한 블록 제거'
      }
    } elseif ($null -ne $up) {
      Write-Status 'WARN' ('{0}: 키트가 무력화한 블록이 아닌 agent-switchboard 블록이 있습니다. 그대로 둡니다.' -f $rel)
    }

    if ((-not $existedBefore) -and $text.Length -eq 0) {
      [System.IO.File]::Delete($path)
      Write-Status 'OK' ('{0}: 삭제 (설치 전에는 없던 파일)' -f $rel)
    } elseif ($text -cne $f.Text) {
      Write-TextFile $path $text $f.Bom
      $msg = '키트 정책 블록 제거'
      if ($null -eq $kit) { $msg = '' }
      if ($note) { if ($msg) { $msg = $msg + ', ' + $note } else { $msg = $note } }
      Write-Status 'OK' ('{0}: {1}' -f $rel, $msg)
    } else {
      Write-Status 'OK' ('{0}: 키트가 넣은 내용 없음' -f $rel)
    }
  } catch {
    Write-Status 'FAIL' ('{0}: 되돌리지 못했습니다 ({1})' -f $rel, $_.Exception.Message)
  }
}

# ---------------------------------------------------------------- role files
Write-Section '롤 파일'
foreach ($rel in $UpstreamRoleRel) {
  $path = Join-Path $HomeDir $rel
  try {
    if (Test-ExistedBefore $rel) {
      $bk = Join-Path $BackupDir $rel
      if (-not [System.IO.File]::Exists($bk)) { throw ('설치 전 백업 파일이 없습니다: {0}' -f $bk) }
      if ([System.IO.File]::Exists($path) -and (Test-SameBytes $path $bk)) {
        Write-Status 'OK' ('{0}: 설치 전과 같음' -f $rel)
      } else {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
        [System.IO.File]::Copy($bk, $path, $true)
        Write-Status 'OK' ('{0}: 설치 전 파일로 복원' -f $rel)
      }
    } elseif ([System.IO.File]::Exists($path)) {
      [System.IO.File]::Delete($path)
      Write-Status 'OK' ('{0}: 삭제 (설치 전에는 없던 파일)' -f $rel)
    } else {
      Write-Status 'SKIP' ('{0}: 없음' -f $rel)
    }
  } catch { Write-Status 'FAIL' ('{0}: 되돌리지 못했습니다 ({1})' -f $rel, $_.Exception.Message) }
}
$consultantRel = '.claude\agents\consultant.md'
$consultantPath = Join-Path $HomeDir $consultantRel
try {
  if (Test-ExistedBefore $consultantRel) {
    Write-Status 'OK' ('{0}: 설치 전부터 있던 파일이라 유지' -f $consultantRel)
  } elseif ([System.IO.File]::Exists($consultantPath)) {
    [System.IO.File]::Delete($consultantPath)
    Write-Status 'OK' ('{0}: 삭제 (키트가 만든 파일)' -f $consultantRel)
  } else {
    Write-Status 'SKIP' ('{0}: 없음' -f $consultantRel)
  }
} catch { Write-Status 'FAIL' ('{0}: 지우지 못했습니다 ({1})' -f $consultantRel, $_.Exception.Message) }
$originalDirs = Get-StateValue $state 'original_dirs'
if ((Test-StateHas $originalDirs '.claude\agents') -and -not [bool](Get-StateValue $originalDirs '.claude\agents')) {
  if ([System.IO.Directory]::Exists($AgentsDir) -and @([System.IO.Directory]::GetFileSystemEntries($AgentsDir)).Count -eq 0) {
    [System.IO.Directory]::Delete($AgentsDir)
    Write-Status 'OK' '.claude\agents: 키트가 만든 빈 폴더 삭제'
  }
}

# ---------------------------------------------------------------- settings.json
Write-Section 'Claude Code 설정'
$spec = Get-KitHookSpec $HomeDir
if (-not [System.IO.File]::Exists($SettingsPath)) {
  Write-Status 'SKIP' 'settings.json 없음'
} else {
  try {
    $f = Read-TextFile $SettingsPath
    $eol = $f.Eol
    if ($null -eq $eol) { $eol = "`r`n" }
    $curText = $f.Text
    if ($curText.Trim().Length -eq 0) { $curText = '{}' }
    $root = ConvertFrom-JsonText $curText

    $settingsState = Get-StateValue $state 'settings'
    $bkSettings = Join-Path $BackupDir '.claude\settings.json'
    $backupRoot = $null
    if ([System.IO.File]::Exists($bkSettings)) {
      $bkText = (Read-TextFile $bkSettings).Text
      if ($bkText.Trim().Length -eq 0) { $bkText = '{}' }
      try { $backupRoot = ConvertFrom-JsonText $bkText } catch { $backupRoot = $null }
    }
    if ($null -ne $settingsState) {
      $existed = [bool](Get-StateValue $settingsState 'existed')
      $hooksExisted = [bool](Get-StateValue $settingsState 'hooks_existed')
      $ssExisted = [bool](Get-StateValue $settingsState 'session_start_existed')
    } else {
      $existed = [System.IO.File]::Exists($bkSettings)
      $shape = Get-SessionStartGroups $backupRoot
      $hooksExisted = ($null -ne $shape.Hooks)
      $ssExisted = ($null -ne $shape.SessionStart)
    }

    $n = Remove-KitHandlers $root $spec (-not $ssExisted) (-not $hooksExisted)
    if ($n -eq 0) {
      Write-Status 'OK' 'settings.json: 키트 훅 없음 (변경 없음)'
    } elseif ((-not $existed) -and @($root.PSObject.Properties).Count -eq 0) {
      [System.IO.File]::Delete($SettingsPath)
      Write-Status 'OK' 'settings.json: 삭제 (키트가 만든 파일이고 다른 내용이 없음)'
    } elseif ($existed -and $null -ne $backupRoot -and (Test-JsonEqual $root $backupRoot)) {
      [System.IO.File]::Copy($bkSettings, $SettingsPath, $true)
      Write-Status 'OK' 'settings.json: 키트 훅 제거 (내용이 설치 전과 같아 원본 파일 그대로 복원)'
    } else {
      $newText = ConvertTo-JsonText $root $eol
      $check = ConvertFrom-JsonText $newText
      if (-not (Test-JsonEqual $check $root)) { throw '직렬화 검증 실패' }
      Write-TextFile $SettingsPath $newText $f.Bom
      Write-Status 'OK' ('settings.json: 키트 훅 {0}개 제거 (다른 설정은 유지)' -f $n)
    }
  } catch {
    Write-Status 'FAIL' ('settings.json: 건드리지 않았습니다 ({0})' -f $_.Exception.Message)
  }
}

# ---------------------------------------------------------------- env var
Write-Section '라우팅 게이트'
if ($SkipEnvVar) {
  Write-Status 'SKIP' ('사용자 환경 변수 {0} (-SkipEnvVar)' -f $GateVar)
} elseif (-not (Test-StateHas $state 'gate_mode_previous')) {
  Write-Status 'WARN' ('설치 전 {0} 값 기록이 없어 그대로 둡니다.' -f $GateVar)
} else {
  try {
    $prevValue = Get-StateValue $state 'gate_mode_previous'
    if ($null -ne $prevValue) { $prevValue = [string]$prevValue }
    $cur = [Environment]::GetEnvironmentVariable($GateVar, 'User')
    if ($cur -ceq $prevValue) {
      Write-Status 'OK' ('{0}: 설치 전 값과 같음' -f $GateVar)
    } elseif ($cur -ceq 'warn') {
      [Environment]::SetEnvironmentVariable($GateVar, $prevValue, 'User')
      if ($null -eq $prevValue) { Write-Status 'OK' ('{0}: 삭제 (설치 전에는 없었음)' -f $GateVar) }
      else { Write-Status 'OK' ('{0}: 설치 전 값 {1} 로 복원' -f $GateVar, $prevValue) }
    } else {
      Write-Status 'WARN' ('{0}: 현재 값 {1} 은 키트가 설정한 값이 아니라 그대로 둡니다.' -f $GateVar, $cur)
    }
  } catch { Write-Status 'FAIL' ('환경 변수 복원 실패 ({0})' -f $_.Exception.Message) }
}

# ---------------------------------------------------------------- kit dir
Write-Section '키트 폴더'
try {
  $kitState = Join-Path $KitDir 'install-state.json'
  $kitRoles = Join-Path $KitDir 'roles.json'
  $kitSync = Join-Path $KitDir 'sync-roles.ps1'
  foreach ($pair in @(@($kitRoles, '.claude\orchestration\roles.json'), @($kitState, '.claude\orchestration\install-state.json'))) {
    $src = $pair[0]; $rel = $pair[1]
    if (-not [System.IO.File]::Exists($src)) { continue }
    if ($rel -eq '.claude\orchestration\roles.json' -and (Test-ExistedBefore $rel)) {
      Write-Status 'OK' ('roles.json: 설치 전부터 있던 파일이라 유지: {0}' -f $src)
      continue
    }
    $dst = Join-Path $Snapshot $rel
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
    [System.IO.File]::Copy($src, $dst, $true)
    [System.IO.File]::Delete($src)
    Write-Status 'OK' ('{0}: 백업 폴더로 옮김: {1}' -f [System.IO.Path]::GetFileName($src), $dst)
  }
  $syncRel = '.claude\orchestration\sync-roles.ps1'
  if (Test-ExistedBefore $syncRel) {
    $bk = Join-Path $BackupDir $syncRel
    if ([System.IO.File]::Exists($bk)) {
      [System.IO.File]::Copy($bk, $kitSync, $true)
      Write-Status 'OK' 'sync-roles.ps1: 설치 전 파일로 복원'
    }
  } elseif ([System.IO.File]::Exists($kitSync)) {
    [System.IO.File]::Delete($kitSync)
    Write-Status 'OK' 'sync-roles.ps1: 삭제'
  }
  $kitDirBefore = (Test-StateHas $originalDirs '.claude\orchestration') -and [bool](Get-StateValue $originalDirs '.claude\orchestration')
  if ([System.IO.Directory]::Exists($KitDir)) {
    $left = @([System.IO.Directory]::GetFileSystemEntries($KitDir))
    if ($kitDirBefore) {
      Write-Status 'OK' ('키트 폴더는 설치 전부터 있던 폴더라 유지: {0}' -f $KitDir)
    } elseif ($left.Count -eq 0) {
      [System.IO.Directory]::Delete($KitDir)
      Write-Status 'OK' ('키트 폴더 삭제: {0}' -f $KitDir)
    } else {
      $names = ($left | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', '
      Write-Status 'WARN' ('키트 폴더에 다른 파일이 있어 폴더는 남겨 둡니다: {0}' -f $names)
    }
  }
} catch { Write-Status 'FAIL' ('키트 폴더 정리 실패 ({0})' -f $_.Exception.Message) }

# ---------------------------------------------------------------- verification
Write-Section '검증'
foreach ($rel in $instructionRel) {
  $path = Join-Path $HomeDir $rel
  if (-not [System.IO.File]::Exists($path)) { continue }
  try {
    $t = (Read-TextFile $path).Text
    if ($t.Contains($KitBegin) -or $t.Contains($KitEnd)) { Write-Status 'FAIL' ('{0}: 키트 정책 표식이 남아 있습니다' -f $rel) }
    else { Write-Status 'OK' ('{0}: 키트 정책 블록 없음' -f $rel) }
  } catch { Write-Status 'FAIL' ('{0}: 검증 실패 ({1})' -f $rel, $_.Exception.Message) }
}
foreach ($rel in $UpstreamRoleRel) {
  $path = Join-Path $HomeDir $rel
  $bk = Join-Path $BackupDir $rel
  if (Test-ExistedBefore $rel) {
    if ([System.IO.File]::Exists($path) -and [System.IO.File]::Exists($bk) -and (Test-SameBytes $path $bk)) { Write-Status 'OK' ('{0}: 설치 전과 같음' -f $rel) }
    else { Write-Status 'FAIL' ('{0}: 설치 전 파일과 다릅니다' -f $rel) }
  } elseif ([System.IO.File]::Exists($path)) { Write-Status 'FAIL' ('{0}: 설치 전에는 없던 파일이 남아 있습니다' -f $rel) }
}
if ([System.IO.File]::Exists($SettingsPath)) {
  try {
    $root = ConvertFrom-JsonText (Read-TextFile $SettingsPath).Text
    if ((Get-KitHandlerCount $root $spec) -eq 0) { Write-Status 'OK' 'settings.json: 키트 훅 없음' }
    else { Write-Status 'FAIL' 'settings.json: 키트 훅이 남아 있습니다' }
  } catch { Write-Status 'FAIL' ('settings.json 검증 실패 ({0})' -f $_.Exception.Message) }
}
if ([System.IO.File]::Exists((Join-Path $KitDir 'install-state.json'))) { Write-Status 'FAIL' 'install-state.json 이 남아 있습니다' }
else { Write-Status 'OK' 'install-state.json 정리됨' }

Write-Host ''
if ($script:FailCount -gt 0) {
  Write-Host ('실패 {0}건, 경고 {1}건. 위의 [FAIL] 줄을 확인하세요. 제거 전 파일: {2}' -f $script:FailCount, $script:WarnCount, $Snapshot) -ForegroundColor Red
  exit 1
}
Write-Host ('제거 완료 (경고 {0}건). 제거 전 파일: {1}' -f $script:WarnCount, $Snapshot) -ForegroundColor Green
if (-not $SkipEnvVar) {
  Write-Host '환경 변수 변경을 반영하려면 Claude Code 와 Codex, VS Code 등 agent-switchboard 를 띄우는 앱을 모두 완전히 종료한 뒤 다시 시작하세요.' -ForegroundColor Yellow
}
Write-Host '참고: agent-switchboard 는 다음 실행 때 자기 관리 블록과 롤 파일을 다시 관리합니다.'
exit 0
