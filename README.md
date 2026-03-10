# League-Script-Self-Control-
I need to make a script or systematic way to wrangle in my hunger for games. It can be overwhelming to rely on pure willpower.

Block Schedule:

Monday, Wednesday, Saturday — fully blocked all day, no access
Tuesday, Friday — blocked until 8:30 PM, free to play after
Thursday, Sunday — free to play with a 4-game limit; warned on game 4, firewall blocked on attempt 5
No block days reset at midnight — game counter for Thu/Sun resets each day

Implementation:

Language: PowerShell (most robust for Windows firewall + Task Scheduler)
Blocking method: Windows Firewall rules targeting LoL's executable and network traffic
Game detection: LoL log file monitoring to count completed games on Thu/Sun
Trigger: Runs automatically at login via Task Scheduler, no manual intervention needed
Unblock trigger: A second scheduled task fires at 8:30 PM on Tue/Fri to lift the block
Midnight task: Resets the game counter on Thu/Sun at 12:00 AM

Hardening:

Scripts run as SYSTEM, not your user account — can't be killed from your session
Task Scheduler entries use obfuscated GUID-based names so they're not easy to find
Firewall rules use obscure rule names so they're not obvious to locate and delete
Reversing requires admin access + knowing exactly what to look for

Scripts to be written:

lol-enforcer.ps1 — main daemon handling all blocking logic and log monitoring
lol-unblock.ps1 — lifts Tue/Fri time block at 8:30 PM and resets Thu/Sun game counter at midnight
setup.ps1 — one-time setup registering firewall rules and Task Scheduler jobs as SYSTEM
