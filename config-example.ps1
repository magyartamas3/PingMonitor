# Ezt a fajlt a PingMonitor automatikusan config.ps1 neven masolja elso inditaskor.
# A config.ps1 nem kerul fel GitHubra; ide ird be a sajat Telegram adataidat.

$TelegramTargets = @(
    @{ Token = "IDE_IRD_A_BOT_TOKENED"; ChatID = "IDE_IRD_A_CHAT_ID-D" }
    # ,@{ Token = "IDE_IRD_A_MASODIK_BOT_TOKENJET"; ChatID = "IDE_IRD_A_MASODIK_CHAT_ID-T" }
)
