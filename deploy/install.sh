#!/bin/zsh
# Installs or restarts the T3 Bot server on this Mac: a LaunchAgent that starts it at login and restarts it if it
# stops, the `t3bot` command in ~/.local/bin, and an address the phone can reach (Tailscale Serve when Tailscale is
# connected, otherwise this Mac's address on the home network). Safe to run again; it ends with `t3bot pair`.
#
#   deploy/install.sh [--dry-run] [--lan] [--no-pair] [--label <launchd label>] [--project <name>] [--name <your name>]
#   deploy/install.sh --uninstall [--dry-run]
#
#   --dry-run    print what would be done and change nothing
#   --lan        do not use Tailscale even when it is connected
#   --no-pair    do not print the pairing code at the end
#   --project, --name   passed to `t3bot setup` when there is no config yet
#   --uninstall  stop the server and remove the LaunchAgent and the command (config, token and data stay)
#
# T3BOT_PORT, T3BOT_HOST, T3BOT_CONFIG, T3BOT_CONFIG_DIR, T3BOT_DATA_DIR, T3BOT_TOKEN_FILE and T3BOT_KEEP_DAYS set when
# this runs are written into the LaunchAgent, so the server keeps them. T3BOT_LABEL does the same as --label.
set -eu

HERE=${0:A:h}
ROOT=${HERE:h}
PORT=${T3BOT_PORT:-8809}
CONF_DIR=${T3BOT_CONFIG_DIR:-$HOME/.config/t3bot}
TOKEN_FILE=${T3BOT_TOKEN_FILE:-$CONF_DIR/token}
AGENTS=$HOME/Library/LaunchAgents
LOG=$HOME/Library/Logs/t3bot.log
DOMAIN=gui/$(id -u)
T3BOT=$ROOT/bin/t3bot

DRY=0; LAN=0; PAIR=1; UNINSTALL=0; LABEL=${T3BOT_LABEL:-}; SETUP_ARGS=()
while (( $# )); do
  case $1 in
    --dry-run) DRY=1 ;;
    --lan) LAN=1 ;;
    --no-pair) PAIR=0 ;;
    --uninstall) UNINSTALL=1 ;;
    --label) LABEL=${2:?--label needs a value}; shift ;;
    --project|--name) SETUP_ARGS+=($1 "${2:?$1 needs a value}"); shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "install.sh: unknown option $1 (see --help)"; exit 2 ;;
  esac
  shift
done

say() { print -r -- "$@" }
run() { if (( DRY )); then say "  would run: $*"; else "$@"; fi }
xml() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -rn -- "$s" }

# ---------- an install that is already there ----------
# A LaunchAgent that runs this folder's server keeps its label, so installing again never leaves two servers.
# One whose folder is gone (the repo was moved) is taken over. One that runs another folder that still exists is
# left alone: two servers would fight over the port.
FOUND_LABEL=""; OTHER=""
for p in $AGENTS/*.plist(N); do
  grep -q 'server/t3bot\.ts' "$p" 2>/dev/null || continue
  script=$(sed -n 's:.*<string>\(.*/server/t3bot\.ts\)</string>.*:\1:p' "$p" | head -1)
  if [[ $script == "$ROOT/server/t3bot.ts" || ! -e $script ]]; then
    if [[ -z $FOUND_LABEL ]]; then FOUND_LABEL=${p:t:r}; fi
  else
    OTHER="${p:t:r} (${script:h:h})"
  fi
done
GIVEN_LABEL=$LABEL
[[ -z $LABEL ]] && LABEL=${FOUND_LABEL:-com.t3bot.server}
PLIST=$AGENTS/$LABEL.plist

stop_agent() {
  launchctl print $DOMAIN/$1 >/dev/null 2>&1 || return 0
  run launchctl bootout $DOMAIN/$1 || true
  (( DRY )) && return 0
  for i in {1..25}; do launchctl print $DOMAIN/$1 >/dev/null 2>&1 || return 0; sleep 0.2; done
}

# ---------- uninstall ----------
if (( UNINSTALL )); then
  if [[ ! -e $PLIST ]]; then say "No T3 Bot LaunchAgent is installed for this folder. Nothing to remove."; exit 0; fi
  say "Removing the T3 Bot server ($LABEL)"
  stop_agent $LABEL
  run rm -f $PLIST
  [[ -L $HOME/.local/bin/t3bot && ${$(readlink $HOME/.local/bin/t3bot):A} == ${T3BOT:A} ]] && run rm -f $HOME/.local/bin/t3bot
  say "Done. Your config, token and data are still in ${CONF_DIR/#$HOME/~} and ~/.local/share/t3bot."
  say "If Tailscale served it: tailscale serve --https=$PORT off"
  exit 0
fi

if [[ -n $OTHER && -z $GIVEN_LABEL && -z $FOUND_LABEL ]]; then
  print -u2 "T3 Bot is already installed from another folder: $OTHER."
  print -u2 "To run it from this folder instead, take over its LaunchAgent: deploy/install.sh --label ${OTHER%% *}"
  exit 1
fi

# ---------- bun ----------
BUN=""
for b in "$(command -v bun 2>/dev/null || true)" $HOME/.bun/bin/bun /opt/homebrew/bin/bun /usr/local/bin/bun; do
  [[ -n $b && -x $b ]] && { BUN=$b; break }
done
if [[ -z $BUN ]]; then
  print -u2 "bun was not found. Install it (https://bun.sh), then run this again."
  exit 1
fi

(( DRY )) && { say "Dry run: nothing is changed."; say }
say "T3 Bot server"
say "  folder   ${ROOT/#$HOME/~}"
kept=""; [[ $LABEL == $FOUND_LABEL ]] && kept=" (already installed, kept)"
say "  label    $LABEL$kept"
say "  port     $PORT"

# ---------- config folder and token ----------
if [[ ! -d $CONF_DIR ]]; then run mkdir -p $CONF_DIR; fi
run chmod 700 $CONF_DIR
if [[ ! -s $TOKEN_FILE ]]; then
  if (( DRY )); then say "  would create a token in ${TOKEN_FILE/#$HOME/~} (mode 600)"
  else ( umask 077; openssl rand -hex 24 > $TOKEN_FILE ); chmod 600 $TOKEN_FILE; fi
fi

# ---------- how the phone reaches it ----------
TS=""
for t in "$(command -v tailscale 2>/dev/null || true)" /usr/local/bin/tailscale /opt/homebrew/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  [[ -n $t && -x $t ]] && { TS=$t; break }
done
MODE=lan
if (( ! LAN )) && [[ -n $TS ]] && $TS status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then MODE=tailscale; fi

if [[ $MODE == tailscale ]]; then
  say "  phone    through Tailscale (HTTPS, works away from home)"
  if (( DRY )); then say "  would run: $TS serve --bg --https=$PORT http://127.0.0.1:$PORT"
  else
    # Serve can wait for an approval in the browser the first time; do not hang on it.
    $TS serve --bg --https=$PORT http://127.0.0.1:$PORT >/dev/null 2>$CONF_DIR/.serve.err &
    spid=$!; ok=0
    for i in {1..40}; do kill -0 $spid 2>/dev/null || { wait $spid && ok=1; break }; sleep 0.5; done
    if (( ! ok )); then
      kill $spid 2>/dev/null || true
      say "  Tailscale Serve did not start:"
      sed 's/^/    /' $CONF_DIR/.serve.err 2>/dev/null | head -6
      say "  Using the home network for now. Once Serve is allowed on your tailnet, run this again."
      MODE=lan
    fi
    rm -f $CONF_DIR/.serve.err
  fi
fi
HOST_ENV=${T3BOT_HOST:-}
if [[ $MODE == lan ]]; then
  [[ -z $HOST_ENV ]] && HOST_ENV=0.0.0.0
  say "  phone    over your home network, plain http"
  say "           Works while the phone is on the same Wi-Fi. Anyone on that network could read the traffic,"
  say "           so use it at home only. With Tailscale (free for personal use) connected on this Mac and"
  say "           the phone, run this again: the phone then reaches the server over HTTPS from anywhere."
fi

# ---------- the LaunchAgent ----------
path_list=(${BUN:h} /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin $HOME/.local/bin)
typeset -U path_list
env_keys=(PATH T3BOT_LOG_FILE); env_vals=(${(j.:.)path_list} $LOG)
[[ -n $HOST_ENV ]] && { env_keys+=(T3BOT_HOST); env_vals+=($HOST_ENV) }
for k in T3BOT_PORT T3BOT_CONFIG T3BOT_CONFIG_DIR T3BOT_DATA_DIR T3BOT_TOKEN_FILE T3BOT_KEEP_DAYS; do
  [[ -n ${(P)k:-} ]] && { env_keys+=($k); env_vals+=(${(P)k}) }
done
plist() {
  print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
  print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  print -r -- '<plist version="1.0"><dict>'
  print -r -- "  <key>Label</key><string>$(xml $LABEL)</string>"
  print -r -- "  <key>ProgramArguments</key><array><string>$(xml $BUN)</string><string>$(xml $ROOT/server/t3bot.ts)</string></array>"
  print -r -- '  <key>EnvironmentVariables</key><dict>'
  for i in {1..$#env_keys}; do print -r -- "    <key>$env_keys[i]</key><string>$(xml $env_vals[i])</string>"; done
  print -r -- '  </dict>'
  print -r -- '  <key>RunAtLoad</key><true/>'
  print -r -- '  <key>KeepAlive</key><true/>'
  print -r -- '  <key>ThrottleInterval</key><integer>10</integer>'
  print -r -- "  <key>StandardOutPath</key><string>$(xml $LOG)</string>"
  print -r -- "  <key>StandardErrorPath</key><string>$(xml $LOG)</string>"
  print -r -- '</dict></plist>'
}

# The server was once called Crew: a LaunchAgent from then that still runs this folder is stopped and removed.
for p in $AGENTS/*.plist(N); do
  if grep -q "$ROOT/server/crew\.ts" "$p" 2>/dev/null; then stop_agent ${p:t:r}; run rm -f $p; fi
done

if (( DRY )); then
  say; say "  would write ${PLIST/#$HOME/~}:"
  plist | sed 's/^/    /'
  say "  would restart the LaunchAgent $LABEL"
else
  mkdir -p $AGENTS ${LOG:h}
  plist > $PLIST.tmp && mv $PLIST.tmp $PLIST
  stop_agent $LABEL
  launchctl bootstrap $DOMAIN $PLIST 2>/dev/null || { sleep 2; launchctl bootstrap $DOMAIN $PLIST }
fi

# ---------- the command ----------
run mkdir -p $HOME/.local/bin
run ln -sf $T3BOT $HOME/.local/bin/t3bot
if [[ :$PATH: != *:$HOME/.local/bin:* ]]; then
  say "  ~/.local/bin is not in your PATH. Add it (echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc), or call ${T3BOT/#$HOME/~} directly."
fi

if (( DRY )); then
  then_pair=""
  if (( PAIR )); then then_pair=", then \`t3bot pair\`"; fi
  say; say "  would wait for http://127.0.0.1:$PORT/health, run \`t3bot setup\` if there is no bot yet$then_pair."
  exit 0
fi

# ---------- is it up ----------
up=0
for i in {1..30}; do curl -fsS --max-time 2 http://127.0.0.1:$PORT/health >/dev/null 2>&1 && { up=1; break }; sleep 0.5; done
if (( ! up )); then
  print -u2 ""; print -u2 "The server did not answer on port $PORT. Its log: ${LOG/#$HOME/~}"
  tail -5 $LOG >&2 2>/dev/null || true
  exit 1
fi
say; say "The server is running and will start again at login. Log: ${LOG/#$HOME/~}"
[[ $MODE == lan ]] && say "If the phone cannot connect, macOS may be blocking incoming connections to bun: System Settings > Network > Firewall."

# ---------- the first bot, then the phone ----------
export T3BOT_PORT=$PORT
if ! $T3BOT setup --if-needed $SETUP_ARGS; then
  say; say "No bot yet. When T3 Code is open and has a project, run: t3bot setup"
fi
if (( PAIR )); then say; $T3BOT pair || true; fi
