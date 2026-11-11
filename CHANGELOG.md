# Changelog

Each release has its full notes on the [releases page](https://github.com/Soren-Starck/t3-bot/releases).

## 0.3.0, 11 Nov 2026

The app pairs straight with T3 Code. The T3 Bot server is now optional. Full notes: [docs/RELEASE-0.3.0.md](docs/RELEASE-0.3.0.md).

- Pair by scanning a link from T3 Code's Settings > Sharing & access, with nothing installed beside T3 Code.
- Works with T3 Code 0.1.0 and later. An older one is refused at pairing with a sentence that names its version.
- Notifications without the server, through a push sender you deploy yourself (`push/`), published for the first time. Claude threads ring. Codex threads do not ring yet.
- A roster of every bot on home, and search over your bots' conversations and your cards.
- Setup is one script, `ios/scripts/setup.sh`, and `ios/scripts/run-on-iphone.sh` installs on a connected iPhone without opening Xcode.
- Fixes: the app no longer stays on Offline, every message that did not leave keeps its own retry, a retry no longer posts twice, VoiceOver and Reduce Motion are respected, photos are scaled down before upload.
- A security policy: [SECURITY.md](SECURITY.md).

## 0.2.0, 10 Nov 2026

The first public beta. The app needed the T3 Bot server running beside T3 Code.

- Bots as contacts: make a bot from the phone with a name, a job and a face, and it gets its own T3 Code thread. Send text or photos and tap a suggested reply.
- One list of what needs you: questions and approvals from any T3 Code thread, plus cards from your own scripts, most urgent first.
- Answer from the lock screen: reply to a bot or approve a request from the notification.
- Review, quiet hours, widgets, a Live Activity and a share sheet.
- `t3bot notify` puts a card on the phone from any script or agent, `t3bot doctor` checks the whole chain, and `t3bot demo` runs the app in the simulator with no T3 Code.
- Known issues, all fixed in 0.3.0: a message could be posted twice on a bad connection, a new message removed an earlier "Not sent" one, and a slash command stayed marked as sending.
