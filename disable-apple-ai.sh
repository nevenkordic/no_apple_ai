#!/usr/bin/env bash
# disable-apple-ai.sh
# Persistently reduce Apple Intelligence / Siri RAM use on macOS.
#
# No Homebrew. No third-party tools. Pure bash + macOS builtins.
#
# Install / run (curl-able):
#   curl -fsSL -o disable-apple-ai.sh 'https://raw.githubusercontent.com/nevenkordic/no_apple_ai/main/disable-apple-ai.sh'
#   chmod +x disable-apple-ai.sh
#   ./disable-apple-ai.sh
#
# Non-interactive:
#   ./disable-apple-ai.sh disable soft|medium|hard
#   ./disable-apple-ai.sh status
#   ./disable-apple-ai.sh reenable
#   ./disable-apple-ai.sh kill [--sudo]
#   ./disable-apple-ai.sh guard-install|guard-uninstall|guard-status
#   ./disable-apple-ai.sh animate          # demo the boot animation
#
# Use at your own risk. Review before running.
# Also: System Settings → Siri → Turn Off Siri

set -euo pipefail

VERSION="1.6.0"
UID_NUM="$(id -u)"
GUI_DOMAIN="gui/${UID_NUM}"

# User-domain watchdog that re-kills on-demand AI XPCs (they are not LaunchAgents)
GUARD_LABEL="local.disable-apple-ai.guard"
GUARD_DIR="${HOME}/Library/Application Support/disable-apple-ai"
GUARD_SCRIPT="${GUARD_DIR}/guard.sh"
GUARD_PLIST="${HOME}/Library/LaunchAgents/${GUARD_LABEL}.plist"
GUARD_INTERVAL_SEC="${DISABLE_APPLE_AI_GUARD_INTERVAL:-30}"

# Root LaunchDaemon — kills root-owned leftovers (e.g. ANECompilerService)
ROOT_GUARD_LABEL="local.disable-apple-ai.guard-root"
ROOT_GUARD_DIR="/Library/Application Support/disable-apple-ai"
ROOT_GUARD_SCRIPT="${ROOT_GUARD_DIR}/guard-root.sh"
ROOT_GUARD_PLIST="/Library/LaunchDaemons/${ROOT_GUARD_LABEL}.plist"

AGENTS=(
  com.apple.campo
  com.apple.Siri.agent
  com.apple.siriactionsd
  com.apple.sirittsd
  com.apple.siriinferenced
  com.apple.siriknowledged
  com.apple.siriappintentsd
  com.apple.SiriTTSTrainingAgent
  com.apple.assistantd
  com.apple.assistant_service
  com.apple.assistant_cdmd
  com.apple.visualintelligenced
  com.apple.intelligenceflowd
  com.apple.intelligencecontextd
  com.apple.intelligenceplatformd
  com.apple.intelligencetasksd
  com.apple.privatecloudcomputed
  com.apple.textunderstandingd
  com.apple.callintelligenced
  com.apple.generativeexperiencesd
  com.apple.ModelCatalogAgent
  com.apple.GenerativeFunctions.agentstored
)

# System-domain daemons (require SIP OFF to disable persistently)
NUCLEAR_DAEMONS=(
  com.apple.modelmanagerd
  com.apple.modelcatalogd
)

# Includes known respawning leftovers (XPC / appex), not only LaunchAgents
PROCESS_PATTERN='siri|TGOnDevice|visualintelligence|textunderstanding|ANECompiler|intelligenceflow|intelligencecontext|intelligenceplatform|intelligencetask|privatecloud|assistantd|assistant_service|Siri AI|generativeexperiences|modelcatalog|AppleIntelligence|modelmanagerd|GenerativeExperiencesSafety|IntelligencePlatformCompute|SiriAUSP|SiriSetupSettings|generativeassistant|GenerativeFunctions'

die() { echo "error: $*" >&2; exit 1; }

need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script only runs on macOS."
}

match_lines() {
  grep -Ei "$1" || true
}

# --- colors / animation -------------------------------------------------

supports_anim() {
  [[ -t 1 ]] && [[ "${DISABLE_APPLE_AI_NO_ANIM:-0}" != "1" ]]
}

if supports_anim && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_DIM="$(tput dim)"
  C_BOLD="$(tput bold)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_CYAN="$(tput setaf 6)"
  C_WHITE="$(tput setaf 7)"
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""
  C_YELLOW=""; C_CYAN=""; C_WHITE=""
fi

hide_cursor() { supports_anim && printf '\033[?25l' >&2 || true; }
show_cursor() { printf '\033[?25h' >&2 2>/dev/null || true; }
trap 'show_cursor' EXIT INT TERM

sleep_frame() {
  # macOS /bin/sleep supports fractional seconds; never use a hanging select()
  /bin/sleep "$1" 2>/dev/null || /bin/sleep 1
}

ai_process_table() {
  ps -axo rss=,pid=,comm= \
    | match_lines "$PROCESS_PATTERN" \
    | awk '{
        rss=$1; pid=$2;
        $1=$2=""; sub(/^ +/,"");
        n=split($0,a,"/");
        printf "%8.1f MB  %6s  %s\n", rss/1024, pid, a[n]
      }' \
    | sort -nr
}

ai_rss_mb() {
  ps -axo rss=,comm= \
    | match_lines "$PROCESS_PATTERN" \
    | awk '{s+=$1} END {printf "%.1f", (s?s:0)/1024}'
}

ai_proc_count() {
  ps -axo comm= | match_lines "$PROCESS_PATTERN" | wc -l | tr -d ' '
}

disabled_agent_count() {
  launchctl print-disabled "${GUI_DOMAIN}" 2>/dev/null \
    | match_lines 'campo|siri|intelligence|assistant|privatecloud|textunderstanding|visual|generative' \
    | wc -l | tr -d ' '
}

prefs_disabled() {
  local v
  v="$(defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null || echo unset)"
  [[ "$v" == "0" ]]
}

free_ram_mb() {
  local page_size
  page_size="$(pagesize 2>/dev/null || echo 16384)"
  vm_stat | awk -v ps="$page_size" '/Pages free/ {gsub(/\./,""); printf "%.0f", $3*ps/1024/1024}'
}

confirm() {
  local prompt="$1" reply
  # Always read from the real terminal (avoids "stuck" when stdin is weird)
  show_cursor
  printf "\n%s%s%s " "$C_YELLOW" "$prompt" "$C_RESET"
  printf "%s[y/N]%s " "$C_BOLD" "$C_RESET"
  if ! read -r reply </dev/tty; then
    echo
    return 1
  fi
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

ask_line() {
  local prompt="$1" reply
  show_cursor
  # Prompt on stderr so $(ask_line) only captures the answer
  printf "%s%s%s " "$C_CYAN" "$prompt" "$C_RESET" >&2
  if ! read -r reply </dev/tty; then
    printf '\n' >&2
    reply=""
  fi
  # Trim CR/whitespace (Terminal / paste safety)
  reply="${reply//$'\r'/}"
  reply="${reply#"${reply%%[![:space:]]*}"}"
  reply="${reply%"${reply##*[![:space:]]}"}"
  printf '%s' "$reply"
}

progress_bar() {
  local pct="$1" width="${2:-28}" filled empty i
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  printf "["
  for ((i=0; i<filled; i++)); do printf "#"; done
  for ((i=0; i<empty; i++)); do printf "-"; done
  printf "] %3d%%" "$pct"
}

# Short, non-blocking animation — no cursor-up tricks (those looked "stuck")
animate_reclaim() {
  local level="${1:-medium}" before="${2:-0}"
  if ! supports_anim; then
    echo "-> Applying ${level}..."
    return 0
  fi

  printf "\n%s== disable-apple-ai v%s ==%s\n" "$C_CYAN" "$VERSION" "$C_RESET"
  printf "%s   level: %s | baseline AI RAM: %s MB%s\n\n" "$C_DIM" "$level" "$before" "$C_RESET"

  printf "%s  [oooo] APPLE AI  ONLINE%s\n" "$C_CYAN" "$C_RESET"
  sleep_frame 0.08
  printf "%s  [OOoo] APPLE AI  DRAINING%s\n" "$C_YELLOW" "$C_RESET"
  sleep_frame 0.08
  printf "%s  [XX--] APPLE AI  KILLING%s\n" "$C_RED" "$C_RESET"
  sleep_frame 0.08
  printf "%s  [----] APPLE AI  OFFLINE%s\n\n" "$C_GREEN" "$C_RESET"

  local labels=(
    "locking prefs"
    "disabling agents"
    "stopping processes"
    "finishing"
  )
  local i pct
  for i in "${!labels[@]}"; do
    pct=$(( (i + 1) * 100 / ${#labels[@]} ))
    printf "  %s%s%s  %s\n" \
      "$C_GREEN" "$(progress_bar "$pct")" "$C_RESET" \
      "${labels[$i]}"
    sleep_frame 0.06
  done
  printf "\n"
  show_cursor
}

animate_demo() {
  need_macos
  local before
  before="$(ai_rss_mb)"
  animate_reclaim "demo" "$before"
  printf "%s★ animation complete%s — run disable soft|medium|hard to actually apply.\n" "$C_CYAN" "$C_RESET"
}

print_verdict() {
  local rss count disabled
  rss="$(ai_rss_mb)"
  count="$(ai_proc_count)"
  disabled="$(disabled_agent_count)"

  echo "=== Verdict ==="
  if prefs_disabled; then
    echo "  ${C_GREEN}✓${C_RESET} Prefs: Assistant disabled (soft layer OK)"
  else
    echo "  ${C_RED}✗${C_RESET} Prefs: Assistant still enabled / unset"
  fi

  if [[ "$disabled" -ge 5 ]]; then
    echo "  ${C_GREEN}✓${C_RESET} Agents: ${disabled} AI-related LaunchAgents disabled"
  elif [[ "$disabled" -ge 1 ]]; then
    echo "  ${C_YELLOW}~${C_RESET} Agents: only ${disabled} disabled (try medium/hard)"
  else
    echo "  ${C_RED}✗${C_RESET} Agents: none disabled (soft only, or disable failed)"
  fi

  if guard_is_installed; then
    echo "  ${C_GREEN}✓${C_RESET} Guard: user installed (re-kills leftovers every ${GUARD_INTERVAL_SEC}s)"
  else
    echo "  ${C_YELLOW}~${C_RESET} Guard: user not installed (leftover XPCs can respawn)"
  fi

  if root_guard_is_installed; then
    echo "  ${C_GREEN}✓${C_RESET} Guard: root installed (kills ANECompiler / root AI XPCs)"
  else
    echo "  ${C_YELLOW}~${C_RESET} Guard: root not installed (root leftovers need: $0 guard-install)"
  fi

  # Rough thresholds — on a loaded Mac, “working” means big drop
  if awk "BEGIN {exit !($rss < 150)}"; then
    echo "  ${C_GREEN}✓${C_RESET} RAM: AI-ish processes ~${rss} MB (${count} procs) — looking good"
    echo ""
    echo "${C_GREEN}${C_BOLD}RESULT: YES — Apple AI is largely down.${C_RESET}"
  elif awk "BEGIN {exit !($rss < 500)}"; then
    echo "  ${C_YELLOW}~${C_RESET} RAM: AI-ish processes ~${rss} MB (${count} procs) — partial"
    echo ""
    echo "${C_YELLOW}${C_BOLD}RESULT: PARTIAL — prefs may be set, but daemons still hold RAM.${C_RESET}"
    echo "  Next: ./disable-apple-ai.sh disable hard"
    echo "  Then reboot and run: ./disable-apple-ai.sh status"
  else
    echo "  ${C_RED}✗${C_RESET} RAM: AI-ish processes still ~${rss} MB (${count} procs)"
    echo ""
    echo "${C_RED}${C_BOLD}RESULT: NO — Apple AI is still active in memory.${C_RESET}"
    echo "  Next: ./disable-apple-ai.sh disable medium   (or hard)"
    echo "  Then reboot and run: ./disable-apple-ai.sh status"
  fi
}

# --- SIP / nuclear ------------------------------------------------------

sip_status_text() {
  csrutil status 2>/dev/null || echo "unknown"
}

sip_is_disabled() {
  sip_status_text | grep -qi 'disabled'
}

print_sip_recovery_howto() {
  cat <<EOF

${C_BOLD}${C_RED}NUCLEAR requires System Integrity Protection (SIP) to be OFF.${C_RESET}

SIP is software-only — it will ${C_BOLD}not${C_RESET} damage your hardware.
It ${C_BOLD}does${C_RESET} weaken OS security until you turn it back on.

How to disable SIP (Apple Silicon / Intel):
  1. Shut down your Mac.
  2. Apple Silicon: hold power until startup options → Terminal
     (or Recovery). Intel: power on and hold Cmd+R → Terminal.
  3. In Recovery Terminal run:
       csrutil disable
  4. Reboot into macOS.
  5. Re-run:
       $0 nuclear

To turn SIP back on later (recommended if you undo nuclear):
  Recovery Terminal →  csrutil enable  → reboot
  Then:  $0 nuclear-undo

Current SIP status: $(sip_status_text)

EOF
}

confirm_nuclear() {
  cat <<EOF

${C_BOLD}${C_RED}╔══════════════════════════════════════════════════════╗
║  NUCLEAR OPTION — READ BEFORE CONTINUING             ║
╚══════════════════════════════════════════════════════╝${C_RESET}

This will:
  • Require SIP to stay ${C_BOLD}disabled${C_RESET} (weaker security)
  • Disable system daemons ${C_BOLD}modelmanagerd${C_RESET} + ${C_BOLD}modelcatalogd${C_RESET}
  • Also apply medium disables (prefs + user agents + kill)
  • May break some Camera/Photos/writing/Siri ML features
  • Will ${C_BOLD}NOT${C_RESET} damage hardware

Undo later with:  $0 nuclear-undo
(and ideally re-enable SIP in Recovery)

EOF
  local reply
  reply="$(ask_line "Type NUCLEAR to proceed (or anything else to abort):")"
  [[ "$reply" == "NUCLEAR" ]]
}

disable_nuclear_daemons() {
  echo "→ [nuclear] Disabling system AI daemons (needs SIP off + sudo)…"
  local d
  for d in "${NUCLEAR_DAEMONS[@]}"; do
    if sudo launchctl bootout "system/${d}" 2>/dev/null; then
      echo "   booted out system/${d}"
    else
      echo "   bootout skip system/${d}"
    fi
    if sudo launchctl disable "system/${d}" 2>/dev/null; then
      echo "   disabled system/${d}"
    else
      echo "   ${C_YELLOW}disable failed system/${d}${C_RESET} (SIP still on, or unsupported)"
    fi
  done
}

enable_nuclear_daemons() {
  echo "→ [nuclear-undo] Re-enabling system AI daemons…"
  local d plist
  for d in "${NUCLEAR_DAEMONS[@]}"; do
    sudo launchctl enable "system/${d}" 2>/dev/null && echo "   enabled system/${d}" || echo "   skip enable ${d}"
    plist="/System/Library/LaunchDaemons/${d}.plist"
    if [[ -f "$plist" ]]; then
      sudo launchctl bootstrap system "$plist" 2>/dev/null || \
        sudo launchctl kickstart -k "system/${d}" 2>/dev/null || true
    fi
  done
}

cmd_nuclear() {
  need_macos
  if ! confirm_nuclear; then
    echo "Aborted — nuclear not applied."
    exit 0
  fi

  if ! sip_is_disabled; then
    print_sip_recovery_howto
    die "SIP is still enabled. Disable SIP in Recovery, reboot, then re-run: $0 nuclear"
  fi

  echo ""
  echo "${C_GREEN}SIP is disabled — proceeding with nuclear.${C_RESET}"
  local before after
  before="$(ai_rss_mb)"
  animate_reclaim "nuclear" "$before"

  # Full user-level stack first
  write_prefs
  disable_agents
  disable_nuclear_daemons
  kill_ai_processes 1
  install_guard

  sleep 2
  after="$(ai_rss_mb)"
  echo ""
  echo "Nuclear applied."
  echo "AI-ish RSS: ${before} MB → ${after} MB"
  echo "Free RAM (approx): $(free_ram_mb) MB"
  echo "SIP: $(sip_status_text)"
  echo ""
  print_verdict
  echo ""
  echo "Keep SIP disabled for this to stick across reboot."
  echo "Undo: $0 nuclear-undo   then Recovery: csrutil enable"
}

cmd_nuclear_undo() {
  need_macos
  if [[ -r /dev/tty ]]; then
    confirm "Undo nuclear (re-enable modelmanagerd + user AI agents)?" || { echo "Aborted."; exit 0; }
  fi
  uninstall_guard
  enable_nuclear_daemons
  enable_agents
  clear_prefs
  echo ""
  echo "Nuclear undo attempted."
  echo "Strongly recommended: Recovery → csrutil enable → reboot"
  echo "SIP now: $(sip_status_text)"
}

cmd_nuclear_status() {
  need_macos
  echo "=== Nuclear / SIP ==="
  echo "SIP: $(sip_status_text)"
  echo ""
  echo "System daemons (nuclear targets):"
  local d
  for d in "${NUCLEAR_DAEMONS[@]}"; do
    if launchctl print-disabled system 2>/dev/null | grep -q "\"${d}\" => disabled"; then
      echo "  ${C_GREEN}disabled${C_RESET}  system/${d}"
    else
      # print may fail without root; check if process running
      if pgrep -x modelmanagerd >/dev/null 2>&1 && [[ "$d" == "com.apple.modelmanagerd" ]]; then
        echo "  ${C_YELLOW}running${C_RESET}   system/${d} (modelmanagerd alive)"
      else
        echo "  unknown/enabled  system/${d}"
      fi
    fi
  done
  echo ""
  if sip_is_disabled; then
    echo "Nuclear ${C_GREEN}possible${C_RESET} (SIP off). Run: $0 nuclear"
  else
    echo "Nuclear ${C_RED}blocked${C_RESET} until SIP is disabled in Recovery."
  fi
}

# CLI equivalent of System Settings → Siri → Turn Off Siri (confirm).
# Apple does not ship a public `siri --off` binary; the UI writes these prefs.
turn_off_siri_cli() {
  echo "→ CLI: Turn Off Siri (same prefs System Settings writes)…"

  # Master switch — this is what "Turn Off Siri" primarily toggles
  defaults write com.apple.assistant.support "Assistant Enabled" -bool false

  # Decline / hide entry points
  defaults write com.apple.Siri StatusMenuVisible -bool false
  defaults write com.apple.Siri UserHasDeclinedEnable -bool true 2>/dev/null || true
  defaults write com.apple.Siri VoiceTriggerUserEnabled -bool false 2>/dev/null || true
  defaults write com.apple.Siri LockscreenEnabled -bool false 2>/dev/null || true
  defaults write com.apple.assistantd InvokedAtLogin -bool false 2>/dev/null || true

  # Refresh prefs daemons so Settings UI reflects the change
  killall -HUP cfprefsd 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true

  echo "   Assistant Enabled = $(defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null || echo "?")"
}

# Optional: drive the real Settings buttons (needs Accessibility permission for Terminal).
# Fast path only — never walks the whole UI tree (that hangs).
turn_off_siri_ui() {
  echo "→ UI: trying System Settings → Turn Off Siri (needs Accessibility)…"
  if ! command -v osascript >/dev/null 2>&1; then
    echo "   skip (no osascript)"
    return 0
  fi

  open "x-apple.systempreferences:com.apple.Siri-Settings.extension" 2>/dev/null || \
    open -b com.apple.systempreferences 2>/dev/null || true

  # Timeout wrapper: UI scripting must not hang the script
  local result
  result="$(
    perl -e 'alarm 12; exec @ARGV' osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Settings" to activate
delay 1.0
tell application "System Events"
  if not (exists process "System Settings") then return "NO_SETTINGS"
  tell process "System Settings"
    set frontmost to true
    delay 0.6
    -- Click any "Turn Off Siri" control if present (may need scroll / already off)
    try
      click (first button of window 1 whose name is "Turn Off Siri")
      delay 0.6
      -- Confirm sheet
      try
        click (first button of sheet 1 of window 1 whose name is "Turn Off Siri")
      end try
      try
        click (first button of window 1 whose name is "Turn Off Siri")
      end try
      return "CLICKED"
    on error
      -- Already off, or button label differs / needs Accessibility
      return "BUTTON_NOT_FOUND"
    end try
  end tell
end tell
APPLESCRIPT
  )"

  case "${result:-}" in
    CLICKED) echo "   clicked Turn Off Siri in System Settings" ;;
    BUTTON_NOT_FOUND)
      echo "   button not found (already off, or enable:"
      echo "   System Settings → Privacy & Security → Accessibility → allow Terminal)"
      ;;
    *) echo "   UI automation skipped/timed out (CLI prefs still applied)" ;;
  esac
}

write_prefs() {
  echo "→ [soft] Writing preference disables…"

  # Official Siri off (CLI) — replaces the Settings checklist item
  turn_off_siri_cli

  local domain="com.apple.applicationaccess"
  defaults write "$domain" allowAssistant -bool false
  defaults write "$domain" allowWritingTools -bool false
  defaults write "$domain" allowMailSummary -bool false
  defaults write "$domain" allowMailSmartReplies -bool false
  defaults write "$domain" allowNotesTranscriptionSummary -bool false
  defaults write "$domain" allowGenmoji -bool false
  defaults write "$domain" allowImagePlayground -bool false
  defaults write "$domain" allowImageWand -bool false
  defaults write "$domain" allowPersonalizedHandshake -bool false
  defaults write "$domain" allowSafariSummary -bool false
  defaults write "$domain" allowAppleIntelligenceReport -bool false
  defaults write "$domain" allowExternalIntelligenceIntegrations -bool false
  defaults write "$domain" allowExternalIntelligenceIntegrationsSignIn -bool false
  defaults write "$domain" allowIntelligenceTextCompletion -bool false
}

clear_prefs() {
  echo "→ Removing preference disables…"
  defaults delete com.apple.assistant.support "Assistant Enabled" 2>/dev/null || true
  defaults delete com.apple.applicationaccess 2>/dev/null || true
  defaults write com.apple.Siri StatusMenuVisible -bool true 2>/dev/null || true
}

# --- medium -------------------------------------------------------------

disable_agents() {
  echo "→ [medium] Disabling + booting out user-domain AI/Siri agents…"
  local a
  for a in "${AGENTS[@]}"; do
    if launchctl disable "${GUI_DOMAIN}/${a}" 2>/dev/null; then
      echo "   disabled ${a}"
    else
      echo "   skip disable ${a}"
    fi
    if launchctl bootout "${GUI_DOMAIN}/${a}" 2>/dev/null; then
      echo "   booted out ${a}"
    fi
  done
}

enable_agents() {
  echo "→ Re-enabling user-domain AI/Siri agents…"
  local a
  for a in "${AGENTS[@]}"; do
    launchctl enable "${GUI_DOMAIN}/${a}" 2>/dev/null && echo "   enabled ${a}" || echo "   skip enable ${a}"
    local plist="/System/Library/LaunchAgents/${a}.plist"
    if [[ -f "$plist" ]]; then
      launchctl bootstrap "${GUI_DOMAIN}" "$plist" 2>/dev/null || \
        launchctl kickstart -k "${GUI_DOMAIN}/${a}" 2>/dev/null || true
    fi
  done
}

kill_ai_processes() {
  local use_sudo="${1:-0}"
  echo "→ Stopping running Apple AI / Siri processes…"
  local pids
  pids="$(ps -axo pid=,comm= | match_lines "$PROCESS_PATTERN" | awk '{print $1}')"
  if [[ -z "${pids}" ]]; then
    echo "   (none running)"
    return 0
  fi
  echo "   PIDs: $(echo "$pids" | tr '\n' ' ')"
  # Kill one PID at a time (avoids "illegal process id: 1 2 3" quoting bugs)
  local pid
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null || true
  done <<< "$pids"
  sleep 1
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    kill -9 "$pid" 2>/dev/null || true
  done <<< "$pids"

  local left
  left="$(ps -axo pid=,comm= | match_lines "$PROCESS_PATTERN" | awk '{print $1}')"
  if [[ -n "${left}" ]]; then
    if [[ "$use_sudo" == "1" ]]; then
      echo "→ [hard] sudo kill remaining…"
      while read -r pid; do
        [[ -z "$pid" ]] && continue
        sudo kill -9 "$pid" 2>/dev/null || true
      done <<< "$left"
    else
      echo "   some processes survived (often system-protected)."
      echo "   choose hard / pass --sudo to retry with sudo."
    fi
  fi
}

# --- guard (keep leftovers dead) ----------------------------------------

guard_is_installed() {
  [[ -f "$GUARD_PLIST" ]] && [[ -f "$GUARD_SCRIPT" ]]
}

root_guard_is_installed() {
  [[ -f "$ROOT_GUARD_PLIST" ]] && [[ -f "$ROOT_GUARD_SCRIPT" ]]
}

write_guard_script() {
  mkdir -p "$GUARD_DIR"
  # Embedded pattern so the LaunchAgent does not depend on Desktop path
  cat > "$GUARD_SCRIPT" <<EOF
#!/bin/bash
# Auto-generated by disable-apple-ai.sh — re-kill on-demand Apple AI leftovers
set -euo pipefail
PATTERN='${PROCESS_PATTERN}'
match() { grep -Ei "\$PATTERN" || true; }
pids="\$(ps -axo pid=,comm= | match | awk '{print \$1}')"
[[ -z "\${pids}" ]] && exit 0
while read -r pid; do
  [[ -z "\$pid" ]] && continue
  kill "\$pid" 2>/dev/null || true
done <<< "\$pids"
sleep 0.4
while read -r pid; do
  [[ -z "\$pid" ]] && continue
  kill -9 "\$pid" 2>/dev/null || true
done <<< "\$pids"
exit 0
EOF
  chmod 755 "$GUARD_SCRIPT"
}

write_guard_plist() {
  mkdir -p "$(dirname "$GUARD_PLIST")"
  cat > "$GUARD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${GUARD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${GUARD_SCRIPT}</string>
  </array>
  <key>StartInterval</key>
  <integer>${GUARD_INTERVAL_SEC}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${GUARD_DIR}/guard.out.log</string>
  <key>StandardErrorPath</key>
  <string>${GUARD_DIR}/guard.err.log</string>
</dict>
</plist>
EOF
}

install_root_guard() {
  echo "→ [guard-root] Installing root LaunchDaemon (every ${GUARD_INTERVAL_SEC}s, needs admin)…"

  # Stage files in a temp dir, then install with elevated privileges
  local tmp
  tmp="$(mktemp -d)"
  local staged_script="${tmp}/guard-root.sh"
  local staged_plist="${tmp}/${ROOT_GUARD_LABEL}.plist"

  cat > "$staged_script" <<EOF
#!/bin/bash
# Auto-generated by disable-apple-ai.sh — root re-kill for Apple AI leftovers
set -euo pipefail
PATTERN='${PROCESS_PATTERN}'
match() { grep -Ei "\$PATTERN" || true; }
pids="\$(ps -axo pid=,comm= | match | awk '{print \$1}')"
[[ -z "\${pids}" ]] && exit 0
while read -r pid; do
  [[ -z "\$pid" ]] && continue
  kill "\$pid" 2>/dev/null || true
done <<< "\$pids"
sleep 0.4
while read -r pid; do
  [[ -z "\$pid" ]] && continue
  kill -9 "\$pid" 2>/dev/null || true
done <<< "\$pids"
exit 0
EOF
  chmod 755 "$staged_script"

  cat > "$staged_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${ROOT_GUARD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ROOT_GUARD_SCRIPT}</string>
  </array>
  <key>StartInterval</key>
  <integer>${GUARD_INTERVAL_SEC}</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${ROOT_GUARD_DIR}/guard-root.out.log</string>
  <key>StandardErrorPath</key>
  <string>${ROOT_GUARD_DIR}/guard-root.err.log</string>
</dict>
</plist>
EOF

  local install_cmd
  install_cmd="/bin/mkdir -p '${ROOT_GUARD_DIR}' && /bin/cp '${staged_script}' '${ROOT_GUARD_SCRIPT}' && /bin/chmod 755 '${ROOT_GUARD_SCRIPT}' && /bin/cp '${staged_plist}' '${ROOT_GUARD_PLIST}' && /bin/chmod 644 '${ROOT_GUARD_PLIST}' && (/bin/launchctl bootout system/${ROOT_GUARD_LABEL} 2>/dev/null || true) && (/bin/launchctl bootstrap system '${ROOT_GUARD_PLIST}' 2>/dev/null || /bin/launchctl load -w '${ROOT_GUARD_PLIST}' 2>/dev/null || true) && (/bin/bash '${ROOT_GUARD_SCRIPT}' 2>/dev/null || true)"

  if run_elevated "$install_cmd"; then
    echo "   loaded ${ROOT_GUARD_LABEL}"
  else
    echo "   ${C_YELLOW}root guard install failed / cancelled${C_RESET}"
  fi
  rm -rf "$tmp"
}

uninstall_root_guard() {
  echo "→ [guard-root] Removing root LaunchDaemon…"
  local uninstall_cmd
  uninstall_cmd="(/bin/launchctl bootout system/${ROOT_GUARD_LABEL} 2>/dev/null || true); (/bin/launchctl unload -w '${ROOT_GUARD_PLIST}' 2>/dev/null || true); /bin/rm -f '${ROOT_GUARD_PLIST}' '${ROOT_GUARD_SCRIPT}' 2>/dev/null || true; /bin/rmdir '${ROOT_GUARD_DIR}' 2>/dev/null || true"
  if run_elevated "$uninstall_cmd"; then
    echo "   root guard removed"
  else
    echo "   ${C_YELLOW}root guard uninstall failed / cancelled${C_RESET}"
  fi
}

# Prefer passwordless sudo; otherwise macOS GUI admin prompt (works from Cursor).
run_elevated() {
  local cmd="$1"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo /bin/bash -c "$cmd"
    return $?
  fi
  if command -v osascript >/dev/null 2>&1; then
    local escaped
    escaped="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    osascript -e "do shell script \"${escaped}\" with administrator privileges" >/dev/null
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo /bin/bash -c "$cmd"
    return $?
  fi
  return 1
}

install_guard() {
  echo "→ [guard] Installing leftover re-kill LaunchAgent (every ${GUARD_INTERVAL_SEC}s)…"
  write_guard_script
  # Unload if already present, then load fresh
  launchctl bootout "${GUI_DOMAIN}/${GUARD_LABEL}" 2>/dev/null || true
  write_guard_plist
  if launchctl bootstrap "${GUI_DOMAIN}" "$GUARD_PLIST" 2>/dev/null; then
    echo "   loaded ${GUARD_LABEL}"
  else
    # Older / already loaded path
    launchctl load -w "$GUARD_PLIST" 2>/dev/null || true
    launchctl enable "${GUI_DOMAIN}/${GUARD_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "${GUI_DOMAIN}/${GUARD_LABEL}" 2>/dev/null || true
    echo "   installed ${GUARD_LABEL} (best-effort load)"
  fi
  # Immediate pass
  /bin/bash "$GUARD_SCRIPT" 2>/dev/null || true
  install_root_guard
}

uninstall_guard() {
  echo "→ [guard] Removing leftover re-kill LaunchAgent…"
  launchctl bootout "${GUI_DOMAIN}/${GUARD_LABEL}" 2>/dev/null || true
  launchctl unload -w "$GUARD_PLIST" 2>/dev/null || true
  rm -f "$GUARD_PLIST" 2>/dev/null || true
  rm -f "$GUARD_SCRIPT" 2>/dev/null || true
  echo "   guard removed"
  uninstall_root_guard
}

cmd_guard_install() {
  need_macos
  install_guard
  echo ""
  print_verdict
}

cmd_guard_uninstall() {
  need_macos
  uninstall_guard
  echo ""
  print_verdict
}

cmd_guard_status() {
  need_macos
  echo "=== Guard (user) ==="
  echo "Label:    ${GUARD_LABEL}"
  echo "Interval: ${GUARD_INTERVAL_SEC}s"
  echo "Plist:    ${GUARD_PLIST}"
  echo "Script:   ${GUARD_SCRIPT}"
  if guard_is_installed; then
    echo "State:    ${C_GREEN}installed${C_RESET}"
    launchctl print "${GUI_DOMAIN}/${GUARD_LABEL}" 2>/dev/null | match_lines 'state =|pid =|runs =' | sed 's/^/  /' || true
  else
    echo "State:    ${C_YELLOW}not installed${C_RESET}"
  fi
  echo ""
  echo "=== Guard (root) ==="
  echo "Label:    ${ROOT_GUARD_LABEL}"
  echo "Interval: ${GUARD_INTERVAL_SEC}s"
  echo "Plist:    ${ROOT_GUARD_PLIST}"
  echo "Script:   ${ROOT_GUARD_SCRIPT}"
  if root_guard_is_installed; then
    echo "State:    ${C_GREEN}installed${C_RESET}"
    launchctl print "system/${ROOT_GUARD_LABEL}" 2>/dev/null | match_lines 'state =|pid =|runs =' | sed 's/^/  /' || true
  else
    echo "State:    ${C_YELLOW}not installed${C_RESET}"
  fi
}

cmd_guard_tick() {
  need_macos
  # Used by tests / manual; LaunchAgent calls GUARD_SCRIPT directly
  kill_ai_processes 0
}

# --- levels -------------------------------------------------------------

explain_levels() {
  cat <<EOF

Aggressiveness levels (you choose):

  1) soft     Prefs only — safest to share / try first
  2) medium   Prefs + disable LaunchAgents + kill + guard   ${C_GREEN}(recommended)${C_RESET}
  3) hard     Medium + sudo kill + guard
  4) nuclear  ${C_RED}SIP must be OFF${C_RESET} — disables modelmanagerd system-wide + guard

EOF
}

resolve_level() {
  local arg="${1:-}"
  case "$arg" in
    soft|1)     echo soft ;;
    medium|2)   echo medium ;;
    hard|3)     echo hard ;;
    nuclear|4)  echo nuclear ;;
    "")         echo "" ;;
    *)          die "unknown level: $arg (use soft|medium|hard|nuclear)" ;;
  esac
}

pick_level_interactive() {
  explain_levels >&2
  local choice
  choice="$(ask_line "Choose level [1 soft / 2 medium / 3 hard / 4 nuclear] (default 2):")"
  case "${choice:-2}" in
    1|soft|s|S)       echo soft ;;
    2|medium|m|M|"")  echo medium ;;
    3|hard|h|H)       echo hard ;;
    4|nuclear|n|N)    echo nuclear ;;
    *)                die "invalid choice: $choice" ;;
  esac
}

apply_level() {
  local level="$1"
  if [[ "$level" == "nuclear" ]]; then
    cmd_nuclear
    return
  fi
  local before after
  before="$(ai_rss_mb)"

  animate_reclaim "$level" "$before"

  case "$level" in
    soft)
      write_prefs
      ;;
    medium)
      write_prefs
      disable_agents
      kill_ai_processes 0
      install_guard
      ;;
    hard)
      write_prefs
      disable_agents
      kill_ai_processes 1
      install_guard
      ;;
    *) die "internal: bad level $level" ;;
  esac

  sleep 2
  after="$(ai_rss_mb)"
  echo ""
  echo "Level applied: ${level}"
  echo "AI-ish RSS: ${before} MB → ${after} MB"
  echo "Free RAM (approx): $(free_ram_mb) MB"
  echo ""
  print_verdict
  echo ""
  echo "Siri master switch: already applied via CLI (Assistant Enabled=false)."
  echo "Optional UI confirm:  $0 turn-off-siri-ui"
  echo "Nuclear (SIP off):    $0 nuclear"
  echo "Guard leftovers:      $0 guard-status"
  echo "Then reboot and run:  $0 status"
}

# --- commands -----------------------------------------------------------

cmd_status() {
  need_macos
  echo "disable-apple-ai ${VERSION}"
  echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "SIP: $(sip_status_text)"
  echo ""
  echo "=== Prefs ==="
  echo -n "Assistant Enabled: "
  defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null || echo "(unset)"
  echo ""
  echo "=== LaunchAgents disabled (AI-related) ==="
  local disabled
  disabled="$(launchctl print-disabled "${GUI_DOMAIN}" 2>/dev/null \
    | match_lines 'campo|siri|intelligence|assistant|privatecloud|textunderstanding|visual|generative|ModelCatalog|GenerativeFunctions' \
    | sed 's/^/  /')"
  if [[ -z "$disabled" ]]; then
    echo "  (none listed)"
  else
    echo "$disabled"
  fi
  echo ""
  cmd_nuclear_status
  echo ""
  cmd_guard_status
  echo ""
  echo "=== Apple AI processes ==="
  local table
  table="$(ai_process_table)"
  if [[ -z "$table" ]]; then
    echo "  (none)"
  else
    echo "$table"
  fi
  echo ""
  echo "AI-ish RSS total: $(ai_rss_mb) MB"
  echo "Free RAM (approx): $(free_ram_mb) MB"
  echo ""
  print_verdict
}

cmd_disable() {
  need_macos
  local level had_arg=0
  if [[ -n "${1:-}" ]]; then
    had_arg=1
  fi
  level="$(resolve_level "${1:-}")"
  if [[ -z "$level" ]]; then
    if [[ ! -t 1 ]] || [[ ! -r /dev/tty ]]; then
      die "no TTY — pass a level: disable soft|medium|hard"
    fi
    level="$(pick_level_interactive)"
  fi

  echo ""
  echo "About to apply level: ${level}"
  # Only confirm when the user did not already pass soft|medium|hard
  if [[ "$had_arg" -eq 0 ]] && [[ -r /dev/tty ]]; then
    confirm "Continue?" || { echo "Aborted."; exit 0; }
  fi
  apply_level "$level"
}

cmd_kill() {
  need_macos
  local use_sudo=0
  if [[ "${1:-}" == "--sudo" || "${1:-}" == "hard" ]]; then
    use_sudo=1
  fi
  local before after
  before="$(ai_rss_mb)"
  if [[ "$use_sudo" == "1" ]]; then
    animate_reclaim "hard-kill" "$before"
  else
    animate_reclaim "kill" "$before"
  fi
  kill_ai_processes "$use_sudo"
  sleep 1
  after="$(ai_rss_mb)"
  echo "AI-ish RSS: ${before} MB → ${after} MB"
  echo "(kill alone does not persist across reboot — use: $0 disable)"
  echo ""
  print_verdict
}

cmd_reenable() {
  need_macos
  if [[ -t 0 ]]; then
    confirm "Re-enable Apple AI prefs/agents?" || { echo "Aborted."; exit 0; }
  fi
  uninstall_guard
  clear_prefs
  enable_agents
  echo ""
  echo "Re-enabled best-effort. Use System Settings → Siri if needed."
}

cmd_menu() {
  need_macos
  cat <<EOF
${C_BOLD}${C_CYAN}disable-apple-ai${C_RESET} v${VERSION}
Persistently cut Apple Intelligence / Siri RAM (no Homebrew).

Quick verdict (AI RAM now: $(ai_rss_mb) MB) | SIP: $(sip_status_text)

What do you want to do?

  1) disable          - pick soft / medium / hard / nuclear
  2) status           - show current AI RAM / prefs + verdict
  3) reenable         - undo soft/medium/hard prefs+agents
  4) kill             - temporary process kill only
  5) turn-off-siri-ui - click Settings "Turn Off Siri" (Accessibility)
  6) nuclear          - ${C_RED}SIP OFF required${C_RESET} — disable modelmanagerd
  7) nuclear-undo     - reverse nuclear daemon disables
  8) guard-install    - keep leftover XPCs dead (every ${GUARD_INTERVAL_SEC}s)
  9) guard-uninstall  - remove leftover watchdog
  10) animate         - play the boot animation (no changes)
  11) quit

EOF
  local choice k
  choice="$(ask_line "Choice [1-11]:")"
  case "$choice" in
    1|disable) cmd_disable ;;
    2|status)  cmd_status ;;
    3|reenable) cmd_reenable ;;
    4|kill)
      echo ""
      echo "Kill options: 1) normal  2) with sudo (hard)"
      k="$(ask_line "Choice [1-2]:")"
      case "$k" in
        2) cmd_kill --sudo ;;
        *) cmd_kill ;;
      esac
      ;;
    5|turn-off-siri-ui|siri-ui)
      turn_off_siri_cli
      turn_off_siri_ui
      ;;
    6|nuclear) cmd_nuclear ;;
    7|nuclear-undo) cmd_nuclear_undo ;;
    8|guard-install|guard) cmd_guard_install ;;
    9|guard-uninstall) cmd_guard_uninstall ;;
    10|animate) animate_demo ;;
    11|q|quit|"") echo "Bye."; exit 0 ;;
    *) die "invalid choice: '${choice}' (len=${#choice})" ;;
  esac
}

cmd_selftest() {
  need_macos
  local fail=0
  echo "selftest v${VERSION}"

  printf '  AGENTS contains com.apple.campo … '
  if printf '%s\n' "${AGENTS[@]}" | grep -qx 'com.apple.campo'; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  NUCLEAR contains com.apple.modelcatalogd … '
  if printf '%s\n' "${NUCLEAR_DAEMONS[@]}" | grep -qx 'com.apple.modelcatalogd'; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  plist LaunchAgents/com.apple.campo.plist … '
  if [[ -f /System/Library/LaunchAgents/com.apple.campo.plist ]]; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  plist LaunchDaemons/com.apple.modelcatalogd.plist … '
  if [[ -f /System/Library/LaunchDaemons/com.apple.modelcatalogd.plist ]]; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  PROCESS_PATTERN matches Siri AI … '
  if echo 'Siri AI' | match_lines "$PROCESS_PATTERN" | grep -q .; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  PROCESS_PATTERN matches IntelligencePlatformComputeService … '
  if echo 'IntelligencePlatformComputeService' | match_lines "$PROCESS_PATTERN" | grep -q .; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  GUARD_LABEL set … '
  if [[ -n "$GUARD_LABEL" ]]; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  printf '  ROOT_GUARD_LABEL set … '
  if [[ -n "$ROOT_GUARD_LABEL" ]]; then
    echo OK
  else
    echo FAIL; fail=1
  fi

  if [[ "$fail" -ne 0 ]]; then
    die "selftest failed"
  fi
  echo "selftest: all checks passed"
}

usage() {
  cat <<EOF
disable-apple-ai.sh v${VERSION}
Persistently reduce Apple Intelligence / Siri RAM on macOS.
No Homebrew. Pure bash.

Interactive:
  ./disable-apple-ai.sh

Non-interactive:
  ./disable-apple-ai.sh disable soft|medium|hard|nuclear
  ./disable-apple-ai.sh status
  ./disable-apple-ai.sh reenable
  ./disable-apple-ai.sh kill [--sudo]
  ./disable-apple-ai.sh guard-install     # user + root re-kill every ${GUARD_INTERVAL_SEC}s
  ./disable-apple-ai.sh guard-uninstall
  ./disable-apple-ai.sh guard-status
  ./disable-apple-ai.sh turn-off-siri
  ./disable-apple-ai.sh turn-off-siri-ui
  ./disable-apple-ai.sh nuclear            # requires SIP off
  ./disable-apple-ai.sh nuclear-undo
  ./disable-apple-ai.sh nuclear-status
  ./disable-apple-ai.sh animate
  ./disable-apple-ai.sh selftest

Levels:
  soft     prefs only (includes CLI Turn Off Siri)
  medium   prefs + launchctl disable/bootout + kill + guard
  hard     medium + sudo kill + guard
  nuclear  ${C_RED}REQUIRES SIP DISABLED${C_RESET} — disables modelmanagerd + modelcatalogd + guard
           Does NOT damage hardware; weakens OS security while SIP is off.

Guard:
  On-demand XPCs (e.g. IntelligencePlatformComputeService) are not LaunchAgents.
  medium/hard/nuclear install:
    • user LaunchAgent  — kills user-owned leftovers
    • root LaunchDaemon — kills root leftovers (ANECompilerService); needs sudo once
  Interval override: DISABLE_APPLE_AI_GUARD_INTERVAL=15 ./disable-apple-ai.sh guard-install

Nuclear steps:
  1. Recovery Terminal:  csrutil disable  → reboot
  2. ./disable-apple-ai.sh nuclear        (type NUCLEAR to confirm)
  3. Keep SIP off for it to stick
  Undo: ./disable-apple-ai.sh nuclear-undo
        Recovery: csrutil enable → reboot

Skip animation:  DISABLE_APPLE_AI_NO_ANIM=1 ./disable-apple-ai.sh disable medium

EOF
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    if [[ -t 0 ]]; then
      cmd_menu
    else
      usage
      die "piped with no command — use: bash <(curl …) disable medium"
    fi
    return
  fi
  shift || true
  case "$cmd" in
    disable)           cmd_disable "${1:-}" ;;
    kill)              cmd_kill "${1:-}" ;;
    status)            cmd_status ;;
    reenable)          cmd_reenable ;;
    guard-install)     cmd_guard_install ;;
    guard-uninstall)   cmd_guard_uninstall ;;
    guard-status)      cmd_guard_status ;;
    guard-tick)        cmd_guard_tick ;;
    turn-off-siri)     need_macos; turn_off_siri_cli ;;
    turn-off-siri-ui)  need_macos; turn_off_siri_cli; turn_off_siri_ui ;;
    nuclear)           cmd_nuclear ;;
    nuclear-undo)      cmd_nuclear_undo ;;
    nuclear-status)    cmd_nuclear_status ;;
    animate)           animate_demo ;;
    selftest|test)     cmd_selftest ;;
    soft|medium|hard|nuclear)  cmd_disable "$cmd" ;;
    -h|--help|help)    usage ;;
    *)                 die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"