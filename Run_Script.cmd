powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Check_Server_Status.ps1" -serversFile "%~dp0Servers.csv" -reportFile "%~dp0HTML\server-status.html"
