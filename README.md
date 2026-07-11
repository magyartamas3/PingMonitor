# PingMonitor V4

## GUI valtozat

A `PingMonitorGUI.ps1` a kattintgatos, Windows-os feluletu valtozat. Ebben egyetlen ablakbol valaszthatsz CSV-t, kezelheted az eszkozoket, a karbantartasi idoszakokat es a Telegram celokat, valamint eloben latod az eszkozok allapotat es pingjet. Az eszkozlista az ablak meretevel egyutt novekszik vagy csokken; a vezerlogombok es az esemenynaplo mindig alatta maradnak.

A korabbi `PingMonitorV3.ps1` konzolos valtozat megmarad tartaleknak.

PowerShell-alapu halozatfigyelo. Az eszkozoket parhuzamosan meri, a kieseseket Telegramon jelzi, es egyetlen konzolablakban mutatja az aktualis allapotot.

## Fobb funkciok

- 1 masodperces parhuzamos ping meres, 1000 ms idotullepessel
- Eszkoz hozzaadasa es torlese konzolos menubol
- Az utoljara hasznalt CSV eszkozlista megjegyzese az aktualis gepen
- Eszkozokent ki- es bekapcsolhato, idozitett karbantartasi idoszak
- Karbantartas alatt nincs kiesesi riasztas, es az ido nem szamit a statisztikaba
- Egyideju kiesesek es helyreallasok csoportositott Telegram-ertesitese
- Napi Telegram osszesito minden nap 21:00-kor: elerhetoseg, atlag- es maximum ping
- Napi naplofajlok, 30 napos automatikus megorzessel

## Inditas

```powershell
.\PingMonitorV3.ps1
```

Elso inditaskor letrejon a `config.ps1`. Ird bele a Telegram bot tokenedet es Chat ID-dat, majd inditsd ujra a programot.

Ha a `config.ps1` meg nem tartalmaz Telegram celt, a script inditaskor rakerdez, szeretnel-e Telegram ertesiteseket. Az `i` valasszal egy vagy tobb token/Chat ID par felveheto. Az `n` valasszal Telegram nelkul fut, es csak helyi naplot keszit.

## PowerShell futtatasi engedely

Ha a PowerShell azt irja, hogy a scriptek futtatasa tiltott, egyszer futtasd a sajat felhasznalod alatt:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Ezutan a script mappajaban add ki:

```powershell
Unblock-File .\PingMonitorV3.ps1
.\PingMonitorV3.ps1
```

Ezt a beallitast nem kell minden inditaskor megismetelned.

## Automatikus inditas Windows bejelentkezeskor

Ha folyamatosan szeretned futtatni, a Windows Feladatutemezoben hozz letre egy uj feladatot `PingMonitor` nevvel:

- Indito: **Bejelentkezeskor**
- Program: `powershell.exe`
- Argumentumok: `-NoProfile -ExecutionPolicy Bypass -File "C:\TELJES\UT\PingMonitorV3.ps1"`
- Kezdes helye: a script mappaja

Igy a monitor automatikusan elindul, amikor bejelentkezel a Windowsba.

## Konzolos menu

Inditaskor a menu fejleceben mindig lathato az aktiv CSV teljes utvonala. CSV nelkul csak a CSV-kivalasztas jelenik meg; aktiv CSV utan indithato a figyeles es nyilik meg az eszkozlista szerkesztese.

A `3. Eszkozlista szerkesztese` menupont egy kulon szerkeszto menut nyit. Itt eloszor a felvett eszkozok listaja lathato, utana a hozzaadas, torles es karbantartasi beallitasok. A lista felirata jelzi: `Esc = vissza a fo menuhez`; az Esc vagy az OK bezarja a listat. A karbantartas be-/kikapcsolasa egyetlen menupont: bekapcsolaskor napi kezdo es vegidot ker, kikapcsolaskor nem ker idot. Az eszkozvalasztasi es idopont ablakokban az Esc vagy a Megse visszalep az elozo menube. A modositasok eloszor csak ideiglenesek. Az `M` pont menti a CSV-t es visszalep a fo menuhoz; a `V` pont visszalep a fo menuhoz.

A `8. Uj Telegram API token es Chat ID par hozzaadasa` menuponttal kesobb is barmikor felvehetsz egy vagy tobb uj Telegram celt. A parok a helyi `config.ps1` fajlba mentodnek.

A karbantartasi beallitas eszkozonkent adhato meg. Pelda: az `Isombar` eszkozhz 22:00 kezdetet es 07:00 veget beallitva a script ejfelkor atnyulo idoszakot is helyesen kezeli.

## CSV formatum

```csv
Name,IP,MaintenanceEnabled,MaintenanceStart,MaintenanceEnd
Router,192.168.1.1,False,,
Isombar,192.168.1.202,True,22:00,07:00
```
