$targets = @()

# 1) qualquer powershell que esteja rodando rodar_hexaly.ps1
$targets += Get-CimInstance Win32_Process -Filter "name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'rodar_hexaly' }

# 2) qualquer python rodando vrprdl_hexaly.py
$targets += Get-CimInstance Win32_Process -Filter "name='python.exe'" |
    Where-Object { $_.CommandLine -match 'vrprdl_hexaly' }

# 3) hexaly nativo, se existir
$targets += Get-CimInstance Win32_Process -Filter "name='hexaly.exe'"

$targets = $targets | Sort-Object ProcessId -Unique
foreach ($p in $targets) {
    Write-Host ("Killing PID {0} {1}" -f $p.ProcessId, $p.Name)
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 3
Write-Host ''
Write-Host '--- restantes ---'
Get-CimInstance Win32_Process -Filter "name='python.exe' or name='powershell.exe' or name='hexaly.exe'" |
    Where-Object { $_.CommandLine -match 'rodar_hexaly|vrprdl_hexaly|hexaly\.exe' } |
    Select-Object ProcessId, Name | Format-Table -AutoSize
