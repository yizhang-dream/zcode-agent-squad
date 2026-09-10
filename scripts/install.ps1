# install.ps1 - zcode-agent-squad installer for Windows
#
# - copies subagent definitions (coder / watcher / reviewer) into
#   "$ZCODE_HOME\agents\"
# - injects a managed rules block into "$ZCODE_HOME\AGENTS.md"
#
# Idempotent: re-running only replaces the managed block; user content
# around it is preserved untouched. Existing agent files that differ from
# the repo copies are backed up as <name>.md.bak before being overwritten.
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+ (pwsh).
# Accepts both PowerShell-style (-Strong X) and long-style (--strong X) flags.

$ErrorActionPreference = 'Stop'

$BeginMark  = '<!-- BEGIN: zcode-agent-squad -->'
$EndMark    = '<!-- END: zcode-agent-squad -->'
$AgentNames = @('coder', 'watcher', 'reviewer')

$StrongModel = 'GLM-5.3'
$FastModel   = 'GLM-5.3-Flash'
$Concurrency = '50'
$Uninstall = $false
$ShowHelp  = $false

function Die([string]$Msg) {
  [Console]::Error.WriteLine("install.ps1: error: $Msg")
  exit 1
}

function Write-Usage {
  Write-Host @'
zcode-agent-squad installer (Windows)

Usage:
  install.ps1 [options]

Options:
  -Strong <model> | --strong <model>      Strong model name (default: GLM-5.3)
  -Fast <model> | --fast <model>          Fast model name (default: GLM-5.3-Flash)
  -Concurrency <n> | --concurrency <n>    Max concurrent subagents (default: 50)
  -Uninstall | --uninstall                Remove agents and the managed rules block
  -h | -Help | --help                     Show this help

Environment:
  ZCODE_HOME  ZCode config directory (default: ~\.zcode)
'@
}

function Trim-Newlines([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  return $Text.TrimEnd([char]13, [char]10)
}

function LTrim-Newlines([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  return $Text.TrimStart([char]13, [char]10)
}

function Get-Newline([string]$Text) {
  if (-not [string]::IsNullOrEmpty($Text) -and $Text.Contains("`r`n")) { return "`r`n" }
  return "`n"
}

function Replace-Placeholders([string]$Text) {
  return $Text.Replace('{{STRONG_MODEL}}', $StrongModel).Replace('{{FAST_MODEL}}', $FastModel).Replace('{{CONCURRENCY}}', $Concurrency)
}

function Render-Block([string]$Nl) {
  $snippetPath = Join-Path (Join-Path $RepoRoot 'rules') 'AGENTS.snippet.md'
  if (-not (Test-Path -LiteralPath $snippetPath -PathType Leaf)) {
    Die "rules snippet not found: $snippetPath"
  }
  $body = Replace-Placeholders ([System.IO.File]::ReadAllText($snippetPath))
  # the snippet may already carry the marker lines itself; drop them so the
  # installed block contains exactly one BEGIN/END pair
  $lines = @($body -split "`r?`n") | Where-Object { $t = $_.Trim(); ($t -cne $BeginMark) -and ($t -cne $EndMark) }
  $body = Trim-Newlines ($lines -join $Nl)
  return $BeginMark + $Nl + $body + $Nl + $EndMark
}

function Render-Agent([string]$Path) {
  # placeholders in the agent frontmatter (e.g. model: {{FAST_MODEL}}) are
  # filled in on install, same replacement rules as the rules snippet
  $body = [System.IO.File]::ReadAllText($Path)
  return Replace-Placeholders $body
}

function Merge-Block([string]$Existing, [string]$Block, [string]$Nl) {
  if ([string]::IsNullOrEmpty($Existing)) { return $Block }
  $bi = $Existing.IndexOf($BeginMark, [System.StringComparison]::Ordinal)
  if ($bi -ge 0) {
    $before = Trim-Newlines $Existing.Substring(0, $bi)
    $after = ''
    $ei = $Existing.IndexOf($EndMark, [System.StringComparison]::Ordinal)
    if ($ei -ge 0) {
      $after = LTrim-Newlines $Existing.Substring($ei + $EndMark.Length)
    }
    if ($before -and $after) { return $before + $Nl + $Nl + $Block + $Nl + $Nl + $after }
    if ($before) { return $before + $Nl + $Nl + $Block }
    if ($after)  { return $Block + $Nl + $Nl + $after }
    return $Block
  }
  if ($Existing.IndexOf($EndMark, [System.StringComparison]::Ordinal) -ge 0) {
    Write-Warning "found END marker without BEGIN in $AgentsMd; appending a fresh block"
  }
  $trimmed = Trim-Newlines $Existing
  if ($trimmed) { return $trimmed + $Nl + $Nl + $Block }
  return $Block
}

function Remove-Block([string]$Existing, [string]$Nl) {
  $bi = $Existing.IndexOf($BeginMark, [System.StringComparison]::Ordinal)
  if ($bi -lt 0) { return $null }  # no managed block present
  $before = Trim-Newlines $Existing.Substring(0, $bi)
  $after = ''
  $ei = $Existing.IndexOf($EndMark, [System.StringComparison]::Ordinal)
  if ($ei -ge 0) {
    $after = LTrim-Newlines $Existing.Substring($ei + $EndMark.Length)
  }
  if ($before -and $after) { return $before + $Nl + $Nl + $after }
  if ($before) { return $before }
  if ($after)  { return $after }
  return ''
}

function Invoke-Install {
  $repoAgents = Join-Path $RepoRoot 'agents'
  if (-not (Test-Path -LiteralPath $repoAgents -PathType Container)) {
    Die "agents directory not found: $repoAgents"
  }

  if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $AgentsDir -Force | Out-Null
  }

  # --- 1. agent definitions ----------------------------------------------------
  foreach ($name in $AgentNames) {
    $src = Join-Path $repoAgents ($name + '.md')
    $dst = Join-Path $AgentsDir ($name + '.md')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
      Die "agent definition not found: $src"
    }
    # drift detection compares against the rendered content so re-installing
    # with the same parameters creates no backup
    $rendered = Render-Agent $src
    if ((Test-Path -LiteralPath $dst -PathType Leaf) -and
        ($rendered -cne [System.IO.File]::ReadAllText($dst))) {
      Copy-Item -LiteralPath $dst -Destination ($dst + '.bak') -Force
      Write-Host "backed up: $dst -> $dst.bak"
    }
    [System.IO.File]::WriteAllText($dst, $rendered)
    Write-Host "installed: $dst"
  }

  # --- 2. merge managed block into AGENTS.md -----------------------------------
  $existing = ''
  if (Test-Path -LiteralPath $AgentsMd -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($AgentsMd)
  }
  $Nl = Get-Newline $existing
  $block = Render-Block $Nl
  $merged = Merge-Block $existing $block $Nl
  [System.IO.File]::WriteAllText($AgentsMd, ((Trim-Newlines $merged) + $Nl))
  Write-Host "updated: $AgentsMd"

  # --- 3. next steps -------------------------------------------------------------
  Write-Host ''
  Write-Host "zcode-agent-squad installed into $ZcodeHome"
  Write-Host 'next steps:'
  Write-Host ("  1. Desktop Settings -> Subagents: switch the built-in general-purpose and Explore agents to the fast model ({0}), or back up and edit {1} (builtInModelOverrides)." -f $FastModel, (Join-Path $ZcodeHome 'v2\agents-state.json'))
  Write-Host '  2. Changes take effect in new sessions.'
}

function Invoke-Uninstall {
  $did = 0

  # --- 1. agent definitions (leave *.bak alone) ---------------------------------
  foreach ($name in $AgentNames) {
    $f = Join-Path $AgentsDir ($name + '.md')
    if (Test-Path -LiteralPath $f -PathType Leaf) {
      Remove-Item -LiteralPath $f -Force
      Write-Host "removed: $f"
      $did = 1
    }
  }

  # --- 2. managed block -----------------------------------------------------------
  if (Test-Path -LiteralPath $AgentsMd -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($AgentsMd)
    $Nl = Get-Newline $existing
    $rest = Remove-Block $existing $Nl
    if ($null -ne $rest) {
      if ($rest) {
        [System.IO.File]::WriteAllText($AgentsMd, ((Trim-Newlines $rest) + $Nl))
      } else {
        [System.IO.File]::WriteAllText($AgentsMd, '')
      }
      Write-Host "removed managed block from: $AgentsMd"
      $did = 1
    }
  }

  if ($did -eq 0) {
    Write-Host "nothing to uninstall in $ZcodeHome"
  }
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
if (-not $PSScriptRoot) {
  [Console]::Error.WriteLine('install.ps1: error: must be run as a script file (pwsh -File install.ps1)')
  exit 1
}
$RepoRoot = Split-Path -Parent $PSScriptRoot

# --- argument parsing (accepts -Flag and --flag forms) -------------------------
for ($i = 0; $i -lt $args.Count; $i++) {
  $key = ([string]$args[$i]).TrimStart('-').ToLowerInvariant()
  switch ($key) {
    'strong' {
      if ($i + 1 -ge $args.Count) { Die '-Strong requires an argument' }
      $i++
      $StrongModel = [string]$args[$i]
    }
    'fast' {
      if ($i + 1 -ge $args.Count) { Die '-Fast requires an argument' }
      $i++
      $FastModel = [string]$args[$i]
    }
    'concurrency' {
      if ($i + 1 -ge $args.Count) { Die '-Concurrency requires an argument' }
      $i++
      $Concurrency = [string]$args[$i]
    }
    'uninstall' { $Uninstall = $true }
    'h'    { $ShowHelp = $true }
    'help' { $ShowHelp = $true }
    default { Die "unknown option: $($args[$i]) (see -Help)" }
  }
}

if ($Concurrency -notmatch '^[0-9]+$') {
  Die "-Concurrency expects a positive integer, got: '$Concurrency'"
}

$ZcodeHome = $env:ZCODE_HOME
if ([string]::IsNullOrWhiteSpace($ZcodeHome)) {
  $ZcodeHome = Join-Path $HOME '.zcode'
}
$AgentsDir = Join-Path $ZcodeHome 'agents'
$AgentsMd  = Join-Path $ZcodeHome 'AGENTS.md'

if ($ShowHelp) {
  Write-Usage
  exit 0
}

if ($Uninstall) {
  Invoke-Uninstall
  exit 0
}

Invoke-Install
exit 0
