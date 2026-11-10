<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/bots-dark.png">
    <img src="docs/bots.png" width="200" alt="Three T3 Bot faces">
  </picture>
</p>

<h1 align="center">T3 Bot</h1>

<p align="center">An unofficial iPhone app for <a href="https://github.com/pingdotgg/t3code">T3 Code</a>, made to sit alongside its official app, not to replace it. Each bot is a T3 Code thread you chat with like a contact, in the style of Grok Bot, and when an agent needs you, you answer from your lock screen.</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-dark.png">
  <img src="docs/screenshots/hero-light.png" width="820" alt="T3 Bot on three iPhones: the home screen with the bots and what needs you, a conversation with a bot, and an approval card with its checks and buttons">
</picture>

## Set it up

Paste this into Claude Code, Codex or a T3 Code thread, on the Mac that runs T3 Code:

```text
Set up T3 Bot on this Mac for me: https://github.com/Soren-Starck/t3-bot
Clone it somewhere permanent and follow docs/AGENT-SETUP.md from the
clone, step by step. Run every command you can yourself, and stop to
tell me exactly what to do when a step needs me (my Apple account,
Xcode, my iPhone). Keep the pairing token out of this chat.
```

You do what only you can: sign in to Xcode with a paid Apple Developer account, plug in your iPhone, create a push key and scan the pairing code. To do it all by hand, follow [docs/SETUP.md](docs/SETUP.md). To look first, [the demo](docs/SETUP.md#the-demo) runs the app in the simulator with no T3 Code and no Apple account.

## What it does

- **Bots as contacts.** Make a bot from the phone with a name, a job and a face. It gets its own T3 Code thread: send text or photos, watch it work, tap a suggested reply.
- **One list of what needs you.** Questions and approvals from every T3 Code thread, most urgent first.
- **Answers from the lock screen.** Reply or approve inside the notification, which comes from the bot by name and face.
- **Cards from anything.** `t3bot notify` puts a card on your phone from a script, a cron job or an agent. See [docs/CARDS.md](docs/CARDS.md).
- **The rest.** Review one card at a time, quiet hours with a morning summary, widgets, a Live Activity and a share sheet.

## Good to know

- **Alongside T3 Code's own app, not instead of it.** Theirs is the full client: projects, diffs, a terminal, files, every thread. T3 Bot does one job next to it: your bots, and what waits on you. It was written from scratch, not forked.
- **No model of its own.** Unlike Grok Bot, you talk to the agent T3 Code runs in each thread.
- **You build it yourself.** There is no TestFlight build. You need a Mac running T3 Code with [Bun](https://bun.sh), Xcode 27, an iPhone on iOS 26 and a paid Apple Developer account. Tailscale lets the phone reach the server away from home.
- **Local.** The server runs on your Mac. Nothing leaves your machines except Apple's pushes.
- **Not a public API.** It reads T3 Code's database and uses its local websocket, so a T3 Code update can break it. `t3bot doctor` is the first thing to run.

## Docs

[Setup](docs/SETUP.md) · [Setup for agents](docs/AGENT-SETUP.md) · [Cards](docs/CARDS.md) · [Architecture](docs/ARCHITECTURE.md) · [Contributing](CONTRIBUTING.md)

MIT. Faces: [BoopFace](ios/T3Bot/BoopFace/LICENSE) by CX ArtLab, MIT. Not affiliated with T3 Code, Ping or xAI.
