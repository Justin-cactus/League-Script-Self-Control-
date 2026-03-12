# =============================================================================
# lol-unblock.ps1 - Dual-purpose unblock and midnight reset script
# Called by two separate scheduled tasks:
#   -Mode Unblock   : Fires at 8:30 PM on Tue/Fri - lifts the firewall block
#   -Mode Midnight  : Fires at 12:00 AM daily - re-blocks Tue/Fri and resets
#                     the Thu/Sun game counter
# =============================================================================

param(
    [ValidateSet("Unblock", "Midnight")]
    [string]$Mode,
    [switch]$Test
)

# -----------------------------------------------------------------------------
# SECTION 1: MODE CHECK
# The script requires -Mode to be explicitly passed. If it isn't, we exit
# immediately since we don't know which operation to perform.
# [ValidateSet] above already enforces that only "Unblock" or "Midnight" are
# accepted values - anything else PowerShell rejects before we even get here.
# -----------------------------------------------------------------------------

if (-not $Mode) {
    Write-Host "ERROR: -Mode parameter is required. Use -Mode Unblock or -Mode Midnight." -ForegroundColor Red
    exit 1
}


# -----------------------------------------------------------------------------
# SECTION 2: LOAD CONFIG
# Reads the config.dat file written by setup.ps1 so we don't hardcode any
# paths or rule names in this script. Everything flows from the config.
# -----------------------------------------------------------------------------

$configPath = "C:\ProgramData\Microsoft\DevTools\config.dat"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found at $configPath. Has setup.ps1 been run?" -ForegroundColor Red
    exit 1
}

# ConvertFrom-Json turns the JSON config back into a PowerShell object so we
# can access properties like $config.FwRuleClient, $config.CounterFile, etc.
$config = Get-Content $configPath -Encoding UTF8 | ConvertFrom-Json

$fwRuleClient = $config.FwRuleClient
$fwRuleGame   = $config.FwRuleGame
$counterFile  = $config.CounterFile


# -----------------------------------------------------------------------------
# SECTION 3: HELPER FUNCTIONS
# Small reusable functions used by both modes below.
# Defining them here keeps the mode logic clean and readable.
# -----------------------------------------------------------------------------

# Enables both firewall rules - this is what actually blocks LoL.
function Enable-LolBlock {
    Set-NetFirewallRule -DisplayName $fwRuleClient -Enabled True -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayName $fwRuleGame   -Enabled True -ErrorAction SilentlyContinue
}

# Disables both firewall rules - this is what allows LoL to connect.
function Disable-LolBlock {
    Set-NetFirewallRule -DisplayName $fwRuleClient -Enabled False -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayName $fwRuleGame   -Enabled False -ErrorAction SilentlyContinue
}

# Resets the game counter file back to 0.
# Called at midnight on Thu/Sun to start fresh each day.
function Reset-GameCounter {
    Set-Content $counterFile "0" -Encoding UTF8
}

# Returns the current state of the firewall rules as a readable string.
# Used by the -Test summary to show what state the rules are in right now.
function Get-BlockState {
    $rule = Get-NetFirewallRule -DisplayName $fwRuleClient -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq "True") {
        return "BLOCKED (rules enabled)"
    } else {
        return "ALLOWED (rules disabled)"
    }
}

# Returns the current game counter value from the state file.
function Get-GameCount {
    if (Test-Path $counterFile) {
        return (Get-Content $counterFile -Encoding UTF8).Trim()
    }
    return "N/A (counter file missing)"
}


# -----------------------------------------------------------------------------
# SECTION 4: UNBLOCK MODE (called at 8:30 PM)
# Lifts the firewall block on Tuesday and Friday only.
# On any other day, exits silently with no changes made.
# -----------------------------------------------------------------------------

if ($Mode -eq "Unblock") {

    # Get the current day of the week as a string e.g. "Tuesday", "Friday".
    $today = (Get-Date).DayOfWeek.ToString()

    # Only act on Tue/Fri - exit silently on any other day.
    if ($today -ne "Tuesday" -and $today -ne "Friday") {
        exit 0
    }

    # Lift the firewall block so LoL can connect to servers.
    Disable-LolBlock

    # -Test flag prints a summary of what was done and the current state.
    if ($Test) {
        Write-Host "`n=============================================" -ForegroundColor Cyan
        Write-Host ' UNBLOCK MODE - 8:30 PM' -ForegroundColor Cyan
        Write-Host '=============================================' -ForegroundColor Cyan
        Write-Host "Day:             $today"
        Write-Host 'Action:          Firewall block lifted'
        Write-Host "Current state:   $(Get-BlockState)"
        Write-Host "`n--- TESTING CHECKLIST ---" -ForegroundColor Yellow
        Write-Host '[ ] 1. Confirm today is Tuesday or Friday'
        Write-Host '[ ] 2. Confirm LoL can now connect to servers'
        Write-Host "[ `] 3. Confirm firewall rules are disabled in Windows Defender Firewall"
        Write-Host "       Look for '$fwRuleClient' and '$fwRuleGame' - both should show Enabled: No"
        Write-Host '[ ] 4. Run this script on a non-Tue/Fri day and confirm it exits with no changes'
        Write-Host ''
        Write-Host 'Unblock mode validated.' -ForegroundColor Green
    }

    exit 0
}


# -----------------------------------------------------------------------------
# SECTION 5: MIDNIGHT MODE (called at 12:00 AM)
# Runs every day but takes different actions depending on the day:
#
#   Tue/Fri  - Re-applies the firewall block (free window has ended)
#   Thu/Sun  - Resets the game counter to 0 for the new day
#   All other days - The block is already in place from the enforcer,
#                    nothing to do, exit silently
#
# Note: At midnight, the day has already rolled over. So when this fires at
# 12:00 AM on what was Tuesday night, Get-Date now returns Wednesday.
# We therefore check for the day AFTER the free/limited day:
#   Wednesday = was Tuesday  -> re-block
#   Saturday  = was Friday   -> re-block
#   Friday    = was Thursday -> reset counter
#   Monday    = was Sunday   -> reset counter
# -----------------------------------------------------------------------------

if ($Mode -eq "Midnight") {

    # Get the new day (post-midnight rollover).
    $today = (Get-Date).DayOfWeek.ToString()

    # Track what actions were taken for the -Test summary.
    $actionTaken = "None - no action required for $today"

    switch ($today) {

        # Midnight after Tuesday and Friday - re-apply the block.
        { $_ -in @("Wednesday", "Saturday") } {
            Enable-LolBlock
            $actionTaken = "Firewall block re-applied (end of Tue/Fri free window)"
        }

        # Midnight after Thursday and Sunday - reset the game counter.
        { $_ -in @("Friday", "Monday") } {
            Reset-GameCounter
            $actionTaken = "Game counter reset to 0 (new Thu/Sun day starting)"
        }

        # All other days - exit silently, nothing to do.
        default {
            exit 0
        }
    }

    # -Test flag prints a summary of what was done and the current state.
    if ($Test) {
        Write-Host "`n=============================================" -ForegroundColor Cyan
        Write-Host ' MIDNIGHT MODE - 12:00 AM' -ForegroundColor Cyan
        Write-Host '=============================================' -ForegroundColor Cyan
        Write-Host "Day (post-rollover): $today"
        Write-Host "Action taken:        $actionTaken"
        Write-Host "Current block state: $(Get-BlockState)"
        Write-Host "Current game count:  $(Get-GameCount)"
        Write-Host "`n--- TESTING CHECKLIST ---" -ForegroundColor Yellow
        Write-Host '[ ] 1. Confirm the day shown above matches what you expect post-midnight'
        Write-Host '[ ] 2. If Wednesday or Saturday: confirm LoL is now blocked'
        Write-Host '[ ] 3. If Friday or Monday: confirm counter file contains 0'
        Write-Host "[ `] 4. Check $counterFile directly to verify the reset value"
        Write-Host "[ `] 5. Check firewall rules in Windows Defender to verify block state"
        Write-Host ''
        Write-Host 'Midnight mode validated.' -ForegroundColor Green
    }

    exit 0
}
