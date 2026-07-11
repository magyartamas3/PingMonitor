# PingMonitor GUI - Windows PowerShell 5.1 / PowerShell 7 (Windows)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRoot = $PSScriptRoot
$ConfigFile = Join-Path $ScriptRoot 'config.ps1'
$SettingsFile = Join-Path $ScriptRoot 'pingmonitor-settings.json'
$LogDirectory = Join-Path $ScriptRoot 'logs'
$PingTimeoutMilliseconds = 1000
$SummaryHour = 21
$MonitorName = $env:COMPUTERNAME
if (-not (Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory | Out-Null }
Get-ChildItem $LogDirectory -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Force
if (-not (Test-Path $ConfigFile)) { '$TelegramTargets = @()' | Set-Content $ConfigFile -Encoding UTF8 }
. $ConfigFile
if ($null -eq $TelegramTargets) { $TelegramTargets = @() }

$script:Devices = [System.Collections.ArrayList]::new()
$script:States = @{}; $script:Stats = @{}; $script:Clients = @{}; $script:Pending = @{}
$script:CsvPath = $null; $script:Monitoring = $false; $script:SummaryFrom = Get-Date
$script:NextSummary = (Get-Date).Date.AddHours($SummaryHour)
if ($script:NextSummary -le (Get-Date)) { $script:NextSummary = $script:NextSummary.AddDays(1) }

function Add-Log([string]$Text) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content (Join-Path $LogDirectory ((Get-Date).ToString('yyyy-MM-dd') + '.log')) "[$stamp] $Text"
    $txtEvents.AppendText("[$stamp] $Text`r`n")
}
function Save-Settings { @{ LastCsvPath = $script:CsvPath } | ConvertTo-Json | Set-Content $SettingsFile -Encoding UTF8 }
function Load-Settings {
    if (Test-Path $SettingsFile) { try { return (Get-Content $SettingsFile -Raw | ConvertFrom-Json).LastCsvPath } catch {} }
    return $null
}
function Save-TelegramTargets {
    $lines = @('$TelegramTargets = @(')
    foreach ($target in $TelegramTargets) {
        $token = ([string]$target.Token).Replace("'", "''"); $chat = ([string]$target.ChatID).Replace("'", "''")
        $lines += "    @{ Token = '$token'; ChatID = '$chat' }"
    }
    $lines += ')'; Set-Content $ConfigFile -Value $lines -Encoding UTF8
}
function Read-GuiInput([string]$Prompt,[string]$Title) {
    $f=New-Object Windows.Forms.Form;$f.Text=$Title;$f.Size=[System.Drawing.Size]::new(450,160);$f.StartPosition='CenterParent';$f.TopMost=$true
    $l=New-Object Windows.Forms.Label;$l.Text=$Prompt;$l.AutoSize=$true;$l.Location='15,15'
    $t=New-Object Windows.Forms.TextBox;$t.Location='15,45';$t.Size='400,24'
    $ok=New-Object Windows.Forms.Button;$ok.Text='OK';$ok.Location='240,85';$ok.DialogResult='OK'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Megse';$cancel.Location='325,85';$cancel.DialogResult='Cancel'
    $f.Controls.AddRange(@($l,$t,$ok,$cancel));$f.AcceptButton=$ok;$f.CancelButton=$cancel;$f.Add_Shown({$t.Focus()})
    $result=$f.ShowDialog();$value=if($result -eq 'OK'){$t.Text.Trim()}else{$null};$f.Dispose();return $value
}
function Send-Telegram([string]$Message) {
    if (@($TelegramTargets).Count -eq 0) { return }
    foreach ($target in $TelegramTargets) {
        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$($target.Token)/sendMessage" -Method Post -Body @{ chat_id=$target.ChatID; text=$Message } -ErrorAction Stop | Out-Null }
        catch { Add-Log "Telegram hiba: $($_.Exception.Message)" }
    }
}
function Test-Maintenance($Device) {
    if (-not $Device.MaintenanceEnabled -or -not $Device.MaintenanceStart -or -not $Device.MaintenanceEnd) { return $false }
    try {
        $start = [TimeSpan]::Parse($Device.MaintenanceStart); $end = [TimeSpan]::Parse($Device.MaintenanceEnd); $now = (Get-Date).TimeOfDay
        if ($start -eq $end) { return $false }
        if ($start -lt $end) { return $now -ge $start -and $now -lt $end }
        return $now -ge $start -or $now -lt $end
    } catch { return $false }
}
function New-Stats { @{ Total=0; Success=0; LatencyCount=0; LatencyTotal=0; MaxLatency=0 } }
function Reset-MonitorData {
    $script:States=@{}; $script:Stats=@{}; $script:Clients=@{}; $script:Pending=@{}
    foreach ($device in $script:Devices) {
        $script:States[$device.IP] = @{ Online=$null; DownSince=$null; Latency=$null; Maintenance=$false }
        $script:Stats[$device.IP] = New-Stats
        $script:Clients[$device.IP] = New-Object System.Net.NetworkInformation.Ping
    }
}
function Save-Devices {
    if (-not $script:CsvPath) { return }
    $script:Devices | Select-Object Name,IP,MaintenanceEnabled,MaintenanceStart,MaintenanceEnd | Export-Csv $script:CsvPath -NoTypeInformation -Encoding UTF8
    Add-Log 'Eszkozlista elmentve.'
}
function Load-Devices([string]$Path) {
    try {
        $items = @(Import-Csv $Path | ForEach-Object {
            if (-not $_.Name -or -not $_.IP) { throw 'A CSV minden soraban kell Name es IP.' }
            [pscustomobject]@{ Name=[string]$_.Name; IP=[string]$_.IP; MaintenanceEnabled=([string]$_.MaintenanceEnabled -eq 'True'); MaintenanceStart=[string]$_.MaintenanceStart; MaintenanceEnd=[string]$_.MaintenanceEnd }
        })
        if ($items.Count -eq 0) { throw 'A CSV ures.' }
        if (@($items | Group-Object IP | Where-Object Count -gt 1).Count) { throw 'Egy IP csak egyszer szerepelhet.' }
        $script:Devices.Clear(); foreach ($item in $items) { [void]$script:Devices.Add($item) }
        $script:CsvPath=$Path; $txtCsv.Text=$Path; Save-Settings; Reset-MonitorData; Update-Grid; $btnStart.Enabled=$true; Add-Log "CSV betoltve: $Path"
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'CSV hiba') | Out-Null }
}
function Update-Grid {
    $grid.Rows.Clear()
    foreach ($device in $script:Devices) {
        $state=$script:States[$device.IP]; $maintenance = if ($device.MaintenanceEnabled) { "Minden nap: $($device.MaintenanceStart)-$($device.MaintenanceEnd)" } else { 'Kikapcsolva' }
        $status='Nincs meres'; $ping=''
        if ($state) {
            if ($state.Maintenance) { $status='Karbantartas' }
            elseif ($state.Online -eq $true) { $status='Online'; $ping="$($state.Latency) ms" }
            elseif ($state.Online -eq $false) { $status='Offline' }
        }
        $row=$grid.Rows.Add($device.Name,$device.IP,$status,$ping,$maintenance)
        if ($status -eq 'Online') { $grid.Rows[$row].DefaultCellStyle.BackColor=[Drawing.Color]::Honeydew }
        elseif ($status -eq 'Offline') { $grid.Rows[$row].DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose }
        elseif ($status -eq 'Karbantartas') { $grid.Rows[$row].DefaultCellStyle.BackColor=[Drawing.Color]::LemonChiffon }
    }
}
function Get-SelectedDevice {
    if ($grid.SelectedRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Valassz ki egy eszkozt a tablazatbol.','PingMonitor') | Out-Null; return $null }
    return $script:Devices[$grid.SelectedRows[0].Index]
}
function Show-DeviceDialog($Device) {
    $edit = $null -ne $Device
    $f=New-Object Windows.Forms.Form; $f.Text=if($edit){'Eszköz szerkesztése'}else{'Új eszköz'}; $f.Size=[System.Drawing.Size]::new(440,300); $f.StartPosition='CenterParent'; $f.TopMost=$true
    $name=New-Object Windows.Forms.TextBox; $name.Location='130,20'; $name.Size='250,24'; $name.Text=if($edit){$Device.Name}else{''}
    $ip=New-Object Windows.Forms.TextBox; $ip.Location='130,55'; $ip.Size='250,24'; $ip.Text=if($edit){$Device.IP}else{''}
    $enabled=New-Object Windows.Forms.CheckBox; $enabled.Text='Napi karbantartás'; $enabled.AutoSize=$true; $enabled.Location='20,95'; $enabled.Checked=if($edit){$Device.MaintenanceEnabled}else{$false}
    $start=New-Object Windows.Forms.DateTimePicker; $start.Format='Custom'; $start.CustomFormat='HH:mm'; $start.ShowUpDown=$true; $start.Location='130,130'; $start.Value=(Get-Date).Date.AddHours(22)
    $end=New-Object Windows.Forms.DateTimePicker; $end.Format='Custom'; $end.CustomFormat='HH:mm'; $end.ShowUpDown=$true; $end.Location='130,165'; $end.Value=(Get-Date).Date.AddHours(7)
    if($edit -and $Device.MaintenanceStart){try{$start.Value=(Get-Date).Date.Add([TimeSpan]::Parse($Device.MaintenanceStart));$end.Value=(Get-Date).Date.Add([TimeSpan]::Parse($Device.MaintenanceEnd))}catch{}}
    $setEnabled={ $start.Enabled=$enabled.Checked; $end.Enabled=$enabled.Checked }; & $setEnabled; $enabled.Add_CheckedChanged($setEnabled)
    $ok=New-Object Windows.Forms.Button; $ok.Text='Mentés'; $ok.Location='210,210'; $ok.DialogResult='OK'
    $cancel=New-Object Windows.Forms.Button; $cancel.Text='Mégse'; $cancel.Location='300,210'; $cancel.DialogResult='Cancel'
    foreach($pair in @(@('Név:',20),@('IP-cím:',55),@('Kezdete:',130),@('Vége:',165))){$l=New-Object Windows.Forms.Label;$l.Text=$pair[0];$l.Location="20,$($pair[1])";$f.Controls.Add($l)}
    $f.Controls.AddRange(@($name,$ip,$enabled,$start,$end,$ok,$cancel));$f.AcceptButton=$ok;$f.CancelButton=$cancel
    if($f.ShowDialog() -eq 'OK') {
        if(-not $name.Text.Trim() -or -not $ip.Text.Trim()){[Windows.Forms.MessageBox]::Show('Nev es IP-cim kotelezo.','Hiba')|Out-Null; $f.Dispose(); return}
        if(-not $edit -and @($script:Devices | Where-Object IP -eq $ip.Text.Trim()).Count){[Windows.Forms.MessageBox]::Show('Ez az IP-cim mar letezik.','Hiba')|Out-Null; $f.Dispose(); return}
        if($edit){$Device.Name=$name.Text.Trim();$Device.IP=$ip.Text.Trim();$Device.MaintenanceEnabled=$enabled.Checked;$Device.MaintenanceStart=$start.Value.ToString('HH:mm');$Device.MaintenanceEnd=$end.Value.ToString('HH:mm')}
        else{[void]$script:Devices.Add([pscustomobject]@{Name=$name.Text.Trim();IP=$ip.Text.Trim();MaintenanceEnabled=$enabled.Checked;MaintenanceStart=$start.Value.ToString('HH:mm');MaintenanceEnd=$end.Value.ToString('HH:mm')})}
        Reset-MonitorData;Update-Grid
    };$f.Dispose()
}
function Show-TelegramDialog {
    $f=New-Object Windows.Forms.Form;$f.Text='Telegram celok';$f.Size='600,360';$f.StartPosition='CenterParent';$f.TopMost=$true
    $g=New-Object Windows.Forms.DataGridView;$g.Location='15,15';$g.Size='550,210';$g.AllowUserToAddRows=$false;$g.SelectionMode='FullRowSelect';$g.AutoSizeColumnsMode='Fill'
    [void]$g.Columns.Add('Token','Bot token');[void]$g.Columns.Add('Chat','Chat ID'); foreach($t in $TelegramTargets){[void]$g.Rows.Add($t.Token,$t.ChatID)}
    $add=New-Object Windows.Forms.Button;$add.Text='Hozzaadas';$add.Location='15,245';$delete=New-Object Windows.Forms.Button;$delete.Text='Torles';$delete.Location='110,245';$save=New-Object Windows.Forms.Button;$save.Text='Mentes';$save.Location='385,245';$close=New-Object Windows.Forms.Button;$close.Text='Bezárás';$close.Location='475,245'
    $add.Add_Click({$token=Read-GuiInput 'Telegram bot API token:' 'Uj Telegram cel';if($null -eq $token){return};$chat=Read-GuiInput 'Telegram Chat ID:' 'Uj Telegram cel';if($null -ne $chat -and $token -and $chat){[void]$g.Rows.Add($token,$chat)}})
    $delete.Add_Click({if($g.SelectedRows.Count){$g.Rows.RemoveAt($g.SelectedRows[0].Index)}})
    $save.Add_Click({$script:TelegramTargets=@();foreach($row in $g.Rows){if(-not $row.IsNewRow -and $row.Cells[0].Value -and $row.Cells[1].Value){$script:TelegramTargets+=@{Token=[string]$row.Cells[0].Value;ChatID=[string]$row.Cells[1].Value}}};Save-TelegramTargets;Add-Log 'Telegram celok elmentve.'})
    $close.Add_Click({$f.Close()});$f.Controls.AddRange(@($g,$add,$delete,$save,$close));[void]$f.ShowDialog();$f.Dispose()
}
function Send-Events($Down,$Up,[datetime]$Now) {
    if($Down.Count){$list=($Down|ForEach-Object{"- $($_.Name) ($($_.IP))"})-join"`n";Send-Telegram "[RIASZTAS] HALOZATI KIMARADAS`n`nMonitor: $MonitorName`nIdo: $($Now.ToString('yyyy-MM-dd HH:mm:ss'))`n`n$list"}
    if($Up.Count){$list=($Up|ForEach-Object{"- $($_.Name) ($($_.IP))"})-join"`n";$max=($Up|Measure-Object DownSeconds -Maximum).Maximum;Send-Telegram "[HELYREALLT]`n`nMonitor: $MonitorName`nIdo: $($Now.ToString('yyyy-MM-dd HH:mm:ss'))`n`n$list`n`nLegnagyobb kieses: $('{0:N1}' -f $max) mp"}
}
function Send-DailySummary {
    $lines=foreach($d in $script:Devices){$s=$script:Stats[$d.IP];if(-not $s.Total){"- $($d.Name): nincs meres"}else{$pct=100*$s.Success/$s.Total;$avg=if($s.LatencyCount){$s.LatencyTotal/$s.LatencyCount}else{0};"- $($d.Name): $('{0:N2}' -f $pct)% | atlag: $('{0:N1}' -f $avg) ms | max: $($s.MaxLatency) ms"}}
    Send-Telegram "[NAPI OSSZESITO]`n`nMonitor: $MonitorName`n`n$($lines -join "`n")"
    foreach($d in $script:Devices){$script:Stats[$d.IP]=New-Stats};$script:SummaryFrom=Get-Date;$script:NextSummary=$script:NextSummary.AddDays(1);Add-Log 'Napi osszesito elkuldve.'
}
function Monitor-Tick {
    if(-not $script:Monitoring){return};$now=Get-Date;$down=[Collections.Generic.List[object]]::new();$up=[Collections.Generic.List[object]]::new()
    foreach($d in $script:Devices){
        $state=$script:States[$d.IP];$state.Maintenance=Test-Maintenance $d
        if($state.Maintenance){$state.Online=$null;$state.DownSince=$null;continue}
        $task=$script:Pending[$d.IP];$ok=$false;$latency=$null
        if($null -eq $task) {
            try{$script:Pending[$d.IP]=$script:Clients[$d.IP].SendPingAsync($d.IP,$PingTimeoutMilliseconds)}catch{$script:Pending[$d.IP]=$null}
            continue
        }
        if($task){if($task.IsCompleted){try{$r=$task.Result;$ok=$r.Status -eq [Net.NetworkInformation.IPStatus]::Success;if($ok){$latency=[int]$r.RoundtripTime}}catch{}}else{$script:Clients[$d.IP].Dispose();$script:Clients[$d.IP]=New-Object Net.NetworkInformation.Ping}}
        $s=$script:Stats[$d.IP];$s.Total++;if($ok){$s.Success++;$s.LatencyCount++;$s.LatencyTotal+=$latency;if($latency -gt $s.MaxLatency){$s.MaxLatency=$latency}}
        $prev=$state.Online;$state.Online=$ok;$state.Latency=$latency
        if($null -ne $prev -and $prev -and -not $ok){$state.DownSince=$now;$down.Add($d);Add-Log "$($d.Name) KIESETT"}
        elseif($prev -eq $false -and $ok){$seconds=($now-$state.DownSince).TotalSeconds;$state.DownSince=$null;$up.Add([pscustomobject]@{Name=$d.Name;IP=$d.IP;DownSeconds=$seconds});Add-Log "$($d.Name) HELYREALLT - $('{0:N1}' -f $seconds) mp"}
        try{$script:Pending[$d.IP]=$script:Clients[$d.IP].SendPingAsync($d.IP,$PingTimeoutMilliseconds)}catch{$script:Pending[$d.IP]=$null}
    }
    Send-Events $down $up $now;if($now -ge $script:NextSummary){Send-DailySummary};Update-Grid
}

# GUI
$form=New-Object Windows.Forms.Form;$form.Text="PingMonitor GUI - $MonitorName";$form.Size=[System.Drawing.Size]::new(1100,720);$form.StartPosition='CenterScreen';$form.MinimumSize=[System.Drawing.Size]::new(950,600)
$txtCsv=New-Object Windows.Forms.TextBox;$txtCsv.Location='15,15';$txtCsv.Size='650,24';$txtCsv.ReadOnly=$true
$btnCsv=New-Object Windows.Forms.Button;$btnCsv.Text='CSV kiválasztása';$btnCsv.Size='140,28'
$btnSave=New-Object Windows.Forms.Button;$btnSave.Text='Eszközlista mentése';$btnSave.Size='160,28'
$btnTelegram=New-Object Windows.Forms.Button;$btnTelegram.Text='Telegram célok';$btnTelegram.Size='120,28'
$grid=New-Object Windows.Forms.DataGridView;$grid.AllowUserToAddRows=$false;$grid.ReadOnly=$true;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='Fill';$grid.MultiSelect=$false
foreach($header in @('Nev','IP','Allapot','Ping','Karbantartas')){[void]$grid.Columns.Add($header,$header)}
$btnAdd=New-Object Windows.Forms.Button;$btnAdd.Text='Hozzáadás';$btnAdd.Size='90,30'
$btnEdit=New-Object Windows.Forms.Button;$btnEdit.Text='Szerkesztés';$btnEdit.Size='100,30'
$btnDelete=New-Object Windows.Forms.Button;$btnDelete.Text='Törlés';$btnDelete.Size='85,30'
$btnStart=New-Object Windows.Forms.Button;$btnStart.Text='Figyelés indítása';$btnStart.Size='140,30';$btnStart.Enabled=$false
$btnStop=New-Object Windows.Forms.Button;$btnStop.Text='Leállítás';$btnStop.Size='85,30';$btnStop.Enabled=$false
$txtEvents=New-Object Windows.Forms.TextBox;$txtEvents.Multiline=$true;$txtEvents.ScrollBars='Vertical';$txtEvents.ReadOnly=$true
$btnCsv.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='CSV fajlok (*.csv)|*.csv';if($d.ShowDialog() -eq 'OK'){Load-Devices $d.FileName}})
$btnSave.Add_Click({Save-Devices})
$btnTelegram.Add_Click({Show-TelegramDialog})
$btnAdd.Add_Click({Show-DeviceDialog $null})
$btnEdit.Add_Click({$d=Get-SelectedDevice;if($d){Show-DeviceDialog $d}})
$btnDelete.Add_Click({$d=Get-SelectedDevice;if($d -and [Windows.Forms.MessageBox]::Show("Toroljem: $($d.Name)?",'Torles',[Windows.Forms.MessageBoxButtons]::YesNo) -eq 'Yes'){[void]$script:Devices.Remove($d);Reset-MonitorData;Update-Grid}})
$btnStart.Add_Click({$script:Monitoring=$true;$btnStart.Enabled=$false;$btnStop.Enabled=$true;Add-Log 'Figyeles elindult.';Send-Telegram "[INDITAS] PingMonitor elindult`nMonitor: $MonitorName"})
$btnStop.Add_Click({$script:Monitoring=$false;$btnStart.Enabled=$true;$btnStop.Enabled=$false;Add-Log 'Figyeles leallitva.'})
$form.Controls.AddRange(@($txtCsv,$btnCsv,$btnSave,$btnTelegram,$grid,$btnAdd,$btnEdit,$btnDelete,$btnStart,$btnStop,$txtEvents))
function Update-Layout {
    $width=$form.ClientSize.Width; $height=$form.ClientSize.Height
    $btnTelegram.Location=[System.Drawing.Point]::new(($width - 135),13)
    $btnSave.Location=[System.Drawing.Point]::new(($width - 300),13)
    $btnCsv.Location=[System.Drawing.Point]::new(($width - 450),13)
    $txtCsv.Location=[System.Drawing.Point]::new(15,15); $txtCsv.Size=[System.Drawing.Size]::new([Math]::Max(200,($width - 480)),24)
    $grid.Location=[System.Drawing.Point]::new(15,55); $grid.Size=[System.Drawing.Size]::new(($width - 30),[Math]::Max(150,($height - 280)))
    $y=$grid.Bottom+8; $x=15
    foreach($button in @($btnAdd,$btnEdit,$btnDelete,$btnStart,$btnStop)) { $button.Location=[System.Drawing.Point]::new($x,$y); $x+=$button.Width+10 }
    $txtEvents.Location=[System.Drawing.Point]::new(15,($y + 40)); $txtEvents.Size=[System.Drawing.Size]::new(($width - 30),[Math]::Max(100,($height - $txtEvents.Top - 15)))
}
$form.Add_Shown({ Update-Layout })
$form.Add_ClientSizeChanged({ Update-Layout })
$form.Add_ResizeEnd({ Update-Layout })
$timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({Monitor-Tick});$timer.Start()
$form.Add_FormClosing({$timer.Stop();foreach($c in $script:Clients.Values){$c.Dispose()}})
$saved=Load-Settings;if($saved -and (Test-Path $saved)){Load-Devices $saved}
$form.Add_Shown({if(@($TelegramTargets).Count -eq 0 -and [Windows.Forms.MessageBox]::Show('Szeretnel Telegram ertesiteseket beallitani?','PingMonitor',[Windows.Forms.MessageBoxButtons]::YesNo) -eq 'Yes'){Show-TelegramDialog}})
[void]$form.ShowDialog()
