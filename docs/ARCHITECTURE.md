# Architecture

T3 Bot is three small parts around a T3 Code install you already have.

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

## The server

One Bun process with no dependencies. Three files do the work; `server/config.ts` finds the config, the token and the folders, `server/text.ts` makes the one-line previews, the search snippets and the quick replies (the demo uses the same file, so both answer alike), and `server/qr.ts` draws the pairing code in the terminal.

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

## The app

SwiftUI, iOS 26, generated with XcodeGen from `ios/project.yml`. Four targets:

| Target | Job |
|---|---|
| `T3Bot` | The app: home, a bot's conversation, cards, Review, search, settings, the connect screen |
| `T3BotNotify` | Notification service extension. Turns a push into a message from the bot, with its face |
| `T3BotWidgets` | Home Screen and Lock Screen widgets, and the Live Activity |
| `T3BotShare` | Share extension: send a link, text or images to a bot |

The app holds no state of its own beyond the server address, the token and a few caches. It refreshes from the server while open and applies your actions at once, with a short Undo window before Done and Not now reach the server.

The server address and token are saved by the app and mirrored into a shared Keychain group so the extensions can read them.

Bot faces are BoopFace, animated on the device. Notifications, widgets and lists use a still PNG that the server serves. For a bot made or recoloured in the app, the server draws that PNG with headless Chrome or Chromium (`tools/faces/render.ts`). Without a browser it serves the stock picture of the face, in the face's own colour.

## The CLI

`bin/t3bot.ts` is a client of the same HTTP API, plus the setup commands.

| Command | What it does |
|---|---|
| `t3bot setup` | First run: finds T3 Code, creates the first bot, writes the config, and the token if there is none |
| `t3bot pair` | Prints the pairing link and a QR code |
| `t3bot doctor` | Checks Bun, T3 Code, the config, each bot's thread, the token, the server, the phone's address and the push key |
| `t3bot demo` | Starts the demo server and prints its pairing link |
| `t3bot notify` | Puts a card on the phone |
| `t3bot draft` | Leaves a message, mail or event for you to send from the phone |
| `t3bot needs` | Prints the ranked list |
| `t3bot phone` | Reads what the phone shared: `calendar`, `contacts <name>` |
| `t3bot connect '<link>'` | On another computer of yours: saves the server's address and token from a pairing link |
| `t3bot roster`, `home`, `agent <id>` | Print the bots, the home screen or one bot's conversation, for scripts |
| `t3bot version` | Prints the version |

## The demo server

`server/demo.ts` speaks the same HTTP API with made-up data held in memory and no T3 Code. It exists so the app can be tried, developed and screenshotted without an install. Its token is `demo`. It sends no pushes.

It listens on every network interface unless `--host 127.0.0.1` is given, so a phone on the same Wi-Fi can reach it. `--frozen` stops its bots from working on their own, for screenshots. `POST /v1/demo/reset` puts the data back as it was at start, and `POST /v1/cards/undo` exists only there. `bun server/demo-check.ts --url http://127.0.0.1:8810` starts nothing: it asks a running demo for every route the app uses and checks the answers.

## HTTP API

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

None of this is a public API of T3 Code. It works with the versions it was tested against and can break with an update.

- The location and schema of the SQLite projection (`~/.t3/userdata/`), including table and column names.
- The local websocket and its command names (`message.dispatch`, `runtime-request.respond`, `thread.create` and a few thread housekeeping commands).
- `auth session issue` in T3 Code's command line tool.
- The `t3code://threads/...` link, to open a thread in T3 Code's own app.

T3 Code also has documented ways in for outside programs: an MCP endpoint and the `t3 thread` commands. T3 Bot does not use them yet. MCP covers messages and questions; the `t3 thread` commands cover messages only. Neither covers approvals, and neither has a way to tell a client that something changed, so the lock screen would lag.

## Security

- The server binds to `127.0.0.1` unless `T3BOT_HOST` says otherwise. You choose what forwards to it. With `tailscale serve` that is your own tailnet. Installed without Tailscale, it binds to every interface so the phone can reach it at home, over plain http: anyone on that network can see the traffic.
- One bearer token guards everything. Anyone who has it can message your agents, and your agents can run commands on your Mac. Keep it and the pairing link private. To rotate it, delete `~/.config/t3bot/token` and run `deploy/install.sh`: it writes a new one, restarts the server and prints the new pairing code.
- The token and the push key live in `~/.config/t3bot/` with owner-only permissions. Nothing in that folder belongs in git.
- Handlers and sources run with your user's rights. Only put commands you wrote in the config.
- The image route serves only images under your home or temp folders, and refuses credential folders such as `.ssh` and `.config`. The face pictures are the only thing served without the token.
- A bot can read the calendar and contacts the phone shared with the server only after you turn that on in the app. Drafts are never sent by the server.
