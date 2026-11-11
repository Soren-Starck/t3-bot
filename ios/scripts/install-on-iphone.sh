#!/bin/zsh
# Builds and signs T3 Bot on another Mac over ssh and installs it on an iPhone paired with that Mac.
# This is the headless route, for when the Mac that has Xcode and the iPhone is not the one you are typing
# on. Most people do not need it: run ios/scripts/setup.sh, then open ios/T3Bot.xcodeproj and press Run, or
# run ios/scripts/run-on-iphone.sh with the iPhone plugged into this Mac.
#
#   ios/scripts/install-on-iphone.sh [device UDID]
#
# Values come from the environment, else ios/Config/Local.xcconfig, else ios/Config/T3Bot.xcconfig:
#   T3BOT_BUILD_HOST      ssh name of the Mac that builds and holds the iPhone pairing.
#   T3BOT_BUILD_DIR       folder the build uses on that Mac, under its home folder (t3bot-build when not
#                         set). The copy of the sources in it is deleted afterwards.
#   T3BOT_DEVICE          the iPhone's UDID. Not set: the one iPhone paired with the build Mac.
#   T3BOT_PROFILES_DIR    folder of .mobileprovision files copied to the build Mac when signing is manual
#                         (~/.config/t3bot/profiles when not set).
#   T3BOT_ASC_KEY_ID, T3BOT_ASC_ISSUER_ID, T3BOT_ASC_KEY_PATH
#                         an App Store Connect API key on the build Mac, for when Xcode there has no Apple
#                         account and must make or refresh profiles itself. The path is
#                         ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 when not set. Manual signing
#                         with profiles that are already made needs none of this.
#   CONFIG                Release (default) or Debug.
#
# codesign needs the build Mac's login session, so the build runs there through `launchctl submit` (no
# window), at low priority, in the build folder. Only the login keychain is in the search list during the
# build, restored after.
set -euo pipefail
HERE=${0:A:h}
ROOT=$HERE/..
source "$HERE/lib.zsh"

# Where the build lives on the build Mac, under its home folder: the sources, the build script and its log.
BUILD_DIR=$(setting T3BOT_BUILD_DIR)
BUILD_DIR=${BUILD_DIR:-t3bot-build}
BUILD_DIR=${BUILD_DIR%/}
# It is used in remote commands, one of which deletes the sources: a plain folder name or path only.
[[ $BUILD_DIR =~ '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' && $BUILD_DIR != *..* && $BUILD_DIR != -* ]] \
  || die "T3BOT_BUILD_DIR must be a folder under the build Mac's home (letters, digits, dots, dashes, slashes). Got: $BUILD_DIR"
REMOTE=$BUILD_DIR/t3bot
LOG=$BUILD_DIR/t3bot-build.log
JOB=$BUILD_DIR/t3bot-build.sh
CONFIG=${CONFIG:-Release}
PRODUCTS="~/$REMOTE/build/Build/Products/$CONFIG-iphoneos"

BUILD_HOST=$(setting T3BOT_BUILD_HOST)
[[ -n $BUILD_HOST ]] || die "This script builds on another Mac over ssh, and T3BOT_BUILD_HOST (its ssh name) is not set. To build on this Mac for the iPhone plugged into it, run ios/scripts/run-on-iphone.sh, or open ios/T3Bot.xcodeproj in Xcode."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$BUILD_HOST" true 2>/dev/null \
  || die "Cannot reach $BUILD_HOST over ssh. Nothing was built."

# The iPhones paired with the build Mac, one per line: "<udid> <state> <name>".
paired_iphones() {
  ssh "$BUILD_HOST" 'f=$(mktemp) && xcrun devicectl list devices --json-output "$f" >/dev/null 2>&1; cat "$f"; rm -f "$f"' \
    | python3 -I -c '
import json, sys
try:
    devices = json.load(sys.stdin).get("result", {}).get("devices", [])
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    link = d.get("connectionProperties", {})
    if hw.get("deviceType") != "iPhone" or link.get("pairingState") != "paired":
        continue
    udid = hw.get("udid") or d.get("identifier") or ""
    name = d.get("deviceProperties", {}).get("name", "iPhone")
    if udid:
        print(udid, link.get("tunnelState", "unknown"), name)
'
}

DEVICE=${1:-$(setting T3BOT_DEVICE)}
if [[ -z $DEVICE ]]; then
  FOUND=("${(@f)$(paired_iphones || true)}")
  FOUND=(${FOUND:#})
  # An iPhone that was paired once and is gone stays in the list as unavailable: leave those out when
  # another one can be reached.
  REACHABLE=(${FOUND:#* unavailable *})
  (( $#REACHABLE )) && FOUND=($REACHABLE)
  if (( $#FOUND == 1 )); then
    DEVICE=${FOUND[1]%% *}
    echo "installing on ${FOUND[1]#* * }"
  elif (( $#FOUND == 0 )); then
    die "No iPhone is paired with $BUILD_HOST. Pair one there, or pass its UDID: $0 <udid>"
  else
    print -r -u2 -- "Several iPhones are paired with $BUILD_HOST:"
    print -r -u2 -l -- "  "${^FOUND}
    die "Pass the UDID of the one to install on, or set T3BOT_DEVICE."
  fi
fi

# The device tunnel resets now and then: retry.
install_on() {
  for attempt in 1 2 3; do
    ssh "$BUILD_HOST" "xcrun devicectl device install app --device $1 $PRODUCTS/$2" && { echo "installed on $1"; return 0; }
    echo "install attempt $attempt failed, retrying"; sleep 5
  done
  return 1
}

# The build carries the server's address and token, so the app needs no pairing step.
if ! grep -q -E '^T3BOT_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]' "$LOCAL_CONFIG" 2>/dev/null \
  || ! grep -q -E '^T3BOT_URL[[:space:]]*=[[:space:]]*[^[:space:]]' "$LOCAL_CONFIG" 2>/dev/null; then
  "$HERE/write-local-config.sh" || echo "No connection in the build: the app will open on its connect screen."
fi

# No picture of any bot goes into the build: the app and its extensions get the faces from the server.
(cd "$ROOT" && xcodegen generate >/dev/null)
ssh "$BUILD_HOST" "mkdir -p ~/$REMOTE"
rsync -a --delete --exclude build/ --exclude DerivedData/ "$ROOT/" "$BUILD_HOST:$REMOTE/"

SIGN_STYLE=$(setting T3BOT_SIGN_STYLE)
if [[ $SIGN_STYLE == Manual ]]; then
  # The signing profiles go where Xcode looks for them.
  PROFILES=("${T3BOT_PROFILES_DIR:-$HOME/.config/t3bot/profiles}"/*.mobileprovision(N))
  if (( $#PROFILES )); then
    ssh "$BUILD_HOST" 'mkdir -p "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"'
    scp -q $PROFILES "$BUILD_HOST:Library/Developer/Xcode/UserData/Provisioning Profiles/"
  fi
fi

# With an App Store Connect key, Xcode can make and refresh profiles with no Apple account signed in.
# Automatic signing with no key relies on the account in Xcode on the build Mac.
AUTH=""
ASC_KEY=$(setting T3BOT_ASC_KEY_ID)
ASC_ISSUER=$(setting T3BOT_ASC_ISSUER_ID)
if [[ -n $ASC_KEY && -n $ASC_ISSUER ]]; then
  ASC_PATH=$(setting T3BOT_ASC_KEY_PATH)
  AUTH="-allowProvisioningUpdates -authenticationKeyPath ${ASC_PATH:-~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY.p8} -authenticationKeyID $ASC_KEY -authenticationKeyIssuerID $ASC_ISSUER"
elif [[ $SIGN_STYLE != Manual ]]; then
  AUTH="-allowProvisioningUpdates"
fi

ssh "$BUILD_HOST" "cat > ~/$JOB" <<SCRIPT
#!/bin/zsh
cd ~/$REMOTE
exec > ~/$LOG 2>&1
ORIG=(\${(f)"\$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"\$//')"})
restore() { security list-keychains -d user -s "\${ORIG[@]}"; }
trap restore EXIT
security list-keychains -d user -s ~/Library/Keychains/login.keychain-db
nice -n 15 taskpolicy -c utility xcodebuild -project T3Bot.xcodeproj -scheme T3Bot -configuration $CONFIG \\
  -destination 'generic/platform=iOS' -derivedDataPath build $AUTH build
echo "BUILD_RC=\$?"
# launchctl submit restarts a job that exits, which would wipe this log before it is read.
exec sleep 3600
SCRIPT
# Clear the last build's log first, or the wait below can read its result before this one starts.
ssh "$BUILD_HOST" "rm -f ~/$LOG; launchctl remove t3bot-build 2>/dev/null; launchctl submit -l t3bot-build -- /bin/zsh ~/$JOB"

echo "building on $BUILD_HOST (log: $BUILD_HOST:~/$LOG)"
until ssh "$BUILD_HOST" "grep -q BUILD_RC ~/$LOG 2>/dev/null"; do sleep 10; done
ssh "$BUILD_HOST" "launchctl remove t3bot-build 2>/dev/null; grep -E ' error: ' ~/$LOG | head -20; tail -2 ~/$LOG"
ssh "$BUILD_HOST" "grep -q 'BUILD_RC=0' ~/$LOG" || { echo "build failed"; exit 1; }
install_on "$DEVICE" T3Bot.app
ssh "$BUILD_HOST" "rm -rf ~/$REMOTE ~/$JOB"
echo "done"
