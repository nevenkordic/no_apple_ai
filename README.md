# no_apple_ai

Persistently cut Apple Intelligence / Siri RAM on macOS. No Homebrew. Pure bash.

## Install / run

```bash
curl -fsSL -o disable-apple-ai.sh \
  https://raw.githubusercontent.com/nevenkordic/no_apple_ai/main/disable-apple-ai.sh
chmod +x disable-apple-ai.sh
./disable-apple-ai.sh
```

## Non-interactive

```bash
./disable-apple-ai.sh disable soft|medium|hard|nuclear
./disable-apple-ai.sh status
./disable-apple-ai.sh kill [--sudo]
./disable-apple-ai.sh guard-install    # user + root leftover re-kill
./disable-apple-ai.sh reenable
```

## Levels

| Level | What it does |
|---|---|
| soft | Prefs only (Turn Off Siri via CLI) |
| medium | Prefs + disable LaunchAgents + kill + guard |
| hard | medium + sudo kill |
| nuclear | Requires SIP off — also disables `modelmanagerd` / `modelcatalogd` |

## Guard

On-demand XPCs (e.g. `IntelligencePlatformComputeService`, `ANECompilerService`) are not LaunchAgents. `medium` / `hard` / `nuclear` install:

- **user** LaunchAgent — re-kills user leftovers every 30s
- **root** LaunchDaemon — re-kills root leftovers (admin prompt once)

```bash
DISABLE_APPLE_AI_GUARD_INTERVAL=15 ./disable-apple-ai.sh guard-install
```

## Notes

- Use at your own risk. Review the script before running.
- Nuclear weakens OS security while SIP is off (does not damage hardware).
- Disabling AI pieces can affect Spotlight / Apps until Spotlight is restarted.

