# Set up T3 Bot: steps for a coding agent

A T3 Code user pasted the prompt from the README into their agent (Claude Code, Codex, a T3 Code thread) and asked it to install T3 Bot on their Mac. These are the steps for that agent. A person can follow them too; [SETUP.md](SETUP.md) explains each part in more detail and has the troubleshooting table.

## Rules for the whole setup

- Run every step that is a command on this Mac yourself. When a step needs the user (an Apple account, a click in Xcode or on developer.apple.com, their iPhone), stop and tell them exactly what to do, then wait for them.
- The token in `~/.config/t3bot/token` and the pairing link that holds it give full access to the user's agents. Never print them, never read the token file into this conversation, never paste them anywhere. Run the installer with `--no-pair`, and do not run `t3bot pair` yourself (step 5 shows the code to the user without you seeing it). Do not print the push key either.
- Put the user's own values (team, bundle identifier) only where `ios/scripts/setup.sh` writes them, in `ios/Config/Local.xcconfig`. Do not edit `ios/project.yml` or `ios/Config/T3Bot.xcconfig`.
- When something fails, run `~/.local/bin/t3bot doctor` and read the end of `~/Library/Logs/t3bot.log` before trying something else. The troubleshooting table at the end of [SETUP.md](SETUP.md#troubleshooting) lists the usual causes.

## 1. Check this Mac

| Check | Command | If it is missing |
|---|---|---|
| T3 Code is installed, open, and has a project | `ls ~/.t3/userdata/statev2.sqlite` | The user installs T3 Code, opens it and creates a project. If it keeps its data elsewhere, set `T3BOT_T3_HOME` |
| Bun | `bun --version` | Install it (`brew install oven-sh/bun/bun`) and say so |
| XcodeGen | `xcodegen --version` | `brew install xcodegen` |
| Xcode 27 | `xcodebuild -version` | The user installs or updates it from the App Store. Do step 2 meanwhile |
| Tailscale | `tailscale status` | See below |

With Tailscale connected on this Mac and on the phone, the server gets an HTTPS address that works at home and away. Without it, the phone reaches the server only on the same Wi-Fi, over plain http. If Tailscale is not set up, tell the user that and ask whether to go on with Wi-Fi only (they can install Tailscale later and run `deploy/install.sh --no-pair` again).

The Mac that runs T3 Code and the Mac with Xcode can be two machines. Then steps 2, 4 and 5 happen on the T3 Code Mac and step 3 on the Xcode Mac.

## 2. Install the server

Clone the repository somewhere permanent, such as where the user keeps their code. The server runs from this folder.

```sh
git clone https://github.com/Soren-Starck/t3-bot ~/t3-bot
cd ~/t3-bot
bin/t3bot setup --dry-run
```

The dry run changes nothing. When T3 Code has several projects, it lists them and stops. Ask the user which project the bots should live in: each bot is a thread in that project, and its agent works in that project's folder. Then install:

```sh
deploy/install.sh --no-pair --project "<project name>"
```

Add `--name "<name>"` when the user wants the bots to call them something other than the first name of their macOS account. The installer starts the server at login (LaunchAgent `com.t3bot.server`), links `t3bot` into `~/.local/bin`, gives the server an address the phone can reach, and creates the first bot, Chief, as a T3 Code thread titled `%BOT Chief`.

Then check:

```sh
~/.local/bin/t3bot doctor
```

Everything except the push key should be ok now. Fix what it flags before going on.

## 3. Build the app with the user's Apple team

Tell the user what this needs from them, and wait until it is ready:

- A paid Apple Developer account, signed in to Xcode (Xcode, Settings, Accounts). A free personal team cannot sign the app's push and communication notification entitlements.
- Their iPhone on iOS 26, connected to this Mac by cable (or paired over Wi-Fi in Xcode), unlocked, with Developer Mode on (iOS Settings, Privacy and Security).

Find the Team ID. The code in brackets in an identity's name is not the Team ID; the Team ID is the `OU` of its certificate:

```sh
security find-identity -v -p codesigning
security find-certificate -c "Apple Development: <name> (<code>)" -p | openssl x509 -noout -subject
```

If there are several teams, or no Apple Development identity yet, ask the user (the Team ID is under Membership on developer.apple.com).

Pick a bundle identifier of the user's own, such as `com.<their name>.t3bot`. It must not be taken by anyone else in Apple's system. Then write the signing settings and generate the project:

```sh
ios/scripts/setup.sh --team <team id> --bundle-id <bundle identifier>
```

Build and install. Find the iPhone's name with `xcrun devicectl list devices`, then:

```sh
cd ios
xcodebuild -project T3Bot.xcodeproj -scheme T3Bot -configuration Release \
  -destination "platform=iOS,name=<iPhone name>" -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device "<iPhone name>" build/DerivedData/Build/Products/Release-iphoneos/T3Bot.app
cd ..
```

macOS may ask the user to let `codesign` use the keychain: they click Always Allow. The first build registers the app's four identifiers (the app, `.notify`, `.widgets`, `.share`) and makes their profiles.

If signing fails, ask the user to open `ios/T3Bot.xcodeproj`, choose the `T3Bot` scheme and their iPhone, and press Run once: Xcode shows what is missing and usually fixes it with one click. A missing capability on the App ID is the usual cause (Push Notifications, Time Sensitive Notifications, Communication Notifications, Keychain Sharing); it is ticked on the identifier at developer.apple.com, Certificates, Identifiers & Profiles. If iOS refuses to open the app because the developer is not trusted, the user trusts it in iOS Settings, General, VPN & Device Management.

## 4. Pushes

Without a push key the app works whenever it is open, and nothing rings. The pushes are the point of the app, so set them up unless the user says no.

Ask the user to create the key: on developer.apple.com, Certificates, Identifiers & Profiles, Keys, add a key with "Apple Push Notifications service (APNs)" enabled, and download the `.p8` file (Apple allows one download). A push key they already have for the same team works too. When they have it:

```sh
mv ~/Downloads/AuthKey_<key id>.p8 ~/.config/t3bot/
chmod 600 ~/.config/t3bot/AuthKey_<key id>.p8
```

The key ID is the ten characters in the file name. Write `~/.config/t3bot/apns.json`, then `chmod 600` it:

```json
{
  "keyId": "<key id>",
  "teamId": "<team id>",
  "keyPath": "~/.config/t3bot/AuthKey_<key id>.p8",
  "topic": "<the bundle identifier from step 3>"
}
```

The server reads it when it sends, so there is no restart. `t3bot doctor` should now report the push key as ok.

## 5. Pair the phone

The pairing code holds the token, so it goes on the user's screen and not into this conversation. Open a Terminal window for them that shows it:

```sh
printf '#!/bin/zsh\n~/.local/bin/t3bot pair\nread -sk "?Scan the code, then press a key to close. "\n' > /tmp/t3bot-pair.command
chmod +x /tmp/t3bot-pair.command
open /tmp/t3bot-pair.command
```

Tell the user: open T3 Bot on the iPhone, scan the code from its connect screen, and allow notifications when it asks. If the code does not scan, they can run `~/.local/bin/t3bot pair --invert` in a terminal of their own.

Once they are in, check that a push reaches the phone:

```sh
curl -s -X POST -H "Authorization: Bearer $(cat ~/.config/t3bot/token)" \
  -H 'content-type: application/json' -d '{}' http://127.0.0.1:8809/v1/test-push
```

The answer should hold `"devices":1` and `"push":true`, and the phone should ring within seconds. `"devices":0` means the app has not registered yet: the user opens it once more and allows notifications.

## 6. Tell the user

In a few lines:

- What was installed, and where the clone is.
- The address the phone uses (from `t3bot doctor`), and whether it works away from home.
- To try it: send Chief a message from the phone, or run `t3bot notify --kind do --title "Hello from my Mac"`.
- To update: `git pull` in the clone, then `deploy/install.sh --no-pair`, and rebuild the app (step 3) when `ios/` changed.
- To undo: `deploy/install.sh --uninstall`, then `rm -r ~/.config/t3bot ~/.local/share/t3bot`. The bots' threads stay in T3 Code.
- T3 Bot reads T3 Code's local data, not a public API, so a T3 Code update can break it. `t3bot doctor` is the first thing to run when something stops working.
