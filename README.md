# show-codex-usage

A lightweight local shell tool for inspecting Codex usage across multiple ChatGPT-authenticated accounts and switching the current account without re-authenticating.

This tool is built for a very specific but common pain point: the $20 Plus plan is often not enough, while the $200 Pro plan can be overkill. For some users, 2–3 Plus accounts are the practical middle ground. But once you start doing that, account management becomes annoying fast. You forget to monitor usage limits, you hit a window unexpectedly, and switching accounts usually means logging out and logging back into Codex again.

`show-codex-usage` fixes that workflow. After you sign into a new account with Codex once, run `scu` and it will automatically add or update that account in `auth-poll.json`. Later, when you run `scu switch`, it simply swaps the selected account entry into `auth.json`. That means no repeated Codex login flow, no unnecessary friction, and a much faster way to rotate between accounts based on actual remaining usage.

It reads your local Codex auth files, refreshes an auth pool automatically, queries usage data from the Codex usage endpoint, renders a clean terminal view, and optionally lets you switch the active account through a simple keyboard-driven TUI.

## Quick Install

One-line install for copy/paste:

```bash
curl -fsSL https://raw.githubusercontent.com/nick-ma/show-codex-usage/main/install.sh | bash && export PATH="$HOME/.local/bin:$PATH" && alias scu='show-codex-usage'
```

Then use:

```bash
# check usage data for all account profile
show-codex-usage
# or
scu


# swtich account auth profile
scu switch
```

---

## Features

- Show Codex usage for all accounts stored in `auth-poll.json`
- Automatically upsert the current `auth.json` into the auth pool before every run
- Highlight the account currently in use
- Show remaining quota instead of used quota
- Color-coded remaining usage:
  - red: `<= 10%`
  - yellow: `<= 25%`
  - green: `> 25%`
- Format reset time as both relative and absolute time
- Sort accounts by urgency:
  - current account first
  - then by lowest `5h remaining`
- Interactive account switch mode
  - `↑ / ↓` to move
  - `Enter` to confirm
  - `q` to quit
- Switch the current Codex account by overwriting `~/.codex/auth.json`

---

## How it works

This script uses the `access_token` stored in your local Codex auth files and sends a request to:

```bash
https://chatgpt.com/backend-api/wham/usage
````

It then parses the response and displays the usage summary for each account in your pool.

Before doing that, it performs an **upsert** from:

```bash
~/.codex/auth.json
```

into:

```bash
~/.codex/auth-poll.json
```

So your currently active account is always kept in the pool and updated.

---

## Requirements

* macOS or Linux
* `bash`
* `curl`
* `jq`

Check dependencies:

```bash
command -v bash
command -v curl
command -v jq
```

Install `jq` if needed.

### macOS

```bash
brew install jq
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y jq
```

---

## Auth file structure

This script expects local Codex auth files similar to the following.

### `~/.codex/auth.json`

```json
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "",
    "access_token": "eyJhbG...",
    "refresh_token": "rt_xxx...",
    "account_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  },
  "last_refresh": "2026-03-17T09:20:30.755457Z"
}
```

### `~/.codex/auth-poll.json`

```json
[
  {
    "auth_mode": "chatgpt",
    "OPENAI_API_KEY": null,
    "tokens": {
      "id_token": "",
      "access_token": "eyJhbG...",
      "refresh_token": "rt_xxx...",
      "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    },
    "last_refresh": "2026-03-17T09:20:30.755457Z"
  },
  {
    "auth_mode": "chatgpt",
    "OPENAI_API_KEY": null,
    "tokens": {
      "id_token": "",
      "access_token": "eyJhbG...",
      "refresh_token": "rt_xxx...",
      "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    },
    "last_refresh": "2026-03-17T09:20:30.755457Z"
  }
]
```

---

## Installation

Install with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/nick-ma/show-codex-usage/main/install.sh | bash
```

The installer will:

- download the main script to `~/.local/bin/show-codex-usage`
- ensure `~/.local/bin` is added to your `PATH`
- add `alias scu='show-codex-usage'` to your shell rc file

If you want the command to be available immediately in the current shell, run:

```bash
export PATH="$HOME/.local/bin:$PATH" && alias scu='show-codex-usage'
```

Or reload your shell rc file:

```bash
source ~/.zshrc
```

If you use bash instead of zsh, reload the file the installer updated, or just open a new terminal. Then run:

```bash
show-codex-usage
scu
```

---

## Usage

### Show usage

```bash
show-codex-usage
```

This uses:

* current auth: `~/.codex/auth.json`
* auth pool: `~/.codex/auth-poll.json`

You can also specify a custom pool file:

```bash
show-codex-usage /path/to/auth-poll.json
```

---

### Switch current account

```bash
show-codex-usage switch
```

Or with a custom pool file:

```bash
show-codex-usage switch /path/to/auth-poll.json
```

Interactive controls:

* `↑` move up
* `↓` move down
* `Enter` confirm switch
* `q` quit without changes

When confirmed, the selected account object from `auth-poll.json` is written to:

```bash
~/.codex/auth.json
```

---

## Example output

### Show mode

```text
Codex usage from: /Users/nick/.codex/auth-poll.json
Current auth: /Users/nick/.codex/auth.json

Account: jaaaa-08908@gmail.com [plus] [Current Using]
Rate Limit: false
  5h remaining: 71%  reset at: 4hr 12m (2026-03-17 15:40 UTC)
  1w remaining: 1%   reset at: 1d 8hr (2026-03-18 19:48 UTC)

Account: nick-998892@gmail.com [plus]
Rate Limit: false
  5h remaining: 98%  reset at: 3hr 44m (2026-03-17 15:12 UTC)
  1w remaining: 73%  reset at: 5d 14hr (2026-03-22 21:26 UTC)
```

### Switch mode

```text
Select account to switch (↑/↓ move, Enter confirm, q quit)

> jaaaa-08908@gmail.com [plus] [Current Using]  RL:false  5h:71%  1w:1%
  nick-998892@gmail.com [plus]                  RL:false  5h:98%  1w:73%

Current auth file: /Users/nick/.codex/auth.json
Auth pool file: /Users/nick/.codex/auth-poll.json
```

---

## Sorting rules

Accounts are sorted in this order:

1. The current account always appears first
2. All other accounts are sorted by `5h remaining` ascending

That means the most urgent accounts appear near the top.

---

## Output rules

The script displays:

* account email
* plan type
* whether rate limit is reached
* `5h remaining`
* `1w remaining`
* reset time in:

  * relative format, such as `1d 3hr`
  * absolute UTC format, such as `2026-03-18 19:48 UTC`

Color rules:

* red: remaining `<= 10%`
* yellow: remaining `<= 25%`
* green: remaining `> 25%`

The current active account is marked as:

```text
[Current Using]
```

---

## Safety notes

This tool relies on local authentication artifacts and an internal web endpoint. It is intended for personal/local use.

Things to keep in mind:

* the endpoint is not a documented public API
* response fields may change over time
* expired tokens will cause query failures
* switching accounts overwrites `~/.codex/auth.json`

You should back up your auth files if you rely on a specific account setup.

For example:

```bash
cp ~/.codex/auth.json ~/.codex/auth.json.bak
cp ~/.codex/auth-poll.json ~/.codex/auth-poll.json.bak
```

---

## Troubleshooting

### `jq is required but not installed`

Install `jq` first.

### `unable to query`

Possible reasons:

* access token has expired
* endpoint response changed
* network issue
* current auth entry is incomplete

### `missing access_token`

The selected auth object does not contain a valid token set.

### arrow keys do not work properly

Make sure you run the script in a normal terminal that supports standard ANSI escape sequences.

---

## Suggested file layout

```text
~/.codex/
  auth.json
  auth-poll.json

project/
  show_codex_usage.sh
  README.md
```

---

## License

MIT
