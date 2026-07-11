# PingMonitor V3

PowerShell-alapu halozatfigyelo belso halozati eszkozokhoz. Minden IP-cimet parhuzamosan pingel, a kieseseket Telegramon jelzi, es az egy idoben torteno kieseseket egyetlen ertesitesbe csoportositja.

## Funkciok

- Eszkozlista CSV fajlbol (`Name,IP`)
- Kulon, parhuzamos natív `ping.exe` folyamat minden eszkozhoz
- A futtato PC neve minden Telegram-ertesitesben
- Csoportositott kiesesi es helyreallasi uzenetek
- Valaszido kijelzese a konzolon
- Opcionális riasztas magas kesleltetes eseten
- Windows PowerShell 5.1 es PowerShell 7 tamogatas

## Elso inditas

1. Toltsd le vagy klonozd a repot egy helyi mappaba.
2. Inditsd el a `PingMonitorV3.ps1` fajlt. Elso inditaskor letrejon mellette a helyi `config.ps1` fajl a mintabol.
3. A kovetkezo fejezet szerint allitsd be a Telegram botot a `config.ps1` fajlban.
4. Masold le a `devices-example.csv` fajlt `devices.csv` neven egy biztonsagos helyre, majd ird bele a sajat eszkozeidet.
5. Inditsd ujra a scriptet, es a fajlvalaszto ablakban jelold ki a sajat `devices.csv` fajlt.

PowerShellbol pelda inditas:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\PingMonitorV3.ps1
```

## Telegram bot beallitasa

### 1. Bot token letrehozasa

1. Telegramban nyisd meg az [@BotFather](https://t.me/BotFather) beszelgetest.
2. Kuldd el: `/newbot`.
3. Add meg a bot megjeleno nevet, majd a felhasznalonevet. A felhasznalonevnek `bot` vegzodesunek kell lennie.
4. A BotFather kiir egy **HTTP API tokent**. Ez a bot token; masnak ne add meg.
5. Nyisd meg az uj botoddal a beszelgetest, es kuldd el neki: `/start`.

Botot a BotFatherrel lehet letrehozni, a kapott tokennel pedig a Telegram Bot API hasznalhato. [Telegram bot dokumentacio](https://core.telegram.org/bots), [Bot API referencia](https://core.telegram.org/bots/api).

### 2. Chat ID lekerese

PowerShellben futtasd az alabbi parancsot. A `SAJAT_BOT_TOKEN` helyere a BotFather altal adott token kerul:

```powershell
$token = 'SAJAT_BOT_TOKEN'
$updates = Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates"
$updates.result | ConvertTo-Json -Depth 10
```

A kimenetben keresd meg ezt a reszt:

```text
"chat": { "id": 123456789, ... }
```

Az `id` erteke a `ChatID`. Csoportnal ez gyakran negativ szam. Ha ures a `result`, ellenorizd, hogy elobb elkuldted-e a `/start` uzenetet a botnak. A `getUpdates` hivatalos Telegram Bot API metodus. [Referencia](https://core.telegram.org/bots/api#getupdates)

### 3. config.ps1 kitoltese

Nyisd meg a **helyi** `config.ps1` fajlt, es ird be a tokenedet es a Chat ID-t:

```powershell
$TelegramTargets = @(
    @{ Token = "SAJAT_BOT_TOKEN"; ChatID = "SAJAT_CHAT_ID" }
)
```

Tobb Telegram cel is megadhato a tombben. A `config-example.ps1` csak minta, azt ne ird at a sajat adataiddal.

## Eszkozlista

Pelda `devices.csv`:

```csv
Name,IP
Router,192.168.1.1
Firewall,192.168.1.254
NAS,192.168.1.10
Switch,192.168.1.20
```
