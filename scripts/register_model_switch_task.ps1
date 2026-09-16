# register_model_switch_task.ps1 - Windows scheduled task for the time-of-day model router
#
# Registers a daily job that runs scripts/model_switch.py at both window
# boundaries (day start and night start). The script is invoked WITHOUT
# arguments, so it derives the mode from the real local clock; a trigger that
# fires late still applies the correct window.
#
# Verified constraints on Windows (why this file looks the way it does):
#   * Register-ScheduledTask - notably with an explicit -Principal - and a
#     <LogonTrigger> element inside the XML are both refused with 0x80070005
#     (access denied).
#   * The working path is a LogonTrigger-free XML definition registered with:
#       schtasks /create /tn <TaskName> /xml <file> /f
#   * No LogonTrigger is needed for catch-up: StartWhenAvailable=true makes a
#     trigger missed while the machine was asleep run shortly after the next
#     boot, and because the script resolves the mode from the real time, such
#     a catch-up run is inherently correct.
#
# The XML is written as UTF-16 (Task Scheduler requires that encoding for
# /xml input) next to the router script:
#   <ZcodeHome>\scripts\model_switch_task.xml
#
# Note: the task itself sets no environment variables, so the router resolves
# its config root from ZCODE_HOME or falls back to ~\.zcode. If you installed
# into a non-default root, persist the variable first (setx ZCODE_HOME <path>;
# scheduled tasks read the persisted user environment), or edit the XML before
# registering it.
#
# Re-register manually:
#   schtasks /create /tn "ZCode-SubagentModelSwitch" /xml "$HOME\.zcode\scripts\model_switch_task.xml" /f
# Run once immediately (does not change the schedule):
#   schtasks /run /tn "ZCode-SubagentModelSwitch"
# Inspect:
#   schtasks /query /tn "ZCode-SubagentModelSwitch" /v /fo LIST
#
# Parameters:
#   -TaskName       scheduled task name        (default: ZCode-SubagentModelSwitch)
#   -ZcodeHome      config root, script source (default: $env:ZCODE_HOME, else ~\.zcode)
#   -PythonPath     interpreter for the task   (default: "python")
#   -DayStartHour   day window start hour      (default: 9)
#   -NightStartHour night window start hour    (default: 23)

param(
  [string]$TaskName = 'ZCode-SubagentModelSwitch',
  [string]$ZcodeHome = '',
  [string]$PythonPath = 'python',
  [ValidateRange(0, 23)][int]$DayStartHour = 9,
  [ValidateRange(0, 23)][int]$NightStartHour = 23
)

$ErrorActionPreference = 'Stop'

function Escape-Xml([string]$Text) {
  # '&' must be replaced first so the entities below are not double-escaped
  return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
}

function New-StartBoundary([int]$Hour) {
  # local wall clock + local UTC offset; roll to tomorrow if the boundary
  # already passed today so the trigger never starts in the past
  $start = (Get-Date).Date.AddHours($Hour)
  if ($start -le (Get-Date)) { $start = $start.AddDays(1) }
  $offset = (Get-Date).ToString('zzz', [System.Globalization.CultureInfo]::InvariantCulture)
  return $start.ToString("yyyy-MM-dd'T'HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture) + $offset
}

# --- resolve paths -----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ZcodeHome)) { $ZcodeHome = $env:ZCODE_HOME }
if ([string]::IsNullOrWhiteSpace($ZcodeHome)) { $ZcodeHome = Join-Path $HOME '.zcode' }

$scriptDir  = Join-Path $ZcodeHome 'scripts'
$scriptPath = Join-Path $scriptDir 'model_switch.py'
$xmlPath    = Join-Path $scriptDir 'model_switch_task.xml'

if (-not (Test-Path -LiteralPath $scriptDir -PathType Container)) {
  New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  [Console]::Error.WriteLine("register_model_switch_task.ps1: warning: $scriptPath not found - run the installer first, or the task will fail when it fires")
}

# --- task definition ---------------------------------------------------------
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$description = ("Switch subagent models by time of day: day window at {0}:00, night window at {1}:00. " +
                "The task runs the router script without arguments, which resolves the window from the local clock.") -f $DayStartHour, $NightStartHour

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(Escape-Xml $description)</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$(New-StartBoundary $DayStartHour)</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <CalendarTrigger>
      <StartBoundary>$(New-StartBoundary $NightStartHour)</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$(Escape-Xml $PythonPath)</Command>
      <Arguments>"$(Escape-Xml $scriptPath)"</Arguments>
      <WorkingDirectory>$(Escape-Xml $scriptDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# UTF-16LE with BOM, matching the declaration in the XML header
[System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))
Write-Host "xml written: $xmlPath"

# --- register ----------------------------------------------------------------
$output = & schtasks /create /tn $TaskName /xml $xmlPath /f 2>&1
$code = $LASTEXITCODE
foreach ($line in @($output)) { Write-Host $line }
if ($code -ne 0) {
  [Console]::Error.WriteLine("register_model_switch_task.ps1: error: schtasks exited with code $code")
  exit $code
}
Write-Host "registered task: $TaskName"
Write-Host "manual trigger: schtasks /run /tn `"$TaskName`""
