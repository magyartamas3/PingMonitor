# PingMonitor V3 - Windows PowerShell 5.1 / PowerShell 7
# A figyelt eszkozoket inditaskor, CSV fajlbol valasztja ki.

Add-Type -AssemblyName System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfigFile = Join-Path $PSScriptRoot 'config.ps1'
$ConfigExampleFile = Join-Path $PSScriptRoot 'config-example.ps1'
if (-not (Test-Path -LiteralPath $ConfigFile)) {
    if (Test-Path -LiteralPath $ConfigExampleFile) {
        Copy-Item -LiteralPath $ConfigExampleFile -Destination $ConfigFile
        Write-Host "Letrejott: $ConfigFile. Toltsd ki, majd inditsd ujra a programot." -ForegroundColor Yellow
    }
    else { Write-Host "Hianyzik a config.ps1 es a config-example.ps1 fajl is." -ForegroundColor Red }
    exit 1
}
. $ConfigFile
if ($null -eq $TelegramTargets -or $TelegramTargets.Count -eq 0) {
    Write-Host "A config.ps1 fajlban nincs Telegram cel beallitva." -ForegroundColor Red
    exit 1
}

$PingTimeoutMilliseconds = 1500
# $null: nincs magas kesleltetesi riasztas. Pelda: 100 = 100 ms felett riaszt.
$HighLatencyThresholdMs = $null

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Valaszd ki a figyelt eszkozok CSV-fajljat'
$dialog.Filter = 'CSV fajlok (*.csv)|*.csv|Minden fajl (*.*)|*.*'
if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit }

try {
    $Devices = @(Import-Csv -LiteralPath $dialog.FileName | ForEach-Object {
        $name = ([string]$_.Name).Trim(); $ip = ([string]$_.IP).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($ip)) { throw 'Minden CSV-sorhoz kell Name es IP oszlop.' }
        [pscustomobject]@{ Name = $name; IP = $ip }
    })
}
catch { Write-Host "A CSV beolvasasa sikertelen: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
if ($Devices.Count -eq 0) { Write-Host 'A kivalasztott CSV ures.' -ForegroundColor Yellow; exit 1 }
if (@($Devices | Group-Object IP | Where-Object Count -gt 1).Count -gt 0) { Write-Host 'Egy IP csak egyszer szerepelhet a CSV-ben.' -ForegroundColor Red; exit 1 }

$MonitorName = $env:COMPUTERNAME
$LogFile = Join-Path $PSScriptRoot 'halozat_hiba.log'
$StartTime = Get-Date
$LastEvent = 'Nincs esemeny.'

function Send-Telegram {
    param([Parameter(Mandatory)][string]$Message)
    $sentCount = 0
    foreach ($target in $TelegramTargets) {
        if ($target.Token -like 'IDE_IRD_*' -or $target.ChatID -like 'IDE_IRD_*') { continue }
        try {
            $uri = "https://api.telegram.org/bot$($target.Token)/sendMessage"
            $response = Invoke-RestMethod -Uri $uri -Method Post -Body @{ chat_id = $target.ChatID; text = $Message } -ErrorAction Stop
            if (-not $response.ok) { throw 'A Telegram API elutasitotta a kuldest.' }
            [void]$sentCount++
        }
        catch {
            $errorText = '[{0}] Telegram hiba: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
            Write-Host $errorText -ForegroundColor Yellow
            Add-Content -LiteralPath $LogFile -Value $errorText
        }
    }
    return ($sentCount -gt 0)
}

function Get-DeviceListText {
    param([object[]]$Items)
    (($Items | ForEach-Object { '- {0} ({1})' -f $_.Name, $_.IP }) -join "`n")
}

function Send-GroupedNotification {
    param([object[]]$Items, [ValidateSet('Down','Up')][string]$Kind, [datetime]$Time)
    $list = Get-DeviceListText $Items
    if ($Kind -eq 'Down') {
        $title = if ($Items.Count -gt 1) { 'HALOZATI KIMARADAS' } else { 'HALOZATI HIBA' }
        Send-Telegram "[RIASZTAS] $title`n`nMonitor:`n$MonitorName`n`nIdo:`n$($Time.ToString('yyyy-MM-dd HH:mm:ss'))`n`nKiesett eszkozok:`n$list`n`nOsszesen: $($Items.Count)" | Out-Null
    }
    else {
        $maxSeconds = ($Items | Measure-Object -Property DownSeconds -Maximum).Maximum
        Send-Telegram "[HELYREALLT] HALOZAT HELYREALLT`n`nMonitor:`n$MonitorName`n`nIdo:`n$($Time.ToString('yyyy-MM-dd HH:mm:ss'))`n`nErintett eszkozok:`n$list`n`nOsszesen: $($Items.Count)`nLegnagyobb kieses: $('{0:N1}' -f $maxSeconds) mp" | Out-Null
    }
}

$State = @{}
foreach ($device in $Devices) { $State[$device.IP] = @{ Online = $null; DownSince = $null; LatencyMs = $null; HighLatencyAlerted = $false } }

$startMessage = "[INDITAS] PingMonitor elindult`n`nMonitor:`n$MonitorName`n`nIdo:`n$($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))`n`nFigyelt eszkozok:`n$(Get-DeviceListText $Devices)"
$telegramStarted = Send-Telegram $startMessage
$TelegramStatus = if ($telegramStarted) { 'Telegram inditasi uzenet: ELKULDVE' } else { 'Telegram inditasi uzenet: SIKERTELEN - reszletek: halozat_hiba.log' }

while ($true) {
    # Minden IP sajat natív ping.exe folyamatban indul, ezert a pingek parhuzamosak.
    $pingProcesses = @()
    foreach ($device in $Devices) {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $process.StartInfo.FileName = "$env:SystemRoot\System32\ping.exe"
        $process.StartInfo.Arguments = "-n 1 -w $PingTimeoutMilliseconds $($device.IP)"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.CreateNoWindow = $true
        [void]$process.Start()
        $pingProcesses += [pscustomobject]@{ Device = $device; Process = $process }
    }

    $results = @{}
    foreach ($ping in $pingProcesses) {
        $ping.Process.WaitForExit($PingTimeoutMilliseconds + 500) | Out-Null
        if (-not $ping.Process.HasExited) { $ping.Process.Kill(); $ping.Process.WaitForExit() }
        $output = $ping.Process.StandardOutput.ReadToEnd()
        $null = $ping.Process.StandardError.ReadToEnd()
        $match = [regex]::Match($output, '(?i)(?:time|ido|id\u0151)\s*[=<]\s*(\d+)\s*ms')
        $latency = if ($match.Success) { [int]$match.Groups[1].Value } else { $null }
        $results[$ping.Device.IP] = [pscustomobject]@{ Online = ($ping.Process.ExitCode -eq 0); LatencyMs = $latency }
        $ping.Process.Dispose()
    }

    $now = Get-Date
    $wentDown = [System.Collections.Generic.List[object]]::new()
    $cameUp = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $Devices) {
        $ok = $results[$device.IP].Online; $previous = $State[$device.IP].Online
        $State[$device.IP].LatencyMs = $results[$device.IP].LatencyMs
        if ($null -eq $previous) {
            $State[$device.IP].Online = $ok
            if (-not $ok) { $State[$device.IP].DownSince = $now }
            continue
        }
        if ($previous -and -not $ok) {
            $State[$device.IP].Online = $false; $State[$device.IP].DownSince = $now; $wentDown.Add($device)
            $LastEvent = '[{0}] {1} ({2}) KIESETT' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $device.Name, $device.IP
            Add-Content -LiteralPath $LogFile -Value $LastEvent
        }
        elseif (-not $previous -and $ok) {
            $downSeconds = ($now - $State[$device.IP].DownSince).TotalSeconds
            $State[$device.IP].Online = $true; $State[$device.IP].DownSince = $null
            $cameUp.Add([pscustomobject]@{ Name = $device.Name; IP = $device.IP; DownSeconds = $downSeconds })
            $LastEvent = '[{0}] {1} ({2}) HELYREALLT - Kieses: {3:N1} mp' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $device.Name, $device.IP, $downSeconds
            Add-Content -LiteralPath $LogFile -Value $LastEvent
        }
        if ($ok -and $null -ne $HighLatencyThresholdMs -and $State[$device.IP].LatencyMs -gt $HighLatencyThresholdMs -and -not $State[$device.IP].HighLatencyAlerted) {
            Send-Telegram "[LASSU VALASZ]`n`nMonitor:`n$MonitorName`n`nEszkoz:`n$($device.Name) ($($device.IP))`n`nValaszido: $($State[$device.IP].LatencyMs) ms`nKuszob: $HighLatencyThresholdMs ms" | Out-Null
            $State[$device.IP].HighLatencyAlerted = $true
        }
        elseif (-not $ok -or $null -eq $HighLatencyThresholdMs -or $State[$device.IP].LatencyMs -le $HighLatencyThresholdMs) { $State[$device.IP].HighLatencyAlerted = $false }
    }
    if ($wentDown.Count -gt 0) { Send-GroupedNotification $wentDown.ToArray() Down $now }
    if ($cameUp.Count -gt 0) { Send-GroupedNotification $cameUp.ToArray() Up $now }

    Clear-Host
    $onlineCount = @($State.Values | Where-Object Online -eq $true).Count
    $offlineCount = @($State.Values | Where-Object Online -eq $false).Count
    Write-Host "================ PingMonitor V3 - $MonitorName ================" -ForegroundColor Cyan
    Write-Host "Indult: $StartTime    Uptime: $($now - $StartTime)"
    if ($telegramStarted) { Write-Host $TelegramStatus -ForegroundColor Green } else { Write-Host $TelegramStatus -ForegroundColor Yellow }
    Write-Host "Online: $onlineCount" -ForegroundColor Green; Write-Host "Offline: $offlineCount" -ForegroundColor Red
    Write-Host '---------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($device in $Devices) {
        $status = $State[$device.IP].Online
        $latencyText = if ($null -ne $State[$device.IP].LatencyMs) { " - $($State[$device.IP].LatencyMs) ms" } else { '' }
        if ($status -eq $true) { Write-Host ('[ONLINE ] {0,-25} {1}{2}' -f $device.Name, $device.IP, $latencyText) -ForegroundColor Green }
        else { Write-Host ('[OFFLINE] {0,-25} {1}' -f $device.Name, $device.IP) -ForegroundColor Red }
    }
    Write-Host '---------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "Utolso esemeny: $LastEvent" -ForegroundColor Yellow
    Write-Host 'Ctrl+C = Kilepes'
    Start-Sleep -Milliseconds 250
}
