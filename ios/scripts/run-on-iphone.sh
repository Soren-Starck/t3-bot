#!/bin/zsh
# Builds T3 Bot on this Mac and installs it on the iPhone connected to it, without opening Xcode.
# Run ios/scripts/setup.sh first: it writes your team and bundle identifier.
#
#   ios/scripts/run-on-iphone.sh [device identifier]
#
# The iPhone must be plugged in (or on the same Wi-Fi after a first cabled pairing), unlocked, trusted by
# this Mac, and have Developer Mode on (Settings > Privacy & Security > Developer Mode).
#
# Values come from the environment, else ios/Config/Local.xcconfig, else ios/Config/T3Bot.xcconfig:
#   T3BOT_DEVICE          the iPhone's identifier. Not set: the one iPhone this Mac can reach.
#   T3BOT_ASC_KEY_ID, T3BOT_ASC_ISSUER_ID, T3BOT_ASC_KEY_PATH
#                         an App Store Connect API key, for a Mac whose Xcode has no Apple account. Without
#                         it, automatic signing uses the account under Xcode > Settings > Accounts.
#   CONFIG                Debug (default) or Release.
#
# The build goes to ios/build, which git ignores. Its log is ios/build/run-on-iphone.log.
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h}
source "$HERE/lib.zsh"

CONFIG=${CONFIG:-Debug}
TEAM=$(setting T3BOT_TEAM)
BUNDLE=$(setting T3BOT_BUNDLE_ID)
[[ -n $TEAM ]] || die "No team is set yet. Run ios/scripts/setup.sh first."
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild was not found. Install Xcode, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
xcrun devicectl --version >/dev/null 2>&1 || die "This Xcode has no devicectl (it needs Xcode 15 or later; the app needs Xcode 27)."
command -v xcodegen >/dev/null 2>&1 || die "XcodeGen is not installed. Run: brew install xcodegen"

# The iPhones this Mac knows, one per line: "<identifier> <state> <name>".
paired_iphones() {
  local f
  f=$(mktemp)
  xcrun devicectl list devices --json-output "$f" >/dev/null 2>&1 || true
  python3 -I -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
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
' "$f"
  rm -f "$f"
}

DEVICE=${1:-$(setting T3BOT_DEVICE)}
if [[ -z $DEVICE ]]; then
  FOUND=("${(@f)$(paired_iphones || true)}")
  FOUND=(${FOUND:#})
  # An iPhone that was paired once and is gone stays in the list as unavailable. Building for it takes
  # minutes and then fails with nothing that says why, so it stops here.
  REACHABLE=(${FOUND:#* unavailable *})
  if (( $#FOUND > 0 && $#REACHABLE == 0 )); then
    print -r -u2 -- "This Mac knows these iPhones, but cannot reach any of them now:"
    for f in $FOUND; do print -r -u2 -- "  ${f#* * } (${f%% *})"; done
    die "Plug the iPhone in, unlock it, then run this again. To try one anyway: $0 <identifier>"
  fi
  FOUND=($REACHABLE)
  if (( $#FOUND == 1 )); then
    DEVICE=${FOUND[1]%% *}
    echo "iPhone: ${FOUND[1]#* * }"
  elif (( $#FOUND == 0 )); then
    die "No iPhone found. Plug it in, unlock it, tap Trust, turn on Developer Mode (Settings > Privacy & Security), then run this again. Or build from Xcode: open ios/T3Bot.xcodeproj"
  else
    print -r -u2 -- "Several iPhones are known to this Mac:"
    print -r -u2 -l -- "  "${^FOUND}
    die "Pass the identifier of the one to install on: $0 <identifier>"
  fi
fi
[[ $DEVICE =~ '^[A-Za-z0-9-]+$' ]] || die "That does not look like a device identifier: $DEVICE"

(cd "$ROOT" && xcodegen generate >/dev/null) || die "xcodegen could not generate the project. Run: cd ios && xcodegen generate"

# Automatic signing may make certificates and profiles and register this iPhone, with the account in Xcode or
# with an App Store Connect key. Manual signing uses the profiles named in Local.xcconfig as they are.
AUTH=()
SIGN_STYLE=$(setting T3BOT_SIGN_STYLE)
ASC_KEY=$(setting T3BOT_ASC_KEY_ID)
ASC_ISSUER=$(setting T3BOT_ASC_ISSUER_ID)
if [[ $SIGN_STYLE != Manual ]]; then
  AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  if [[ -n $ASC_KEY && -n $ASC_ISSUER ]]; then
    ASC_PATH=$(setting T3BOT_ASC_KEY_PATH)
    ASC_PATH=${ASC_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY.p8}
    ASC_PATH=${ASC_PATH/#\~/$HOME}
    AUTH+=(-authenticationKeyPath "$ASC_PATH" -authenticationKeyID "$ASC_KEY" -authenticationKeyIssuerID "$ASC_ISSUER")
  fi
fi

mkdir -p "$ROOT/build"
LOG=$ROOT/build/run-on-iphone.log
echo "building ($CONFIG, team $TEAM, $BUNDLE). The first build takes a few minutes. Log: ios/build/run-on-iphone.log"
if ! xcodebuild -project "$ROOT/T3Bot.xcodeproj" -scheme T3Bot -configuration "$CONFIG" \
     -destination "platform=iOS,id=$DEVICE" -derivedDataPath "$ROOT/build" $AUTH build > "$LOG" 2>&1; then
  grep -E '(error|Error):' "$LOG" | sort -u | head -20 >&2 || true
  print -r -u2 -- ""
  if grep -q -E 'No Accounts|No profiles for|requires a development team|No signing certificate' "$LOG"; then
    print -r -u2 -- "Signing failed. Open Xcode > Settings > Accounts and sign in with the Apple account of team $TEAM,"
    print -r -u2 -- "then run this again. Or open ios/T3Bot.xcodeproj and press Run once: Xcode shows what is missing."
  elif grep -q -E "doesn't (include|support)|does not (include|support) the .* (capability|entitlement)" "$LOG"; then
    print -r -u2 -- "A capability is missing on one of your App IDs. On developer.apple.com > Identifiers, open $BUNDLE and"
    print -r -u2 -- "tick Push Notifications, Time Sensitive Notifications and Communication Notifications, then run this again."
  fi
  die "The build failed. Full log: ios/build/run-on-iphone.log"
fi

APP=$ROOT/build/Build/Products/$CONFIG-iphoneos/T3Bot.app
[[ -d $APP ]] || die "The build finished but $APP is missing. See ios/build/run-on-iphone.log"
# The device tunnel resets now and then: retry.
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
    INSTALLED=1
    break
  fi
  echo "install attempt $attempt failed, retrying"
  sleep 5
done
[[ -n ${INSTALLED:-} ]] || die "Could not install on the iPhone. Unlock it, keep it plugged in and run this again. Log: ios/build/run-on-iphone.log"
echo "installed T3 Bot on the iPhone"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >> "$LOG" 2>&1 \
  || echo "Open T3 Bot on the iPhone (it could not be opened from here, which is normal while the phone is locked)."
echo "Next: in T3 Code, Settings > Sharing & access, create a link and scan its code from the app."
