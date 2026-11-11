# Architecture

T3 Bot is an iPhone app that talks to a T3 Code you already run. Since 0.3.0 it pairs with T3 Code directly and nothing else runs on your Mac. Two more parts are optional: a push sender, so the phone rings, and the T3 Bot server of earlier versions, for what T3 Code alone does not give.

```
   your computer                                        your iPhone
 ┌───────────────────────────────┐                ┌──────────────────────────────┐
 │  T3 Code                      │   HTTPS and    │  T3 Bot app (SwiftUI)        │
 │   ├─ HTTP API   ◄─────────────┼── websocket ───┼─► ios/Direct                 │
 │   ├─ websocket  ◄─────────────┼── Bearer ──────┤    T3Link, T3Socket,         │
 │   └─ Claude provider          │                │    DirectBackend,            │
 │        hooks (curl) ──┐       │                │    DirectRouter              │
 └───────────────────────┼───────┘                └──────────────▲───────────────┘
                         ▼                                       │
               your push sender (push/, Vercel) ──► Apple push service
```

## Direct mode

The Swift package in `ios/Direct` is the only code in the app that knows about T3 Code. Its sources are compiled into the app and into each extension.

| File | Job |
|---|---|
| `T3Link.swift` | Pairing and HTTP. Reads T3 Code's pairing links, trades the one-time code for a bearer token at `POST /oauth/token`, reads the environment descriptor at `/.well-known/t3/environment`, and fetches snapshots |
| `T3Socket.swift`, `T3Wire.swift` | The websocket at `/ws` and its messages. A one-time ticket from `POST /api/auth/websocket-ticket/rpc` opens it |
| `DirectBackend.swift` | An actor that holds the state of one pairing: the thread list, the open threads, scheduled tasks. It subscribes to changes (`orchestration.subscribeShell`, `orchestration.subscribeThread`) and sends commands (`orchestration.dispatchCommand`, `orchestration.launchThread`) |
| `DirectRouter.swift` | Answers the `v1/...` paths the app was written against, in process, from the backend's state. The screens do not know which kind of pairing they are on |
| `Compose.swift`, `BotBook.swift`, `Roster.swift`, `Rules.swift`, `Skins.swift`, `T3Text.swift` | Build the home screen, the bots and their state, the copy of the bots that the notification extension and the widgets read, the standing rules a new bot is given, faces, and the one-line previews |
| `HookSettings.swift` | Writes and reads the notification hooks in a Claude provider's launch arguments |

How a pairing works:

- The link or code from T3 Code's Settings > Sharing & access is traded for a token that lasts 30 days. The token is kept in the iPhone's Keychain, in a group the extensions share.
- Snapshots come over HTTP. The websocket carries what changes after that, so home and an open chat stay current without polling. The extensions read over HTTP and open a socket only to send.
- Messages, answers to questions and approvals go to T3 Code as its own commands: `message.dispatch`, `runtime-request.respond`, `thread.user-input.dismiss`, `thread.metadata.update`, `thread.archive`.
- The app checks T3 Code's protocol version and refuses one it does not know ("This T3 Code is too new") instead of guessing.

A bot is a T3 Code thread titled `%BOT <Name>` (a group chat: `%BOT Group: <Name>`), in any project. T3 Code has no place for a face or a job, so those live on the phone. A bot made on the phone also carries them in a marker line of its first message, so a second phone paired with the same T3 Code shows the same bot.

Not served in direct mode, because they are the server's own features: notes and cards from `t3bot notify`, sources and handlers, drafts, the phone's calendar and contacts, the evening summary and morning brief, images a bot wrote on the Mac (`v1/file`), and Live Activity updates sent by push. Quiet hours, snoozes and quick replies are kept on the phone.

`swift test` in `ios/Direct` runs the package's tests on a Mac. `ios/Direct/live-test.sh` runs the live ones against the T3 Code on that Mac.

## Notifications in direct mode

T3 Code does not send pushes for other apps, and nothing of T3 Bot runs on the Mac. So the app asks Claude Code to tell it:

1. The phone sends its push token to the push sender (`POST /api/address`) and gets back a sealed address that only that sender can open.
2. The app writes Claude Code hooks into the launch arguments of each Claude provider in T3 Code's settings, as a `--settings` argument (`server.updateSettings`). A `PermissionRequest` hook covers every Claude thread that asks a question or needs an approval. A `Stop` hook covers the bot threads, for finished replies.
3. When a hook fires, it runs `curl` against the sender's `POST /api/ring` with the sealed address, the thread's id and the kind of event.
4. The sender (`push/`, three small Vercel functions) opens the address and sends the push with your Apple key. It stores nothing.
5. On the phone, the notification service extension reads the question or the reply from T3 Code and shows it as a message from the bot.

The sender never sees the content of a thread. It exists because Apple only accepts pushes for an app from a key of the team that signed it, and a hook on your Mac should not hold that key. Each person who builds the app deploys their own: [push/README.md](../push/README.md).

Only Claude threads ring this way. Codex has no hook that T3 Bot can use yet.

## The app

SwiftUI, iOS 26, generated with XcodeGen from `ios/project.yml`. Four targets:

| Target | Job |
|---|---|
| `T3Bot` | The app: home, a bot's conversation, cards, Review, search, settings, the connect screen |
| `T3BotNotify` | Notification service extension. Turns a push into a message from the bot, with its face |
| `T3BotWidgets` | Home Screen and Lock Screen widgets, and the Live Activity |
| `T3BotShare` | Share extension: send a link, text or images to a bot |

The app holds one pairing at a time, with T3 Code or with a T3 Bot server, and a few caches. It applies your actions at once, with a short Undo window before Done and Not now are sent.

Bot faces are BoopFace, animated on the device. Paired with a server, notifications, widgets and lists use a still PNG that the server serves; for a bot made or recoloured in the app, the server draws that PNG with headless Chrome or Chromium (`tools/faces/render.ts`), and without a browser it serves the stock picture of the face.

## The optional server

```
        your Mac                                             your iPhone
 ┌──────────────────────────────────────────────┐      ┌────────────────────────┐
 │  T3 Code                                     │      │  T3 Bot app (SwiftUI)  │
 │   ├─ SQLite projection   ──── read only ──┐  │      │   bots, needs, review  │
 │   └─ local websocket     ◄── commands ─┐  │  │      │   widgets, Live        │
 │                                        │  │  │      │   Activity, share,     │
 │  T3 Bot server (Bun, one process)      │  │  │      │   notification service │
 │   server/t3.ts  ───────────────────────┴──┘  │      └───────────▲────────────┘
 │   server/t3bot.ts   HTTP on 127.0.0.1:8809 ◄─┼── HTTPS, Bearer ──┘
 │   server/push.ts ────────────────────────────┼──► Apple push service ──► phone
 │        ▲                    │                │
 │   t3bot CLI          your sources and        │
 │   (scripts, agents)  handlers (commands)     │
 └──────────────────────────────────────────────┘
```

One Bun process with no dependencies, beside T3 Code on a Mac that stays on. The phone pairs with it instead of with T3 Code. It was the only way in until 0.2.0 and still gives what direct mode does not: cards from scripts, sources and handlers, drafts, the phone's calendar and contacts, pushes held during quiet hours, the summaries, and pushes for every provider.

Three files do the work; `server/config.ts` finds the config, the token and the folders, `server/text.ts` makes the one-line previews, the search snippets and the quick replies (the demo uses the same file, so both answer alike), and `server/qr.ts` draws the pairing code in the terminal.

**`server/t3.ts`** is the only code that knows about T3 Code.

- Reads go to T3 Code's SQLite database, opened read only: threads and their titles, runs and their status, messages, pending questions and approvals, what a run is doing right now, and scheduled tasks.
- Writes go through T3 Code's local websocket as ordinary commands (send a message, answer a question, create a thread, settle or rename one). The session token comes from T3 Code's own command line tool and lasts 12 hours. With `T3BOT_READONLY=1` nothing is sent.
- It never writes to T3 Code's database.

**`server/t3bot.ts`** is the HTTP API the app talks to, plus a loop that runs every five seconds.

- It builds the home screen: your bots with their state (working, waiting on you, watching, asleep) and the ranked list of cards.
- Cards come from T3 Code's pending requests, from notes (`POST /v1/notify`) and from your sources. See [CARDS.md](CARDS.md).
- The loop compares the current state with what it has already announced and sends a push for what is new: a question, a finished reply, an urgent card, the morning and evening summaries. Quiet hours hold pushes. On first run it records a baseline, so nothing old rings.
- It keeps its own small SQLite file in `~/.local/share/t3bot/` for snoozes, notes, registered phones and settings, and the photos sent from the phone beside it. `keepDays` in the config says how long old notes, card taps and photos stay ([SETUP.md](SETUP.md#what-the-server-keeps)).
- It keeps bot threads tidy in T3 Code: the `%BOT <Name>` title, unpinned, settled when the bot has finished and nothing waits on you.

**`server/push.ts`** sends pushes to Apple with your own key, including Live Activity updates. With no key, or with `T3BOT_NO_PUSH=1`, it logs and skips.

The config file is read again when it changes. See [SETUP.md](SETUP.md#the-config-file).

### The CLI

`bin/t3bot.ts` is a client of the server's HTTP API, plus the setup commands. It does not talk to T3 Code directly.

| Command | What it does |
|---|---|
| `t3bot setup` | First run: finds T3 Code, creates the first bot, writes the config, and the token if there is none |
| `t3bot pair` | Prints the pairing link and a QR code |
| `t3bot doctor` | Checks Bun, T3 Code, the config, each bot's thread, the token, the server, the phone's address and the push key |
| `t3bot demo` | Starts the demo server on this computer only and prints its pairing link. `--lan` opens it to a phone on the same Wi-Fi |
| `t3bot notify` | Puts a card on the phone |
| `t3bot draft` | Leaves a message, mail or event for you to send from the phone |
| `t3bot needs` | Prints the ranked list |
| `t3bot phone` | Reads what the phone shared: `calendar`, `contacts <name>` |
| `t3bot connect '<link>'` | On another computer of yours: saves the server's address and token from a pairing link |
| `t3bot roster`, `home`, `agent <id>` | Print the bots, the home screen or one bot's conversation, for scripts |
| `t3bot version` | Prints the version |

### The demo server

`server/demo.ts` speaks the same HTTP API with made-up data held in memory and no T3 Code. It exists so the app can be tried, developed and screenshotted without an install. Its token is `demo`. It sends no pushes.

It listens on `127.0.0.1`, this computer only, because its token is public. `--lan` opens it to a phone on the same Wi-Fi (`--host <address>` and `T3BOT_DEMO_HOST` do the same for one address). `--frozen` stops its bots from working on their own, for screenshots. `POST /v1/demo/reset` puts the data back as it was at start, and `POST /v1/cards/undo` exists only there. `bun server/demo-check.ts --url http://127.0.0.1:8810` starts nothing: it asks a running demo for every route the app uses and checks the answers.

### HTTP API

Everything under `/v1/` needs `Authorization: Bearer <token>`, except the bots' face pictures under `/v1/avatars/`, which notifications load without one. `/health` is open.

| Route | Purpose |
|---|---|
| `GET /v1/hello` | Checks an address and token. Returns the server's name, version, your display name, and whether it is the demo and whether push is configured |
| `GET /v1/home` | Bots and the ranked list |
| `GET /v1/agents/<id>` | One bot's conversation, cards, routines and watched threads |
| `POST /v1/agents/<id>/send` | Send text and up to six images |
| `POST /v1/answer` | Answer a question or an approval |
| `POST /v1/cards/act` | Run a card's button |
| `POST /v1/cards/done`, `/snooze`, `/handle` | Done, Not now and Handle it, by card id |
| `POST /v1/notify` | Add a note |
| `GET /v1/know` | What agents did alone today |
| `POST /v1/notes/wrong` | Mark one of those as wrong. The bot is told |
| `GET /v1/search?q=` | Search bot conversations and cards. Each hit has a one-line snippet around the match, cut at whole words |
| `GET`, `POST /v1/settings` | Quiet hours, morning brief, quick replies. The saved quick replies come back as a message's `suggestions` only when the bot's last message asks something and has no suggestions of its own |
| `POST /v1/devices`, `/v1/devices/remove` | Register a phone for pushes, or forget it |
| `POST /v1/live` | Register a Live Activity for a bot that is working |
| `POST /v1/test-push` | Send a test push to the registered phones |
| `POST /v1/share` | What the share extension sends: a link, text or images for a bot |
| `POST /v1/agents`, `POST /v1/agents/<id>/edit` | Create and edit bots |
| `GET /v1/skins` | The faces a new bot can take |
| `POST /v1/routines/enabled` | Turn one of a bot's scheduled tasks on or off |
| `POST /v1/phone/sync`, `/v1/phone/forget` | The calendar and contacts the phone shares, and removing them |
| `GET /v1/phone/calendar`, `/v1/phone/contacts?q=` | What `t3bot phone` reads |
| `GET /v1/file?path=` | An image a bot wrote on the Mac, for the conversation |
| `GET /v1/avatars/<id>.png` | A bot's still face. No token |

The API is the app's own and can change between versions. The pairing link is `t3bot://connect?url=<percent-encoded address>&token=<token>`.

## What it relies on in T3 Code

None of this is a documented public API of T3 Code. It works with the versions it was tested against and can break with an update.

In direct mode:

- The pairing routes (`/oauth/token`, `/.well-known/t3/environment`, `/api/auth/websocket-ticket/rpc`) and the pairing link formats.
- The websocket at `/ws`, its RPC names and the shape of its snapshots and events.
- Provider instance settings: `server.getConfig`, `server.updateSettings` and the Claude provider's `launchArgs`.
- Claude Code's `--settings` argument and its `PermissionRequest` and `Stop` hooks.

With the server:

- The location and schema of the SQLite projection (`~/.t3/userdata/`), including table and column names.
- The local websocket and its command names (`message.dispatch`, `runtime-request.respond`, `thread.create` and a few thread housekeeping commands).
- `auth session issue` in T3 Code's command line tool.
- The `t3code://threads/...` link, to open a thread in T3 Code's own app.

T3 Code also has documented ways in for outside programs: an MCP endpoint and the `t3 thread` commands. T3 Bot does not use them yet. MCP covers messages and questions; the `t3 thread` commands cover messages only. Neither covers approvals, and neither has a way to tell a client that something changed, so the lock screen would lag.

## Security

In direct mode:

- The phone holds a T3 Code token with the access of the link you made. Anyone with that token can message your agents, and your agents can run commands on your computer. It is kept in the iPhone's Keychain, lasts 30 days, and you can remove the phone under Settings > Sharing & access in T3 Code at any time.
- A pairing code works once and for a few minutes. Treat a fresh link like a password all the same.
- The hooks are plain text in T3 Code's provider settings. They hold the sender's address and a sealed phone address, not your push key. "Ring this phone" off removes them.
- The push sender holds your Apple push key and a sealing key as Vercel environment variables. It only pushes to the bundle identifiers you allow, and it slows a flood of calls. What reaches it: a sealed address, a thread id, and the kind of event.

With the server:

- The server binds to `127.0.0.1` unless `T3BOT_HOST` says otherwise. You choose what forwards to it. With `tailscale serve` that is your own tailnet. Installed without Tailscale, it binds to every interface so the phone can reach it at home, over plain http: anyone on that network can see the traffic.
- One bearer token guards everything. Anyone who has it can message your agents, and your agents can run commands on your Mac. Keep it and the pairing link private. To rotate it, delete `~/.config/t3bot/token` and run `deploy/install.sh`: it writes a new one, restarts the server and prints the new pairing code.
- The token and the push key live in `~/.config/t3bot/` with owner-only permissions. Nothing in that folder belongs in git.
- Handlers and sources run with your user's rights. Only put commands you wrote in the config.
- The image route serves only images under your home or temp folders, and refuses credential folders such as `.ssh` and `.config`. The face pictures are the only thing served without the token.
- A bot can read the calendar and contacts the phone shared with the server only after you turn that on in the app. Drafts are never sent by the server.
