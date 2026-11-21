# Audi mode setup

How a long Markdown note reaches the Kindle's Audi view, and how to try it. This file has no token or secret values in it, and none should ever be added.

Audi is a read-only second screen. The Kindle does not send a decision back: there is no reply button and no reply API. Entries are stored apart from the inbox, so they do not use the 100-message cap and Read all does not touch them. The morning briefing is unchanged (`--source dada --type briefing.daily` into `~/kdash-outbox/`).

## 1. What the Kindle shows

The bottom bar is `IP:port`, then **Audi**, **Lock** and **Exit**, each button about 15% of the screen width. Audi toggles the view. With an entry, the header shows the title, `#12 · DeepSeek · 19:12` (spoken ref, source, and Eastern time via `messageTime()`), and `<` `>` with `3/12` to move through the last 20 entries. The body scrolls like the inbox reader. Links show their text, images show their alt text, and raw HTML is shown as text.

With nothing current, the page says **暂无内容**.

**Lock.** Holding Lock still locks the dashboard. While locked, you can scroll the Audi entry that is on screen. You cannot page to another entry, leave Audi mode, or tap Exit. Holding Locked unlocks. A new entry still switches to Audi and full-refreshes when auto-switch is on, including while locked.

**Open Audi mode for new items** (Tools → Dash) defaults to on. A new or updated entry closes an open inbox reader, opens Audi, and full-refreshes. Turn it off and the Audi button shows `Audi·N` until you open Audi yourself. Sending the same id with the same title and body does not refresh.

## 2. Drop directory

| Path | Purpose |
|---|---|
| `~/kdash-audi/` | Drop `*.md` here. This is the only Mac directory Audi writes. |
| `~/kdash-audi/sent/` | Moved here after a 200 or 201 |
| `~/kdash-audi/failed/` | Moved here on a usage error or an HTTP error other than "Kindle unreachable" |

The same LaunchAgent as the briefing, `com.abharosim.koreader-dash.outbox`, watches this folder. It runs `scripts/outbox-send.sh`, which calls `scripts/audi-outbox-send.sh`. Log lines start with `audi-outbox:` in `~/Library/Logs/koreader-dash-outbox.log`.

A file modified less than 5 seconds ago is skipped. Write to a temporary name that does not end in `.md`, then rename it to `.md`. If the Kindle is unreachable (Dash closed, asleep, or off Wi-Fi), the file stays put and the next run retries. The job cannot wake a Kindle that was suspended with the power button.

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

The same note through the drop folder:

```sh
mkdir -p ~/kdash-audi
cat > ~/kdash-audi/.audi-test-12.tmp << 'EOF'
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
mv ~/kdash-audi/.audi-test-12.tmp ~/kdash-audi/audi-test-12.md
```

Within about 5–15 seconds the log should contain `audi-outbox: ... sent audi-test-12`, the file should be in `~/kdash-audi/sent/`, and the Kindle should open Audi and full-refresh `#12`. It should not appear in the inbox. Dropping another file with the same id and a changed body updates the screen and keeps ref 12.

```sh
scripts/audi-push.sh --clear
```

## 5. What to run on the Mac

Do these only when you mean to change the Kindle or the launchd job. Plugin first, then the job: a push before the new routes exist is an HTTP error, and the file is moved to `failed/`.

1. **Kindle plugin.** From the repo, with the Kindle awake and reachable by SSH: `scripts/deploy.sh`. It copies the plugin, checks each file, and asks KOReader to restart and open Dash. The first install on a device that has never run Dash still needs a manual open so the restart request is noticed.
2. **LaunchAgent.** `scripts/install-outbox.sh` recreates `~/Library/LaunchAgents/com.abharosim.koreader-dash.outbox.plist` (now also watching `~/kdash-audi`), creates `~/kdash-audi/sent` and `~/kdash-audi/failed`, and starts the job. Confirm with `launchctl print gui/$(id -u)/com.abharosim.koreader-dash.outbox` that the interval is 60 seconds.

`scripts/install-outbox.sh --uninstall` removes the job and leaves both drop folders on disk.

Check without the Kindle: `scripts/test.sh` (Lua specs plus `scripts/test-audi-push.sh`).
