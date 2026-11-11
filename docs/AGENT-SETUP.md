# Set up T3 Bot: steps for a coding agent

A T3 Code user pasted the prompt from the README into their agent (Claude Code, Codex, a T3 Code thread) and asked it to set T3 Bot up. These are the steps for that agent. A person can follow them too; [SETUP.md](SETUP.md) explains each part in more detail and has the troubleshooting table.

Since 0.3.0 the app pairs straight with T3 Code, so the setup is: build the app, install it on the iPhone, pair, and optionally deploy the push sender so the phone rings. That is part 1. The T3 Bot server is optional and is part 2: do it only when the user asks for it, or wants what only it gives (cards from their scripts with `t3bot notify`, drafts, calendar and contacts sharing, pushes held at night, a morning brief, notifications from Codex threads).

## Rules for the whole setup

- Run every step that is a command on this Mac yourself. When a step needs the user (an Apple account, a click in Xcode, T3 Code or developer.apple.com, their iPhone), stop and tell them exactly what to do, then wait for them.
- Secrets stay out of this conversation: T3 Code's pairing code and link, the Apple push key (`.p8`), the sender's `SEAL_KEY`, and in part 2 the token in `~/.config/t3bot/token` and the link from `t3bot pair`. Never print them, never read them into the chat, never paste them anywhere. The user creates and scans pairing codes on their own screen: in part 2, run the installer with `--no-pair` and do not run `t3bot pair` yourself, because its output would land in this conversation.
- Put the user's own values (team, bundle identifier, push host) only where `ios/scripts/setup.sh` writes them, in `ios/Config/Local.xcconfig`. Do not print that file. Do not edit `ios/project.yml` or `ios/Config/T3Bot.xcconfig`.
- Tell the user the limits before you start: there is no TestFlight or App Store build, so this needs Xcode and a paid Apple Developer account; and without the push sender of step 4 the app works and does not ring.
- The troubleshooting table in [SETUP.md](SETUP.md#troubleshooting) lists the usual causes when something fails.

# Part 1: the app, paired with T3 Code

## 1. Check this Mac

| Check | Command | If it is missing |
|---|---|---|
| Xcode 27 | `xcodebuild -version` | The user installs or updates it from the App Store |
| XcodeGen | `xcodegen --version` | `brew install xcodegen` |
| T3 Code runs, with a project | Ask the user | The user installs T3 Code, opens it and creates a project. It can be on another computer |

Bun and Tailscale are not needed for this part.

## 2. Build the app with the user's Apple team

Clone the repository somewhere permanent, such as where the user keeps their code:

```sh
git clone https://github.com/Soren-Starck/t3-bot ~/t3-bot
cd ~/t3-bot
```

Tell the user what the build needs from them, and wait until it is ready:

- A paid Apple Developer account, signed in to Xcode (Xcode, Settings, Accounts). A free personal team cannot sign the app's push and communication notification entitlements.
- Their iPhone on iOS 26, connected to this Mac by cable (or paired over Wi-Fi in Xcode), unlocked, with Developer Mode on (iOS Settings, Privacy and Security).

Find the Team ID. The code in brackets in an identity's name is not the Team ID; the Team ID is the `OU` of its certificate:

```sh
security find-identity -v -p codesigning
security find-certificate -c "Apple Development: <name> (<code>)" -p | openssl x509 -noout -subject
```

If there are several teams, or no Apple Development identity yet, ask the user (the Team ID is under Membership details on developer.apple.com).

Ask the user for a bundle identifier prefix of their own, in reverse-domain form. It must not be taken by anyone else in Apple's system, and the script refuses the example prefixes. Then write the signing settings and generate the project:

```sh
ios/scripts/setup.sh --team <team id> --bundle-prefix <prefix>
```

The app's bundle identifier becomes `<prefix>.t3bot`. Build, install and open it on the iPhone:

```sh
ios/scripts/run-on-iphone.sh
```

It finds the one iPhone this Mac can reach (pass a device identifier from `xcrun devicectl list devices` when there are several), builds into `ios/build` and writes its log to `ios/build/run-on-iphone.log`. It builds Debug by default; `CONFIG=Release ios/scripts/run-on-iphone.sh` builds Release.

macOS may ask the user to let `codesign` use the keychain: they click Always Allow. The first build registers the app's four identifiers (the app, `.notify`, `.widgets`, `.share`) and makes their profiles.

If signing fails, ask the user to open `ios/T3Bot.xcodeproj`, choose the `T3Bot` scheme and their iPhone, and press Run once: Xcode shows what is missing and usually fixes it with one click. A missing capability on the App ID is the usual cause (Push Notifications, Time Sensitive Notifications, Communication Notifications, Keychain Sharing); it is ticked on the identifier at developer.apple.com, Certificates, Identifiers & Profiles. If iOS refuses to open the app because the developer is not trusted, the user trusts it in iOS Settings, General, VPN & Device Management.

## 3. Pair

This step is the user's. Do not create a pairing code yourself: it would pass through this conversation. Tell them:

1. On the computer, in T3 Code, open Settings > Sharing & access and choose Create link.
2. On the iPhone, open T3 Bot, tap "Scan the code from T3 Code" and point it at the QR code.
3. Away from home, or when T3 Code runs on a machine the phone cannot reach on the local network: "Other ways to connect" > "Enter code", with their T3 Connect or Tailscale address and the link's code.

When T3 Code runs headless, the user runs `t3 pair` in a terminal of their own instead of step 1: it prints the same kind of QR code.

A code works once and for a few minutes. When the app shows the home screen, the pairing is done. If the user has no thread titled `%BOT <Name>` yet, they make their first bot in the app.

## 4. Notifications (optional, ask first)

Without this the app works whenever it is open and nothing rings. It needs a small push sender that the user deploys on their own Vercel account with their own Apple push key, because Apple only lets the owner of the app's signing team send it pushes. Explain that and ask whether to set it up now.

It needs from the user:

- an APNs key: on developer.apple.com, Certificates, Identifiers & Profiles, Keys, add a key with "Apple Push Notifications service (APNs)" enabled and download the `.p8` file (Apple allows one download). A push key they already have for the same team works too;
- a Vercel account, with its CLI signed in on this Mac (`vercel whoami`).

Then follow [push/README.md](../push/README.md) from the clone. Feed the key to `vercel env add` from its file, never through the chat, and make sure the sender's allowed apps hold the bundle identifier from step 2. When the sender is deployed, point the build at its host name and install again:

```sh
ios/scripts/setup.sh --push-host <the sender's host name>
ios/scripts/run-on-iphone.sh
```

Ask the user to open the app, allow notifications, and under Settings > Notifications check that "Ring this phone" is on, then tap "Send a test push". The phone should ring within seconds. "Ring this phone" adds Claude Code hooks to T3 Code's Claude provider settings; tell the user so, and that turning it off removes them.

Only Claude threads ring this way: a question or an approval from any Claude thread, and a finished reply from a bot. Codex threads do not ring yet. A thread that was already running rings from its next session.

## 5. Tell the user

In a few lines:

- What was built and installed, and where the clone is.
- How the phone reaches T3 Code (home network, T3 Connect or Tailscale), and that the pairing lasts 30 days.
- Whether notifications are set up, and what rings.
- To update: `git pull` in the clone, then `ios/scripts/run-on-iphone.sh`.
- To undo: turn off "Ring this phone", remove the phone under Settings > Sharing & access in T3 Code, delete the app.
- T3 Bot talks to T3 Code through the API its own clients use, not a documented public one, so a T3 Code update can break it.

# Part 2 (optional): the T3 Bot server

Do this part only when the user wants the server. The phone then pairs with the server instead of with T3 Code, and the server sends pushes itself, so step 4 above is not needed. The app is the same build.

## 6. Check the server Mac

The server runs on the Mac that runs T3 Code, which must stay on.

| Check | Command | If it is missing |
|---|---|---|
| T3 Code is installed, open, and has a project | `ls ~/.t3/userdata/statev2.sqlite` | The user installs T3 Code, opens it and creates a project. If it keeps its data elsewhere, set `T3BOT_T3_HOME` |
| Bun | `bun --version` | Install it (`brew install oven-sh/bun/bun`) and say so |
| Tailscale | `tailscale status` | See below |

With Tailscale connected on this Mac and on the phone, the server gets an HTTPS address that works at home and away. Without it, the phone reaches the server only on the same Wi-Fi, over plain http. If Tailscale is not set up, tell the user that and ask whether to go on with Wi-Fi only (they can install Tailscale later and run `deploy/install.sh --no-pair` again).

## 7. Install the server

The server runs from the clone, so the clone must stay where it is.

```sh
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

## 8. Pushes from the server

The server sends pushes with a push key of the user's team, kept on this Mac. Without it the app works whenever it is open, and nothing rings.

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
  "topic": "<the bundle identifier from step 2>"
}
```

The server reads it when it sends, so there is no restart. `t3bot doctor` should now report the push key as ok.

## 9. Pair the phone with the server

The pairing code holds the token, so it goes on the user's screen and not into this conversation. Open a Terminal window for them that shows it:

```sh
printf '#!/bin/zsh\n~/.local/bin/t3bot pair\nread -sk "?Scan the code, then press a key to close. "\n' > /tmp/t3bot-pair.command
chmod +x /tmp/t3bot-pair.command
open /tmp/t3bot-pair.command
```

Tell the user: open T3 Bot on the iPhone, scan the code from its connect screen, and allow notifications when it asks. If the app is already paired with T3 Code, they first tap Disconnect at the bottom of the app's Settings to get back to the connect screen. If the code does not scan, they can run `~/.local/bin/t3bot pair --invert` in a terminal of their own.

Once they are in, check that a push reaches the phone:

```sh
curl -s -X POST -H "Authorization: Bearer $(cat ~/.config/t3bot/token)" \
  -H 'content-type: application/json' -d '{}' http://127.0.0.1:8809/v1/test-push
```

The answer should hold `"devices":1` and `"push":true`, and the phone should ring within seconds. `"devices":0` means the app has not registered yet: the user opens it once more and allows notifications.

## 10. Tell the user

In a few lines:

- What was installed, and where the clone is.
- The address the phone uses (from `t3bot doctor`), and whether it works away from home.
- To try it: send Chief a message from the phone, or run `t3bot notify --kind do --title "Hello from my Mac"`.
- To update: `git pull` in the clone, then `deploy/install.sh --no-pair`, and rebuild the app (step 2) when `ios/` changed.
- To undo: `deploy/install.sh --uninstall`, then `rm -r ~/.config/t3bot ~/.local/share/t3bot`. The bots' threads stay in T3 Code.
- The server reads T3 Code's local data, not a public API, so a T3 Code update can break it. `t3bot doctor` is the first thing to run when something stops working, and its log is `~/Library/Logs/t3bot.log`.
