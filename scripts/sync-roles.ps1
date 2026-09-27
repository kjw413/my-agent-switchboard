<#
.SYNOPSIS
  roles.json 값을 네이티브 롤 파일(model/effort)에 동기화하고, agent-switchboard가
  롤 파일 소유권을 되찾아 가지 못하도록 정리합니다.

.DESCRIPTION
  Agent 툴에는 effort 인자가 없어서 네이티브 서브에이전트의 effort는 롤 파일
  frontmatter에서만 읽힙니다. 이 스크립트는 roles.json 을 단일 원본으로 삼아
  값을 롤 파일에 밀어 넣습니다. switchboard-kit 설치 후에는 Claude Code 의
  SessionStart 훅이 세션마다 이 스크립트를 -Quiet 로 실행합니다.

  단계
    A. 정리: Explore.md, economy-worker.md, consultant.md, explorer.toml,
       worker.toml 중 내용이 있는 파일에서 agent-switchboard 관리 표식 줄을 지우고
       설치기 소유권 판정에 쓰이는 문구를 바꿉니다. 그러면 agent-switchboard는
       이 파일들을 사용자 소유로 보고 덮어쓰지 않습니다.
    B. 매니페스트 결정 (앞의 것이 우선)
         1. <ProjectRoot>\.orchestration\roles.json
         2. <HomeDir>\.claude\orchestration\roles.json
    C. active_profile 의 역할을 롤 파일에 적용합니다.
         vendor claude + native_subagent : .claude\agents\<agent_type>.md frontmatter
         vendor codex  + reader          : .codex\agents\explorer.toml
         vendor codex  + implementer     : .codex\agents\worker.toml
    D. 결과 파일에 관리 표식이나 설치기 소유권 문구가 남지 않았는지 확인합니다.

  종료 코드: 0 = 정상(매니페스트가 없을 때 포함), 1 = 매니페스트를 읽을 수 없거나
  형식이 잘못됨, 또는 쓰기/검증 실패.

.PARAMETER ProjectRoot
  프로젝트 매니페스트를 찾을 폴더. 기본값은 현재 폴더입니다.
.PARAMETER HomeDir
  사용자 홈. 기본값은 %USERPROFILE% 입니다.
.PARAMETER DryRun
  무엇이 바뀔지만 보여 주고 디스크에는 쓰지 않습니다.
.PARAMETER Quiet
  오류가 아니면 아무것도 출력하지 않습니다. (SessionStart 훅용)
.PARAMETER ManifestPath
  매니페스트 경로를 직접 지정합니다. 지정하면 B 단계의 탐색을 건너뜁니다.

.EXAMPLE
  & "$env:USERPROFILE\.claude\orchestration\sync-roles.ps1"
.EXAMPLE
  & "$env:USERPROFILE\.claude\orchestration\sync-roles.ps1" -DryRun
#>
[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$HomeDir = $env:USERPROFILE,
  [switch]$DryRun,
  [switch]$Quiet,
  [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- constants
# agent-switchboard (hierarchy_install.py) 가 롤 파일을 자기 소유로 판정하는 조건과 같은 문자열입니다.
$ManagedLineRe = New-Object System.Text.RegularExpressions.Regex '^# agent-switchboard:managed sha256=[0-9a-f]{64}\s*$'
$ManagedFileRe = New-Object System.Text.RegularExpressions.Regex '(?m)^# agent-switchboard:managed sha256=([0-9a-f]{64})\s*$'
$CostWord = 'Cost-efficient'
$CostWordReplacement = 'Low-cost'
$LegacyClaudeString = 'Require an approved work package stating Route, exact model/effort'
$LegacyClaudeReplacement = 'Require an approved work package that states the route and the exact model/effort'

$script:ErrorCount = 0
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Info([string]$Message) {
  if (-not $Quiet) { Write-Host $Message }
}
function Write-Ok([string]$Message) {
  if (-not $Quiet) { Write-Host ('[OK] ' + $Message) -ForegroundColor Green }
}
function Write-Dry([string]$Message) {
  if (-not $Quiet) { Write-Host ('[DRY] ' + $Message) -ForegroundColor Cyan }
}
function Write-Skip([string]$Message) {
  if (-not $Quiet) { Write-Host ('[SKIP] ' + $Message) -ForegroundColor DarkGray }
}
function Write-WarnLine([string]$Message) {
  if (-not $Quiet) { Write-Host ('[WARN] ' + $Message) -ForegroundColor Yellow }
}
function Write-ErrLine([string]$Message) {
  $script:ErrorCount++
  [Console]::Error.WriteLine('[FAIL] sync-roles: ' + $Message)
}

# ---------------------------------------------------------------- text helpers
function Read-TextFile([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $offset = 0
  if ($bom) { $offset = 3 }
  $text = $script:Utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
  return [pscustomobject]@{ Path = $Path; Text = $text; Original = $text; Bom = $bom }
}

function Write-TextFile([string]$Path, [string]$Text) {
  # .md/.toml 은 BOM 없이 씁니다. BOM이 '---' 앞에 붙으면 YAML frontmatter가 깨집니다.
  [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Get-Eol([string]$Text) {
  $crlf = 0; $lf = 0
  for ($i = 0; $i -lt $Text.Length; $i++) {
    if ($Text[$i] -eq [char]10) {
      if ($i -gt 0 -and $Text[$i - 1] -eq [char]13) { $crlf++ } else { $lf++ }
    }
  }
  if ($crlf -eq 0 -and $lf -eq 0) { return "`n" }
  if ($crlf -ge $lf) { return "`r`n" }
  return "`n"
}

function Split-Lines([string]$Text) {
  $list = New-Object System.Collections.Generic.List[object]
  $pos = 0
  while ($pos -lt $Text.Length) {
    $nl = $Text.IndexOf([char]10, $pos)
    if ($nl -lt 0) { $line = $Text.Substring($pos); $pos = $Text.Length }
    else { $line = $Text.Substring($pos, $nl - $pos + 1); $pos = $nl + 1 }
    $content = $line; $eol = ''
    if ($content.EndsWith("`r`n", [System.StringComparison]::Ordinal)) {
      $content = $content.Substring(0, $content.Length - 2); $eol = "`r`n"
    } elseif ($content.EndsWith("`n", [System.StringComparison]::Ordinal)) {
      $content = $content.Substring(0, $content.Length - 1); $eol = "`n"
    }
    $list.Add([pscustomobject]@{ Content = $content; Eol = $eol })
  }
  return ,$list
}

function Join-Lines($Lines) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($l in $Lines) { [void]$sb.Append($l.Content); [void]$sb.Append($l.Eol) }
  return $sb.ToString()
}

function Get-UpstreamView([string]$Text) {
  # agent-switchboard는 Python universal newline 으로 읽으므로 CR/CRLF 가 LF 로 보입니다.
  return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

# ---------------------------------------------------------------- step A: sanitise
function Invoke-Sanitize([string]$Text) {
  $lines = Split-Lines $Text
  $kept = New-Object System.Collections.Generic.List[object]
  foreach ($l in $lines) {
    if ($ManagedLineRe.IsMatch($l.Content)) { continue }
    $kept.Add($l)
  }
  $out = Join-Lines $kept
  $out = $out.Replace($CostWord, $CostWordReplacement)
  $out = $out.Replace($LegacyClaudeString, $LegacyClaudeReplacement)
  return $out
}

# ---------------------------------------------------------------- step C: writers
function Format-YamlValue([string]$Value) {
  if ($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { return $Value }
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Format-TomlString([string]$Value) {
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Test-Blank($Value) {
  return ($null -eq $Value -or ([string]$Value).Trim().Length -eq 0)
}

function Set-MdFrontmatter([string]$Text, $Model, $Effort) {
  # frontmatter 가 없으면 $null 을 돌려줍니다.
  $lines = Split-Lines $Text
  if ($lines.Count -lt 2 -or $lines[0].Content.Trim() -ne '---') { return $null }
  $close = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Content.Trim() -eq '---') { $close = $i; break }
  }
  if ($close -lt 0) { return $null }
  $eol = Get-Eol $Text

  $modelIdx = -1
  for ($i = 1; $i -lt $close; $i++) {
    if ($lines[$i].Content -cmatch '^model\s*:') { $modelIdx = $i; break }
  }
  if (-not (Test-Blank $Model)) {
    $line = 'model: ' + (Format-YamlValue ([string]$Model))
    if ($modelIdx -ge 0) { $lines[$modelIdx].Content = $line }
    else {
      $lines.Insert($close, [pscustomobject]@{ Content = $line; Eol = $eol })
      $modelIdx = $close; $close++
    }
  }

  $effortIdx = -1
  for ($i = 1; $i -lt $close; $i++) {
    if ($lines[$i].Content -cmatch '^effort\s*:') { $effortIdx = $i; break }
  }
  if (Test-Blank $Effort) {
    if ($effortIdx -ge 0) { $lines.RemoveAt($effortIdx) }
  } else {
    $line = 'effort: ' + (Format-YamlValue ([string]$Effort))
    if ($effortIdx -ge 0) { $lines[$effortIdx].Content = $line }
    else {
      $at = $close
      if ($modelIdx -ge 0) { $at = $modelIdx + 1 }
      $lines.Insert($at, [pscustomobject]@{ Content = $line; Eol = $eol })
    }
  }
  return (Join-Lines $lines)
}

function Get-TomlTopLevelInfo($Lines) {
  # 최상위 키 줄 번호를 찾습니다. 여러 줄 문자열("""/''') 안과 [table] 아래는 건너뜁니다.
  $info = @{ Model = -1; Effort = -1; Name = -1; FirstKey = -1; TableStart = -1 }
  $delim = $null
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $c = $Lines[$i].Content
    if ($null -ne $delim) {
      $n = ([regex]::Matches($c, [regex]::Escape($delim))).Count
      if ($n % 2 -eq 1) { $delim = $null }
      continue
    }
    if ($c -match '^\s*\[') { $info.TableStart = $i; break }
    if ($c -cmatch '^\s*model\s*=') { if ($info.Model -lt 0) { $info.Model = $i } }
    elseif ($c -cmatch '^\s*model_reasoning_effort\s*=') { if ($info.Effort -lt 0) { $info.Effort = $i } }
    elseif ($c -cmatch '^\s*name\s*=') { if ($info.Name -lt 0) { $info.Name = $i } }
    if ($c -match '^\s*[A-Za-z0-9_"''-]+\s*=' -and $info.FirstKey -lt 0) { $info.FirstKey = $i }
    foreach ($d in @('"""', "'''")) {
      $n = ([regex]::Matches($c, [regex]::Escape($d))).Count
      if ($n % 2 -eq 1) { $delim = $d; break }
    }
  }
  return $info
}

function Set-TomlRole([string]$Text, $Model, $Effort) {
  $lines = Split-Lines $Text
  $eol = Get-Eol $Text
  if (-not (Test-Blank $Model)) {
    $info = Get-TomlTopLevelInfo $lines
    $line = 'model = ' + (Format-TomlString ([string]$Model))
    if ($info.Model -ge 0) { $lines[$info.Model].Content = $line }
    else {
      $at = 0
      if ($info.Name -ge 0) { $at = $info.Name + 1 }
      elseif ($info.FirstKey -ge 0) { $at = $info.FirstKey }
      elseif ($info.TableStart -ge 0) { $at = $info.TableStart }
      else { $at = $lines.Count }
      if ($at -gt 0 -and $at -eq $lines.Count -and $lines[$at - 1].Eol -eq '') { $lines[$at - 1].Eol = $eol }
      $lines.Insert($at, [pscustomobject]@{ Content = $line; Eol = $eol })
    }
  }
  $info = Get-TomlTopLevelInfo $lines
  if (Test-Blank $Effort) {
    if ($info.Effort -ge 0) { $lines.RemoveAt($info.Effort) }
  } else {
    $line = 'model_reasoning_effort = ' + (Format-TomlString ([string]$Effort))
    if ($info.Effort -ge 0) { $lines[$info.Effort].Content = $line }
    else {
      $at = $lines.Count
      if ($info.Model -ge 0) { $at = $info.Model + 1 }
      elseif ($info.TableStart -ge 0) { $at = $info.TableStart }
      if ($at -gt 0 -and $at -eq $lines.Count -and $lines[$at - 1].Eol -eq '') { $lines[$at - 1].Eol = $eol }
      $lines.Insert($at, [pscustomobject]@{ Content = $line; Eol = $eol })
    }
  }
  return (Join-Lines $lines)
}

# ---------------------------------------------------------------- step D: upstream predicates
function Test-UpstreamOwnable([string]$Path, [string]$Text) {
  # agent-switchboard 가 이 파일을 다시 가져갈 수 있으면 사유 문자열, 아니면 $null.
  # 빈 파일은 agent-switchboard 가 확인 없이 덮어쓰지만 A 단계는 빈 파일을 읽지 않습니다.
  $view = Get-UpstreamView $Text
  if ($ManagedFileRe.IsMatch($view)) { return '관리 표식이 남아 있음' }
  $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($ext -eq '.toml') {
    if ($view.Contains('name = "' + $name + '"') -and $view.Contains($CostWord)) { return "Codex 설치기 소유권 문구('$CostWord')가 남아 있음" }
  } else {
    if ($view.Contains('name: ' + $name) -and ($view.Contains($CostWord) -or $view.Contains($LegacyClaudeString))) {
      return 'Claude 설치기 소유권 문구가 남아 있음'
    }
  }
  return $null
}

# ---------------------------------------------------------------- JSON helpers
function Get-Field($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  if (-not ($Object -is [System.Management.Automation.PSCustomObject])) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# ================================================================ main
if ([string]::IsNullOrWhiteSpace($HomeDir)) {
  Write-ErrLine '홈 폴더를 알 수 없습니다. -HomeDir 를 지정하세요.'
  exit 1
}
$HomeDir = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($HomeDir)).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).ProviderPath }
else { $ProjectRoot = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectRoot)) }

$claudeAgents = Join-Path $HomeDir '.claude\agents'
$codexAgents = Join-Path $HomeDir '.codex\agents'

$files = [ordered]@{}   # full path -> file record
$sanitizeTargets = @(
  (Join-Path $claudeAgents 'Explore.md'),
  (Join-Path $claudeAgents 'economy-worker.md'),
  (Join-Path $claudeAgents 'consultant.md'),
  (Join-Path $codexAgents 'explorer.toml'),
  (Join-Path $codexAgents 'worker.toml')
)

function Get-FileRecord([string]$Path) {
  if ($files.Contains($Path)) { return $files[$Path] }
  $rec = Read-TextFile $Path
  $files[$Path] = $rec
  return $rec
}

# ---- A
foreach ($p in $sanitizeTargets) {
  if (-not [System.IO.File]::Exists($p)) { continue }
  if ((New-Object System.IO.FileInfo $p).Length -eq 0) { continue }
  try {
    $rec = Get-FileRecord $p
    $rec.Text = Invoke-Sanitize $rec.Text
  } catch {
    Write-ErrLine ("{0}: 읽기 실패 ({1})" -f $p, $_.Exception.Message)
  }
}

# ---- B
$manifest = $null
$scope = ''
$manifestBroken = $false
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
  $manifest = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ManifestPath)); $scope = '지정'
  if (-not [System.IO.File]::Exists($manifest)) {
    Write-ErrLine ("지정한 매니페스트가 없습니다: {0}" -f $manifest)
    $manifestBroken = $true
  }
} else {
  $projectManifest = Join-Path $ProjectRoot '.orchestration\roles.json'
  $globalManifest = Join-Path $HomeDir '.claude\orchestration\roles.json'
  if ([System.IO.File]::Exists($projectManifest)) { $manifest = $projectManifest; $scope = '프로젝트' }
  elseif ([System.IO.File]::Exists($globalManifest)) { $manifest = $globalManifest; $scope = '전역' }
  else {
    Write-WarnLine ("roles.json 을 찾지 못했습니다. 롤 파일 정리만 합니다.`n       {0}`n       {1}" -f $projectManifest, $globalManifest)
  }
}

$cfg = $null
if ($null -ne $manifest -and -not $manifestBroken) {
  try {
    $raw = (Read-TextFile $manifest).Text
    if (-not $raw.TrimStart().StartsWith('{', [System.StringComparison]::Ordinal)) { throw 'JSON 객체가 아닙니다.' }
    $cfg = ConvertFrom-Json -InputObject $raw
  } catch {
    Write-ErrLine ("매니페스트를 읽을 수 없습니다: {0} ({1})" -f $manifest, $_.Exception.Message)
    $manifestBroken = $true
  }
}

# ---- C
$targets = [ordered]@{}   # path -> assignment
if ($null -ne $cfg) {
  $profileName = Get-Field $cfg 'active_profile'
  $prof = Get-Field (Get-Field $cfg 'profiles') ([string]$profileName)
  $roles = Get-Field $prof 'roles'
  if ([string]::IsNullOrWhiteSpace([string]$profileName) -or $null -eq $prof -or $null -eq $roles) {
    Write-ErrLine ("active_profile '{0}' 또는 그 roles 가 {1} 에 없습니다." -f $profileName, $manifest)
    $manifestBroken = $true
  } else {
    Write-Info ("매니페스트: {0} [{1}]" -f $manifest, $scope)
    Write-Info ("프로필    : {0}" -f $profileName)
    $valid = Get-Field $cfg '_valid_values'

    foreach ($rp in $roles.PSObject.Properties) {
      $roleName = $rp.Name
      if ($roleName.StartsWith('_', [System.StringComparison]::Ordinal)) { continue }
      $r = $rp.Value
      $vendor = [string](Get-Field $r 'vendor')
      $mechanism = [string](Get-Field $r 'mechanism')
      $model = Get-Field $r 'model'
      $effort = Get-Field $r 'effort'
      $agentType = [string](Get-Field $r 'agent_type')

      if ($null -ne $valid -and ($vendor -eq 'claude' -or $vendor -eq 'codex')) {
        $modelList = @(Get-Field $valid ($vendor + '_model'))
        $effortList = @(Get-Field $valid ($vendor + '_effort'))
        if (-not (Test-Blank $model) -and $modelList.Count -gt 0 -and -not ($modelList -ccontains [string]$model)) {
          Write-WarnLine ("{0}: model '{1}' 은(는) _valid_values.{2}_model 에 없습니다." -f $roleName, $model, $vendor)
        }
        if (-not (Test-Blank $effort) -and $effortList.Count -gt 0 -and -not ($effortList -ccontains [string]$effort)) {
          Write-WarnLine ("{0}: effort '{1}' 은(는) _valid_values.{2}_effort 에 없습니다." -f $roleName, $effort, $vendor)
        }
      }

      $path = $null; $kind = $null
      if ($vendor -eq 'claude') {
        if ($mechanism -ne 'native_subagent') {
          Write-Skip ("{0}: claude/{1} 는 호출 인자로 model/effort 를 넘기므로 롤 파일이 필요 없습니다." -f $roleName, $mechanism)
          continue
        }
        if ([string]::IsNullOrWhiteSpace($agentType) -or $agentType -notmatch '^[A-Za-z0-9._-]+$') {
          Write-WarnLine ("{0}: native_subagent 인데 agent_type 이 없거나 잘못되었습니다. 건너뜁니다." -f $roleName)
          continue
        }
        $path = Join-Path $claudeAgents ($agentType + '.md'); $kind = 'md'
      } elseif ($vendor -eq 'codex') {
        if ($roleName -eq 'reader') { $path = Join-Path $codexAgents 'explorer.toml' }
        elseif ($roleName -eq 'implementer') { $path = Join-Path $codexAgents 'worker.toml' }
        else {
          Write-Skip ("{0}: codex 역할은 Codex 쪽 대응 롤 파일이 없어 호출 인자로만 전달됩니다." -f $roleName)
          continue
        }
        $kind = 'toml'
      } else {
        Write-WarnLine ("{0}: 알 수 없는 vendor '{1}'. 건너뜁니다." -f $roleName, $vendor)
        continue
      }

      if (-not [System.IO.File]::Exists($path)) {
        Write-WarnLine ("{0}: 롤 파일이 없습니다: {1}" -f $roleName, $path)
        continue
      }
      if ($targets.Contains($path)) {
        $prev = $targets[$path]
        if ([string]$prev.Model -cne [string]$model -or [string]$prev.Effort -cne [string]$effort) {
          Write-WarnLine ("{0} 와 {1} 가 같은 파일 {2} 을 서로 다른 값으로 지정합니다. {1} 의 값을 씁니다." -f $roleName, $prev.Role, (Split-Path $path -Leaf))
        }
        continue
      }
      $targets[$path] = [pscustomobject]@{ Role = $roleName; Model = $model; Effort = $effort; Kind = $kind }
    }

    foreach ($path in @($targets.Keys)) {
      $t = $targets[$path]
      try {
        $rec = Get-FileRecord $path
      } catch {
        Write-ErrLine ("{0}: 읽기 실패 ({1})" -f $path, $_.Exception.Message)
        continue
      }
      if ($t.Kind -eq 'md') {
        $new = Set-MdFrontmatter $rec.Text $t.Model $t.Effort
        if ($null -eq $new) {
          Write-WarnLine ("{0}: YAML frontmatter 가 없어 model/effort 를 쓰지 못했습니다: {1}" -f $t.Role, $path)
          continue
        }
      } else {
        $new = Set-TomlRole $rec.Text $t.Model $t.Effort
      }
      $rec.Text = $new
      $effText = '(없음)'
      if (-not (Test-Blank $t.Effort)) { $effText = [string]$t.Effort }
      Write-Info ("  {0,-12} -> {1,-18} model={2} effort={3}" -f $t.Role, (Split-Path $path -Leaf), $t.Model, $effText)
    }
  }
}

# ---- D (쓰기 전에 메모리 상의 최종 결과로 확인)
# agent-switchboard 가 소유권을 판정하는 파일(A 단계 대상)만 검사합니다.
foreach ($path in @($files.Keys)) {
  if (-not ($sanitizeTargets -contains $path)) { continue }
  $rec = $files[$path]
  $reason = Test-UpstreamOwnable $path $rec.Text
  if ($null -ne $reason) { Write-ErrLine ("{0}: {1}" -f $path, $reason) }
}

# ---- write
$changed = 0
foreach ($path in @($files.Keys)) {
  $rec = $files[$path]
  if ($rec.Text -ceq $rec.Original) { continue }
  $changed++
  if ($DryRun) {
    Write-Dry ("바뀔 파일: {0}" -f $path)
  } else {
    try {
      Write-TextFile $path $rec.Text
      Write-Ok ("갱신: {0}" -f $path)
    } catch {
      Write-ErrLine ("{0}: 쓰기 실패 ({1})" -f $path, $_.Exception.Message)
    }
  }
}

if ($DryRun) { Write-Info ("DryRun: 바뀔 파일 {0}개. 디스크는 바뀌지 않았습니다." -f $changed) }
else { Write-Info ("완료: 갱신한 파일 {0}개" -f $changed) }

if ($script:ErrorCount -gt 0) { exit 1 }
exit 0
