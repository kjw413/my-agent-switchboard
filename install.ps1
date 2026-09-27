<#
.SYNOPSIS
  switchboard-kit 설치: agent-switchboard 게이트가 작업을 막지 않게 하고, roles.json 하나로
  모든 역할의 vendor/model/effort 를 정하며, agent-switchboard 의 자동 갱신이 이 설정을
  되돌리지 못하게 합니다.

.DESCRIPTION
  하는 일
    1. 대상 파일을 %USERPROFILE%\.claude\orchestration-backups\<시각>\ 에 백업합니다.
       최초 설치 때는 설치 전 상태를 install-state.json 에 기록합니다.
    2. 사용자 환경 변수 AGENT_BROKER_GATE_MODE=warn 을 설정합니다. (-SkipEnvVar 로 생략)
    3. .claude\orchestration\ 에 roles.json(기존 파일 유지) 과 sync-roles.ps1 을 둡니다.
    4. CLAUDE.md / AGENTS.md 맨 위에 키트 정책 블록을 넣습니다.
    5. CLAUDE.md / AGENTS.md / GEMINI.md 의 agent-switchboard 관리 블록을 무력화합니다.
       (체크섬 자리를 0 으로 채워 agent-switchboard 가 사용자 수정본으로 보고 건드리지 않게 함)
    6. sync-roles.ps1 로 롤 파일 소유권을 정리하고 model/effort 를 맞춥니다.
    7. settings.json 에 SessionStart 훅을 추가해 세션마다 sync-roles.ps1 을 실행합니다.
    8. 결과를 항목별로 검증합니다. 실패 항목이 있으면 종료 코드 1.

.PARAMETER HomeDir
  대상 사용자 홈. 기본값은 %USERPROFILE% 입니다.
.PARAMETER SkipEnvVar
  사용자 환경 변수를 건드리지 않습니다.
.PARAMETER Force
  기존 roles.json 을 템플릿으로 덮어씁니다. agent-switchboard.exe 가 없어도 계속합니다.
.PARAMETER DryRun
  무엇을 할지만 보여 주고 아무것도 쓰지 않습니다.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [string]$HomeDir = $env:USERPROFILE,
  [switch]$SkipEnvVar,
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ================================================================ constants
$RepoRoot = $PSScriptRoot
$TemplateDir = Join-Path $RepoRoot 'templates'
$SyncSource = Join-Path $RepoRoot 'scripts\sync-roles.ps1'
$GateVar = 'AGENT_BROKER_GATE_MODE'

$KitBegin = '<!-- switchboard-kit:policy:begin -->'
$KitEnd = '<!-- switchboard-kit:policy:end -->'
$UpBeginRe = New-Object System.Text.RegularExpressions.Regex '<!-- agent-switchboard:cost-routing:begin sha256=([0-9a-f]{64}) -->'
$UpEnd = '<!-- agent-switchboard:cost-routing:end -->'
$Sentinel = '0' * 64
$UpNeutralBegin = '<!-- agent-switchboard:cost-routing:begin sha256=' + $Sentinel + ' -->'
$KnownUpstreamChecksums = @('d3612ab90cd701c91ab254b0ea52841ba04e314a435992c829ed19207b737184')
$LegacyHeadingRe = New-Object System.Text.RegularExpressions.Regex '(?im)^(#{1,2})\s+cost-aware model routing\s*$'
$ManagedFileRe = New-Object System.Text.RegularExpressions.Regex '(?m)^# agent-switchboard:managed sha256=([0-9a-f]{64})\s*$'
$LegacyClaudeString = 'Require an approved work package stating Route, exact model/effort'

$TargetRel = @(
  '.claude\CLAUDE.md',
  '.claude\settings.json',
  '.claude\agents\Explore.md',
  '.claude\agents\economy-worker.md',
  '.claude\agents\consultant.md',
  '.claude\orchestration\roles.json',
  '.claude\orchestration\sync-roles.ps1',
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
    'DRY' { $color = 'Cyan' }
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
  # 잘못된 UTF-8 이면 예외: 사용자 파일을 깨뜨리지 않도록 그 파일은 건드리지 않습니다.
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
  # 파일의 줄바꿈 방식. 줄바꿈이 없으면 $null.
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

function Get-UpstreamView([string]$Text) {
  # agent-switchboard 는 Python universal newline 으로 읽습니다.
  return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-Sha256Hex([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $hash = $sha.ComputeHash($script:Utf8NoBom.GetBytes($Text)) } finally { $sha.Dispose() }
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
  return $sb.ToString()
}

function Get-OccurrenceCount([string]$Text, [string]$Needle) {
  $n = 0; $pos = 0
  while ($true) {
    $i = $Text.IndexOf($Needle, $pos, [System.StringComparison]::Ordinal)
    if ($i -lt 0) { break }
    $n++; $pos = $i + $Needle.Length
  }
  return $n
}

function Test-BomFile([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
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

function New-KitBlock([string]$Body, [string]$Eol) {
  return $KitBegin + $Eol + (Convert-Eol $Body.Trim() $Eol) + $Eol + $KitEnd
}

function New-NeutralBlock([string]$Body, [string]$Eol) {
  return $UpNeutralBegin + $Eol + (Convert-Eol $Body.Trim() $Eol) + $Eol + $UpEnd
}

function Get-UpstreamBlockVerdict([string]$Text) {
  # agent-switchboard update_instruction_block 의 판정을 옮긴 것. 'untouched' 여야 안전합니다.
  $view = Get-UpstreamView $Text
  $m = $UpBeginRe.Match($view)
  if (-not $m.Success) {
    if ($LegacyHeadingRe.IsMatch($view)) { return 'replace-legacy' }
    return 'append'
  }
  $bs = $m.Index + $m.Length
  if ($bs -lt $view.Length -and $view[$bs] -eq [char]10) { $bs++ }
  $end = $view.IndexOf($UpEnd, $bs, [System.StringComparison]::Ordinal)
  if ($end -lt 0) { return 'untouched' }
  $body = $view.Substring($bs, $end - $bs)
  $hex = $m.Groups[1].Value
  if ((Get-Sha256Hex $body) -ceq $hex) { return 'overwrite' }
  if ($KnownUpstreamChecksums -ccontains $hex) { return 'overwrite' }
  return 'untouched'
}

function Get-UpstreamRoleVerdict([string]$Path, [string]$Text) {
  # agent-switchboard write_managed_file 의 판정을 옮긴 것. 'untouched' 여야 안전합니다.
  $view = Get-UpstreamView $Text
  if ($view.Length -eq 0) { return 'overwrite' }
  $m = $ManagedFileRe.Match($view)
  if ($m.Success) {
    $end = $m.Index + $m.Length
    if ($end -lt $view.Length -and $view[$end] -eq [char]10) { $end++ }
    $body = $view.Substring(0, $m.Index) + $view.Substring($end)
    if ((Get-Sha256Hex $body) -ceq $m.Groups[1].Value) { return 'overwrite' }
    return 'untouched'
  }
  $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.toml') {
    if ($view.Contains('name = "' + $name + '"') -and $view.Contains('Cost-efficient')) { return 'overwrite' }
  } else {
    if ($view.Contains('name: ' + $name) -and ($view.Contains('Cost-efficient') -or $view.Contains($LegacyClaudeString))) { return 'overwrite' }
  }
  return 'untouched'
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

function New-KitGroup($Spec) {
  $handler = [pscustomobject]@{
    type = 'command'
    command = $Spec.Command
    args = [object[]]($Spec.Arguments)
    timeout = 30
  }
  return [pscustomobject]@{ hooks = [object[]]@($handler) }
}

function Get-HandlerInvocation($Handler) {
  $c = Get-ExactProp $Handler 'command'
  $a = Get-ExactProp $Handler 'args'
  $parts = New-Object System.Collections.Generic.List[string]
  if ($null -ne $c) { $parts.Add([string]$c.Value) }
  if ($null -ne $a -and $a.Value -is [array]) { foreach ($x in $a.Value) { $parts.Add([string]$x) } }
  return ($parts -join ' ')
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
  # (hooks 속성, SessionStart 속성) 을 찾습니다. 모양이 예상과 다르면 예외.
  $hp = Get-ExactProp $Root 'hooks'
  if ($null -eq $hp) { return [pscustomobject]@{ Hooks = $null; SessionStart = $null } }
  if (-not ($hp.Value -is [System.Management.Automation.PSCustomObject])) { throw "'hooks' 가 JSON 객체가 아닙니다." }
  $sp = Get-ExactProp $hp.Value 'SessionStart'
  if ($null -ne $sp -and -not ($sp.Value -is [array])) { throw "'hooks.SessionStart' 가 JSON 배열이 아닙니다." }
  return [pscustomobject]@{ Hooks = $hp; SessionStart = $sp }
}

function Test-SyncHookPresent($Root) {
  $g = Get-SessionStartGroups $Root
  if ($null -eq $g.SessionStart) { return $false }
  foreach ($grp in $g.SessionStart.Value) {
    $gh = Get-ExactProp $grp 'hooks'
    if ($null -eq $gh -or -not ($gh.Value -is [array])) { continue }
    foreach ($h in $gh.Value) {
      if ((Get-HandlerInvocation $h).IndexOf('sync-roles.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
  }
  return $false
}

function Add-KitGroup($Root, $Group) {
  $g = Get-SessionStartGroups $Root
  if ($null -eq $g.Hooks) {
    $Root | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
    $g = Get-SessionStartGroups $Root
  }
  if ($null -eq $g.SessionStart) {
    $g.Hooks.Value | Add-Member -NotePropertyName 'SessionStart' -NotePropertyValue ([object[]]@($Group))
  } else {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in $g.SessionStart.Value) { $list.Add($x) }
    $list.Add($Group)
    $g.SessionStart.Value = $list.ToArray()
  }
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

# ================================================================ plans
function Get-InstructionPlan([string]$Path, $PolicyBody, [string]$NeutralBody) {
  $plan = [pscustomobject]@{
    Path = $Path; State = 'ok'; Message = ''; Existed = $false; Bom = $false
    OldText = ''; NewText = ''; Changed = $false; HasPolicy = ($null -ne $PolicyBody)
  }
  try { $f = Read-TextFile $Path }
  catch {
    $plan.State = 'fail'; $plan.Message = ('읽기 실패. UTF-8 이 아니거나 잠겨 있습니다 ({0})' -f $_.Exception.Message)
    return $plan
  }
  $plan.Existed = $f.Exists; $plan.Bom = $f.Bom; $plan.OldText = $f.Text
  $text = $f.Text
  $eol = $f.Eol
  if ($null -eq $eol) { $eol = "`r`n" }

  $up = Find-UpstreamBlock $text
  if ($null -ne $up -and $up.Broken) {
    $plan.State = 'warn'; $plan.Message = 'agent-switchboard 관리 블록의 시작 표식만 있고 끝 표식이 없습니다. 파일을 건드리지 않았습니다. 직접 확인하세요.'
    return $plan
  }
  $kit = Find-KitBlock $text
  if ($null -ne $kit -and $kit.Broken) {
    $plan.State = 'warn'; $plan.Message = '키트 정책 블록의 시작 표식만 있고 끝 표식이 없습니다. 파일을 건드리지 않았습니다. 직접 확인하세요.'
    return $plan
  }

  # 1) agent-switchboard 블록 무력화 (없으면 끝에 추가해 agent-switchboard 의 추가를 선점)
  $neutral = New-NeutralBlock $NeutralBody $eol
  if ($null -ne $up) {
    $text = $text.Substring(0, $up.Start) + $neutral + $text.Substring($up.End)
  } else {
    $sep = ''
    if ($text.Length -gt 0) {
      if ($text.EndsWith("`n", [System.StringComparison]::Ordinal)) { $sep = $eol } else { $sep = $eol + $eol }
    }
    $text = $text + $sep + $neutral + $eol
  }

  # 2) 키트 정책 블록 (있으면 제자리 교체, 없으면 맨 위에 추가하고 빈 줄 하나)
  if ($null -ne $PolicyBody) {
    $rendered = New-KitBlock ([string]$PolicyBody) $eol
    $kit = Find-KitBlock $text
    if ($null -ne $kit) { $text = $text.Substring(0, $kit.Start) + $rendered + $text.Substring($kit.End) }
    else { $text = $rendered + $eol + $eol + $text }
  }

  $plan.NewText = $text
  $plan.Changed = ((-not $f.Exists) -or ($text -cne $f.Text))
  return $plan
}

function Get-SettingsPlan([string]$Path, $Spec) {
  $plan = [pscustomobject]@{
    Path = $Path; State = 'ok'; Message = ''; Action = 'none'; Existed = $false; Bom = $false
    HooksExisted = $false; SessionStartExisted = $false; SyncHookExisted = $false; NewText = ''
  }
  try {
    $f = Read-TextFile $Path
    $plan.Existed = $f.Exists; $plan.Bom = $f.Bom
    $eol = $f.Eol
    if ($null -eq $eol) { $eol = "`r`n" }
    $origText = $f.Text
    if ($origText.Trim().Length -eq 0) { $origText = '{}' }
    $root = ConvertFrom-JsonText $origText
    $shape = Get-SessionStartGroups $root
    $plan.HooksExisted = ($null -ne $shape.Hooks)
    $plan.SessionStartExisted = ($null -ne $shape.SessionStart)
    if (Test-SyncHookPresent $root) {
      $plan.SyncHookExisted = $true
      $plan.Action = 'present'
      return $plan
    }
    Add-KitGroup $root (New-KitGroup $Spec)
    $newText = ConvertTo-JsonText $root $eol

    # 검증: 다시 파싱해서 우리 훅 하나만 빼면 원본과 완전히 같아야 합니다.
    $check = ConvertFrom-JsonText $newText
    $orig = ConvertFrom-JsonText $origText
    $n = Remove-KitHandlers $check $Spec (-not $plan.SessionStartExisted) (-not $plan.HooksExisted)
    if ($n -ne 1) { throw ('직렬화 검증 실패: 추가한 훅이 {0}개로 읽힙니다.' -f $n) }
    if (-not (Test-JsonEqual $check $orig)) { throw '직렬화 검증 실패: 기존 설정이 바뀌어 읽힙니다.' }
    $plan.NewText = $newText
    $plan.Action = 'add'
  } catch {
    $plan.State = 'fail'
    $plan.Message = $_.Exception.Message
  }
  return $plan
}

function Invoke-SyncScript([string]$ScriptPath, [string[]]$Arguments) {
  $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not [System.IO.File]::Exists($exe)) { $exe = (Get-Process -Id $PID).Path }
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $saved }
  foreach ($line in @($out)) {
    $s = [string]$line
    if ($s.Length -gt 0) { Write-Host ('      ' + $s) }
  }
  return $code
}

function New-BackupDir([string]$Root) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dir = Join-Path $Root $stamp
  $n = 1
  while (Test-Path -LiteralPath $dir) { $dir = Join-Path $Root ('{0}-{1}' -f $stamp, $n); $n++ }
  [void][System.IO.Directory]::CreateDirectory($dir)
  return $dir
}

# ================================================================ main
Write-Host ''
Write-Host 'switchboard-kit 설치'

if ([string]::IsNullOrWhiteSpace($HomeDir)) { Write-Status 'FAIL' '홈 폴더를 알 수 없습니다. -HomeDir 를 지정하세요.'; exit 1 }
$HomeDir = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HomeDir)).TrimEnd('\')
$ClaudeDir = Join-Path $HomeDir '.claude'
$CodexDir = Join-Path $HomeDir '.codex'
$GeminiDir = Join-Path $HomeDir '.gemini'
$KitDir = Join-Path $ClaudeDir 'orchestration'
$StatePath = Join-Path $KitDir 'install-state.json'
$BackupRoot = Join-Path $ClaudeDir 'orchestration-backups'
$BrokerExe = Join-Path $HomeDir '.agent-broker\agent-switchboard.exe'
$KitRoles = Join-Path $KitDir 'roles.json'
$KitSync = Join-Path $KitDir 'sync-roles.ps1'
$ClaudeMd = Join-Path $ClaudeDir 'CLAUDE.md'
$AgentsMd = Join-Path $CodexDir 'AGENTS.md'
$GeminiMd = Join-Path $GeminiDir 'GEMINI.md'
$SettingsPath = Join-Path $ClaudeDir 'settings.json'
$AgentsDir = Join-Path $ClaudeDir 'agents'
$ConsultantPath = Join-Path $AgentsDir 'consultant.md'

Write-Host ('  홈   : {0}' -f $HomeDir)
if ($DryRun) { Write-Host '  모드 : DryRun (아무것도 쓰지 않습니다)' }

# ---------------------------------------------------------------- preflight
Write-Section '사전 점검'
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
  Write-Status 'FAIL' ('PowerShell 5.1 이상이 필요합니다. 현재 버전: {0}' -f $PSVersionTable.PSVersion)
  exit 1
}
Write-Status 'OK' ('PowerShell {0}' -f $PSVersionTable.PSVersion)
if (-not [System.IO.Directory]::Exists($ClaudeDir)) {
  Write-Status 'FAIL' ('{0} 폴더가 없습니다. Claude Code 를 한 번 실행한 뒤 다시 시도하세요.' -f $ClaudeDir)
  exit 1
}
Write-Status 'OK' ('Claude Code 설정 폴더: {0}' -f $ClaudeDir)
if ([System.IO.File]::Exists($BrokerExe)) {
  Write-Status 'OK' ('agent-switchboard: {0}' -f $BrokerExe)
} elseif ($Force) {
  Write-Status 'WARN' ('agent-switchboard.exe 를 찾지 못했지만 -Force 이므로 계속합니다: {0}' -f $BrokerExe)
} else {
  Write-Status 'FAIL' ('agent-switchboard.exe 를 찾지 못했습니다: {0} (그래도 설치하려면 -Force)' -f $BrokerExe)
  exit 1
}
if ([System.IO.Directory]::Exists($CodexDir)) { Write-Status 'OK' 'Codex 설정 폴더 있음 (.codex)' }
else { Write-Status 'SKIP' 'Codex 설정 폴더 없음 (.codex): AGENTS.md 와 Codex 롤 파일은 건너뜁니다.' }
if ([System.IO.Directory]::Exists($GeminiDir)) { Write-Status 'OK' 'Gemini 설정 폴더 있음 (.gemini): GEMINI.md 블록만 무력화합니다.' }
else { Write-Status 'SKIP' 'Gemini 설정 폴더 없음 (.gemini)' }

$templates = @{
  Roles = Join-Path $TemplateDir 'roles.json'
  ClaudePolicy = Join-Path $TemplateDir 'claude-policy.md'
  CodexPolicy = Join-Path $TemplateDir 'codex-policy.md'
  Neutral = Join-Path $TemplateDir 'neutralized-block.md'
  Consultant = Join-Path $TemplateDir 'agents\consultant.md'
}
foreach ($k in @($templates.Keys) + @('Sync')) {
  $p = $SyncSource
  if ($k -ne 'Sync') { $p = $templates[$k] }
  if (-not [System.IO.File]::Exists($p)) {
    Write-Status 'FAIL' ('키트 파일이 없습니다: {0}' -f $p)
    exit 1
  }
}
$claudePolicy = (Read-TextFile $templates.ClaudePolicy).Text
$codexPolicy = (Read-TextFile $templates.CodexPolicy).Text
$neutralBody = (Read-TextFile $templates.Neutral).Text

$hookSpec = Get-KitHookSpec $HomeDir
$invocation = $hookSpec.Command + ' ' + ($hookSpec.Arguments -join ' ')
if ($invocation.Contains('agent-switchboard') -and $invocation.Contains('routing-hook')) {
  # agent-switchboard 는 이 두 문자열이 모두 든 훅을 자기 것으로 보고 지웁니다.
  Write-Status 'FAIL' '홈 경로에 agent-switchboard 와 routing-hook 이 모두 들어 있어 훅이 agent-switchboard 소유로 오인됩니다.'
  exit 1
}

# ---------------------------------------------------------------- plans
$claudePlan = Get-InstructionPlan $ClaudeMd $claudePolicy $neutralBody
$codexPlan = $null
if ([System.IO.Directory]::Exists($CodexDir)) { $codexPlan = Get-InstructionPlan $AgentsMd $codexPolicy $neutralBody }
$geminiPlan = $null
if ([System.IO.Directory]::Exists($GeminiDir)) { $geminiPlan = Get-InstructionPlan $GeminiMd $null $neutralBody }
$instructionPlans = @($claudePlan, $codexPlan, $geminiPlan) | Where-Object { $null -ne $_ }
$settingsPlan = Get-SettingsPlan $SettingsPath $hookSpec
$firstInstall = -not [System.IO.File]::Exists($StatePath)
$rolesExists = [System.IO.File]::Exists($KitRoles)

# ---------------------------------------------------------------- dry run
if ($DryRun) {
  Write-Section 'DryRun: 할 일'
  if ($firstInstall) { Write-Status 'DRY' ('최초 설치: 백업과 설치 전 상태 기록 -> {0}' -f $BackupRoot) }
  else { Write-Status 'DRY' ('재설치: 백업 -> {0} (최초 설치 기록은 유지)' -f $BackupRoot) }
  if ($SkipEnvVar) { Write-Status 'SKIP' ('사용자 환경 변수 {0} (-SkipEnvVar)' -f $GateVar) }
  else { Write-Status 'DRY' ('사용자 환경 변수 {0}=warn (현재: {1})' -f $GateVar, [Environment]::GetEnvironmentVariable($GateVar, 'User')) }
  if (-not $rolesExists) { Write-Status 'DRY' ('roles.json 생성: {0}' -f $KitRoles) }
  elseif ($Force) { Write-Status 'DRY' ('roles.json 덮어쓰기 (-Force): {0}' -f $KitRoles) }
  else { Write-Status 'DRY' ('roles.json 유지 (기존 파일): {0}' -f $KitRoles) }
  Write-Status 'DRY' ('sync-roles.ps1 갱신: {0}' -f $KitSync)
  foreach ($p in $instructionPlans) {
    if ($p.State -eq 'fail') { Write-Status 'FAIL' ('{0}: {1}' -f $p.Path, $p.Message) }
    elseif ($p.State -eq 'warn') { Write-Status 'WARN' ('{0}: {1}' -f $p.Path, $p.Message) }
    elseif ($p.Changed -and $p.HasPolicy) { Write-Status 'DRY' ('{0}: 키트 정책 블록과 무력화 블록 적용' -f $p.Path) }
    elseif ($p.Changed) { Write-Status 'DRY' ('{0}: agent-switchboard 블록 무력화' -f $p.Path) }
    else { Write-Status 'DRY' ('{0}: 변경 없음' -f $p.Path) }
  }
  if ([System.IO.File]::Exists($ConsultantPath)) { Write-Status 'DRY' 'consultant.md 유지 (이미 있음)' }
  else { Write-Status 'DRY' ('consultant.md 생성: {0}' -f $ConsultantPath) }
  if ($settingsPlan.State -eq 'fail') { Write-Status 'FAIL' ('settings.json: JSON 을 안전하게 병합할 수 없어 건드리지 않습니다 ({0})' -f $settingsPlan.Message) }
  elseif ($settingsPlan.Action -eq 'present') { Write-Status 'DRY' 'settings.json: sync-roles.ps1 SessionStart 훅이 이미 있음' }
  else { Write-Status 'DRY' 'settings.json: SessionStart 훅 추가' }
  Write-Status 'DRY' '롤 파일 동기화 미리보기 (sync-roles.ps1 -DryRun):'
  $manifestForDry = $templates.Roles
  if ($rolesExists -and -not $Force) { $manifestForDry = $KitRoles }
  [void](Invoke-SyncScript $SyncSource @('-HomeDir', $HomeDir, '-ManifestPath', $manifestForDry, '-DryRun'))
  Write-Host ''
  Write-Host 'DryRun 이므로 아무것도 바꾸지 않았습니다.'
  if ($script:FailCount -gt 0) { exit 1 }
  exit 0
}

# ---------------------------------------------------------------- backup + state
Write-Section '백업'
try {
  $origExisted = [ordered]@{}
  foreach ($rel in $TargetRel) { $origExisted[$rel] = [System.IO.File]::Exists((Join-Path $HomeDir $rel)) }
  $backupDir = New-BackupDir $BackupRoot
  $copied = 0
  foreach ($rel in $TargetRel) {
    $src = Join-Path $HomeDir $rel
    if (-not [System.IO.File]::Exists($src)) { continue }
    $dst = Join-Path $backupDir $rel
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
    [System.IO.File]::Copy($src, $dst, $true)
    $copied++
  }
  Write-Status 'OK' ('백업: {0} (파일 {1}개)' -f $backupDir, $copied)
} catch {
  Write-Status 'FAIL' ('백업 실패. 아무것도 바꾸지 않고 중단합니다 ({0})' -f $_.Exception.Message)
  exit 1
}

try {
  if ($firstInstall) {
    $state = [ordered]@{
      kit = 'switchboard-kit'
      schema_version = 1
      installed_at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
      home = $HomeDir
      original_backup_dir = $backupDir
      original_files = $origExisted
      original_dirs = [ordered]@{
        '.claude\agents' = [System.IO.Directory]::Exists($AgentsDir)
        '.claude\orchestration' = [System.IO.Directory]::Exists($KitDir)
      }
      gate_mode_previous = [Environment]::GetEnvironmentVariable($GateVar, 'User')
      settings = [ordered]@{
        existed = $settingsPlan.Existed
        hooks_existed = $settingsPlan.HooksExisted
        session_start_existed = $settingsPlan.SessionStartExisted
        sync_hook_existed = $settingsPlan.SyncHookExisted
      }
    }
    $json = ConvertTo-Json -InputObject $state -Depth 10
    Write-TextFile $StatePath ((Convert-Eol $json "`r`n") + "`r`n") $false
    Write-Status 'OK' ('최초 설치: 설치 전 상태를 기록했습니다: {0}' -f $StatePath)
  } else {
    $prev = ConvertFrom-JsonText (Read-TextFile $StatePath).Text
    Write-Status 'OK' ('재설치: 최초 설치 기록 유지 (설치 전 백업: {0})' -f $prev.original_backup_dir)
  }
} catch {
  Write-Status 'FAIL' ('설치 상태 기록 실패. 중단합니다 ({0})' -f $_.Exception.Message)
  exit 1
}

# ---------------------------------------------------------------- env var
Write-Section '라우팅 게이트'
if ($SkipEnvVar) {
  Write-Status 'SKIP' ('사용자 환경 변수 {0} (-SkipEnvVar)' -f $GateVar)
} else {
  try {
    $cur = [Environment]::GetEnvironmentVariable($GateVar, 'User')
    if ($cur -ceq 'warn') { Write-Status 'OK' ('사용자 환경 변수 {0}=warn (이미 설정됨)' -f $GateVar) }
    else {
      [Environment]::SetEnvironmentVariable($GateVar, 'warn', 'User')
      Write-Status 'OK' ('사용자 환경 변수 {0}=warn 설정 (이전 값: {1})' -f $GateVar, $cur)
    }
  } catch { Write-Status 'FAIL' ('환경 변수 설정 실패 ({0})' -f $_.Exception.Message) }
}

# ---------------------------------------------------------------- kit dir
Write-Section '키트 파일'
try {
  if (-not $rolesExists) {
    [System.IO.File]::Copy($templates.Roles, $KitRoles, $true)
    Write-Status 'OK' ('roles.json 생성: {0}' -f $KitRoles)
  } elseif ($Force) {
    [System.IO.File]::Copy($templates.Roles, $KitRoles, $true)
    Write-Status 'OK' ('roles.json 덮어씀 (-Force, 이전 파일은 백업에 있음): {0}' -f $KitRoles)
  } else {
    Write-Status 'OK' ('roles.json 유지 (기존 파일, 덮어쓰려면 -Force): {0}' -f $KitRoles)
  }
} catch { Write-Status 'FAIL' ('roles.json 쓰기 실패 ({0})' -f $_.Exception.Message) }
try {
  $syncBytes = [System.IO.File]::ReadAllBytes($SyncSource)
  if (-not ($syncBytes.Length -ge 3 -and $syncBytes[0] -eq 0xEF -and $syncBytes[1] -eq 0xBB -and $syncBytes[2] -eq 0xBF)) {
    throw 'scripts\sync-roles.ps1 에 UTF-8 BOM 이 없습니다. (PowerShell 5.1 이 한글을 cp949 로 잘못 읽습니다)'
  }
  [System.IO.File]::WriteAllBytes($KitSync, $syncBytes)
  Write-Status 'OK' ('sync-roles.ps1 갱신: {0}' -f $KitSync)
} catch { Write-Status 'FAIL' ('sync-roles.ps1 쓰기 실패 ({0})' -f $_.Exception.Message) }

# ---------------------------------------------------------------- instruction files
Write-Section '지침 파일'
foreach ($p in $instructionPlans) {
  if ($p.State -eq 'fail') { Write-Status 'FAIL' ('{0}: {1}' -f $p.Path, $p.Message); continue }
  if ($p.State -eq 'warn') { Write-Status 'WARN' ('{0}: {1}' -f $p.Path, $p.Message); continue }
  if (-not $p.Changed) { Write-Status 'OK' ('{0}: 변경 없음' -f $p.Path); continue }
  try {
    Write-TextFile $p.Path $p.NewText $p.Bom
    if ($p.HasPolicy) { Write-Status 'OK' ('{0}: 키트 정책 블록과 무력화 블록 적용' -f $p.Path) }
    else { Write-Status 'OK' ('{0}: agent-switchboard 블록 무력화' -f $p.Path) }
  } catch { Write-Status 'FAIL' ('{0}: 쓰기 실패 ({1})' -f $p.Path, $_.Exception.Message) }
}
if ($null -eq $codexPlan) { Write-Status 'SKIP' 'AGENTS.md (.codex 없음)' }
if ($null -eq $geminiPlan) { Write-Status 'SKIP' 'GEMINI.md (.gemini 없음)' }

# ---------------------------------------------------------------- roles
Write-Section '롤 파일'
try {
  if ([System.IO.File]::Exists($ConsultantPath)) {
    Write-Status 'OK' ('consultant.md 유지 (이미 있음): {0}' -f $ConsultantPath)
  } else {
    [void][System.IO.Directory]::CreateDirectory($AgentsDir)
    [System.IO.File]::Copy($templates.Consultant, $ConsultantPath, $false)
    Write-Status 'OK' ('consultant.md 생성: {0}' -f $ConsultantPath)
  }
} catch { Write-Status 'FAIL' ('consultant.md 쓰기 실패 ({0})' -f $_.Exception.Message) }
if ([System.IO.File]::Exists($KitSync) -and [System.IO.File]::Exists($KitRoles)) {
  $code = Invoke-SyncScript $KitSync @('-HomeDir', $HomeDir, '-ManifestPath', $KitRoles, '-Quiet')
  if ($code -eq 0) { Write-Status 'OK' '롤 파일 정리와 model/effort 동기화 (sync-roles.ps1)' }
  else { Write-Status 'FAIL' ('sync-roles.ps1 실패 (종료 코드 {0})' -f $code) }
} else {
  Write-Status 'FAIL' 'sync-roles.ps1 또는 roles.json 이 없어 롤 파일을 동기화하지 못했습니다.'
}

# ---------------------------------------------------------------- settings.json
Write-Section 'Claude Code 설정'
if ($settingsPlan.State -eq 'fail') {
  Write-Status 'FAIL' ('settings.json: JSON 을 안전하게 병합할 수 없어 건드리지 않았습니다 ({0})' -f $settingsPlan.Message)
} elseif ($settingsPlan.Action -eq 'present') {
  Write-Status 'OK' 'settings.json: sync-roles.ps1 을 실행하는 SessionStart 훅이 이미 있습니다.'
} else {
  try {
    Write-TextFile $SettingsPath $settingsPlan.NewText $settingsPlan.Bom
    Write-Status 'OK' 'settings.json: 세션마다 sync-roles.ps1 을 실행하는 SessionStart 훅 추가'
  } catch { Write-Status 'FAIL' ('settings.json 쓰기 실패 ({0})' -f $_.Exception.Message) }
}

# ---------------------------------------------------------------- verification
Write-Section '검증'
foreach ($p in $instructionPlans) {
  if ($p.State -ne 'ok') { continue }
  try {
    $t = (Read-TextFile $p.Path).Text
    if ($p.HasPolicy) {
      $nb = Get-OccurrenceCount $t $KitBegin; $ne = Get-OccurrenceCount $t $KitEnd
      if ($nb -eq 1 -and $ne -eq 1) { Write-Status 'OK' ('{0}: 키트 정책 블록 1개' -f $p.Path) }
      else { Write-Status 'FAIL' ('{0}: 키트 정책 표식 수가 이상합니다 (시작 {1}, 끝 {2})' -f $p.Path, $nb, $ne) }
    }
    $v = Get-UpstreamBlockVerdict $t
    if ($v -eq 'untouched') { Write-Status 'OK' ('{0}: agent-switchboard 가 블록을 덮어쓰지 않음' -f $p.Path) }
    else { Write-Status 'FAIL' ('{0}: agent-switchboard 판정이 {1} 입니다' -f $p.Path, $v) }
  } catch { Write-Status 'FAIL' ('{0}: 검증 실패 ({1})' -f $p.Path, $_.Exception.Message) }
}
foreach ($rel in $UpstreamRoleRel) {
  $path = Join-Path $HomeDir $rel
  if (-not [System.IO.File]::Exists($path)) {
    Write-Status 'SKIP' ('{0}: 없음 (agent-switchboard 가 새로 만들면 다음 세션 시작 훅이 정리합니다)' -f $rel)
    continue
  }
  try {
    $t = (Read-TextFile $path).Text
    if ($t.Length -eq 0) { Write-Status 'WARN' ('{0}: 빈 파일은 agent-switchboard 가 덮어씁니다. 다음 세션 시작 훅이 정리합니다.' -f $rel); continue }
    $v = Get-UpstreamRoleVerdict $path $t
    if ($v -eq 'untouched') { Write-Status 'OK' ('{0}: 사용자 소유 (agent-switchboard 가 덮어쓰지 않음)' -f $rel) }
    else { Write-Status 'FAIL' ('{0}: agent-switchboard 가 덮어쓸 수 있는 상태입니다' -f $rel) }
  } catch { Write-Status 'FAIL' ('{0}: 검증 실패 ({1})' -f $rel, $_.Exception.Message) }
}
if ([System.IO.File]::Exists($ConsultantPath)) { Write-Status 'OK' 'consultant.md 있음' } else { Write-Status 'FAIL' 'consultant.md 없음' }
try {
  $cfg = ConvertFrom-JsonText (Read-TextFile $KitRoles).Text
  $active = [string]$cfg.active_profile
  if ($null -ne $cfg.profiles.PSObject.Properties[$active]) { Write-Status 'OK' ('roles.json 유효 (active_profile: {0})' -f $active) }
  else { Write-Status 'FAIL' ('roles.json: active_profile {0} 이 profiles 에 없습니다' -f $active) }
} catch { Write-Status 'FAIL' ('roles.json 을 읽을 수 없습니다 ({0})' -f $_.Exception.Message) }
if ([System.IO.File]::Exists($KitSync) -and (Test-BomFile $KitSync)) { Write-Status 'OK' 'sync-roles.ps1 (UTF-8 BOM)' }
else { Write-Status 'FAIL' 'sync-roles.ps1 이 없거나 BOM 이 없습니다' }
if ($settingsPlan.State -eq 'ok') {
  try {
    $root = ConvertFrom-JsonText (Read-TextFile $SettingsPath).Text
    if (Test-SyncHookPresent $root) { Write-Status 'OK' 'settings.json: SessionStart 동기화 훅 있음' }
    else { Write-Status 'FAIL' 'settings.json: SessionStart 동기화 훅이 없습니다' }
  } catch { Write-Status 'FAIL' ('settings.json 검증 실패 ({0})' -f $_.Exception.Message) }
}
if ($SkipEnvVar) { Write-Status 'SKIP' ('{0} (-SkipEnvVar)' -f $GateVar) }
elseif ([Environment]::GetEnvironmentVariable($GateVar, 'User') -ceq 'warn') { Write-Status 'OK' ('{0}=warn (사용자 환경 변수)' -f $GateVar) }
else { Write-Status 'FAIL' ('{0} 이 warn 이 아닙니다' -f $GateVar) }

Write-Host ''
if ($script:FailCount -gt 0) {
  Write-Host ('실패 {0}건, 경고 {1}건. 위의 [FAIL] 줄을 확인하세요. 백업: {2}' -f $script:FailCount, $script:WarnCount, $backupDir) -ForegroundColor Red
  exit 1
}
Write-Host ('설치 완료 (경고 {0}건). 백업: {1}' -f $script:WarnCount, $backupDir) -ForegroundColor Green
if (-not $SkipEnvVar) {
  Write-Host '환경 변수와 훅을 반영하려면 Claude Code 와 Codex, VS Code 등 agent-switchboard 를 띄우는 앱을 모두 완전히 종료한 뒤 다시 시작하세요. 창만 새로 여는 것으로는 반영되지 않습니다.' -ForegroundColor Yellow
} else {
  Write-Host '훅을 반영하려면 Claude Code 를 완전히 종료한 뒤 다시 시작하세요.' -ForegroundColor Yellow
}
Write-Host ('역할을 바꾸려면 이 파일을 고치세요: {0}' -f $KitRoles)
exit 0
