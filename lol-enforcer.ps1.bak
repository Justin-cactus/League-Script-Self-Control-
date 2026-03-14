# =============================================================================
# lol-enforcer.ps1 - Main daemon for the LoL Block Enforcer system
# Runs at every login via Task Scheduler under the SYSTEM account.
# Handles all day-of-week block logic and Thu/Sun game count monitoring.
# =============================================================================

param(
    [switch]$Test
)


# -----------------------------------------------------------------------------
# SECTION 1: LOAD CONFIG
# Reads config.dat written by setup.ps1. All paths and rule names come
# from here so nothing is hardcoded in this script.
# -----------------------------------------------------------------------------

$configPath = "C:\ProgramData\Microsoft\DevTools\config.dat"

if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found at $configPath. Has setup.ps1 been run?" -ForegroundColor Red
    exit 1
}

$config = Get-Content $configPath -Encoding UTF8 | ConvertFrom-Json

$fwRuleClient = $config.FwRuleClient
$fwRuleGame   = $config.FwRuleGame
$counterFile  = $config.CounterFile
$installDir   = $config.InstallDir
$lolPath      = $config.LolPath


# -----------------------------------------------------------------------------
# SECTION 2: LOGGING
# All enforcer activity is written to a log file in the install directory.
# Rotates at 1MB to avoid unbounded growth - the old log is renamed to
# enforcer.log.bak and a fresh log starts. Only one backup is kept.
# -----------------------------------------------------------------------------

$logFile = Join-Path $installDir "enforcer.log"
$logMaxBytes = 1MB

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    # Rotate the log if it has exceeded the size limit.
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $logMaxBytes) {
        $backupLog = "$logFile.bak"
        if (Test-Path $backupLog) { Remove-Item $backupLog -Force }
        Rename-Item $logFile $backupLog -Force
    }

    # Format: [2025-01-14 20:30:00] [INFO] Message
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content $logFile $line -Encoding UTF8
}


# -----------------------------------------------------------------------------
# SECTION 3: HELPER FUNCTIONS
# Reusable functions for firewall control, counter management, and
# notifications. Defined once here, called throughout the daemon loop.
# -----------------------------------------------------------------------------

# Enables both firewall rules to block LoL from connecting.
function Enable-LolBlock {
    Set-NetFirewallRule -DisplayName $fwRuleClient -Enabled True -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayName $fwRuleGame   -Enabled True -ErrorAction SilentlyContinue
    Write-Log "Firewall block ENABLED."
}

# Disables both firewall rules to allow LoL to connect.
function Disable-LolBlock {
    Set-NetFirewallRule -DisplayName $fwRuleClient -Enabled False -ErrorAction SilentlyContinue
    Set-NetFirewallRule -DisplayName $fwRuleGame   -Enabled False -ErrorAction SilentlyContinue
    Write-Log "Firewall block DISABLED."
}

# Reads the current game count from the state file.
# Returns 0 if the file is missing or unreadable.
function Get-GameCount {
    if (Test-Path $counterFile) {
        $raw = (Get-Content $counterFile -Encoding UTF8).Trim()
        $count = 0
        if ([int]::TryParse($raw, [ref]$count)) { return $count }
    }
    return 0
}

# Increments the game counter by 1 and writes it back to the state file.
function Increment-GameCount {
    $current = Get-GameCount
    $new = $current + 1
    Set-Content $counterFile $new -Encoding UTF8
    Write-Log "Game counter incremented to $new."
    return $new
}

# Sends a visible popup message to the logged-in user via msg.exe.
# msg.exe works reliably from SYSTEM context unlike toast notifications.
# '*' targets all logged-in sessions on the machine.
function Send-UserMessage {
    param([string]$Message)
    try {
        & msg.exe * $Message 2>$null
        Write-Log "msg.exe notification sent: $Message"
    } catch {
        Write-Log "WARNING: Failed to send msg.exe notification." "WARN"
    }
}

# Returns the current enabled state of the firewall rules as a string.
function Get-BlockState {
    $rule = Get-NetFirewallRule -DisplayName $fwRuleClient -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq "True") { return "BLOCKED" }
    return "ALLOWED"
}


# -----------------------------------------------------------------------------
# SECTION 4: LCU LOG PATH DETECTION
# The LCU (League Client Update) writes a rolling log that contains
# GameFlowPhase state transitions. We monitor this file for "EndOfGame"
# to detect when a game has completed.
#
# The LCU log path is:
#   C:\Riot Games\League of Legends\Logs\LeagueClient Logs\
#   LeagueClient_<timestamp>.log  (most recent file is the active one)
#
# We find the most recently modified .log file in that directory since
# the LCU creates a new log file each time the client launches.
# -----------------------------------------------------------------------------

function Get-LcuLogPath {
    $logDir = Join-Path $lolPath "Logs\LeagueClient Logs"

    if (-not (Test-Path $logDir)) {
        Write-Log "LCU log directory not found: $logDir" "WARN"
        return $null
    }

    # Get the most recently written log file in the directory.
    $latest = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if ($latest) {
        Write-Log "LCU log file detected: $($latest.FullName)"
        return $latest.FullName
    }

    Write-Log "No LCU log files found in $logDir" "WARN"
    return $null
}


# -----------------------------------------------------------------------------
# SECTION 5: DAY-OF-WEEK BLOCK LOGIC
# Determines what the enforcer should do based on the current day.
# Called once at startup and returns a mode string that drives the
# daemon's behavior for the rest of the session.
#
# Modes returned:
#   "FullBlock"    - Mon/Wed/Sat: apply firewall block immediately, stay blocked
#   "TimedBlock"   - Tue/Fri: apply block now, lol-unblock.ps1 lifts it at 8:30 PM
#   "GameLimit"    - Thu/Sun: no immediate block, monitor games and enforce limit
#   "Unknown"      - Fallback, should never happen given 7-day coverage
# -----------------------------------------------------------------------------

function Get-DayMode {
    $day = (Get-Date).DayOfWeek.ToString()

    switch ($day) {
        { $_ -in @("Monday", "Wednesday", "Saturday") } { return "FullBlock" }
        { $_ -in @("Tuesday", "Friday") }               { return "TimedBlock" }
        { $_ -in @("Thursday", "Sunday") }              { return "GameLimit" }
        default                                          { return "Unknown" }
    }
}


# -----------------------------------------------------------------------------
# SECTION 6: FILESYSTEM WATCHER SETUP
# Sets up a FileSystemWatcher on the LCU log file directory.
# Rather than polling every N seconds, the watcher fires an event the
# moment the log file is written to - much more efficient for a daemon.
#
# DEBOUNCE: The LCU often writes multiple change events in rapid succession
# for a single log entry. We track the last time we processed an EndOfGame
# event and ignore duplicates within a 30-second window.
# -----------------------------------------------------------------------------

# Tracks the last time an EndOfGame was processed to debounce duplicates.
$script:lastEndOfGameTime = [datetime]::MinValue
$script:debounceSeconds   = 30

# Tracks the last file position we read up to, so we only scan new content
# appended since the last check rather than re-reading the entire log.
$script:lastReadPosition = 0

# The active FileSystemWatcher instance (stored at script scope so it can
# be disposed cleanly if the daemon exits).
$script:watcher = $null

function Start-LcuWatcher {
    param([string]$LogFilePath)

    $logDir      = Split-Path $LogFilePath -Parent
    $logFileName = Split-Path $LogFilePath -Leaf

    # Create a new FileSystemWatcher targeting the log directory.
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path   = $logDir
    $watcher.Filter = $logFileName

    # NotifyFilters.LastWrite fires when the file content changes.
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite

    # EnableRaisingEvents must be set to $true to start watching.
    $watcher.EnableRaisingEvents = $true

    # Initialize the read position to the current end of the file so we
    # only process new lines written after the watcher starts.
    $script:lastReadPosition = (Get-Item $LogFilePath).Length

    Write-Log "FileSystemWatcher started on: $LogFilePath"
    $script:watcher = $watcher
    return $watcher
}

# Called each time the FileSystemWatcher detects a file change.
# Reads only the newly appended content and scans for EndOfGame.
function Invoke-LogChangeHandler {
    param(
        [string]$LogFilePath,
        [int]$CurrentGameCount
    )

    # Debounce: ignore events within 30 seconds of the last EndOfGame.
    $secondsSinceLast = ([datetime]::Now - $script:lastEndOfGameTime).TotalSeconds
    if ($secondsSinceLast -lt $script:debounceSeconds) {
        return $CurrentGameCount
    }

    # Read only the bytes appended since we last checked.
    try {
        $fileStream = [System.IO.File]::Open(
            $LogFilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite   # Share mode - LCU still writes while we read
        )
        $fileStream.Seek($script:lastReadPosition, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader  = New-Object System.IO.StreamReader($fileStream)
        $newText = $reader.ReadToEnd()

        # Update position so next call only reads content after this point.
        $script:lastReadPosition = $fileStream.Position

        $reader.Close()
        $fileStream.Close()
    } catch {
        Write-Log "WARNING: Could not read LCU log file: $_" "WARN"
        return $CurrentGameCount
    }

    # Check the new content for the EndOfGame GameFlowPhase transition.
    # The LCU logs this as: GameFlowPhase changed to EndOfGame
    if ($newText -match "GameFlowPhase.*EndOfGame") {
        Write-Log "EndOfGame detected in LCU log."
        $script:lastEndOfGameTime = [datetime]::Now

        # Increment the counter and act based on the new count.
        $newCount = Increment-GameCount

		switch ($newCount) {
			1 { Send-UserMessage "League of Legends: Game 1 of 4 completed." }
			2 { Send-UserMessage "League of Legends: Game 2 of 4 completed." }
			3 { Send-UserMessage "League of Legends: Game 3 of 4 completed." }
			4 { Write-Log "Game 4 reached - sending warning notification."
				Send-UserMessage "League of Legends: Game 4 of 4 completed. This was your last game - access will be blocked after this session."
				}
			{ $_ -ge 5 } {
				Write-Log "Game limit exceeded ($newCount games). Applying firewall block." "WARN"
				Enable-LolBlock
				Send-UserMessage "League of Legends: Daily game limit reached. Access has been blocked until tomorrow."
			}
		}

        return $newCount
    }

    return $CurrentGameCount
}


# -----------------------------------------------------------------------------
# SECTION 7: MAIN DAEMON LOOP
# Entry point of the enforcer. Determines the day mode, applies any
# immediate blocks, then enters a watch loop for GameLimit days.
#
# For FullBlock and TimedBlock days the loop still runs but is essentially
# idle - it just keeps the script alive as a SYSTEM process and logs
# periodically to confirm it's still running.
#
# For GameLimit days the loop actively monitors the LCU log via the
# FileSystemWatcher and responds to EndOfGame events.
# -----------------------------------------------------------------------------

Write-Log "========================================="
Write-Log "lol-enforcer.ps1 started."

$dayMode = Get-DayMode
Write-Log "Day mode: $dayMode ($(Get-Date -Format 'dddd, yyyy-MM-dd'))"

# --- Apply immediate block for full and timed block days ---
if ($dayMode -eq "FullBlock" -or $dayMode -eq "TimedBlock") {

    # Check if we're on a TimedBlock day but it's already past 8:30 PM.
    # If so, the unblock task has already fired (or will fire shortly) so
    # we should not re-apply the block and undo the unblock.
    if ($dayMode -eq "TimedBlock") {
        $now = Get-Date
        $unblockTime = $now.Date.AddHours(20).AddMinutes(30)   # 8:30 PM today

        if ($now -ge $unblockTime) {
            Write-Log "TimedBlock day but past 8:30 PM - skipping block application."
            $dayMode = "PostUnblock"   # Treat remainder of session as unblocked
        } else {
            Enable-LolBlock
            Write-Log "TimedBlock day - block applied. Will lift at 8:30 PM via scheduled task."
        }
    } else {
        # FullBlock day - apply block unconditionally.
        Enable-LolBlock
        Write-Log "FullBlock day - block applied for the remainder of the day."
    }
}

# --- GameLimit day setup ---
$currentGameCount = 0
$lcuLogPath       = $null
$watcher          = $null

if ($dayMode -eq "GameLimit") {
    Write-Log "GameLimit day - monitoring for EndOfGame events."
    $currentGameCount = Get-GameCount
    Write-Log "Current game count at startup: $currentGameCount"

    # If the counter is already at 5+ from a previous session today,
    # apply the block immediately without waiting for another game.
    if ($currentGameCount -ge 5) {
        Write-Log "Game limit already exceeded at startup - applying block immediately."
        Enable-LolBlock
    }
}

# --- Main loop ---
# The loop runs indefinitely. On GameLimit days it actively watches the
# LCU log. On other days it idles and logs a heartbeat every 5 minutes
# to confirm the daemon is still alive.

$heartbeatInterval  = 300   # Seconds between heartbeat log entries
$lastHeartbeat      = [datetime]::Now
$watcherRetryDelay  = 60    # Seconds to wait before retrying LCU log detection

Write-Log "Entering main loop."

try {
    while ($true) {

        # --- GameLimit: manage the FileSystemWatcher ---
        if ($dayMode -eq "GameLimit") {

            # If we don't have a watcher yet, try to find the LCU log.
            # The log file only exists after the client has been launched
            # at least once, so we retry until it appears.
            if ($null -eq $watcher) {
                $lcuLogPath = Get-LcuLogPath
                if ($lcuLogPath) {
                    $watcher = Start-LcuWatcher -LogFilePath $lcuLogPath
                } else {
                    Write-Log "LCU log not found yet - will retry in $watcherRetryDelay seconds." "WARN"
                    Start-Sleep -Seconds $watcherRetryDelay
                    continue
                }
            }

            # Check if the LCU log file has changed since last loop.
            # WaitForChanged blocks for up to 5 seconds waiting for an event,
            # then returns regardless so the loop can do other work.
            $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 5000)

            if (-not $change.TimedOut) {
                # A change was detected - process new log content.
                $currentGameCount = Invoke-LogChangeHandler `
                    -LogFilePath      $lcuLogPath `
                    -CurrentGameCount $currentGameCount
            }

            # Check if the LCU log file has been replaced (new client launch
            # creates a new log file). If so, reset the watcher to the new file.
            $freshLog = Get-LcuLogPath
            if ($freshLog -and $freshLog -ne $lcuLogPath) {
                Write-Log "New LCU log file detected - resetting watcher."
                $watcher.Dispose()
                $watcher     = $null
                $lcuLogPath  = $null
                $script:lastReadPosition = 0
                continue
            }
        }

        # --- Non-GameLimit days: just sleep ---
        if ($dayMode -ne "GameLimit") {
            Start-Sleep -Seconds 30
        }

        # --- Heartbeat logging (all modes) ---
        $secondsSinceHeartbeat = ([datetime]::Now - $lastHeartbeat).TotalSeconds
        if ($secondsSinceHeartbeat -ge $heartbeatInterval) {
            Write-Log "Heartbeat - mode: $dayMode | block: $(Get-BlockState) | games: $(Get-GameCount)"
            $lastHeartbeat = [datetime]::Now
        }
    }
}
finally {
    # Cleanup: dispose the FileSystemWatcher if the daemon exits for any reason.
    # The 'finally' block runs even if the script is terminated or throws.
    if ($null -ne $watcher) {
        $watcher.Dispose()
        Write-Log "FileSystemWatcher disposed."
    }
    Write-Log "lol-enforcer.ps1 exiting."
}


# -----------------------------------------------------------------------------
# SECTION 8: TEST MODE SUMMARY
# Prints a snapshot of the current enforcer state when -Test is passed.
# Useful for manually validating the script reads config and state correctly
# without waiting for a real game to complete.
# Note: -Test runs before the daemon loop so this outputs at startup and exits.
# -----------------------------------------------------------------------------

if ($Test) {
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host ' LOL ENFORCER - STATE SNAPSHOT' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "Date/Time:       $(Get-Date -Format 'dddd yyyy-MM-dd HH:mm:ss')"
    Write-Host "Day mode:        $(Get-DayMode)"
    Write-Host "Block state:     $(Get-BlockState)"
    Write-Host "Game count:      $(Get-GameCount)"
    Write-Host "LCU log:         $(Get-LcuLogPath)"
    Write-Host "Log file:        $logFile"
    Write-Host "Install dir:     $installDir"
    Write-Host "LoL path:        $lolPath"
    Write-Host ''
    Write-Host '--- TESTING CHECKLIST ---' -ForegroundColor Yellow
    Write-Host '[ ] 1. Confirm Day mode matches the current day of the week'
    Write-Host '[ ] 2. Confirm Block state matches expectations for this day/time'
    Write-Host '[ ] 3. On a GameLimit day (Thu/Sun), launch LoL and play a game'
    Write-Host '       Confirm the game counter increments after the EndOfGame screen'
    Write-Host '[ ] 4. On game 4, confirm the msg.exe warning popup appears'
    Write-Host '[ ] 5. On game 5 attempt, confirm LoL loses server connection'
    Write-Host "[ `] 6. Check $logFile to confirm events are being written"
    Write-Host '[ ] 7. Confirm heartbeat entries appear in the log every 5 minutes'
    Write-Host ''
    Write-Host 'Enforcer state snapshot complete.' -ForegroundColor Green
    exit 0
}