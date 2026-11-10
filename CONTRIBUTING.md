# Contributing

Thanks for looking. T3 Bot is a small project kept by one person, so a short note before a big change saves us both time.

## Before you open a pull request

- **Bugs:** open an issue with what you did, what you expected and what happened. Add the output of `t3bot doctor`, your T3 Code version and your iOS version. Remove tokens and addresses first.
- **Small fixes:** send the pull request directly.
- **Features:** open an issue first and describe the problem you have. Not every feature fits. The app is meant to stay small.

## Working on it

The demo server is the fastest loop. It needs no T3 Code and no phone:

```sh
bun server/demo.ts --port 8810
cd ios && xcodegen generate && open T3Bot.xcodeproj
```

Run the app in a simulator and connect it to `http://127.0.0.1:8810` with the token `demo`. If you change what the server returns, change `server/demo.ts` too, so the demo keeps answering everything the app asks. With the demo running, this checks every route the app uses:

```sh
bun server/demo-check.ts --url http://127.0.0.1:8810
```

To run the real server from your clone against your own T3 Code, on another port and with its own state:

```sh
T3BOT_PORT=8811 T3BOT_DATA_DIR=/tmp/t3bot-dev T3BOT_TOKEN_FILE=/tmp/t3bot-dev/token \
  T3BOT_NO_PUSH=1 T3BOT_READONLY=1 bun server/t3bot.ts
```

It reads the same T3 Code data as your installed server. `T3BOT_READONLY=1` keeps it from sending anything to T3 Code: without it, a second server also tidies your bot threads and can ask for the morning brief a second time, and anything you send from the app goes to your real threads. Drop it only to test sending.

## Rules

- Bun only. No npm or yarn, and no new dependencies in the server without a good reason: it has none today.
- The `.xcodeproj` is generated. Change `ios/project.yml` and never commit the project. Your team and bundle identifier go in `ios/Config/Local.xcconfig`, which `ios/scripts/setup.sh` writes and git ignores.
- Everything specific to T3 Code stays in `server/t3.ts`.
- Nothing personal in the repository: no tokens, keys, team identifiers, device identifiers, hostnames or your own `agents.json`. Your config lives in `~/.config/t3bot/`.
- Do not remove or change the meaning of an interaction people already use. Add beside it.
- Plain words in the interface and the docs. Short sentences. No em dashes.
- Screenshots for any change you can see, before and after.

## Pull requests

One change per pull request. Say what the problem was, what you changed and how you checked it. If you could not test on a real phone, say so.

## License

By contributing you agree that your work is released under the [MIT license](LICENSE).

T3 Bot is independent of T3 Code and Ping. Problems with T3 Code itself belong in [its own repository](https://github.com/pingdotgg/t3code).
