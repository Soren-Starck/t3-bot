#!/bin/zsh
# Sets the app up to build under your own Apple developer team. The repository's defaults
# (ios/Config/T3Bot.xcconfig) name no team and carry an example bundle identifier, which is enough for a
# simulator build and nothing else. This writes your team and bundle identifier to
# ios/Config/Local.xcconfig, which is not committed and wins over the defaults, then generates the Xcode
# project.
#
#   ios/scripts/setup.sh --team ABCDE12345 --bundle-id com.yourname.t3bot
#
# Options:
#   --team <id>          Your team ID: ten letters and digits, shown under Membership on developer.apple.com.
#   --bundle-id <id>     An identifier of your own for the app. The three extensions add .notify, .widgets
#                        and .share to it.
#   --manual <app> <notify> <widgets> <share>
#                        Sign with four provisioning profiles you made yourself, by name. Without this
#                        option signing is automatic and Xcode makes the profiles.
#   --identity <name>    The signing identity, when it is not "Apple Development".
#   --no-generate        Do not run xcodegen at the end.
#   --reset              Remove these values from Local.xcconfig, which brings the defaults back (no team).
#
# Run with no option in a terminal, it asks for the team and the bundle identifier.
# Notifications need a paid Apple Developer membership: a free account cannot sign the push entitlement.
set -eu
umask 077
SELF=${0:A}
HERE=${0:A:h}
source "$HERE/lib.zsh"

NAMES=(T3BOT_TEAM T3BOT_BUNDLE_ID T3BOT_SIGN_STYLE T3BOT_SIGN_IDENTITY
       T3BOT_PROFILE_APP T3BOT_PROFILE_NOTIFY T3BOT_PROFILE_WIDGETS T3BOT_PROFILE_SHARE)
TEAM=""
BUNDLE=""
IDENTITY=""
PROFILES=()
GENERATE=1
RESET=0

usage() { sed -n '2,22p' "$SELF" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case $1 in
    --team) (( $# >= 2 )) || die "--team needs a value"; TEAM=$2; shift 2 ;;
    --bundle-id) (( $# >= 2 )) || die "--bundle-id needs a value"; BUNDLE=$2; shift 2 ;;
    --identity) (( $# >= 2 )) || die "--identity needs a value"; IDENTITY=$2; shift 2 ;;
    --manual) (( $# >= 5 )) || die "--manual needs four profile names: app, notify, widgets, share"
              PROFILES=("$2" "$3" "$4" "$5"); shift 5 ;;
    --no-generate) GENERATE=0; shift ;;
    --reset) RESET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

generate() {
  (( GENERATE )) || return 0
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$HERE/.." && xcodegen generate >/dev/null) && echo "generated ios/T3Bot.xcodeproj"
  else
    echo "xcodegen is not installed. Install it (brew install xcodegen), then run: cd ios && xcodegen generate"
  fi
}

if (( RESET )); then
  if [[ -r $LOCAL_CONFIG ]]; then
    rewrite_local_config $NAMES </dev/null
    echo "removed the team, bundle identifier and signing values from Config/Local.xcconfig"
  else
    echo "Config/Local.xcconfig does not exist, so the defaults already apply"
  fi
  generate
  exit 0
fi

if [[ -z $TEAM && -t 0 ]]; then
  read "TEAM?Team ID (ten letters and digits, under Membership on developer.apple.com): "
fi
if [[ -z $BUNDLE && -t 0 ]]; then
  read "BUNDLE?Bundle identifier of your own (for example com.yourname.t3bot): "
fi
TEAM=${TEAM//[[:space:]]/}
BUNDLE=${BUNDLE//[[:space:]]/}
[[ -n $TEAM && -n $BUNDLE ]] || { usage >&2; die "Both --team and --bundle-id are needed."; }
[[ $TEAM =~ '^[A-Z0-9]{10}$' ]] || die "A team ID is ten capital letters and digits, like ABCDE12345. Got: $TEAM"
[[ $BUNDLE =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || die "A bundle identifier looks like com.yourname.t3bot (letters, digits, dashes and dots). Got: $BUNDLE"
for p in $PROFILES; do
  [[ -n $p && $p != *//* && $p != *\$* ]] || die "A profile name cannot be empty or hold // or \$."
done

{
  print -r -- "T3BOT_TEAM = $TEAM"
  print -r -- "T3BOT_BUNDLE_ID = $BUNDLE"
  if (( $#PROFILES )); then
    print -r -- "T3BOT_SIGN_STYLE = Manual"
    print -r -- "T3BOT_PROFILE_APP = $PROFILES[1]"
    print -r -- "T3BOT_PROFILE_NOTIFY = $PROFILES[2]"
    print -r -- "T3BOT_PROFILE_WIDGETS = $PROFILES[3]"
    print -r -- "T3BOT_PROFILE_SHARE = $PROFILES[4]"
  else
    print -r -- "T3BOT_SIGN_STYLE = Automatic"
    print -r -- "T3BOT_PROFILE_APP ="
    print -r -- "T3BOT_PROFILE_NOTIFY ="
    print -r -- "T3BOT_PROFILE_WIDGETS ="
    print -r -- "T3BOT_PROFILE_SHARE ="
  fi
  [[ -z $IDENTITY ]] || print -r -- "T3BOT_SIGN_IDENTITY = $IDENTITY"
} | rewrite_local_config $NAMES

echo "wrote Config/Local.xcconfig: team $TEAM, bundle identifier $BUNDLE, $( (( $#PROFILES )) && echo "manual signing with your four profiles" || echo "automatic signing")"
generate
if (( ! $#PROFILES )); then
  echo "Next: open ios/T3Bot.xcodeproj in Xcode, sign in with your Apple account under Settings > Accounts,"
  echo "choose your iPhone and press Run. Xcode makes the signing profiles for the four targets."
fi
