# A PingMonitorGUI.exe ujraepitese kulso PowerShell-modul nelkul.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'PingMonitorGUI.Launcher.cs'
$output = Join-Path $PSScriptRoot 'PingMonitorGUI.exe'
$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework*\v4.0.30319\csc.exe" -ErrorAction Stop |
    Select-Object -First 1 -ExpandProperty FullName

& $csc /nologo /target:winexe /out:$output /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) { throw 'Az EXE keszitese nem sikerult.' }
Write-Host "Elkeszult: $output" -ForegroundColor Green
