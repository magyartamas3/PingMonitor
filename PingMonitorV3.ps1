# PingMonitor V4 - Windows PowerShell 5.1 / PowerShell 7

Add-Type -AssemblyName System.Windows.Forms
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfigFile = Join-Path $PSScriptRoot 'config.ps1'
$ConfigExampleFile = Join-Path $PSScriptRoot 'config-example.ps1'
$SettingsFile = Join-Path $PSScriptRoot 'pingmonitor-settings.json'
$LogDirectory = Join-Path $PSScriptRoot 'logs'
$PingTimeoutMilliseconds = 1000
$SummaryHour = 21
$LogRetentionDays = 30

if (-not (Test-Path -LiteralPath $ConfigFile)) { Copy-Item -LiteralPath $ConfigExampleFile -Destination $ConfigFile -ErrorAction Stop }
. $ConfigFile

function Save-TelegramTargets {
    param([object[]]$Targets)
    $configLines = @('$TelegramTargets = @(')
    foreach ($target in $Targets) {
        $safeToken = ([string]$target.Token).Replace("'", "''")
        $safeChatID = ([string]$target.ChatID).Replace("'", "''")
        $configLines += "    @{ Token = '$safeToken'; ChatID = '$safeChatID' }"
    }
    $configLines += ')'
    Set-Content -LiteralPath $ConfigFile -Value $configLines -Encoding UTF8
}

function Add-TelegramTarget {
    $newTargets = @()
    do {
        $token = Read-Host 'Telegram bot API token'
        $chatID = Read-Host 'Telegram Chat ID'
        if ($token -and $chatID) { $newTargets += @{ Token = $token; ChatID = $chatID } }
        $more = Read-Host 'Szeretnel tovabbi Telegram celt felvenni? (i/n)'
    } while ($more -eq 'i')
    if ($newTargets.Count -gt 0) {
        $script:TelegramTargets = @($script:TelegramTargets) + $newTargets
        Save-TelegramTargets $script:TelegramTargets
        $script:TelegramEnabled = $true
        Write-Host 'Telegram beallitasok elmentve.' -ForegroundColor Green
    }
}

$validTelegramTargets = @($TelegramTargets | Where-Object { $_.Token -and $_.ChatID -and $_.Token -notlike 'IDE_IRD_*' -and $_.ChatID -notlike 'IDE_IRD_*' })
$script:TelegramEnabled = $validTelegramTargets.Count -gt 0
if (-not $script:TelegramEnabled) {
    $answer = Read-Host 'Szeretnel Telegram ertesiteseket beallitani? (i/n)'
    if ($answer -eq 'i') {
        Add-TelegramTarget
    }
    if (-not $script:TelegramEnabled) { Write-Host 'Telegram ertesitesek kikapcsolva: csak helyi naplo keszul.' -ForegroundColor Yellow }
}

if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory | Out-Null }
Get-ChildItem -LiteralPath $LogDirectory -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) | Remove-Item -Force

function Add-Log {
    param([string]$Text)
    $logFile = Join-Path $LogDirectory ((Get-Date).ToString('yyyy-MM-dd') + '.log')
    Add-Content -LiteralPath $logFile -Value $Text
}

function Send-Telegram {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $script:TelegramEnabled) { return $false }
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
            $text = '[{0}] Telegram hiba: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
            Write-Host $text -ForegroundColor Yellow
            Add-Log $text
        }
    }
    return ($sentCount -gt 0)
}

function Load-Settings {
    if (Test-Path -LiteralPath $SettingsFile) {
        try { return (Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ LastCsvPath = $null }
}

function Save-Settings {
    param([string]$CsvPath)
    [pscustomobject]@{ LastCsvPath = $CsvPath } | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
}

function Select-DeviceCsv {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Valaszd ki a figyelt eszkozok CSV-fajljat'
    $dialog.Filter = 'CSV fajlok (*.csv)|*.csv|Minden fajl (*.*)|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:SelectedCsvPath = $dialog.FileName
        Save-Settings $script:SelectedCsvPath
        return $true
    }
    return $false
}

function Test-SelectedCsv {
    if ([string]::IsNullOrWhiteSpace([string]$script:SelectedCsvPath)) { return $false }
    return (Test-Path -LiteralPath $script:SelectedCsvPath)
}

function Import-Devices {
    param([string]$Path)
    $items = @(Import-Csv -LiteralPath $Path | ForEach-Object {
        $name = ([string]$_.Name).Trim(); $ip = ([string]$_.IP).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($ip)) { throw 'Minden CSV-sorhoz kell Name es IP oszlop.' }
        [pscustomobject]@{
            Name = $name; IP = $ip
            MaintenanceEnabled = ([string]$_.MaintenanceEnabled -eq 'True')
            MaintenanceStart = ([string]$_.MaintenanceStart).Trim()
            MaintenanceEnd = ([string]$_.MaintenanceEnd).Trim()
        }
    })
    if ($items.Count -eq 0) { throw 'A kivalasztott CSV ures.' }
    if (@($items | Group-Object IP | Where-Object Count -gt 1).Count -gt 0) { throw 'Egy IP csak egyszer szerepelhet a CSV-ben.' }
    return $items
}

function Export-Devices {
    param([object[]]$Items)
    $Items | Select-Object Name, IP, MaintenanceEnabled, MaintenanceStart, MaintenanceEnd | Export-Csv -LiteralPath $script:SelectedCsvPath -NoTypeInformation -Encoding UTF8
}

function Read-InputOrEscape {
    param([string]$Prompt, [string]$Title = 'PingMonitor')
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title; $form.Size = New-Object System.Drawing.Size(500, 180)
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true; $form.KeyPreview = $true
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt; $label.AutoSize = $true; $label.Location = New-Object System.Drawing.Point(15, 15)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(15, 55); $box.Size = New-Object System.Drawing.Size(450, 24)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(290, 95); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Megse (Esc)'; $cancel.Location = New-Object System.Drawing.Point(370, 95); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.AddRange(@($label, $box, $ok, $cancel)); $form.AcceptButton = $ok; $form.CancelButton = $cancel
    $form.Add_Shown({ $box.Focus() })
    $result = $form.ShowDialog()
    $value = if ($result -eq [System.Windows.Forms.DialogResult]::OK) { $box.Text.Trim() } else { $null }
    $form.Dispose()
    return $value
}

function Get-DeviceByNumber {
    param([object[]]$Items)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('{0,2}. {1,-25} {2,-15} Karbantartas: {3} {4}-{5}' -f ($i + 1), $Items[$i].Name, $Items[$i].IP, $Items[$i].MaintenanceEnabled, $Items[$i].MaintenanceStart, $Items[$i].MaintenanceEnd)
    }
    Write-Host 'Esc = vissza a szerkeszto menube'
    $answer = Read-InputOrEscape 'Eszkoz sorszama:' 'Eszkoz kivalasztasa'
    if ($null -eq $answer) { return $null }
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $Items.Count) { return $null }
    return $Items[$number - 1]
}

function Test-TimeValue {
    param([string]$Value)
    $time = [TimeSpan]::Zero
    return [TimeSpan]::TryParse($Value, [ref]$time)
}

function Test-MaintenanceActive {
    param([object]$Device, [datetime]$Now)
    if (-not $Device.MaintenanceEnabled -or -not (Test-TimeValue $Device.MaintenanceStart) -or -not (Test-TimeValue $Device.MaintenanceEnd)) { return $false }
    $start = [TimeSpan]::Parse($Device.MaintenanceStart); $end = [TimeSpan]::Parse($Device.MaintenanceEnd); $current = $Now.TimeOfDay
    if ($start -eq $end) { return $false }
    if ($start -lt $end) { return ($current -ge $start -and $current -lt $end) }
    return ($current -ge $start -or $current -lt $end)
}

function Show-DeviceList {
    param([object[]]$Items)
    Write-Host ''; Write-Host 'Felvett eszkozok:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $maintenance = if ($item.MaintenanceEnabled) { "Minden nap: $($item.MaintenanceStart)-$($item.MaintenanceEnd)" } else { 'Kikapcsolva' }
        Write-Host ('{0,2}. {1,-25} {2,-15} Karbantartas: {3}' -f ($i + 1), $item.Name, $item.IP, $maintenance)
    }
    Write-Host ''
    Write-Host 'Esc = vissza a fo menuhez'
    [void][System.Windows.Forms.MessageBox]::Show('Az eszkozlista bezarasahoz nyomj Esc-t, OK-t vagy Megse-t.', 'Eszkozlista', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
    return $true
}

function Show-DeviceEditor {
    if (-not (Test-SelectedCsv)) { Write-Host 'Elobb valassz CSV-fajlt a fo menu 2-es pontjaban.' -ForegroundColor Yellow; Pause; return }
    $items = @(Import-Devices $script:SelectedCsvPath)
    $dirty = $false
    while ($true) {
        Clear-Host
        Write-Host '============= Eszkozlista szerkesztese =============' -ForegroundColor Cyan
        Write-Host "CSV: $script:SelectedCsvPath"
        Write-Host "Nem mentett modositas: $(if ($dirty) { 'IGEN' } else { 'NINCS' })"
        Write-Host '1. Felvett eszkozok megtekintese'
        Write-Host '2. Eszkoz hozzaadasa'
        Write-Host '3. Eszkoz torlese'
        Write-Host '4. Karbantartas be-/kikapcsolasa'
        Write-Host 'M. Mentes es vissza a fo menuhoz'
        Write-Host 'V. Vissza a fo menuhoz'
        switch (Read-Host 'Valassz') {
            '1' { [void](Show-DeviceList $items); return }
            '2' {
                $name = Read-Host 'Eszkoz neve'; $ip = Read-Host 'IP-cim vagy hosztnev'
                if ($name -and $ip -and -not ($items.IP -contains $ip)) { $items = @($items + [pscustomobject]@{ Name=$name; IP=$ip; MaintenanceEnabled=$false; MaintenanceStart=''; MaintenanceEnd='' }); $dirty=$true }
                else { Write-Host 'Hianyzo vagy mar letezo IP-cim.' -ForegroundColor Yellow; Pause }
            }
            '3' { $device = Get-DeviceByNumber $items; if ($null -ne $device -and (Read-Host "Toroljem: $($device.Name)? (i/n)") -eq 'i') { $items=@($items | Where-Object IP -ne $device.IP); $dirty=$true } }
            '4' {
                $device = Get-DeviceByNumber $items
                if ($null -ne $device) {
                    if ($device.MaintenanceEnabled) {
                        if ((Read-Host "Karbantartas kikapcsolasa ennél: $($device.Name)? (i/n)") -eq 'i') { $device.MaintenanceEnabled=$false; $dirty=$true }
                    }
                    else {
                        Write-Host "A karbantartas minden nap aktiv lesz a megadott idointervallumban." -ForegroundColor Cyan
                        $start = Read-InputOrEscape 'Kezdete HH:mm formatumban, pelda: 22:00.' 'Karbantartasi idoszak'
                        if ([string]::IsNullOrWhiteSpace($start)) { continue }
                        $end = Read-InputOrEscape 'Vege HH:mm formatumban, pelda: 07:00.' 'Karbantartasi idoszak'
                        if ([string]::IsNullOrWhiteSpace($end)) { continue }
                        if ((Test-TimeValue $start) -and (Test-TimeValue $end) -and $start -ne $end) { $device.MaintenanceStart=$start; $device.MaintenanceEnd=$end; $device.MaintenanceEnabled=$true; $dirty=$true }
                        else { Write-Host 'Hibas idopont. A formatum peldaul: 22:00' -ForegroundColor Red; Pause }
                    }
                }
            }
            'M' { if ($dirty) { Export-Devices $items }; return }
            'm' { if ($dirty) { Export-Devices $items }; return }
            'V' { return }
            'v' { return }
        }
    }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host '================ PingMonitor V4 ================' -ForegroundColor Cyan
        if (Test-SelectedCsv) { Write-Host "Aktiv CSV utvonal: $script:SelectedCsvPath" }
        else { Write-Host 'Nincs aktiv CSV kivalasztva.' -ForegroundColor Yellow }
        Write-Host ''
        if (Test-SelectedCsv) {
            Write-Host '1. Figyeles inditasa'
            Write-Host '2. Masik CSV kivalasztasa'
            Write-Host '3. Eszkozlista szerkesztese'
        }
        else { Write-Host '2. CSV eszkozlista kivalasztasa' }
        Write-Host '8. Uj Telegram API token es Chat ID par hozzaadasa'
        Write-Host '0. Kilepes'
        switch (Read-Host 'Valassz') {
            '1' { if (Test-SelectedCsv) { return } }
            '2' { [void](Select-DeviceCsv) }
            '3' { if (Test-SelectedCsv) { Show-DeviceEditor } }
            '8' { Add-TelegramTarget; Pause }
            '0' { exit }
        }
    }
}

$settings = Load-Settings
$script:SelectedCsvPath = $settings.LastCsvPath
Show-Menu
if (-not (Test-SelectedCsv)) { Write-Host 'Nem valasztottal CSV-fajlt. A program leall.' -ForegroundColor Yellow; exit }
$Devices = @(Import-Devices $script:SelectedCsvPath)
$MonitorName = $env:COMPUTERNAME

function Get-DeviceListText { param([object[]]$Items) (($Items | ForEach-Object { '- {0} ({1})' -f $_.Name, $_.IP }) -join "`n") }
function Send-Events { param([object[]]$Items, [ValidateSet('Down','Up')][string]$Kind, [datetime]$Time)
    if ($Items.Count -eq 0) { return }
    $list = Get-DeviceListText $Items
    if ($Kind -eq 'Down') {
        $title = if ($Items.Count -gt 1) { 'HALOZATI KIMARADAS' } else { 'HALOZATI HIBA' }
        Send-Telegram "[RIASZTAS] $title`n`nMonitor:`n$MonitorName`n`nIdo:`n$($Time.ToString('yyyy-MM-dd HH:mm:ss'))`n`nKiesett eszkozok:`n$list" | Out-Null
    } else {
        $maxSeconds = ($Items | Measure-Object DownSeconds -Maximum).Maximum
        Send-Telegram "[HELYREALLT] HALOZAT HELYREALLT`n`nMonitor:`n$MonitorName`n`nIdo:`n$($Time.ToString('yyyy-MM-dd HH:mm:ss'))`n`nErintett eszkozok:`n$list`n`nLegnagyobb kieses: $('{0:N1}' -f $maxSeconds) mp" | Out-Null
    }
}

function New-Stats { @{ TotalSamples=0; SuccessSamples=0; LatencyCount=0; LatencyTotal=0; MaxLatency=0 } }
function Send-DailySummary {
    param([datetime]$From, [datetime]$To)
    $lines = foreach ($device in $Devices) {
        $stats = $Statistics[$device.IP]
        if ($stats.TotalSamples -eq 0) { '- {0}: nincs ertekelheto meres' -f $device.Name }
        else {
            $availability = 100 * $stats.SuccessSamples / $stats.TotalSamples
            $average = if ($stats.LatencyCount) { $stats.LatencyTotal / $stats.LatencyCount } else { 0 }
            '- {0}: {1:N2}% | atlag: {2:N1} ms | max: {3} ms' -f $device.Name, $availability, $average, $stats.MaxLatency
        }
    }
    Send-Telegram "[NAPI OSSZESITO]`n`nMonitor:`n$MonitorName`n`nIdoszak:`n$($From.ToString('yyyy-MM-dd HH:mm')) - $($To.ToString('yyyy-MM-dd HH:mm'))`n`nEszkozok:`n$($lines -join "`n")" | Out-Null
}

$State = @{}; $Statistics = @{}; $PingClients = @{}
foreach ($device in $Devices) {
    $State[$device.IP] = @{ Online=$null; DownSince=$null; LatencyMs=$null; Maintenance=$false }
    $Statistics[$device.IP] = New-Stats
    $PingClients[$device.IP] = New-Object System.Net.NetworkInformation.Ping
}
$started = Get-Date
$summaryFrom = $started
$nextSummary = $started.Date.AddHours($SummaryHour)
if ($nextSummary -le $started) { $nextSummary = $nextSummary.AddDays(1) }
$telegramStarted = Send-Telegram "[INDITAS] PingMonitor elindult`n`nMonitor:`n$MonitorName`n`nIdo:`n$($started.ToString('yyyy-MM-dd HH:mm:ss'))`n`nFigyelt eszkozok:`n$(Get-DeviceListText $Devices)"
$LastEvent = 'Nincs esemeny.'

try {
    while ($true) {
        $now = Get-Date; $tasks = @{}
        foreach ($device in $Devices) {
            $maintenance = Test-MaintenanceActive $device $now
            $State[$device.IP].Maintenance = $maintenance
            if ($maintenance) { $State[$device.IP].Online=$null; $State[$device.IP].DownSince=$null; continue }
            try { $tasks[$device.IP] = $PingClients[$device.IP].SendPingAsync($device.IP, $PingTimeoutMilliseconds) }
            catch { $tasks[$device.IP] = $null }
        }
        $results = @{}
        foreach ($device in $Devices) {
            if ($State[$device.IP].Maintenance) { continue }
            $task = $tasks[$device.IP]
            $ok = $false; $latency = $null
            if ($null -ne $task -and $task.Wait($PingTimeoutMilliseconds + 200)) {
                try { $reply=$task.Result; $ok=($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success); if ($ok) { $latency=[int]$reply.RoundtripTime } } catch { }
            }
            elseif ($null -ne $task) { $PingClients[$device.IP].Dispose(); $PingClients[$device.IP] = New-Object System.Net.NetworkInformation.Ping }
            $results[$device.IP] = [pscustomobject]@{ Online=$ok; LatencyMs=$latency }
        }
        $wentDown = [System.Collections.Generic.List[object]]::new(); $cameUp = [System.Collections.Generic.List[object]]::new()
        foreach ($device in $Devices) {
            if ($State[$device.IP].Maintenance) { continue }
            $ok=$results[$device.IP].Online; $previous=$State[$device.IP].Online; $State[$device.IP].LatencyMs=$results[$device.IP].LatencyMs
            $stats=$Statistics[$device.IP]; $stats.TotalSamples++
            if ($ok) { $stats.SuccessSamples++; $stats.LatencyCount++; $stats.LatencyTotal += $State[$device.IP].LatencyMs; if ($State[$device.IP].LatencyMs -gt $stats.MaxLatency) { $stats.MaxLatency=$State[$device.IP].LatencyMs } }
            if ($null -eq $previous) { $State[$device.IP].Online=$ok; if (-not $ok) { $State[$device.IP].DownSince=$now }; continue }
            if ($previous -and -not $ok) { $State[$device.IP].Online=$false; $State[$device.IP].DownSince=$now; $wentDown.Add($device); $LastEvent='[{0}] {1} KIESETT' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'),$device.Name; Add-Log $LastEvent }
            elseif (-not $previous -and $ok) { $down=($now-$State[$device.IP].DownSince).TotalSeconds; $State[$device.IP].Online=$true; $State[$device.IP].DownSince=$null; $cameUp.Add([pscustomobject]@{Name=$device.Name;IP=$device.IP;DownSeconds=$down}); $LastEvent='[{0}] {1} HELYREALLT - {2:N1} mp' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'),$device.Name,$down; Add-Log $LastEvent }
        }
        Send-Events $wentDown.ToArray() Down $now; Send-Events $cameUp.ToArray() Up $now
        if ($now -ge $nextSummary) { Send-DailySummary $summaryFrom $now; foreach ($device in $Devices) { $Statistics[$device.IP]=New-Stats }; $summaryFrom=$now; $nextSummary=$nextSummary.AddDays(1) }

        Clear-Host; $online=@($State.Values | Where-Object Online -eq $true).Count; $offline=@($State.Values | Where-Object Online -eq $false).Count; $maint=@($State.Values | Where-Object Maintenance).Count
        Write-Host "============= PingMonitor V4 - $MonitorName =============" -ForegroundColor Cyan
        Write-Host "Online: $online | Offline: $offline | Karbantartas: $maint | Kovetkezo osszesito: $($nextSummary.ToString('yyyy-MM-dd HH:mm'))"
        foreach ($device in $Devices) {
            $s=$State[$device.IP]
            if ($s.Maintenance) { Write-Host ('[KARBANT.] {0,-25} {1}' -f $device.Name,$device.IP) -ForegroundColor DarkYellow }
            elseif ($s.Online) { Write-Host ('[ONLINE ] {0,-25} {1} - {2} ms' -f $device.Name,$device.IP,$s.LatencyMs) -ForegroundColor Green }
            else { Write-Host ('[OFFLINE] {0,-25} {1}' -f $device.Name,$device.IP) -ForegroundColor Red }
        }
        Write-Host "Utolso esemeny: $LastEvent" -ForegroundColor Yellow
        Start-Sleep -Milliseconds 1000
    }
}
finally { foreach ($client in $PingClients.Values) { $client.Dispose() } }
