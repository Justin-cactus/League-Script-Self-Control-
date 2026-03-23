# Gaming Rehab Script

This is a self-imposed League of Legends schedule enforcer for Windows. It automatically blocks access on designated days, enforces a daily game limit on free days, and lifts restrictions on a timer — all running silently in the background as a SYSTEM process with no manual intervention required after setup.

---

## Why This Exists

It's easy to tell yourself you'll stop after one more game. This script removes that decision entirely. You define the rules once, run setup, and the system holds the line for you — even if you forget, even if you try to talk yourself out of it. I only have so much Free will in a day, I am not going to dedicate all of it to fighting the urge to do crack.

---

## How It Works

Three PowerShell scripts form three independent subsystems that work together once deployed:

```
setup.ps1          One-time bootstrapper. Deploys everything.
lol-enforcer.ps1   Main daemon. Runs at every login. Enforces the schedule.
lol-unblock.ps1    Dual-purpose. Lifts the evening block and resets the counter at midnight.
```

Blocking is done at the **Windows Firewall** level, targeting LoL's executables directly. The client still loads visually but cannot reach Riot's servers. All scheduled tasks run as **SYSTEM** so they cannot be killed from your user session.

---

## Schedule

| Day | Behavior |
|---|---|
| Monday, Wednesday, Saturday | Fully blocked all day |
| Tuesday, Friday | Blocked until 8:30 PM, free after |
| Thursday, Sunday | Free to play with a 4-game limit |

- Game counter resets at midnight on Thursday and Sunday
- If your PC is off during a transition point (8:30 PM or midnight), the task fires on next boot instead

---

## Game Limit (Thursday / Sunday)

Games are counted by monitoring LoL's `r3dlog.txt` log file for the `GAMESTATE_ENDGAME` string — the signal the engine writes when a match concludes. A `msg.exe` popup appears after each game so you always know where you stand:

- **Game 1-3** — `Game X of 4 completed`
- **Game 4** — Final game warning
- **Game 5 attempt** — Firewall block applied, LoL loses server connection

---

## File Structure

After setup, files are deployed to a hidden system-looking directory:

```
C:\ProgramData\Microsoft\DevTools\
    lol-enforcer.ps1
    lol-unblock.ps1
    config.dat          LoL paths and firewall rule names
    enforcer.log        Enforcer activity log (rotates at 1MB)
    unblock.log         Unblock/midnight activity log (rotates at 1MB)

C:\ProgramData\
    lol_game_counter.dat    Current day's game count (Thu/Sun)
```

Firewall rules and Task Scheduler entries use obfuscated GUID-based names so they are not easy to locate and delete casually.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later (included with Windows)
- League of Legends installed
- Administrator access (setup only)

---

## Installation

### Step 1 — Download the scripts

Clone or download the repository so all three scripts are in the same folder:

```
setup.ps1
lol-enforcer.ps1
lol-unblock.ps1
```

### Step 2 — Allow script execution

Open PowerShell as Administrator and run:

```powershell
#Just let me run my code button
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser
```

### Step 3 — Run setup

In the same Administrator PowerShell window, navigate to the folder and run:

```powershell
.\setup.ps1
```

Setup will auto-detect your League of Legends installation. If it cannot find it automatically, it will prompt you for the path.

### Step 4 — Validate

Run setup with the `-Test` flag to print a full checklist of what was deployed:

```powershell
.\setup.ps1 -Test
```

Work through the checklist to confirm firewall rules, scheduled tasks, and config files are all in place before relying on the system.

---

## Adapting to Your Own Schedule

All schedule logic lives in `lol-enforcer.ps1` inside the `Get-DayMode` function, and in `lol-unblock.ps1` inside the midnight `switch` block. Both are clearly commented.

**To change which days are blocked**, edit `Get-DayMode`:

```powershell
function Get-DayMode {
    $day = (Get-Date).DayOfWeek.ToString()
    switch ($day) {
        { $_ -in @("Monday", "Wednesday", "Saturday") } { return "FullBlock" }
        { $_ -in @("Tuesday", "Friday") }               { return "TimedBlock" }
        { $_ -in @("Thursday", "Sunday") }              { return "GameLimit" }
        default                                          { return "Unknown" }
    }
}
```

**To change the unblock time** from 8:30 PM, edit this line in `lol-enforcer.ps1`:

```powershell
$unblockTime = $now.Date.AddHours(20).AddMinutes(30)   # 8:30 PM
```

And update the scheduled task trigger in `setup.ps1`:

```powershell
$unblockTrigger = New-ScheduledTaskTrigger -Daily -At "8:30 PM"
```

**To change the game limit** from 4, edit the switch in `Invoke-LogChangeHandler` in `lol-enforcer.ps1` and update the counter threshold from `5` to your preferred limit + 1.

After any changes to `setup.ps1`, re-run it as Administrator to redeploy. Existing firewall rules and tasks are removed and recreated cleanly — no duplicates.

---

## Monitoring

Check the enforcer log to see what the daemon is doing:

```powershell
Get-Content "C:\ProgramData\Microsoft\DevTools\enforcer.log"
```

Check the unblock log to confirm midnight and 8:30 PM tasks are firing:

```powershell
Get-Content "C:\ProgramData\Microsoft\DevTools\unblock.log"
```

Check the current game count:

```powershell
Get-Content "C:\ProgramData\lol_game_counter.dat"
```

Run any script with `-Test` for a live state snapshot:

```powershell
.\lol-enforcer.ps1 -Test
.\lol-unblock.ps1 -Mode Unblock -Test
.\lol-unblock.ps1 -Mode Midnight -Test
```

---

## Manually Toggling the Firewall

If you need to override the block temporarily (e.g. for testing), you can toggle the firewall rules directly. Replace the rule name with the one from your `config.dat`:

```powershell
# Block LoL
Set-NetFirewallRule -DisplayName "MsDevDiagSvc_NetFilter_4421" -Enabled True

# Unblock LoL
Set-NetFirewallRule -DisplayName "MsDevDiagSvc_NetFilter_4421" -Enabled False
```

---

## Uninstalling

To remove everything the system deployed:

```powershell
# Remove firewall rules (use names from your config.dat)
Remove-NetFirewallRule -DisplayName "MsDevDiagSvc_NetFilter_4421"
Remove-NetFirewallRule -DisplayName "MsDevDiagSvc_NetFilter_4422"

# Remove scheduled tasks (use GUIDs from your config block in setup.ps1)
Unregister-ScheduledTask -TaskName "{3F7A2B1C-09DE-4F8A-BC12-7E6D5A490831}" -Confirm:$false
Unregister-ScheduledTask -TaskName "{A1C4E290-5B73-4D1F-9022-FD8B3C71A654}" -Confirm:$false
Unregister-ScheduledTask -TaskName "{D9F0127E-C384-4AB6-8E51-3047BC96F210}" -Confirm:$false

# Remove deployed files
Remove-Item "C:\ProgramData\Microsoft\DevTools" -Recurse -Force
Remove-Item "C:\ProgramData\lol_game_counter.dat" -Force
```

---

## Adapting for Other Games

The system is not LoL-specific beyond two things — the executable paths used in the firewall rules, and the log file path and trigger string used for game detection. To adapt for another game:

1. In `setup.ps1`, point `$exeClient` and `$exeGame` at your game's executables
2. In `lol-enforcer.ps1`, update `Get-GameLogPath` to find your game's log file and update the trigger string in `Invoke-LogChangeHandler` from `GAMESTATE_ENDGAME` to whatever end-of-match signal your game writes

---

## Known Limitations

- The League client loads visually even when blocked — it just cannot connect to Riot's servers. This is by design; the block operates at the network layer.
- `msg.exe` popups require the Messenger service to be running. On some Windows configurations this is disabled. If popups are not appearing, check Services for `Messenger`.
- Game detection requires at least one game to have been played previously so the `GameLogs` directory exists. On a fresh install with no game history, the watcher initializes after the first launch.
- If you find bugs: MAKE AN ISSUE ANDD LEMME KNOW
---

## License

MIT — do whatever you want with it.
