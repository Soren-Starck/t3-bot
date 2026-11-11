#!/bin/zsh
# One command from a fresh clone to a project that builds under your own Apple developer team.
#
#   ios/scripts/setup.sh                                          asks for the two values
#   ios/scripts/setup.sh --team ABCDE12345 --bundle-prefix com.yourname
#   ios/scripts/setup.sh --push-host my-sender.vercel.app        later: keeps the team and identifier
#
# It writes your team and bundle identifier to ios/Config/Local.xcconfig (not committed, wins over the
# defaults in ios/Config/T3Bot.xcconfig), generates ios/T3Bot.xcodeproj with XcodeGen, and prints the two
# ways to put the app on your iPhone. ios/Config/Local.example.xcconfig explains every value.
#
# Options:
#   --team <id>            Your team ID: ten letters and digits. developer.apple.com > Account > Membership
#                          details, or Xcode > Settings > Accounts.
#   --bundle-prefix <p>    A reverse-domain prefix of your own, like com.yourname. The app becomes
#                          <p>.t3bot, and its three extensions <p>.t3bot.notify, .widgets and .share.
#   --bundle-id <id>       The app's whole bundle identifier instead of a prefix, like com.yourname.t3bot.
#   --push-host <host>     Host name of your own push sender (push/README.md), for notifications when the
#                          app is paired straight with T3 Code.
#   --no-push-host         Build with no push sender.
#   --manual <app> <notify> <widgets> <share>
#                          Sign with four provisioning profiles you made yourself, by name. A first setup
#                          without this option signs automatically and Xcode makes the profiles.
#   --automatic            Go back to automatic signing after --manual (and to the default identity).
#   --identity <name>      The signing identity, when it is not "Apple Development".
#   --no-generate          Do not run xcodegen at the end.
#   --reset                Remove these values from Local.xcconfig, which brings the defaults back (no team).
#
# Run it again at any time: it keeps the team, identifier and signing it wrote before unless you give new
# ones, and every other line of the file.
# Notifications need a paid Apple Developer membership: a free account cannot sign the push entitlement.
set -eu
umask 077
SELF=${0:A}
HERE=${0:A:h}
source "$HERE/lib.zsh"

NAMES=(T3BOT_TEAM T3BOT_BUNDLE_ID)
SIGN_NAMES=(T3BOT_SIGN_STYLE T3BOT_PROFILE_APP T3BOT_PROFILE_NOTIFY T3BOT_PROFILE_WIDGETS T3BOT_PROFILE_SHARE)
# keep: leave the signing lines as they are. manual: write the four profiles. automatic: write none.
SIGN=keep
TEAM=""
BUNDLE=""
PREFIX=""
IDENTITY=""
PROFILES=()
GENERATE=1
RESET=0
# keep: leave the push sender as it is. set: write PUSH_HOST. off: write an empty one.
PUSH=keep
PUSH_HOST=""

usage() { sed -n '2,31p' "$SELF" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case $1 in
    --team) (( $# >= 2 )) || die "--team needs a value"; TEAM=$2; shift 2 ;;
    --bundle-id) (( $# >= 2 )) || die "--bundle-id needs a value"; BUNDLE=$2; shift 2 ;;
    --bundle-prefix|--prefix) (( $# >= 2 )) || die "--bundle-prefix needs a value"; PREFIX=$2; shift 2 ;;
    --push-host) (( $# >= 2 )) || die "--push-host needs a value"; PUSH=set; PUSH_HOST=$2; shift 2 ;;
    --no-push-host) PUSH=off; shift ;;
    --identity) (( $# >= 2 )) || die "--identity needs a value"; IDENTITY=$2; shift 2 ;;
    --manual) (( $# >= 5 )) || die "--manual needs four profile names: app, notify, widgets, share"
              PROFILES=("$2" "$3" "$4" "$5"); SIGN=manual; shift 5 ;;
    --automatic) SIGN=automatic; PROFILES=(); NAMES+=(T3BOT_SIGN_IDENTITY); shift ;;
    --no-generate) GENERATE=0; shift ;;
    --reset) RESET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

GENERATED=0
generate() {
  (( GENERATE )) || return 0
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen is not installed, so there is no Xcode project yet. Your values are saved. Install it and"
    echo "generate the project:  brew install xcodegen && (cd ios && xcodegen generate)"
    return 0
  fi
  local out
  if out=$(cd "$HERE/.." && xcodegen generate 2>&1); then
    GENERATED=1
    echo "generated ios/T3Bot.xcodeproj"
  else
    print -r -u2 -- "$out"
    die "xcodegen could not generate the project (above). Your values are saved in ios/Config/Local.xcconfig."
  fi
}

if (( RESET )); then
  if [[ -r $LOCAL_CONFIG ]]; then
    rewrite_local_config $NAMES $SIGN_NAMES T3BOT_SIGN_IDENTITY </dev/null
    echo "removed the team, bundle identifier and signing values from ios/Config/Local.xcconfig"
  else
    echo "ios/Config/Local.xcconfig does not exist, so the defaults already apply"
  fi
  generate
  exit 0
fi

# A first setup of this checkout: nothing here names a team or a push sender yet.
FIRST=1
if [[ -r $LOCAL_CONFIG ]] && grep -q -E '^T3BOT_(TEAM|PUSH_HOST)[[:space:]]*=' "$LOCAL_CONFIG"; then
  FIRST=0
fi

# Values this checkout already has, so that a later run can change one thing (--push-host, --manual) without
# repeating the rest. Only Local.xcconfig counts: the defaults name an example identifier and no team.
local_value() {
  [[ -r $LOCAL_CONFIG ]] || return 0
  sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$LOCAL_CONFIG" | sed 's/[[:space:]]*$//' | tail -1
}
[[ -n $TEAM ]] || TEAM=$(local_value T3BOT_TEAM)
[[ -n $BUNDLE || -n $PREFIX ]] || BUNDLE=$(local_value T3BOT_BUNDLE_ID)

if [[ -z $TEAM && -t 0 ]]; then
  echo "Your Apple team ID is ten letters and digits. Find it on developer.apple.com > Account >"
  echo "Membership details, or in Xcode > Settings > Accounts."
  read "TEAM?Team ID: " || true
fi
if [[ -z $BUNDLE && -z $PREFIX && -t 0 ]]; then
  echo "A bundle identifier prefix is a reverse-domain name of your own that nobody else uses, like"
  echo "com.yourname. The app becomes <prefix>.t3bot."
  read "PREFIX?Bundle identifier prefix: " || true
fi
TEAM=${TEAM//[[:space:]]/}
# A team ID typed in small letters is the same team.
TEAM=${(U)TEAM}
BUNDLE=${BUNDLE//[[:space:]]/}
PREFIX=${PREFIX//[[:space:]]/}
PREFIX=${PREFIX%.}
[[ -n $BUNDLE || -z $PREFIX ]] || BUNDLE=$PREFIX.t3bot
[[ -n $TEAM && -n $BUNDLE ]] || { usage >&2; die "Both a team (--team) and a bundle identifier (--bundle-prefix or --bundle-id) are needed."; }
[[ $TEAM =~ '^[A-Z0-9]{10}$' ]] || die "A team ID is ten capital letters and digits, like ABCDE12345. Got: $TEAM"
[[ $BUNDLE =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || die "A bundle identifier looks like com.yourname.t3bot (letters, digits, dashes and dots). Got: $BUNDLE"
[[ $BUNDLE != com.example.* && $BUNDLE != com.yourname.* ]] || die "Use a prefix of your own in place of the example one. Got: $BUNDLE"
for p in "${PROFILES[@]}"; do
  [[ -n $p && $p != *//* && $p != *\$* && $p != *$'\n'* ]] || die "A profile name cannot be empty or hold //, \$ or a line break."
done
[[ $IDENTITY != *//* && $IDENTITY != *\$* && $IDENTITY != *$'\n'* ]] || die "A signing identity cannot hold //, \$ or a line break."
# A file that says nothing about signing yet gets the automatic lines. One that does keeps them (the four
# profile names of an earlier --manual included) until --manual or --automatic says otherwise.
if [[ $SIGN == keep ]] && ! { [[ -r $LOCAL_CONFIG ]] && grep -q -E '^T3BOT_SIGN_STYLE[[:space:]]*=' "$LOCAL_CONFIG"; }; then
  SIGN=automatic
fi
[[ $SIGN == keep ]] || NAMES+=($SIGN_NAMES)
[[ -z $IDENTITY ]] || NAMES+=(T3BOT_SIGN_IDENTITY)
if [[ $PUSH == set ]]; then
  PUSH_HOST=${PUSH_HOST#https://}
  PUSH_HOST=${PUSH_HOST%%/*}
  [[ $PUSH_HOST =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || die "--push-host takes a host name, like my-sender.vercel.app. Got: $PUSH_HOST"
fi
# A sender only rings the app signed by its own team, so a first setup starts with none and writes the
# empty line, which also shows where the value goes.
[[ $PUSH == keep && $FIRST == 1 ]] && PUSH=off
[[ $PUSH == keep ]] || NAMES+=(T3BOT_PUSH_HOST)

{
  print -r -- "T3BOT_TEAM = $TEAM"
  print -r -- "T3BOT_BUNDLE_ID = $BUNDLE"
  if [[ $SIGN == manual ]]; then
    print -r -- "T3BOT_SIGN_STYLE = Manual"
    print -r -- "T3BOT_PROFILE_APP = $PROFILES[1]"
    print -r -- "T3BOT_PROFILE_NOTIFY = $PROFILES[2]"
    print -r -- "T3BOT_PROFILE_WIDGETS = $PROFILES[3]"
    print -r -- "T3BOT_PROFILE_SHARE = $PROFILES[4]"
  elif [[ $SIGN == automatic ]]; then
    print -r -- "T3BOT_SIGN_STYLE = Automatic"
    print -r -- "T3BOT_PROFILE_APP ="
    print -r -- "T3BOT_PROFILE_NOTIFY ="
    print -r -- "T3BOT_PROFILE_WIDGETS ="
    print -r -- "T3BOT_PROFILE_SHARE ="
  fi
  [[ -z $IDENTITY ]] || print -r -- "T3BOT_SIGN_IDENTITY = $IDENTITY"
  case $PUSH in
    set) print -r -- "T3BOT_PUSH_HOST = $PUSH_HOST" ;;
    off) print -r -- "T3BOT_PUSH_HOST =" ;;
  esac
} | rewrite_local_config $NAMES

# What the file says now, so a kept manual signing is reported as what it is.
MANUAL=0
[[ $(local_value T3BOT_SIGN_STYLE) == Manual ]] && MANUAL=1
echo "wrote ios/Config/Local.xcconfig: team $TEAM, bundle identifier $BUNDLE, $( (( MANUAL )) && echo "manual signing with your four profiles" || echo "automatic signing")"
generate

echo
if (( GENERATED )); then
  echo "Put the app on your iPhone, one of two ways:"
else
  echo "Once the project is generated, put the app on your iPhone, one of two ways:"
fi
echo "  1. Xcode:    open ios/T3Bot.xcodeproj"
echo "               Sign in under Xcode > Settings > Accounts, choose your iPhone at the top, press Run."
echo "  2. Terminal: ios/scripts/run-on-iphone.sh"
echo "               With the iPhone plugged in, unlocked and trusted. It builds, installs and opens the app."
(( MANUAL )) || echo "The first build makes the signing profiles for the four targets, so it needs your Apple account in Xcode."
echo
echo "Then pair: in T3 Code, open Settings > Sharing & access, create a link, and scan its code from the"
echo "app's first screen. Nothing else has to be installed on the Mac."
case $PUSH in
  off) echo
       echo "Notifications: this build has no push sender, so the phone stays silent and the app shows what is new"
       echo "when you open it. To make the phone ring, deploy your own sender (push/README.md), then run:"
       echo "  ios/scripts/setup.sh --push-host <its host name>" ;;
  set) echo
       echo "Notifications ring through $PUSH_HOST. Its ALLOWED_TOPICS must hold $BUNDLE." ;;
esac
