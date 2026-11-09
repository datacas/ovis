<#
  A Windows scheduled task, for your user only, that starts your WSL distribution at logon and keeps
  it running, so that systemd starts the ovis-wsl user service (ovis-wsl.sh service install).

    ovis-wsl-task.ps1 -Install -Script <Linux path of ovis-wsl.sh> [-Distro Ubuntu]
    ovis-wsl-task.ps1 -Status
    ovis-wsl-task.ps1 -Uninstall

  The task runs `wsl.exe -d <distro> --exec <script> keepalive` in a hidden window (one named `sleep`
  under a lock): with no process left, WSL stops the distribution and the service with it. It needs no administrator rights, changes
  no firewall rule and starts no Windows service. It does not start the Herdr app or its core; it
  does not stop anything either. Removing it leaves WSL, Ovis's service and Herdr as they are.
#>
param(
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Status,
  [string]$Distro = 'Ubuntu',
  [string]$Script = ''
)
$ErrorActionPreference = 'Stop'
$name = 'Ovis WSL keepalive'

if ($Install) {
  if ($Script -eq '') { throw '-Script <Linux path of ovis-wsl.sh> is required' }
  $arg = "-NoProfile -WindowStyle Hidden -Command `"& wsl.exe -d '$Distro' --exec $Script keepalive`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Keeps the WSL distribution running so that its Ovis systemd user service starts at logon.' | Out-Null
  Write-Output "Task '$name' created for $env:USERNAME (at logon). Start it now with: Start-ScheduledTask '$name'"
}
elseif ($Uninstall) {
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    # Stop-ScheduledTask ends the window, not the sleep inside WSL: end it by its name
    wsl.exe -d $Distro --exec /usr/bin/pkill -f '^ovis-wsl-keepalive' 2>$null
    Write-Output "Task '$name' removed."
  } else { Write-Output "Task '$name' is not installed." }
}
elseif ($Status) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($task) { "$name : $($task.State)"; (Get-ScheduledTaskInfo -TaskName $name) | Select-Object LastRunTime, LastTaskResult | Format-List }
  else { "$name : not installed" }
}
else { Write-Output 'Use -Install, -Status or -Uninstall.' }
