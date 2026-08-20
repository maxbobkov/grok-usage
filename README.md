# Grok Usage

A tiny macOS menu bar extra that shows how much of your **Grok Build weekly limit** is used.

It reads the same billing number as `/usage` in the Grok TUI and keeps it in the top-right of the screen: Grok mark + `12%`. Orange from 70%, red from 90%. Click for reset time, a manual refresh, and a link to the usage page.

This is an unofficial personal tool. It is not affiliated with, endorsed by, or supported by xAI.

## Requirements

- Apple Silicon Mac (the binary is `arm64`)
- macOS 13 or later
- [Grok CLI](https://x.ai/grok) installed and signed in (`grok login`)

The app does not have its own login. It reuses `~/.grok/auth.json` and refreshes the OIDC token when it is about to expire.

## Install

```bash
git clone https://github.com/maxbobkov/grok-usage.git
cd grok-usage
make install
```

That builds an unsigned `.app`, copies it to `~/Applications/GrokUsage.app`, and loads a LaunchAgent so it starts at login.

The first open may be blocked by Gatekeeper (ad-hoc signature, no Developer ID). Right-click the app → **Open**. After that the LaunchAgent is enough.

Check the live number without the menu extra:

```bash
make check
```

## Uninstall

```bash
make uninstall
```

## What you see

| Menu bar | Meaning |
| --- | --- |
| `12%` | Weekly Grok Build usage |
| Orange | 70–89% |
| Red | 90–100% |
| `?` | No auth, or the billing request failed |

The dropdown shows the percent, when the weekly window resets, when it last updated, **Refresh Now**, **Open Usage**, and **Quit**. Quit really quits; it does not keep relaunching.

## How it works

Grok CLI has no `grok usage` command. The TUI fetches:

```
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
```

with the session token from `~/.grok/auth.json`. This app calls the same endpoint and prefers `productUsage` for `GrokBuild`.

That path is undocumented and can change without notice. If it breaks, the extra keeps the last good percent when it can, otherwise it shows `?`.

Polling: every 5 minutes, at launch, on Mac wake, and when you hit Refresh.

## Build

Command Line Tools are enough. Full Xcode is not required.

```bash
make build    # GrokUsage.app in the repo (gitignored)
make run
make install
```

`scripts/generate-icon.swift` rebuilds `Resources/AppIcon.png` and `Resources/AppIcon.icns` from `Resources/GrokMark.svg` if you change the mark.

## Privacy

Tokens never leave your machine except as a `Bearer` header to xAI. The app does not log tokens, and they are not stored in the app bundle. `~/.grok/auth.json` stays mode `0600`.

## License

MIT. The Grok mark is used only to refer to Grok; it belongs to xAI.
