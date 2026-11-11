#!/bin/zsh
# Puts a server connection into ios/Config/Local.xcconfig (not committed): T3BOT_URL and T3BOT_TOKEN.
# A build that carries both opens straight on your bots, with no pairing step, and its widgets, share sheet
# and notifications work before the app has been opened once. Without them the app opens on its connect
# screen and is paired with `t3bot pair`, which is all most people need.
#
#   ios/scripts/write-local-config.sh
#   T3BOT_URL=https://my-mac.example.ts.net:8809 ios/scripts/write-local-config.sh
#
# The token is read from this Mac (T3BOT_TOKEN_FILE, else ~/.config/t3bot/token), else over ssh from the Mac
# that runs the server (T3BOT_SERVER_HOST). The address is T3BOT_URL, else the one already in the file, else
# the Tailscale name of the Mac that holds the token, on port T3BOT_PORT (8809 when not set).
# Every other line already in Local.xcconfig (your team and signing from setup.sh) is kept.
set -eu
umask 077
HERE=${0:A:h}
source "$HERE/lib.zsh"

TOKEN_FILE=${T3BOT_TOKEN_FILE:-$HOME/.config/t3bot/token}
PORT=${T3BOT_PORT:-8809}

# Prints this machine's Tailscale name (my-mac.example.ts.net), or nothing. Runs here or over ssh.
TAILSCALE_NAME='for t in tailscale /opt/homebrew/bin/tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  command -v "$t" >/dev/null 2>&1 || continue
  "$t" status --self --peers=false --json 2>/dev/null | sed -n "s/.*\"DNSName\": *\"\([^\"]*\)\.\".*/\1/p" | head -1
  break
done'

REMOTE=""
if [[ -r $TOKEN_FILE ]]; then
  TOKEN=$(<"$TOKEN_FILE")
else
  REMOTE=$(setting T3BOT_SERVER_HOST)
  [[ -n $REMOTE ]] || die "No token at $TOKEN_FILE. Run this on the Mac that runs the server, or set T3BOT_SERVER_HOST to its ssh name."
  TOKEN=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" 'cat ~/.config/t3bot/token') \
    || die "Could not read the token over ssh from $REMOTE."
fi
TOKEN=${TOKEN//[[:space:]]/}
[[ -n $TOKEN ]] || die "The token file is empty."
# An xcconfig reads // as the start of a comment and $( as a build setting, so such a token cannot be carried.
[[ $TOKEN != *//* && $TOKEN != *\$* ]] || die "This token cannot be written to an xcconfig. Pair the app with \`t3bot pair\` instead."

# The address, in the form an xcconfig needs: https:/$()/host:8809, because // starts a comment.
URL_LINE=""
if [[ -n ${T3BOT_URL:-} ]]; then
  URL=$T3BOT_URL
elif [[ -r $LOCAL_CONFIG ]] && grep -q -E '^T3BOT_URL[[:space:]]*=[[:space:]]*[^[:space:]]' "$LOCAL_CONFIG"; then
  URL=""
  URL_LINE=$(grep -E '^T3BOT_URL[[:space:]]*=' "$LOCAL_CONFIG" | tail -1)
else
  if [[ -n $REMOTE ]]; then
    NAME=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" "$TAILSCALE_NAME" 2>/dev/null || true)
  else
    NAME=$(sh -c "$TAILSCALE_NAME" 2>/dev/null || true)
  fi
  URL=${NAME:+https://$NAME:$PORT}
fi
if [[ -n ${URL:-} ]]; then
  [[ $URL == http://* || $URL == https://* ]] || die "T3BOT_URL must start with http:// or https://"
  URL=${URL%/}
  URL_LINE="T3BOT_URL = $(print -r -- "$URL" | sed 's|://|:/$()/|')"
fi

{
  [[ -z $URL_LINE ]] || print -r -- "$URL_LINE"
  print -r -- "T3BOT_TOKEN = $TOKEN"
} | rewrite_local_config T3BOT_URL T3BOT_TOKEN

if [[ -n ${URL:-} ]]; then
  echo "wrote ios/Config/Local.xcconfig: the token, and the server address $URL"
elif [[ -n $URL_LINE ]]; then
  echo "wrote ios/Config/Local.xcconfig: the token, and the server address it already had"
else
  echo "wrote ios/Config/Local.xcconfig: the token, but no server address was found."
  echo "Run it again with T3BOT_URL=<address of your server>, or the app will open on its connect screen."
fi
