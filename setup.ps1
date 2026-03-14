# =============================================================================
# setup.ps1 - One-time setup for the LoL Block Enforcer system
# Run this script ONCE as Administrator to deploy everything.
# After this runs, the system operates automatically with no manual steps.
# =============================================================================
param(
    [switch]$Test
)
# -----------------------------------------------------------------------------
# SECTION 1: ADMIN CHECK
# The script must run elevated (as Administrator) to create firewall rules
# and register Task Scheduler jobs under the SYSTEM account.
# -----------------------------------------------------------------------------

#1.1:
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()


#1.2:
# Wrap that identity in a WindowsPrincipal object so we can check its role.
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)


#1.3:
# Check whether that principal belongs to the built-in Administrators role.
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)


#1.4:
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator. Right-click PowerShell and choose 'Run as Administrator'." -ForegroundColor Red
    exit 1
}


#1.5:
Write-Host "Admin check passed." -ForegroundColor Green


# -----------------------------------------------------------------------------
# SECTION 2: CONFIGURATION BLOCK
# All tunable values live here so you never have to hunt through the script
# to change a path or name. Edit this section if anything moves.
# -----------------------------------------------------------------------------

# Where the enforcer scripts will be stored on disk.
$installDir = "C:\ProgramData\Microsoft\DevTools"


# The state file that tracks how many games have been played on Thu/Sun.
# Stored separately in ProgramData root so SYSTEM can always read/write it.
$counterFile = "C:\ProgramData\lol_game_counter.dat"


# Obfuscated names for the Task Scheduler tasks.
# GUIDs make them hard to find without knowing exactly what to search for.
$taskNameEnforcer  = "{3F7A2B1C-09DE-4F8A-BC12-7E6D5A490831}"   # Main daemon
$taskNameUnblock   = "{A1C4E290-5B73-4D1F-9022-FD8B3C71A654}"   # 8:30 PM unblock (Tue/Fri)
$taskNameMidnight  = "{D9F0127E-C384-4AB6-8E51-3047BC96F210}"   # Midnight re-block + counter reset


# Obfuscated firewall rule names.
# These block LoL's two main executables at the network level. (Verify this)
$fwRuleClient = "MsDevDiagSvc_NetFilter_4421"    # Targets LeagueClient.exe
$fwRuleGame   = "MsDevDiagSvc_NetFilter_4422"    # Targets League of Legends.exe


# -----------------------------------------------------------------------------
# SECTION 3: LOL PATH AUTO-DETECTION
# We try three methods in order:
#   1. Check the default Riot installation path
#   2. Look up the path in the Windows registry (Riot's uninstall entry)
#   3. Ask the user to provide the path manually
# -----------------------------------------------------------------------------

Write-Host "`nDetecting League of Legends installation..." -ForegroundColor Cyan


# Method 1: Check the default install location.
$defaultPath = "C:\Riot Games\League of Legends"
$lolPath = $null

if (Test-Path "$defaultPath\LeagueClient.exe") {
    # Found it at the default path.
    $lolPath = $defaultPath
    Write-Host "Found at default path: $lolPath" -ForegroundColor Green
}


# Method 2: Check the registry for Riot's uninstall entry.
# When Riot installs, it writes the install location to the registry.
if (-not $lolPath) {
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($regBase in $registryPaths) {
        # Get all subkeys under Uninstall and look for Riot/LoL entries.
        $keys = Get-ChildItem $regBase -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $displayName = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).DisplayName
            if ($displayName -like "*League of Legends*") {
                $installLocation = (Get-ItemProperty $key.PSPath).InstallLocation
                if ($installLocation -and (Test-Path "$installLocation\LeagueClient.exe")) {
                    $lolPath = $installLocation.TrimEnd('\')
                    Write-Host "Found via registry: $lolPath" -ForegroundColor Green
                    break
                }
            }
        }
        if ($lolPath) { break }
    }
}


# Method 3: Ask the user directly if both automated methods failed.
if (-not $lolPath) {
    Write-Host "Could not auto-detect League of Legends. Please enter the install path manually." -ForegroundColor Yellow
    Write-Host "Example: C:\Riot Games\League of Legends"
    $userPath = Read-Host "Path"

    if (Test-Path "$userPath\LeagueClient.exe") {
        $lolPath = $userPath.TrimEnd('\')
        Write-Host "Path confirmed: $lolPath" -ForegroundColor Green
    } else {
        Write-Host "ERROR: LeagueClient.exe not found at that path. Exiting." -ForegroundColor Red
        exit 1
    }
}

# Build the full executable paths from the confirmed install directory.
$exeClient = "$lolPath\LeagueClient.exe"
$exeGame   = "$lolPath\Game\League of Legends.exe"


# -----------------------------------------------------------------------------
# SECTION 4: CREATE INSTALL DIRECTORY
# Creates the hidden script directory if it doesn't already exist.
# The Hidden attribute makes it invisible in normal folder browsing.
# -----------------------------------------------------------------------------

Write-Host "`nCreating install directory..." -ForegroundColor Cyan

if (-not (Test-Path $installDir)) {
    # Create the directory.
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    # Set the Hidden attribute so it doesn't show up in Explorer by default.
    $dirItem = Get-Item $installDir -Force
    $dirItem.Attributes = $dirItem.Attributes -bor [System.IO.FileAttributes]::Hidden

    Write-Host "Created: $installDir" -ForegroundColor Green
} else {
    Write-Host "Directory already exists: $installDir" -ForegroundColor Yellow
}


# -----------------------------------------------------------------------------
# SECTION 5: COPY SCRIPTS TO INSTALL DIRECTORY
# Copies lol-enforcer.ps1 and lol-unblock.ps1 from wherever setup.ps1 is
# being run into the hidden install directory.
# -----------------------------------------------------------------------------

Write-Host "`nCopying scripts to install directory..." -ForegroundColor Cyan

# $PSScriptRoot is the folder this setup.ps1 is being run from.
# The other two scripts must be in the same folder as setup.ps1.
$sourceDir = $PSScriptRoot

$scriptsToCopy = @("lol-enforcer.ps1", "lol-unblock.ps1")

foreach ($script in $scriptsToCopy) {
    $sourcePath = Join-Path $sourceDir $script
    $destPath   = Join-Path $installDir $script

    if (Test-Path $sourcePath) {
        Copy-Item $sourcePath $destPath -Force
        Write-Host "Copied: $script" -ForegroundColor Green
    } else {
        Write-Host "WARNING: $script not found in $sourceDir - skipping. Add it later." -ForegroundColor Yellow
    }
}


# -----------------------------------------------------------------------------
# SECTION 6: WRITE CONFIG FILE
# Saves the detected LoL path and all key settings to a config file in the
# install directory. The enforcer and unblock scripts read this at runtime
# instead of having paths hardcoded inside them.
# -----------------------------------------------------------------------------

Write-Host "`nWriting config file..." -ForegroundColor Cyan

$configPath = Join-Path $installDir "config.dat"

# Build the config as a hashtable, then export it as a PowerShell data file.
# ConvertTo-Json makes it easy to read back with ConvertFrom-Json.
$config = @{
    LolPath      = $lolPath
    ExeClient    = $exeClient
    ExeGame      = $exeGame
    CounterFile  = $counterFile
    FwRuleClient = $fwRuleClient
    FwRuleGame   = $fwRuleGame
    InstallDir   = $installDir
}

$config | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
Write-Host "Config written to: $configPath" -ForegroundColor Green


# -----------------------------------------------------------------------------
# SECTION 7: INITIALIZE GAME COUNTER FILE
# Creates the counter file at C:\ProgramData\ with a starting value of 0.
# The enforcer increments this; lol-unblock.ps1 resets it at midnight.
# Only creates the file if it doesn't already exist (avoids resetting mid-day
# if setup is re-run for some reason).
# -----------------------------------------------------------------------------

Write-Host "`nInitializing game counter..." -ForegroundColor Cyan

if (-not (Test-Path $counterFile)) {
    # Write 0 as the initial game count.
    Set-Content $counterFile "0" -Encoding UTF8
    Write-Host "Counter file created: $counterFile" -ForegroundColor Green
} else {
    Write-Host "Counter file already exists, leaving it untouched." -ForegroundColor Yellow
}


# -----------------------------------------------------------------------------
# SECTION 8: CREATE WINDOWS FIREWALL RULES
# Creates two outbound block rules - one for LeagueClient.exe, one for
# League of Legends.exe. These are the rules the enforcer toggles on/off.
#
# IMPORTANT: The rules are created in DISABLED state. The enforcer enables
# them when a block is needed and disables them when access is allowed.
# This means firewall rules existing ≠ being blocked right now.
# -----------------------------------------------------------------------------

Write-Host "`nCreating firewall rules..." -ForegroundColor Cyan

# Helper function to create a single firewall rule, skipping if it exists.
function New-LolFirewallRule {
    param(
        [string]$RuleName,
        [string]$ExePath,
        [string]$Description
    )

    # Check if a rule with this name already exists.
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Firewall rule already exists: $RuleName" -ForegroundColor Yellow
        return
    }

    # New-NetFirewallRule creates the rule. Key parameters:
    #   -DisplayName   : The name we'll use to find/toggle this rule later
    #   -Direction     : Outbound blocks the game from reaching Riot's servers
    #   -Action        : Block drops the packets
    #   -Program       : Scopes the rule to just this executable
    #   -Enabled False : Starts disabled - enforcer activates it when needed
    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Description "LoL schedule enforcer - do not delete" `
        -Direction Outbound `
        -Action Block `
        -Program $ExePath `
        -Enabled False `
        -Profile Any `
        -ErrorAction Stop | Out-Null

    Write-Host "Created firewall rule: $RuleName -> $ExePath" -ForegroundColor Green
}

New-LolFirewallRule -RuleName $fwRuleClient -ExePath $exeClient -Description "LeagueClient block"
New-LolFirewallRule -RuleName $fwRuleGame   -ExePath $exeGame   -Description "LoL game block"


# -----------------------------------------------------------------------------
# SECTION 9: REGISTER SCHEDULED TASKS
# Creates three Task Scheduler entries, all running as SYSTEM.
# Running as SYSTEM means they survive even if you're logged out and cannot
# be killed from a regular user session.
#
# Tasks created:
#   1. Enforcer daemon  - runs at every login
#   2. Unblock task     - runs at 8:30 PM Tue/Fri
#   3. Midnight task    - runs at 12:00 AM every day
# -----------------------------------------------------------------------------

Write-Host "`nRegistering scheduled tasks..." -ForegroundColor Cyan

# The principal defines WHO the task runs as and at what privilege level.
# RunLevel Highest = elevated/admin privileges. UserId S-1-5-18 = SYSTEM.
$systemPrincipal = New-ScheduledTaskPrincipal `
    -UserId "S-1-5-18" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# --- TASK 1: Main Enforcer Daemon (runs at every user login) ---

$enforcerScript = Join-Path $installDir "lol-enforcer.ps1"

# The action is what the task actually executes.
# We call PowerShell.exe with -NonInteractive -WindowStyle Hidden so it runs
# silently in the background with no visible window.
$enforcerAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$enforcerScript`""

# The trigger fires this task whenever ANY user logs on.
$enforcerTrigger = New-ScheduledTaskTrigger -AtLogOn

# Settings control runtime behavior of the task.
$enforcerSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
# MultipleInstances IgnoreNew: if already running, don't start a second copy
# ExecutionTimeLimit 0: no time limit - daemon runs indefinitely
# RestartCount/Interval: auto-restart up to 3 times if it crashes

$existingEnforcer = Get-ScheduledTask -TaskName $taskNameEnforcer -ErrorAction SilentlyContinue
if ($existingEnforcer) {
    Write-Host "Enforcer task already exists, skipping." -ForegroundColor Yellow
} else {
    Register-ScheduledTask `
        -TaskName  $taskNameEnforcer `
        -Action    $enforcerAction `
        -Trigger   $enforcerTrigger `
        -Principal $systemPrincipal `
        -Settings  $enforcerSettings `
        -Force | Out-Null
    Write-Host "Registered enforcer task: $taskNameEnforcer" -ForegroundColor Green
}


# --- TASK 2: Unblock Task (8:30 PM, Tuesday and Friday) ---

$unblockScript = Join-Path $installDir "lol-unblock.ps1"

$unblockAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$unblockScript`" -Mode Unblock"
# -Mode Unblock tells lol-unblock.ps1 which operation to perform (lift block)

# Daily trigger at 8:30 PM - we'll restrict to Tue/Fri inside the script
# because ScheduledTaskTrigger doesn't support multi-day weekly triggers cleanly.
$unblockTrigger = New-ScheduledTaskTrigger -Daily -At "8:30 PM"

$unblockSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable   # <- fires missed task on next startup

$existingUnblock = Get-ScheduledTask -TaskName $taskNameUnblock -ErrorAction SilentlyContinue
if ($existingUnblock) {
    Write-Host "Unblock task already exists, skipping." -ForegroundColor Yellow
} else {
    Register-ScheduledTask `
        -TaskName  $taskNameUnblock `
        -Action    $unblockAction `
        -Trigger   $unblockTrigger `
        -Principal $systemPrincipal `
        -Settings  $unblockSettings `
        -Force | Out-Null
    Write-Host "Registered unblock task: $taskNameUnblock" -ForegroundColor Green
}


# --- TASK 3: Midnight Task (12:00 AM, every day) ---
# Re-applies the block on Tue/Fri and resets the Thu/Sun game counter.
# Runs every day but lol-unblock.ps1 checks the day before acting.

$midnightAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$unblockScript`" -Mode Midnight"
# -Mode Midnight tells lol-unblock.ps1 to do the midnight operation

$midnightTrigger = New-ScheduledTaskTrigger -Daily -At "12:00 AM"

$midnightSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable   # <- fires missed task on next startup

$existingMidnight = Get-ScheduledTask -TaskName $taskNameMidnight -ErrorAction SilentlyContinue
if ($existingMidnight) {
    Write-Host "Midnight task already exists, skipping." -ForegroundColor Yellow
} else {
    Register-ScheduledTask `
        -TaskName  $taskNameMidnight `
        -Action    $midnightAction `
        -Trigger   $midnightTrigger `
        -Principal $systemPrincipal `
        -Settings  $midnightSettings `
        -Force | Out-Null
    Write-Host "Registered midnight task: $taskNameMidnight" -ForegroundColor Green
}


# -----------------------------------------------------------------------------
# SECTION 10: SETUP COMPLETE - SUMMARY & TESTING CHECKLIST
# Prints a summary of everything that was deployed and what to verify.
# -----------------------------------------------------------------------------
if ($Test) {
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host ' SETUP COMPLETE' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
 
    Write-Host "`nDeployed to:     $installDir"
    Write-Host "Config file:     $configPath"
    Write-Host "Counter file:    $counterFile"
    Write-Host "LoL path:        $lolPath"
    Write-Host ''
    Write-Host 'Firewall rules:'
    Write-Host "  $fwRuleClient  (targets LeagueClient.exe)"
    Write-Host "  $fwRuleGame    (targets League of Legends.exe)"
    Write-Host ''
    Write-Host 'Scheduled tasks:'
    Write-Host "  $taskNameEnforcer  (at login)"
    Write-Host "  $taskNameUnblock   (8:30 PM daily)"
    Write-Host "  $taskNameMidnight  (12:00 AM daily)"
 
    Write-Host "`n--- TESTING CHECKLIST ---" -ForegroundColor Yellow
 
    Write-Host '[ ] 1. Open Windows Defender Firewall > Advanced Settings > Outbound Rules'
    Write-Host "       Confirm two rules exist named '$fwRuleClient' and '$fwRuleGame'"
    Write-Host '       Both should show Status: No (disabled) - this is correct'
    Write-Host ''
    Write-Host '[ ] 2. Open Task Scheduler. Look under Task Scheduler Library.'
    Write-Host '       Confirm three tasks exist with the GUID names listed above.'
    Write-Host "       All three should show 'Run As: SYSTEM'"
    Write-Host ''
    Write-Host "[ `] 3. Navigate to $installDir"
    Write-Host '       Confirm lol-enforcer.ps1, lol-unblock.ps1, and config.dat are present'
    Write-Host "       (You may need to enable 'Show hidden items' in Explorer)"
    Write-Host ''
    Write-Host '[ ] 4. Open config.dat and verify the LoL paths look correct'
    Write-Host ''
    Write-Host '[ ] 5. Check C:\ProgramData\lol_game_counter.dat exists and contains 0'
    Write-Host ''
    Write-Host '[ ] 6. Manually enable one firewall rule and try launching LoL.'
    Write-Host '       The client should fail to connect. Then disable the rule and verify it connects.'
    Write-Host '       (This validates the firewall rules actually work before the enforcer uses them)'
    Write-Host ''
    Write-Host 'Once all boxes are checked, setup.ps1 is fully validated.' -ForegroundColor Green
}
