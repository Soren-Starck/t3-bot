# Push sender

When T3 Bot is paired straight with T3 Code (no T3 Bot server), the phone rings through Claude Code hooks that T3 Bot
adds to T3 Code's Claude provider settings. A hook cannot hold an Apple push key, so it calls this sender, which holds
the key and sends the push. It is three small routes for Vercel, with no database and no packages.

Apple only accepts pushes for an app from the team that signs it, so there is no shared sender. A build signed by
your team rings only through a sender that holds your team's push key. **Deploy your own**: about ten minutes, below.

## Your own sender

You need the app already building with your team (`ios/scripts/setup.sh`, see [docs/SETUP.md](../docs/SETUP.md)), a
Vercel account (the free plan is enough) and the Vercel CLI (`npm i -g vercel` or `bun add -g vercel`, then
`vercel login`).

**1. Make a push key.** On developer.apple.com: Certificates, Identifiers & Profiles > Keys > the + button. Name it,
tick Apple Push Notifications service (APNs), and where it asks for an environment choose "Sandbox & Production".
Register it and download `AuthKey_XXXXXXXXXX.p8` (Apple gives the file once). If you already made a key for the T3 Bot server,
use that one. Write down three values:

| Value | Where it is |
|---|---|
| Key ID | The ten characters in the file name, also shown on the key's page |
| Team ID | developer.apple.com > Membership details. The one you gave `setup.sh` |
| Bundle identifier | The one you gave `setup.sh` (`T3BOT_BUNDLE_ID` in `ios/Config/Local.xcconfig`), for example `com.yourname.t3bot` |

**2. Deploy.** From the repository:

```sh
cd push
vercel link     # answer no to linking an existing project, and give the new one a name
openssl rand -base64 32 | vercel env add SEAL_KEY production --sensitive
vercel env add APNS_KEY production --sensitive < ~/Downloads/AuthKey_XXXXXXXXXX.p8
printf %s XXXXXXXXXX | vercel env add APNS_KEY_ID production
printf %s YYYYYYYYYY | vercel env add APNS_TEAM_ID production
printf %s com.yourname.t3bot | vercel env add ALLOWED_TOPICS production
vercel deploy --prod
```

**3. Check it.** Use the project's production domain, the one Vercel lists under Domains (usually
`<project name>.vercel.app`). The address with a hash that each deploy prints sits behind a Vercel login by default, so
the phone cannot use it.

```sh
curl https://your-sender.vercel.app/api/health
```

`{"ok":true}` means every setting is there and the key signs. Otherwise the answer names the setting to fix. A
changed setting only counts after another `vercel deploy --prod`.

**4. Point the app at it.** The app learns the sender when it is built, from the build setting `T3BOT_PUSH_HOST` in
`ios/Config/Local.xcconfig` (the file `setup.sh` wrote, not committed). `setup.sh` sets it for you and keeps your
team and bundle identifier. Give it the host name, with no `https://` and no path. From the `push` folder:

```sh
../ios/scripts/setup.sh --push-host your-sender.vercel.app
```

Build and install the app again (Run in Xcode, or `../ios/scripts/run-on-iphone.sh`). On the phone, paired with T3 Code: Settings > Notifications > Ring this phone, then
Send a test push. Turning Ring this phone on is what writes the hooks, with your sender's address in them, into T3
Code's Claude settings; nothing is edited by hand on the Mac. If the phone already rang through another sender, turn
Ring this phone off and on once.

When the test fails, the app shows the sender's answer:

| Answer | Cause |
|---|---|
| this sender does not push to that app | `ALLOWED_TOPICS` is not the app's bundle identifier, or the build still points at another sender (step 4) |
| this sender is not set up: ... | A setting is missing or malformed. `/api/health` says the same |
| InvalidProviderToken | `APNS_KEY_ID` or `APNS_TEAM_ID` does not match the key |
| BadEnvironmentKeyInToken | The key was made for one environment only. Make one for "Sandbox & Production" |
| TopicDisallowed | The key is restricted to other apps, or the bundle identifier is wrong |
| BadDeviceToken | The app was reinstalled or signed differently. Turn Ring this phone off and on |

## Settings

| Variable | Value |
|---|---|
| `SEAL_KEY` | 32 random bytes in base64. Seals the addresses. Changing it cancels every address handed out |
| `APNS_KEY` | The text of the `.p8` file |
| `APNS_KEY_ID` | The key's ten character ID |
| `APNS_TEAM_ID` | Your ten character team ID |
| `ALLOWED_TOPICS` | The app's bundle identifier. Several, separated by commas, if one sender serves several builds of your team |
| `ADDRESS_MAX_AGE_DAYS` | Optional. Refuses addresses older than this many days. Leave it unset for now: the app keeps its address and does not ask for a new one |

## What it does

| Route | Body | Answer |
|---|---|---|
| `POST /api/address` | `{token, env, topic}`: the phone's push token in hex, `sandbox` or `production`, the app's bundle identifier | `{ok, address}` |
| `POST /api/ring` | `{to, thread, kind}`: an address, a thread id, and `request`, `reply` or `test` | `{ok}` |
| `GET /api/health` | | `{ok}`, or the names of the settings to fix |

The phone asks for an address once: its push token, sealed with `SEAL_KEY` so that only this sender can read it. The
hooks carry the address and send it with the thread's id each time a Claude thread asks something or a bot's thread
finishes. The sender sends a fixed alert ("A bot needs you", "A bot answered") and the phone reads the real words from
T3 Code. Nothing is stored, and the logs hold no token and no address.

A build installed from Xcode has a sandbox token; TestFlight and the App Store give production ones. The app says which
when it asks for its address. When Apple answers that a token is not of that environment, the sender tries the other
one once.

Every failure is JSON: `{ok: false, code, error}`.

| Status | `code` | Meaning |
|---|---|---|
| 400 | `bad_token`, `bad_env`, `bad_kind`, `bad_thread`, `bad_json`, `too_long` | The request is malformed |
| 400 | `bad_address` | Not an address this sender made |
| 403 | `not_this_app` | The bundle identifier is not in `ALLOWED_TOPICS` |
| 405, 413, 415 | `method`, `too_large`, `content_type` | POST only, bodies up to 2 KB, `content-type: application/json` |
| 410 | `gone`, `expired` | With `gone: true`. Apple no longer knows the phone, or the address is too old: drop the address |
| 429 | `too_many` | Too many requests. Try again after a minute |
| 502 | `apns_auth`, `apns_unreachable`, `apns_refused` | Apple refused the sender's key, did not answer, or refused the push |
| 503 | `not_configured` | A setting is missing; `error` names it |

## Who can ring a phone

There are no accounts, so here is what a caller needs and what it gets.

- A ring needs an address, and only the sender can make one. The caller chooses none of the words, the app or the
  phone: the alert text is fixed, and the address fixes the phone and the app. The sender cannot be used to push to
  another app or to send someone a message.
- An address needs the phone's push token, 32 random bytes that iOS gives to the app alone. A stranger cannot guess
  one. Whoever does hold a phone's token can get an address for it and ring it with the fixed alert; the sender has no
  way to tell that caller from the app without a check built into the app (App Attest), which it does not have.
- An address rings its phone until `SEAL_KEY` changes. It sits in T3 Code's Claude launch arguments on the Mac, so
  treat that Mac's settings as you treat its other secrets. To cancel every address: set a new `SEAL_KEY`, deploy,
  then turn Ring this phone off and on.
- Limits: 30 rings a minute per phone (however many addresses it has), 120 rings and 20 addresses a minute per
  caller. They are counted in memory, per running instance, because nothing is stored: they slow a flood and are not
  a hard ceiling. For one, add a rate limit rule for `/api/` in the Vercel project's Firewall.
- Rings for one thread and kind replace each other on the phone instead of piling up.

## Tests

```sh
bun test
```

They run without a network: Apple is a local stand-in, and no push is sent.
