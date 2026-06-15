param(
    [string]$TaskName = "ProVide Transfer Queue Worker",
    [string]$ScriptPath = "C:\ProgramData\ProVideTransfer\Scripts\process-transfer-queue.ps1",
    [string]$ReconcileScriptPath = "C:\ProgramData\ProVideTransfer\Scripts\reconcile-transfer-state.ps1"
)

$ErrorActionPreference = "Stop"

$powershell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

$workerAction = New-ScheduledTaskAction `
    -Execute $powershell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -RunOnce"

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $workerAction -Trigger $trigger -Settings $settings -Description "Copies, verifies, archives, and monitors ProVide upload jobs." -Force | Out-Null

$reconcileTaskName = "$TaskName Reconciliation"
$reconcileAction = New-ScheduledTaskAction `
    -Execute $powershell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ReconcileScriptPath`""

$reconcileTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName $reconcileTaskName -Action $reconcileAction -Trigger $reconcileTrigger -Settings $settings -Description "Reconciles ProVide inbound folders and STOR logs into transfer queue jobs." -Force | Out-Null

Write-Host "Registered scheduled tasks:"
Write-Host " - $TaskName"
Write-Host " - $reconcileTaskName"
