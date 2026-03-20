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

$logFile     = Join-Path $installDir "enforcer.log"
$logMaxBytes = 1MB

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    # Rotate the log if it has exceeded the size limit.
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $logMaxBytes) {
        $backupLog = "$logFile.bak"
        if (Test-Path $backupLog) { Remove-Item $backupLog -Force }
        Rename-Item $logFile $backupLog -Force
    }

    # Format: [2026-03-14 20:30:00] [INFO] Message
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[$timestamp] [$Level] $Message"
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
        $raw   = (Get-Content $counterFile -Encoding UTF8).Trim()
        $count = 0
        if ([int]::TryParse($raw, [ref]$count)) { return $count }
    }
    return 0
}

# Increments the game counter by 1 and writes it back to the state file.
function Increment-GameCount {
    $current = Get-GameCount
    $new     = $current + 1
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
# SECTION 4: GAME LOG PATH DETECTION
# LoL writes a per-game log inside a timestamped subdirectory under GameLogs.
# Structure:
#   D:\Riot Games\League of Legends\Logs\GameLogs\
#     2026-03-13T23-09-59\
#       2026-03-13T23-09-59_r3dlog.txt   <- this is what we monitor
#
# We find the most recently modified subdirectory since that corresponds
# to the last or currently active game session.
# -----------------------------------------------------------------------------

function Get-GameLogPath {
    $gameLogsDir = Join-Path $lolPath "Logs\GameLogs"

    if (-not (Test-Path $gameLogsDir)) {
        Write-Log "GameLogs directory not found: $gameLogsDir" "WARN"
        return $null
    }

    # Get the most recently modified timestamped subdirectory.
    $latestDir = Get-ChildItem $gameLogsDir -Directory -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1

    if (-not $latestDir) {
        Write-Log "No game log subdirectories found in $gameLogsDir" "WARN"
        return $null
    }

    # Find the r3dlog.txt inside that subdirectory.
    $logFile = Get-ChildItem $latestDir.FullName -Filter "*_r3dlog.txt" -ErrorAction SilentlyContinue |
               Select-Object -First 1

    if ($logFile) {
        Write-Log "Game log file detected: $($logFile.FullName)"
        return $logFile.FullName
    }

    Write-Log "No r3dlog.txt found in $($latestDir.FullName)" "WARN"
    return $null
}


# -----------------------------------------------------------------------------
# SECTION 5: FILESYSTEM WATCHER SETUP
# Watches the GameLogs ROOT directory with IncludeSubdirectories = $true.
# This means a single watcher catches writes to r3dlog.txt files inside
# any timestamped subdirectory - including ones created mid-session for
# subsequent games without needing to restart the watcher.
#
# DEBOUNCE: The game engine can write GAMESTATE_ENDGAME multiple times in
# quick succession. We ignore duplicate detections within a 30-second window.
# -----------------------------------------------------------------------------

# Tracks the last time an EndOfGame was processed to debounce duplicates.
$script:lastEndOfGameTime = [datetime]::MinValue
$script:debounceSeconds   = 30

# Tracks the current active log file path and read position.
# Updated whenever a new game session creates a new log file.
$script:currentLogPath   = $null
$script:lastReadPosition = 0

# The active FileSystemWatcher instance.
$script:watcher = $null

function Start-GameLogWatcher {
    $gameLogsDir = Join-Path $lolPath "Logs\GameLogs"

    if (-not (Test-Path $gameLogsDir)) {
        Write-Log "Cannot start watcher - GameLogs directory not found: $gameLogsDir" "WARN"
        return $null
    }

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path   = $gameLogsDir
    $watcher.Filter = "*_r3dlog.txt"

    # IncludeSubdirectories = $true lets a single watcher cover all
    # timestamped subdirectories under GameLogs without resetting
    # the watcher between games.
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter          = [System.IO.NotifyFilters]::LastWrite
    $watcher.EnableRaisingEvents   = $true

    # Seed the current log path and read position from the most recent
    # existing game log so we don't recount old completed games on startup.
    $existingLog = Get-GameLogPath
    if ($existingLog) {
        $script:currentLogPath   = $existingLog
        $script:lastReadPosition = (Get-Item $existingLog).Length
        Write-Log "Seeded read position from existing log: $existingLog"
    }

    Write-Log "FileSystemWatcher started on GameLogs directory: $gameLogsDir"
    $script:watcher = $watcher
    return $watcher
}


# -----------------------------------------------------------------------------
# SECTION 6: LOG CHANGE HANDLER
# Called whenever the FileSystemWatcher detects a write to any r3dlog.txt.
# Reads only newly appended bytes since the last check, then scans for
# GAMESTATE_ENDGAME to detect a completed game.
#
# Also detects when a brand new game log file appears (new game session)
# and resets the read position so we start fresh for that game.
# -----------------------------------------------------------------------------

function Invoke-LogChangeHandler {
    param([int]$CurrentGameCount)

    # Debounce: ignore events within 30 seconds of the last detection.
    $secondsSinceLast = ([datetime]::Now - $script:lastEndOfGameTime).TotalSeconds
    if ($secondsSinceLast -lt $script:debounceSeconds) {
        return $CurrentGameCount
    }

    # Check if a new game session has created a new log file.
    # If so, update the tracked path and reset the read position to 0
    # so we read the new file from the beginning.
    $freshLog = Get-GameLogPath
    if ($freshLog -and $freshLog -ne $script:currentLogPath) {
        Write-Log "New game log detected: $freshLog - resetting read position."
        $script:currentLogPath   = $freshLog
        $script:lastReadPosition = 0
    }

    if (-not $script:currentLogPath) {
        Write-Log "No current log path set - skipping handler." "WARN"
        return $CurrentGameCount
    }

    # Read only the bytes appended since we last checked.
    try {
        $fileStream = [System.IO.File]::Open(
            $script:currentLogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite   # Share mode - game still writes while we read
        )
        $fileStream.Seek($script:lastReadPosition, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader  = New-Object System.IO.StreamReader($fileStream)
        $newText = $reader.ReadToEnd()

        # Advance position so next call only reads content after this point.
        $script:lastReadPosition = $fileStream.Position

        $reader.Close()
        $fileStream.Close()
    } catch {
        Write-Log "WARNING: Could not read game log file: $_" "WARN"
        return $CurrentGameCount
    }

    # Scan new content for the end-of-game state transition string.
    if ($newText -match "GAMESTATE_ENDGAME") {
        Write-Log "GAMESTATE_ENDGAME detected in game log."
        $script:lastEndOfGameTime = [datetime]::Now

        $newCount = Increment-GameCount

        switch ($newCount) {
            1 { Send-UserMessage "League of Legends: Game 1 of 4 completed." }
            2 { Send-UserMessage "League of Legends: Game 2 of 4 completed." }
            3 { Send-UserMessage "League of Legends: Game 3 of 4 completed." }
            4 {
                Write-Log "Game 4 reached - sending final game warning."
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
# For FullBlock and TimedBlock days the loop idles and logs a heartbeat
# every 5 minutes to confirm the daemon is still running.
#
# For GameLimit days the loop actively monitors game logs via the
# FileSystemWatcher and responds to GAMESTATE_ENDGAME events.
# -----------------------------------------------------------------------------

Write-Log "========================================="
Write-Log "lol-enforcer.ps1 started."

function Get-DayMode {
    $day = (Get-Date).DayOfWeek.ToString()
    switch ($day) {
        { $_ -in @("Monday", "Wednesday", "Saturday") } { return "FullBlock" }
        { $_ -in @("Tuesday", "Friday") }               { return "TimedBlock" }
        { $_ -in @("Thursday", "Sunday") }              { return "GameLimit" }
        default                                          { return "Unknown" }
    }
}

$dayMode = Get-DayMode
Write-Log "Day mode: $dayMode ($(Get-Date -Format 'dddd, yyyy-MM-dd'))"

# --- Apply immediate block for FullBlock and TimedBlock days ---
if ($dayMode -eq "FullBlock" -or $dayMode -eq "TimedBlock") {

    if ($dayMode -eq "TimedBlock") {
        $now         = Get-Date
        $unblockTime = $now.Date.AddHours(20).AddMinutes(30)   # 8:30 PM today

        if ($now -ge $unblockTime) {
            # Already past 8:30 PM - don't re-block and undo the unblock task.
            Write-Log "TimedBlock day but past 8:30 PM - skipping block application."
            $dayMode = "PostUnblock"
        } else {
            Enable-LolBlock
            Write-Log "TimedBlock day - block applied. Will lift at 8:30 PM via scheduled task."
        }
    } else {
        Enable-LolBlock
        Write-Log "FullBlock day - block applied for the remainder of the day."
    }
}

# --- GameLimit day setup ---
$currentGameCount = 0

if ($dayMode -eq "GameLimit") {
    Write-Log "GameLimit day - monitoring for GAMESTATE_ENDGAME events."
    $currentGameCount = Get-GameCount
    Write-Log "Current game count at startup: $currentGameCount"

    # If already at limit from an earlier session today, block immediately.
    if ($currentGameCount -ge 5) {
        Write-Log "Game limit already exceeded at startup - applying block immediately."
        Enable-LolBlock
    }
}

# --- Main loop ---
$heartbeatInterval = 300   # Seconds between heartbeat log entries
$lastHeartbeat     = [datetime]::Now
$watcherRetryDelay = 60    # Seconds to wait before retrying watcher init

Write-Log "Entering main loop."

try {
    while ($true) {

        # --- GameLimit: manage the FileSystemWatcher ---
        if ($dayMode -eq "GameLimit") {

            # Initialize the watcher if it hasn't started yet.
            # GameLogs directory only exists after LoL has been launched
            # at least once, so we retry until it appears.
            if ($null -eq $script:watcher) {
                $gameLogsDir = Join-Path $lolPath "Logs\GameLogs"
                if (Test-Path $gameLogsDir) {
                    $script:watcher = Start-GameLogWatcher
                } else {
                    Write-Log "GameLogs directory not found yet - retrying in $watcherRetryDelay seconds." "WARN"
                    Start-Sleep -Seconds $watcherRetryDelay
                    continue
                }
            }

            # Block for up to 5 seconds waiting for a file change event.
            # Returns immediately if a change is detected, otherwise times
            # out and the loop continues to handle heartbeat etc.
            $change = $script:watcher.WaitForChanged(
                [System.IO.WatcherChangeTypes]::Changed, 5000
            )

            if (-not $change.TimedOut) {
                $currentGameCount = Invoke-LogChangeHandler -CurrentGameCount $currentGameCount
            }
        }

        # --- Non-GameLimit days: sleep between heartbeats ---
        if ($dayMode -ne "GameLimit") {
            Start-Sleep -Seconds 30
        }

        # --- Heartbeat (all modes) ---
        $secondsSinceHeartbeat = ([datetime]::Now - $lastHeartbeat).TotalSeconds
        if ($secondsSinceHeartbeat -ge $heartbeatInterval) {
            Write-Log "Heartbeat - mode: $dayMode | block: $(Get-BlockState) | games: $(Get-GameCount)"
            $lastHeartbeat = [datetime]::Now
        }
    }
}
finally {
    # Dispose the watcher cleanly if the daemon exits for any reason.
    # The finally block runs even on termination or unhandled exceptions.
    if ($null -ne $script:watcher) {
        $script:watcher.Dispose()
        Write-Log "FileSystemWatcher disposed."
    }
    Write-Log "lol-enforcer.ps1 exiting."
}


# -----------------------------------------------------------------------------
# SECTION 8: TEST MODE
# Prints a state snapshot when -Test is passed and exits immediately.
# Runs before the daemon loop so it never blocks on the watcher.
# -----------------------------------------------------------------------------

if ($Test) {
    Write-Host "`n=============================================" -ForegroundColor Cyan
    Write-Host ' LOL ENFORCER - STATE SNAPSHOT' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host "Date/Time:       $(Get-Date -Format 'dddd yyyy-MM-dd HH:mm:ss')"
    Write-Host "Day mode:        $(Get-DayMode)"
    Write-Host "Block state:     $(Get-BlockState)"
    Write-Host "Game count:      $(Get-GameCount)"
    Write-Host "Game log:        $(Get-GameLogPath)"
    Write-Host "Log file:        $logFile"
    Write-Host "Install dir:     $installDir"
    Write-Host "LoL path:        $lolPath"
    Write-Host ''
    Write-Host '--- TESTING CHECKLIST ---' -ForegroundColor Yellow
    Write-Host '[ ] 1. Confirm Day mode matches the current day of the week'
    Write-Host '[ ] 2. Confirm Block state matches expectations for this day/time'
    Write-Host '[ ] 3. Confirm Game log path points to a valid r3dlog.txt file'
    Write-Host '[ ] 4. On a GameLimit day (Thu/Sun), play a game'
    Write-Host '       Confirm counter increments and msg.exe popup appears after EndOfGame'
    Write-Host '[ ] 5. On game 4 confirm the final game warning popup appears'
    Write-Host '[ ] 6. On game 5 attempt confirm LoL loses server connection'
    Write-Host "[ `] 7. Check $logFile to confirm GAMESTATE_ENDGAME entries are being written"
    Write-Host '[ ] 8. Confirm heartbeat entries appear in the log every 5 minutes'
    Write-Host ''
    Write-Host 'Enforcer state snapshot complete.' -ForegroundColor Green
    exit 0
}
