# Audi mode setup

How a long Markdown note reaches the Kindle's Audi view, and how to try it. This file has no token or secret values in it, and none should ever be added.

Audi is a read-only second screen. The Kindle does not send a decision back: there is no reply button and no reply API. Entries are stored apart from inbox messages, so they do not use the 100-message cap and `GET /v1/inbox` does not return them. The home Inbox lists the unread ones beside unread briefings. **Read all** marks those listed rows read and does not delete them. The morning briefing is unchanged (`--source dada --type briefing.daily` into `~/kdash-outbox/`).

## 1. What the Kindle shows

The bottom bar's left side is the time and the battery, such as `02:11  ·  90%`. **Audi**, **Lock** and **Exit** stay on the right, each button about 15% of the screen width. The address and the ping count are not shown. Audi toggles the view. With an entry, the header is two short lines: the title, then `#12 · DeepSeek · 19:12` (spoken ref, source, and Eastern time via `messageTime()`). `<` `>` and `3/12` sit at the top right and are the only controls there. The body starts on the same left edge as the title. The page inset is 4, the HTML page and body margins are 0, and the scrollbar gutter is 2. Links show their text, images show their alt text, and raw HTML is shown as text.

With nothing current, the page says **暂无内容**.

**Home Inbox.** Unread briefings and unread Audi entries share one list, newest first. An Audi row is marked **Audi** and `#12`, and shows `● 待看` until it is read. Each row has **Read**, which removes that row. **Read all** in the Inbox header marks every listed briefing and Audi entry read, and the list then says **Inbox empty**. A tap on a briefing opens the reader, which has **Mark as read**. A tap on an Audi row opens Audi fullscreen and marks that entry read, so it leaves the list. Read entries stay stored: briefings remain in the inbox store, and Audi entries remain in the history the Audi button pages through. Briefings never open fullscreen by themselves.

**Lock.** Holding Lock still locks the dashboard. While locked, you can scroll the Audi entry that is on screen. You cannot page to another entry, leave Audi mode, or tap Exit. Holding Locked unlocks. A new entry still switches to Audi and full-refreshes when auto-switch is on, including while locked. The 10-minute idle return below still runs while locked.

**Open Audi mode for new items** (Tools → Dash) defaults to on. A new or updated entry closes an open inbox reader, opens Audi from whatever view is showing, and full-refreshes. Turn it off and the entry waits in the Inbox with `● 待看`, and the Audi button shows `Audi·N`, until you open it. Sending the same id with the same title and body does not refresh.

**Idle return.** After 10 minutes in Audi with no tap, swipe, key or page turn, Dash leaves Audi, returns to the home screen, and full-refreshes. The entry stays in the Inbox. Any of those inputs starts the 10 minutes again, and so does a new or updated entry. Leaving Audi, tapping Exit, or suspending cancels the timer. On wake, if those 10 minutes already passed, Dash is on the home screen; a new entry that arrived while asleep still opens Audi when auto-switch is on. The wait is 600 seconds (`dash_audi_idle.lua`). A whole number `audi_idle_seconds` in `koreader/settings/dash_config.json` overrides it (1 to 86400). You do not need to add that key.

**Font size.** The body face starts at 18. Change it from **Tools → Dash → Audi font size**. That opens a spinner, 14 to 28, step 2, saved as `dash_audi_font_size` in KOReader's settings. If Audi is already open, the body repaginates when you set it. Otherwise it applies the next time Audi opens. A device that has never set it uses 18. The Audi page itself has no font buttons.

**Clear and replace.** `action: clear` (and `POST /v1/audi/clear`, and `scripts/audi-push.sh --clear`) still shows **暂无内容** and keeps the archive. Those entries disappear from the home Inbox until a later update. `replace_id`, or the same id with a changed title or body, updates that entry in place (same id, same ref) and puts that row back. Sending the same title and body again does not.

## 2. Drop directory

| Path | Purpose |
|---|---|
| `~/kdash-audi/` | Drop `*.md` here. This is the only Mac directory Audi writes. |
| `~/kdash-audi/sent/` | Moved here after a 200 or 201 |
| `~/kdash-audi/failed/` | Moved here on a usage error or an HTTP error other than "Kindle unreachable" |

The same LaunchAgent as the briefing, `com.abharosim.koreader-dash.outbox`, watches this folder. It runs `scripts/outbox-send.sh`, which calls `scripts/audi-outbox-send.sh`. Log lines start with `audi-outbox:` in `~/Library/Logs/koreader-dash-outbox.log`.

Writing `name.md` straight into the folder is fine. The producer does not have to stage a temp file. Before a send, the job samples the file's size and modification time, waits about 2 seconds, and samples again. It sends only when both are unchanged and the file was not modified in the last 5 seconds. A file that is still changing, or was just modified, stays in place for the next run. It is not moved to `failed/`. A rename from a dotfile such as `.name.tmp` to `name.md` still works; dotfiles are ignored. If the Kindle is unreachable (Dash closed, asleep, or off Wi-Fi), the file stays put and the next run retries. The job cannot wake a Kindle that was suspended with the power button.

## 3. Frontmatter

UTF-8 Markdown. An optional flat YAML block from the first line `---` to the next `---`. No nesting.

| Field | Required | Default |
|---|---|---|
| `id` | No | File name without `.md`. Characters outside `A-Z a-z 0-9 . _ : -` become `_`, then cut to 64. Stdin with no id lets the device assign one. |
| `ref` | No | The device assigns the next number, shown as `#12`. Send it yourself when the speaker must know the number before the Kindle answers. An update keeps the original ref. |
| `title` | No | The first `# ` heading, otherwise the file name. Stdin with neither uses `Audi`. At most 300 bytes. |
| `source` | No | `Audi`. At most 64 bytes. |
| `created_at` | No | Omitted. The device shows the time it received the entry. ISO 8601, preferably with `-05:00` or `-04:00`. |
| `replace_id` | No | Omitted, so this is a new entry. When that id exists, its title, body, source and time are replaced and its ref stays. |
| `action` | No | Omitted. The only value is `clear`: the screen goes idle and the history stays. The body may be empty. |

Flags on `scripts/audi-push.sh` override the file: `--title`, `--id`, `--ref`, `--source`. `--clear` needs no file. The body is at most 256 KB. On a 6-inch screen, keep tables to 3 columns and lines short.

```markdown
---
id: audi-20261120-191200
ref: 12
title: DeepSeek 审查结果
source: DeepSeek
created_at: 2026-11-20T19:12:00-05:00
---

## 摘要

`fib.py` 的递归实现在 n>30 时会重复计算。
```

To update that entry, send `replace_id: audi-20261120-191200`. The screen keeps `#12`.

## 4. Send by hand

Dash must be open and the Kindle on Wi-Fi. `KDASH_URL` and `KDASH_TOKEN` come from `.env` in the repo root. Exit codes match `inbox-send.sh`: `0` delivered, `3` unreachable, `2` bad usage or file, `1` any other HTTP status.

```sh
scripts/audi-push.sh --title "测试第 12 条" --id audi-test-12 --ref 12 --source DeepSeek - <<'EOF'
## 摘要
这是一条用于验收的多段内容。

- 第一点
- 第二点
EOF
```

The same note through the drop folder, written directly:

```sh
mkdir -p ~/kdash-audi
cat > ~/kdash-audi/audi-test-12.md << 'EOF'
---
id: audi-test-12
ref: 12
title: 测试第 12 条
source: DeepSeek
---

## 摘要
这是一条用于验收的多段内容。

- 第一点
- 第二点
EOF
```

Staging `.audi-test-12.tmp` and then `mv` to `audi-test-12.md` is also fine. After the file has stopped changing, the next outbox run should log `audi-outbox: ... sent audi-test-12`, move the file to `~/kdash-audi/sent/`, and the Kindle should open Audi and full-refresh `#12`. It should show in the home Inbox as **Audi** `#12`, and it should not be in `GET /v1/inbox`. Dropping another file with the same id and a changed body updates that same row and keeps ref 12. `scripts/audi-push.sh --clear` takes Audi rows off the Inbox and leaves the archive in place.

```sh
scripts/audi-push.sh --clear
```

## 5. What to run on the Mac

Do these only when you mean to change the Kindle or the launchd job. Plugin first, then the job: a push before the new routes exist is an HTTP error, and the file is moved to `failed/`.

1. **Kindle plugin.** From the repo, with the Kindle awake and reachable by SSH: `scripts/deploy.sh`. It copies the plugin, checks each file, and asks KOReader to restart and open Dash. The first install on a device that has never run Dash still needs a manual open so the restart request is noticed.
2. **LaunchAgent.** `scripts/install-outbox.sh` recreates `~/Library/LaunchAgents/com.abharosim.koreader-dash.outbox.plist` (now also watching `~/kdash-audi`), creates `~/kdash-audi/sent` and `~/kdash-audi/failed`, and starts the job. Confirm with `launchctl print gui/$(id -u)/com.abharosim.koreader-dash.outbox` that the interval is 60 seconds.

`scripts/install-outbox.sh --uninstall` removes the job and leaves both drop folders on disk.

Check without the Kindle: `scripts/test.sh` (Lua specs plus `scripts/test-audi-push.sh`).
