# Security

T3 Bot has three parts: the iPhone app, an optional server that runs on your Mac (`server/`, `bin/t3bot.ts`), and a push sender (`push/`). This page says what each one trusts, what to keep secret, and how to report a problem.

## Reporting a problem

Report it privately: on the repository page, open the Security tab and choose "Report a vulnerability". Please do not open a public issue for a security problem. Say what you found, how to reproduce it and which version or commit you used. You get an answer within a few days.

## Versions that get fixes

Fixes go to the latest release and to `main`. Older releases are not patched: update to the latest one. If you run your own push sender, redeploy it after a fix to `push/`.

## What the project trusts

- **The server trusts whoever holds its token.** Every route asks for it, except `/health` and the bots' face pictures (`/v1/avatars/...png`), which the share sheet loads without headers. A token holder can read your bots' conversations, send them messages and press the buttons on their cards, so the token is worth as much as access to the agents themselves.
- **The server trusts its own Mac.** Its config, the scripts named as card handlers and the `t3bot` command are yours; anything that can write those files or run commands as you is already inside.
- **The server listens on 127.0.0.1 by default.** Reach it from the phone through Tailscale or another private, encrypted network. On plain http over Wi-Fi, anyone on that network can read the traffic and the token.
- **The push sender trusts nobody.** Anyone on the internet can call it. It rings only a phone whose sealed address it made itself, the words of the notification are fixed by the sender, and it stores nothing. A sealed address is a permission to ring one phone with a generic notification: it cannot be opened without the sender's key, and it carries no message text.
- **The hook in T3 Code's Claude settings** sends the push sender three things on a turn that needs you: the sealed address, the thread id and the kind of ring. No title, message or file leaves the Mac that way.
- **Agents are not trusted with the phone.** A bot can draft a message, a mail or a calendar event; the app shows it and you send it yourself.

## What to keep secret

- **The server token** (the token file under `~/.config/t3bot`). Do not paste it in an issue, a log or a screenshot. To replace it, delete the token file, restart the server and pair again.
- **The pairing link and its QR code** (`t3bot pair`). They hold the server address and the token: treat a screenshot of the QR code like the token.
- **The push key** (the `.p8` file from Apple, `APNS_KEY`) with its key id and team id. With it anyone can send notifications to your app. If it leaks, revoke it in the Apple developer account and make a new one.
- **The sender's `SEAL_KEY`.** With it anyone can read the device tokens inside sealed addresses and make new ones. If it leaks, set a new one: every old address stops working and each phone asks for a fresh one when Ring this phone is turned off and on.

None of these belongs in the repository. `.gitignore` keeps keys, env files and local build settings out; check `git status` before you commit in a fork.

## Running your own push sender

Keep `ALLOWED_TOPICS` to your own bundle ids, and put your host's rate limit in front of `/api/ring` and `/api/address`: the limits inside the function are counted per instance.
