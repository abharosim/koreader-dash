# Daily briefing setup

How the morning briefing reaches the Kindle, and how to set it up again on another Mac or in another place. This file has no token or secret values in it, and none should ever be added.

## 1. Architecture

```
Grok Bot assistant (DaDa, on its cloud box)
  compiles the briefing as Markdown
        │  copied over Grok Bot's Mac connection
        ▼
~/kdash-outbox/briefing-YYYY-MM-DD.md  (on the Mac)
        │  LaunchAgent com.abharosim.koreader-dash.outbox
        │  scripts/outbox-send.sh → scripts/inbox-send.sh
        ▼  HTTP over the home LAN
KOReader Dash inbox on the Kindle (port 8787)
```

There's no GitHub or cloud relay, on purpose. The briefing contains private email, calendar and todo content, so it only travels from the box to the Mac to the Kindle, and the last step stays on the LAN.

## 2. Grok Bot side

- **Routine:** "Kindle morning briefing", owned by DaDa.
  - Runs daily with cron `50 7 * * *` in America/New_York. It's flexible: it may start up to 15 minutes early and never late, so it runs between about 7:35 and 7:50 AM.
  - The briefing is written in Chinese.
- **Sources:**
  - Today's events from Google Calendar.
  - Important Gmail items from the last ~24 hours. Access is read-only: never send or archive.
  - Open todos from the chat.
- **Output:** the routine writes `/workspace/kdash/briefing-YYYY-MM-DD.md` on the box, then copies it to `/Users/rowang/kdash-outbox/briefing-YYYY-MM-DD.md` on the Mac.
- **Notifications:** the briefing only goes to the Kindle. The bot messages Ruoran in chat only if the copy fails.

## 3. Permission rule

The copy runs unattended thanks to an Auto-review Allow rule in Grok Bot Settings:

> Allow DaDa to copy Markdown briefing files from its box into ~/kdash-outbox on my Mac (machine 806b8af2), creating that folder if needed, without asking; any other write on my Mac still needs my approval.

On a new Mac, update the machine id and path in this rule.

General rule: the Mac is read-only for assistants by default, and any other write or install needs explicit approval.

## 4. Mac watcher

| Piece | Path |
|---|---|
| Script | `scripts/outbox-send.sh` |
| launchd template | `scripts/launchd/com.abharosim.koreader-dash.outbox.plist` |
| Installer | `scripts/install-outbox.sh` |
| Installed job | `~/Library/LaunchAgents/com.abharosim.koreader-dash.outbox.plist` |
| Log | `~/Library/Logs/koreader-dash-outbox.log` |
| Outbox | `~/kdash-outbox/`, with `sent/` and `failed/` |

**When it runs:** at login (`RunAtLoad`), every 60 seconds (`StartInterval 60`), and right away when `~/kdash-outbox` changes (`WatchPaths`).

**Each run**, for every `~/kdash-outbox/*.md`, it calls:

```sh
scripts/inbox-send.sh --id <file name without .md> --source dada --type briefing.daily FILE
```

| inbox-send exit | Meaning | What happens to the file |
|---|---|---|
| `0` | 201 created, or 200 when that id already exists | Moved to `sent/` |
| `3` | Kindle unreachable (asleep, off Wi-Fi, Dash closed) | Left in place; the run stops and the next one retries |
| `1`, `2` | HTTP error from the device, or bad file/usage | Moved to `failed/`, with a `FAILED` line in the log |

Details:

- **Fresh files:** a file modified less than 5 seconds ago is skipped, and the next run picks it up. To be safe, copy to a temporary name without `.md` and then rename it to `.md`.
- **No duplicates:** the message id is the file name, with characters outside `A-Z a-z 0-9 . _ : -` replaced by `_` and cut to 64 characters. A per-day name like `briefing-2026-11-16.md` gives a per-day id, so a retry never creates a duplicate.
- **Time limit:** the whole run gives up after 60 seconds (a perl `alarm`).
- **No 1Password:** it uses only `KDASH_URL` and `KDASH_TOKEN` from the repo's `.env`. It doesn't touch aikey, unlike the AI-usage job.
- **Side effect:** while the Kindle sleeps, a pending file gets one retry, and one log line, every minute until it goes through.

Install, disable, remove:

```sh
scripts/install-outbox.sh                                         # install or reinstall, and run once now
launchctl bootout gui/$(id -u)/com.abharosim.koreader-dash.outbox # stop until the next install or login
scripts/install-outbox.sh --uninstall                             # remove the job and plist; keeps ~/kdash-outbox
```

To send a file by hand: `scripts/inbox-send.sh --help`.

## 5. Kindle and Dash

- **Connection settings:** `.env` in the repo root holds `KDASH_URL=http://<kindle-lan-ip>:8787` and `KDASH_TOKEN=...`. Keep `.env` out of git.
- **Token on a new device:**
  - Dash creates its token the first time it opens and stores it on the Kindle in `/mnt/us/koreader/settings/dash_config.json` (the `token` field).
  - Copy it into `.env` over SSH. For example, run `ssh -p 2222 root@<kindle-ip> cat /mnt/us/koreader/settings/dash_config.json` and paste the value into `.env` yourself.
  - Don't put the token in chat, logs or commits.
- **When the server listens:** only while Dash is open and Wi-Fi is up, on port 8787 on all interfaces.
  - Dash replaces sleep by default and keeps the device awake.
  - The power button still really suspends the Kindle. Messages then wait in the outbox.
- **Check:** `curl http://<kindle-ip>:8787/ping` needs no token.
- **Message limits:**
  - The body is Markdown, at most 256 KB.
  - The title is at most 300 bytes. If it's missing, inbox-send uses the first `# ` heading, then the file name.
  - The id is 1 to 64 characters from `A-Z a-z 0-9 . _ : -`.
  - UTF-8 throughout, so Chinese is fine.
- **Rendering:**
  - The screen is 6-inch e-ink, so keep tables narrow (3 columns or fewer) and lines short.
  - The inbox preview is the first 2 lines of the body as plain text, so lead with what matters most.
  - Links show only their text and can't be opened. Images show only their alt text. Raw HTML is shown as text and never run.
- **Inbox cap:** the inbox holds 100 messages and drops the oldest read ones. If all 100 are unread, new messages get `507`.
- **Rate limit:** 60 changes a minute.

## 6. Security notes

- The connection is plain HTTP on the LAN. Anyone on the same Wi-Fi can capture traffic and read the messages and the token. The token can only write the dashboard's state and inbox, and gives no shell.
- Never port-forward the Kindle or put it behind a tunnel (Cloudflare Tunnel or similar). That would expose an unencrypted server with a static token to the internet.
- Tailscale on the Kindle isn't recommended. It needs a daemon outside `/mnt/us/koreader`, drains the battery and is fragile. If remote access is ever needed, use a VPN that ends at the Mac.
- On the Kindle, only touch KOReader files under `/mnt/us/koreader`.

## 7. Re-setup checklist

1. **Kindle:** install the plugin (`scripts/deploy.sh`) and open Dash once so it creates its token. Note the Kindle's LAN IP and check that `curl http://<kindle-ip>:8787/ping` answers from the Mac.
2. **Mac:**
   - Clone koreader-dash.
   - Create `.env` with `KDASH_URL` and `KDASH_TOKEN`, taking the token from `dash_config.json` as in section 5.
   - Check that `jq` and `curl` are installed.
3. **Watcher:** run `scripts/install-outbox.sh`. Confirm that `launchctl print gui/$(id -u)/com.abharosim.koreader-dash.outbox` shows `run interval = 60 seconds`.
4. **Grok Bot:**
   - Make sure the new Mac is connected in Grok Bot.
   - Update the Allow rule in section 3 with the new machine id and path.
   - Update the "Kindle morning briefing" routine's destination path if the home folder changed.
5. **End-to-end test:**
   - Drop a small `test-YYYY-MM-DD.md` (for example `# Test` plus one line) into `~/kdash-outbox`.
   - Within a few seconds it should move to `sent/`, and `~/Library/Logs/koreader-dash-outbox.log` should show `sent test-YYYY-MM-DD: inbox-send: 201`.
   - It should appear unread in the Dash inbox on the Kindle.
