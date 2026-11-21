# KOReader Dash: Specification

An always-on dashboard for a Kindle Paperwhite 4. It shows the date, time and battery, values sent to it over HTTP (weather, a todo count and AI usage), an inbox of messages you can mark as read, and an Audi view that displays one pushed Markdown entry at a time.

**Status:** in progress. See the [build plan](#7-build-plan).
**Target:** Kindle Paperwhite 4 with KOReader v2026.07.1. Source references were read from KOReader `master`.

---

## 1. Principles

1. **The Kindle mostly displays.** Senders push data to it. The one exception is weather, which the Kindle fetches itself ([section 6](#weather)) so it works without the Mac.
2. **Three kinds of data.** One JSON **state** blob holds current values, an **inbox** queue holds messages, and an **Audi** history holds entries pushed for the Audi view. Audi entries are stored apart from inbox messages (`GET /v1/inbox` never returns them). The dash home Inbox list shows both.
3. **Everything but the clock, battery and weather is event-driven.** A value changes only when an HTTP request or a tap changes it.
4. **No redraw without a change.** Sending the same state again doesn't touch the screen, so senders can repeat themselves freely.

### The clock is an exception

Date and time come from the Kindle's own clock, not from HTTP. Pushing them would need a request every minute, and the clock would freeze whenever the Mac slept or Wi-Fi dropped. Battery level is also read from the device.

### Battery drain

`dash_battery.lua` records a reading on open, every minute, on sleep and on wake, while the dashboard is open. It stores a reading only when the level or charging state changes, and keeps 48 hours in `settings/dash_battery.json`. Readings form runs; a run ends when charging starts or stops, or after 5 minutes with no reading (sleep, or the dashboard closed).

The rate is measured between the first and last new low in the current run, each timed from the first moment that level was reached. The level is a whole number, so the first reading could be anywhere within its percent, and it flickers between neighbouring values (37, 36, 37 within minutes), so rises are ignored. It needs two drops (about 30 minutes at 4%/h) before it shows a number. The tile reads `Drain: −4.1%/h` with `about 11 h left · 2h 10m awake` beneath, or `Drain: measuring…`, `Charging`, or `Drain: —` when there's no recent reading. `/v1/health` reports `battery_drain_per_hour` and `battery_hours_left`.

The dashboard always shows US Eastern time, including daylight saving changes. `dash_time.lua` converts it from the device's UTC time, so the Kindle's own time zone setting is left alone. KOReader's other screens keep following that setting.

### Out of scope for v1

- Replying to messages. Marking as read is the only action.
- Opening links or showing images from messages.
- Viewing messages already marked read on the device. They remain available through the API.
- Receiving anything while the dashboard is closed, since the server only runs while it's open.
- TLS, or exposure to the public internet.
- Running on battery. It stays plugged in.

---

## 2. Screen

```
┌──────────────────────────────────────┐
│ Battery 52%          November 2026   │
│ 15:11              S M T W T F S     │
│ Saturday, November 7 1 2 3 4 5 6 [7] │
│ 18° Rain           8 9 10 ...        │
│ High 21, low 14    ...               │
│ Todo: 3                              │
│ Drain: −4.1%/h                       │
│ about 11 h left · 2h 10m awake       │
├──────────────────────────────────────┤
│ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐  │
│ │Grok  │ │Claude│ │DSeek │ │xAI   │  │
│ │17%   │ │35%   │ │¥110  │ │No    │  │
│ │▓░░░░░│ │▓▓░░░░│ │left  │ │data  │  │
│ │Nov 20│ │week  │ │      │ │yet   │  │
│ └──────┘ └──────┘ └──────┘ └──────┘  │
│ Inbox (2 unread)           < 1/2 >   │
│ ──────────────────────────────────── │
│ Build failed                 [ Read ]│
│ Tests failed on main. 3 suites...    │
│ ! ci  ·  15:02                       │
│ ──────────────────────────────────── │
│ DeepSeek review                 Audi │
│ ● 待看                         #12   │
│ DeepSeek  ·  19:12                   │
│                                      │
│ 192.168.1.152:8787  [Audi][Lock][Exit]│
└──────────────────────────────────────┘
```

- The page covers the whole screen with an opaque background.
- Today is shown inverted on the calendar, which is laid out with Sunday first and rebuilt when the date changes. The calendar is a little smaller than before, to make room for the usage row.
- **AI usage:** a row of four equal tiles under the clock, for Grok, Claude, DeepSeek and xAI API, always in that order. Each tile has the provider (or the sender's `label`) with the time it was last updated on the right, a headline (a percentage, a balance, a spend, or the sender's own `headline`), a bar when a percentage is known, and one line with the sender's `detail` and the reset time. A provider with nothing sent shows **No data yet**. Values are **stale** after 24 hours, after their `expires_at`, or once their `resets_at` has passed: the title row then reads `stale Nov 12` and the bar turns grey, so an old number is never mistaken for a current one. Only a tile turning stale (or fresh) rebuilds the screen. Code: `dash_usage.lua` (pure, tested) and `Dashboard:buildUsage`.
- Missing values, or weather past its `expires_at`, show `—`.
- **Inbox order:** the home list merges unread inbox messages and Audi entries that are still listed, newest first. A high-priority briefing is still bold and marked `!`; it does not jump ahead of a newer row. Read briefings leave the list. A read Audi entry stays, without the unread mark. The HTTP inbox and `Store:unreadMessages()` keep the old order (high priority, then oldest) for the API and the SimpleUI module.
- **Preview:** up to two lines of the body as plain text, with Markdown syntax removed.
- **Read button:** marks that message read, so it leaves the list.
- **Tapping a briefing:** opens the reader, described below. Briefings never open that reader on their own.
- **Tapping an Audi entry:** opens Audi fullscreen on that entry. The row shows an **Audi** tag, the ref (`#12`), and, until it has been shown, `● 待看`. Showing it in Audi fullscreen marks it read. `action: clear` takes every Audi row off this list (the archive stays). `replace_id`, or the same id with a new title or body, updates that row in place and lists it again.
- **Paging:** `<` and `>` appear when the messages don't fit on one page.
- **Exit:** the button in the bottom right corner (15% of the screen width) closes the dashboard and returns to KOReader.
- **Lock:** a **Lock** button sits left of Exit, the same size. Holding it locks the dashboard: it then reads **Locked**. Tapping it only shows a hint; holding it again unlocks. While locked, touch does nothing except two cases: holding **Locked** unlocks, and, when Audi mode is showing an entry, scrolling or tapping through that entry's body still works. History paging, the Audi button, Exit, Read, Read all and opening messages stay blocked. Only touch is blocked: the HTTP API, the clock and sleep work as usual. The lock isn't saved, so restarting KOReader clears it. Locking and unlocking are written to `dash_m0.log`.
- **Audi:** a third button, the same size, sits left of Lock. Tapping it opens Audi mode (the button is drawn inverted); tapping it again returns to the dashboard. See [Audi mode](#audi-mode).
- **Read all:** shown in the inbox header, beside the page buttons, while an inbox message is unread. It asks to confirm, then marks every inbox message read in one save. Audi entries are left as they are.
- **Instead of sleeping:** when KOReader would go to sleep, it opens Dash instead. This covers the idle timer, the Sleep menu item and the Sleep gesture, which all go through `UIManager:suspend`. Exit returns to whatever was open before. Exceptions, which sleep as usual:
  - the power button (and a cover), because the Kindle's own power manager handles those before KOReader hears about them;
  - sleep requested while Dash is already open;
  - battery below 20% while not charging.
  KOReader's idle timer doesn't run while charging, so on the charger nothing changes. The menu is now **Tools → Dash**, with **Open Dash** and a checkbox **Open Dash instead of sleeping** (on by default; saved as `dash_replaces_sleep` in KOReader's settings).
- **Home screen module:** with the SimpleUI plugin installed, Dash adds a **Dash** module to its home screen (SimpleUI's layout editor, under Extras; off until added). It shows four lines: the weather, the todo count and unread inbox total, the top unread message's title (high priority first, then oldest; this line does not include Audi entries), and the battery drain. Tapping it opens Dash. It shows the data Dash last received, since the server only runs while Dash is open, and the home screen redraws when Dash closes. It honours SimpleUI's per-module scale. Code: `dash_home.lua`, registered from `Dash:init` through SimpleUI's `Registry.register`.

### Message reader

```
┌──────────────────────────────────────┐
│ <  Build failed                      │
│    ci  ·  15:02                      │
├──────────────────────────────────────┤
│ Results                              │
│ Tests failed on **main**:            │
│ ┌────────┬────────┐                  │
│ │ Suite  │ Failed │                  │
│ └────────┴────────┘                  │
│ • First point                        │
│                                      │
│                      [ Mark as read ]│
└──────────────────────────────────────┘
```

- Fullscreen, with a header showing the title, source and time.
- **Back** (`<`, top left) returns to the dashboard and leaves the message unread.
- The body is rendered from Markdown. Swipe or tap to scroll through long messages.
- **Mark as read** returns to the dashboard and removes the message from the list.

**Supported Markdown:** headings, paragraphs, bold, italic, strikethrough, inline code, fenced code blocks, bullet and numbered lists (including nested), quotes, tables, horizontal rules, and line breaks. Links show their text but can't be opened, and images show their alt text.

**Raw HTML is never run.** `dash_markdown.lua` escapes every character first, so `<script>` appears as text. KOReader's bundled Markdown converter isn't used because it passes raw HTML through, even inside code blocks, and doesn't support tables.

### Audi mode

Audi mode replaces the clock, calendar, usage tiles and inbox with one entry. The bottom bar stays, so Audi, Lock and Exit remain available. There is no Mark as read button and no way to send a decision back.

With nothing to show, the page says **暂无内容**.

With an entry, the header shows the title, then `#12 · DeepSeek · 19:12` (the spoken `ref`, the source, and the time from `messageTime()`: `HH:MM` today, `Mon DD, HH:MM` on another day, US Eastern). `<` `>` and `3/12` on the right move through the saved history. The newest entry is last. Paging does not change `ref`. The body is the same Markdown as the inbox reader (`dash_markdown.lua` and `ScrollHtmlWidget`): swipe or tap to scroll. Links show their text, images show their alt text, and raw HTML is escaped.

The device keeps the last 20 entries (`AUDI_HISTORY_LIMIT` in `dash_audi_store.lua`; `audi_history_limit` in `dash_config.json` overrides it). A 21st entry drops the oldest. There is no "unread, so keep it" rule. Dropped entries leave the home list because they are gone from the store.

The body is denser than the inbox reader. The Audi page margin is 4 (the rest of Dash uses 16). The gap under the header is 2. MuPDF's page and body margins are set to 0, so the body text starts on the same left edge as the title, with no gap above the first heading. The scrollbar stays; the gutter beside it is 2 (the widget's default is 12) and the bar itself is 4 wide (the default is 6). The header is only the title and the `#ref` line. `<` `>` and `n/N` sit at the top right.

The body face defaults to 18 (it was 20). **Tools → Dash → Audi font size** opens a spinner from 14 to 28, step 2. The value is saved as `dash_audi_font_size`. If Audi is open, the body repaginates immediately; otherwise the next time Audi opens. A missing setting means 18.

**Open Audi mode for new items** (Dash menu, saved as `dash_audi_auto_switch`) defaults to on. When a new entry arrives, or an existing one is updated, Dash closes an open inbox reader, switches to Audi mode from whatever view is showing, shows that entry, and does a `full` refresh. The same happens while the screen is locked: the new entry is shown and can be scrolled, and history paging, leaving Audi and Exit stay blocked. With the setting off, Dash stays where it is: the entry is in the home Inbox with `● 待看`, and the Audi button reads `Audi·N` until you open it. A retry of the same id with the same title and body does not refresh or switch. After the power button, if auto-switch is on and an entry arrived that was never shown, resume opens Audi mode and full-refreshes.

Showing an entry in Audi fullscreen sets its `read_at`. That is the only way an Audi entry becomes read. Read all does not touch Audi entries.

**Idle return.** While Audi mode is showing, including when the screen is locked on the current entry, 10 minutes without a tap, swipe, key or page turn leaves Audi and returns to the dash home, with a `full` refresh. The entry stays in the Inbox. Any of those inputs starts the 10 minutes over, and so does a new or updated entry taking the screen. The wait is `TIMEOUT_SECONDS` in `dash_audi_idle.lua` (600). `audi_idle_seconds` in `dash_config.json` overrides it, when it is a whole number from 1 to 86400. The timer is cancelled on leaving Audi, on Exit and on suspend, and it does not run twice. On resume, if those 10 minutes already passed, Dash is back on the home screen; if a new entry arrived while the Kindle was asleep and auto-switch is on, that entry still opens.

`action: clear` (or `POST /v1/audi/clear`) returns to **暂无内容** and keeps the history in the store and on `GET /v1/audi`. Those entries leave the home Inbox (`inbox_hidden`) until a later create or update. A retry of the same title and body stays off the list. An update keeps the id and the ref and lists that one row again.

### Refresh rules

| Trigger | Refresh |
|---|---|
| Each minute boundary | `ui`; only the changed text differs on screen |
| The date changed, or weather expired | `full`, with the screen rebuilt |
| State or inbox changed; changes are grouped over 1 second | `partial` |
| A new or updated Audi entry is shown, or Audi mode is opened or closed | `full` |
| Audi has been idle for 10 minutes, or resume finds that it has | `full`, back on the dash home |
| Audi font size is changed while Audi is open | `full`, and the body is repaginated |
| Every 60 minutes | `full`, to clear ghosting |

---

## 3. HTTP API

- **Base URL:** `http://<kindle-ip>:8787`
- **Auth:** every request except `/ping` needs `Authorization: Bearer <token>`.
- **Format:** JSON in UTF-8. Every response sends `Connection: close`.

| Method and path | Purpose | Success |
|---|---|---|
| `GET /ping` | Connectivity check; needs no token | `200` |
| `GET /v1/health` | Time, battery and drain rate, Wi-Fi, unread count, whether the dashboard is open | `200` |
| `GET /v1/state` | Read the whole state blob | `200` |
| `PUT /v1/state` | Change some fields of the blob | `200` |
| `POST /v1/inbox` | Add a message | `201`, or `200` if that `id` already exists |
| `GET /v1/inbox` | List messages without bodies; `?unread=1` filters | `200` |
| `GET /v1/inbox/{id}` | Get one full message | `200` |
| `PUT /v1/inbox/{id}` | Set `{"read": true}` or `{"read": false}` | `200` |
| `DELETE /v1/inbox/{id}` | Remove a message; repeat calls also succeed | `204` |
| `POST /v1/audi` | Create or update an Audi entry, or `{"action":"clear"}` | `201` created, `200` retry, update or clear |
| `GET /v1/audi` | List Audi entries without bodies; newest last | `200` |
| `GET /v1/audi/{id}` | Get one Audi entry, including `body` | `200` |
| `DELETE /v1/audi/{id}` | Remove an Audi entry; repeat calls also succeed | `204` |
| `POST /v1/audi/clear` | Show the Audi idle line; history is kept | `200` |

### State blob

The dashboard displays these fields. Any other fields are stored and returned by the API, but not shown.

```json
{
  "weather": {
    "summary": "18° Rain",
    "detail": "High 21, low 14",
    "expires_at": 1794090000
  },
  "todo": {
    "count": 3
  }
}
```

`usage` holds the AI usage tiles. Every field is optional; keys other than these four providers are stored but not shown.

```json
"usage": {
  "grok":      { "used_pct": 17.4, "resets_at": 1795217040, "label": "Grok Bot", "updated_at": 1794637579 },
  "anthropic": { "used_pct": 35, "headline": "35% · 5h 9%", "detail": "week", "resets_at": 1795050000, "updated_at": 1794637579 },
  "deepseek":  { "balance": 110.0, "currency": "CNY", "updated_at": 1794637579 },
  "xai":       { "spent": 3.2, "currency": "USD", "detail": "Nov", "updated_at": 1794637579 }
}
```

| Field | Meaning |
|---|---|
| `used_pct` | Share of the plan used, 0 to 100. Shown as the headline and a bar |
| `balance`, `spent`, `currency` | Money left or spent; `currency` defaults to `USD` (`CNY` shows `¥`) |
| `headline` | Replaces the headline built from the numbers, at most 40 bytes |
| `detail` | A short line, at most 60 bytes, shared with the reset time |
| `label` | Replaces the tile title, at most 24 bytes |
| `resets_at`, `updated_at`, `expires_at` | Unix seconds. Without `expires_at`, values go stale 24 hours after `updated_at` |

`scripts/ai-usage.sh` fills these in ([section 6](#ai-usage)).

`PUT /v1/state` follows [JSON Merge Patch](https://www.rfc-editor.org/rfc/rfc7386): only the fields you send change.

| In the request | Effect |
|---|---|
| An object | Merged into the existing object, field by field |
| `null` | Removes the field |
| Any other value, including an array | Replaces the existing value |

The response is `{"changed": true}` or `{"changed": false}`. The blob can hold up to 64 KB, nested at most 8 levels deep.

```sh
curl -X PUT "$KDASH_URL/v1/state" \
  -H "Authorization: Bearer $KDASH_TOKEN" \
  -d '{"todo":{"count":3}}'
```

### Inbox message

| Field | Type | Set by | Rules |
|---|---|---|---|
| `title` | string | Sender, required | At most 300 bytes |
| `body` | string | Sender | Markdown, at most 256 KB; shown when the message is opened |
| `source` | string | Sender | At most 64 bytes, e.g. `claude` or `ci` |
| `type` | string | Sender | At most 64 bytes, e.g. `claude.permission`; stored for senders, not shown |
| `priority` | string | Sender | `low`, `normal` (default) or `high` |
| `data` | object or array | Sender | Any extra details; stored, not shown |
| `id` | string | Sender or device | 1 to 64 of `A-Z a-z 0-9 . _ : -`; generated if omitted |
| `received_at` | integer | Device | Unix seconds |
| `read_at` | integer | Device | Unix seconds; absent while unread |
| `preview` | string | Device | Plain text from the start of the body, at most 200 bytes |
| `body_bytes` | integer | Device | Size of the body; absent if there isn't one |

`GET /v1/inbox` returns `preview` and `body_bytes` but not `body`, which only `GET /v1/inbox/{id}` returns.

Sending an `id` makes retries safe: repeating it returns `200` without creating a duplicate or making a read message unread.

The inbox holds 100 messages. When it's full, the oldest read message is removed. **Unread messages are never dropped**, so if all 100 are unread, new ones are refused with `507`.

```sh
curl -X POST "$KDASH_URL/v1/inbox" \
  -H "Authorization: Bearer $KDASH_TOKEN" \
  -d '{"title":"Build failed","source":"ci","priority":"high","body":"Tests failed on main."}'
```

To send a Markdown file, let `jq` handle the JSON escaping:

```sh
jq -n --arg title "Weekly report" --rawfile body report.md '{title: $title, body: $body}' |
  curl -X POST "$KDASH_URL/v1/inbox" \
    -H "Authorization: Bearer $KDASH_TOKEN" --data-binary @-
```

### Audi entry

Audi entries are not inbox messages. `GET /v1/inbox` never returns them. The dash home screen lists them beside unread briefings; that list is not the HTTP inbox. They live in `dash_audi.json` and `dash_audi_bodies/`.

| Field | Type | Set by | Rules |
|---|---|---|---|
| `title` | string | Sender | At most 300 bytes. Empty if omitted |
| `body` | string | Sender | Markdown, at most 256 KB |
| `source` | string | Sender | At most 64 bytes. `Audi` when omitted on create |
| `id` | string | Sender or device | 1 to 64 of `A-Z a-z 0-9 . _ : -`; generated if omitted |
| `ref` | integer | Sender or device | Positive integer shown as `#12`. Kept when the entry is updated. The device assigns the next number when omitted |
| `replace_id` | string | Sender | Request only. Updates that id in place and keeps its `ref`. A missing id is stored as a new entry under `id` |
| `created_at` | string | Sender | ISO 8601. The header uses it when it parses; otherwise `received_at` |
| `action` | string | Sender | `clear` only. Shows the idle line and keeps history. Response `{"cleared": true}` |
| `received_at` | integer | Device | Unix seconds |
| `preview` | string | Device | Plain text from the start of the body, at most 200 bytes |

`POST /v1/audi` returns `{id, ref, created, updated}`. The same id with the same title and body returns `200` and `"updated": false`, and does not refresh the screen. A changed title or body, or a `replace_id` that points at an existing entry, updates that row, keeps `ref`, and can auto-switch. `GET /v1/health` includes `audi_current_ref` (the ref on screen, or `null` when Audi is idle) when the Audi store is loaded.

Creating, updating, clearing and deleting an Audi entry counts toward the same 60 changes a minute as inbox and state changes.

```sh
curl -X POST "$KDASH_URL/v1/audi" \
  -H "Authorization: Bearer $KDASH_TOKEN" \
  -d '{"id":"audi-test-12","ref":12,"title":"DeepSeek review","source":"DeepSeek","body":"## Summary\n\n- First point"}'
```

The Mac sender is `scripts/audi-push.sh`. Files dropped in `~/kdash-audi/` are delivered by the same launchd job as the morning briefing. Writing `name.md` directly is fine: the job sends a file only after its size and modification time are unchanged across about 2 seconds, and a file that is still changing stays put instead of moving to `failed/`. A rename from a dotfile such as `.name.tmp` still works. See [docs/audi-mode-setup.md](docs/audi-mode-setup.md).

### Errors

Errors look like `{"error":"bad_field","message":"title is required"}`.

| Status | Code | Meaning |
|---|---|---|
| `400` | `bad_json`, `bad_field`, `bad_id`, `bad_request` | The request is invalid |
| `401` | `unauthorized` | Token missing or wrong |
| `404` | `not_found` | Unknown route or message |
| `405` | `method_not_allowed` | Route exists, wrong method |
| `411` | `length_required` | Chunked uploads aren't supported |
| `413` | `too_large`, `state_too_large` | Headers over 8 KB, request over 320 KB, or state over 64 KB |
| `429` | `rate_limited` | Over 60 changes a minute; the body includes `retry_after` |
| `503` | `busy` | More than 4 open connections |
| `500` | `storage_error` | A message body couldn't be saved |
| `507` | `inbox_full` | 100 unread messages |

---

## 4. Plugin design

```
plugin/dash.koplugin/
├── _meta.lua
├── dash_home.lua   # SimpleUI home screen module
├── main.lua        # lifecycle, menu, the one shared runtime
├── dash_server.lua      # non-blocking HTTP; no KOReader imports
├── dash_api.lua         # routes, auth, validation
├── dash_store.lua       # state blob, inbox, JSON file
├── dash_audi_store.lua  # Audi history; the home list reads it, the HTTP inbox does not
├── dash_audi_font.lua   # Audi body size: default 18, range 14–28
├── dash_audi_idle.lua   # 10-minute return from Audi to the dash home
├── dash_inbox.lua       # merged home Inbox: briefings and Audi entries
├── dash_power.lua       # keep-awake
├── dash_time.lua        # Eastern time and month layouts
├── dash_usage.lua       # AI usage tiles: labels, staleness
├── dash_battery.lua     # battery drain history and rate
├── dash_dashboard.lua     # fullscreen widget
├── dash_message_view.lua  # fullscreen message reader
├── dash_audi_view.lua     # Audi header and scrolling body
├── dash_markdown.lua      # Markdown to HTML, and previews
└── dash_weather.lua       # weather URL, parsing and labels
```

Files use a `dash_` prefix because KOReader adds every plugin folder to one shared module path, so a plain `server.lua` could clash with another plugin.

### Server

KOReader's `SimpleTCPServer` isn't used. It blocks the UI while reading and allows 100 ms to receive headers.

| Behaviour | Value |
|---|---|
| Port | `8787`, on all interfaces |
| Polling | Every 0.25 seconds through `UIManager:scheduleIn` |
| Sockets | Non-blocking for reads and writes |
| Limits | 4 connections, 10 seconds each, 8 KB headers, 320 KB request body |
| Reading | Everything waiting is read on each poll, up to 512 KB, so a large body arrives in one or two polls |
| `Expect: 100-continue` | Answered immediately, to avoid a delay in `curl` |
| Firewall | Adds `iptables` rules on start and removes them on stop, as the Kindle requires |

KOReader creates plugin instances separately for the file browser and reader, so the server, store and dashboard live in one module-level runtime object. `onCloseWidget` must not stop them.

### Staying on

Applied when the dashboard opens and undone when it closes:

| Action | Why |
|---|---|
| `PluginShare.pause_auto_suspend = true` | Stops KOReader's auto-suspend and power-off. This is needed on a charger too, because a *fully charged* Kindle counts as not charging. |
| `lipc-set-prop com.lab126.powerd preventScreenSaver 1` | Stops the Kindle's own system from sleeping. |
| `PluginShare.keepalive = true` | KOReader's source warns that resetting the t1 timer with the screensaver disabled causes a crash. This flag skips that reset. |

- **Crash recovery:** `preventScreenSaver` stays set if KOReader dies. A marker file is written while it's active, and the next startup resets the setting if the marker is still there.
- **Power button:** this still suspends the Kindle. The server and timers stop on suspend, then restart and redraw on resume.
- **Models with ads:** KOReader handles screensavers differently on Special Offers Kindles. Milestone 0 will show whether yours is affected.

### Wi-Fi

- Required KOReader settings: **Disable Wi-Fi connection when inactive** off, and **Restore Wi-Fi connection on resume** on.
- The footer shows the current connection and IP address.
- While disconnected, the plugin retries in the background, backing off from 30 seconds to 5 minutes.
- Give the Kindle a fixed IP address through a DHCP reservation on your router.

### Storage

Everything lives under `koreader/settings/`, so it comes back after a restart.

| File | Contents |
|---|---|
| `dash_data.json` | The state blob and the message index, including previews |
| `dash_messages/<n>.md` | One file per message body, named by sequence number |
| `dash_audi.json` | The Audi history index, the current entry and the next `ref` |
| `dash_audi_bodies/<n>.md` | One file per Audi body, named by sequence number |
| `dash_config.json` | The access token. Optional `audi_history_limit` overrides 20. Optional `audi_idle_seconds` overrides the 10-minute Audi idle return |
| `dash_restart_request` | Created by `scripts/deploy.sh`; the plugin restarts KOReader and deletes it |
| `dash_open_request` | Opens Dash on the next start, then is deleted. Created by `scripts/deploy.sh`, and by a restart made while Dash is open |

- **Why bodies are separate:** 100 messages of up to 256 KB each would make one file of up to 25 MB, rewritten on every change. The index stays small instead.
- **Why numbers, not ids:** ids may contain characters such as `:`, which the Kindle's filesystem rejects.
- **Why JSON:** KOReader's `LuaSettings` files run as Lua code on load, which shouldn't apply to network data.
- **Writes:** each file goes to a temporary file and is then renamed. A body is written as it arrives. The index is written at most once every 5 seconds, plus on suspend, Exit and quit, so a crash can lose up to 5 seconds of changes. A body file left over from a crash is overwritten by the next message that gets the same number.
- **Corrupt index:** it's renamed to `.bad`, the store starts empty, and the screen shows a warning.
- **Older data:** bodies stored inside the index by the previous version move to files on first load.

---

## 5. Security

Assume a trusted home network. HTTP is unencrypted, so anyone able to capture traffic on the same Wi-Fi could read values and the token.

- **Token:** 128 random bits from `/dev/urandom`, created the first time the dashboard opens and saved in `koreader/settings/dash_config.json`.
- **Limited powers:** the API can only change dashboard data. It has no shell, file or KOReader control.
- **Server off by default:** it starts when the dashboard opens and stops when it closes.
- **Input handling:** JSON is decoded inside `pcall`, unknown fields are dropped, and network data is never run as code.
- **Remote access:** use a VPN such as Tailscale, and never forward the port.

---

## 6. Senders

The plugin doesn't care what sends data. These are the first senders, all running on the Mac.

### `kdash`

Not built. Nothing in this repo is named `kdash`. Senders that exist are the scripts under `scripts/` (`inbox-send.sh`, `audi-push.sh`, `ai-usage.sh`, and the outbox job). The interface below is only the shape a future CLI would have.

POSIX shell using `curl` and `jq`. Settings come from `~/.config/kdash/config` (mode `600`), or from `KDASH_URL` and `KDASH_TOKEN`.

```
kdash state '{"todo":{"count":3}}'
kdash send "Build failed" [--body B] [--source S] [--high]
kdash inbox [--unread]
kdash doctor     # checks connection, token, clock difference
```

### Weather

The Kindle fetches weather itself, so it works even when the Mac is asleep.

**Source:** [Open-Meteo](https://open-meteo.com), which is free and needs no API key. Tested from the Kindle on 7 November 2026: the first request took 1.3 seconds, including setting up the secure connection, and the next took 0.15 seconds.

```
https://api.open-meteo.com/v1/forecast?latitude=40.7128&longitude=-74.0060
  &current=temperature_2m,weather_code
  &daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max
  &temperature_unit=fahrenheit&timezone=America/New_York&forecast_days=1
```

**What it shows:**

```
51°F Clear
High 61 · Low 45 · Rain 18%
```

**How it fits in:** the result is written into the `weather` field of the state blob, the same as an HTTP update would be, so the dashboard's display code doesn't change.

```json
"weather": {
  "summary": "51°F Clear",
  "detail": "High 61 · Low 45 · Rain 18%",
  "source": "kindle",
  "updated_at": 1794090000,
  "expires_at": 1794100800
}
```

#### When it fetches

| Event | Action |
|---|---|
| Dashboard opens | Fetch now |
| Every 30 minutes while open | Fetch |
| Wake from sleep, or Wi-Fi reconnects | Fetch if the last success is over 30 minutes old |
| A fetch fails | Retry after 5, then 10, then 30 minutes |
| Dashboard closes | Stop fetching |

`expires_at` is set 3 hours ahead, so after 3 hours of failures the dashboard shows `Weather unavailable` instead of an old forecast.

#### Not freezing the screen

A request can hang for up to its timeout, which would freeze the dashboard if it ran directly. So it runs in a separate process:

1. `ffiutil.runInSubProcess` starts a child process with a pipe back to the plugin.
2. The child makes the HTTPS request with a 15-second timeout, writes the response to the pipe, and exits.
3. The plugin checks the pipe every half second with `ffiutil.getNonBlockingReadSize`, and reads it with `ffiutil.readAllFromFD` once it's ready.
4. If there's nothing after 30 seconds, `ffiutil.terminateSubProcess` stops the child and the fetch counts as failed.
5. Only one fetch runs at a time.

KOReader's own AI assistant plugin uses the same pattern for network requests.

#### Weather codes

Open-Meteo reports conditions as [WMO codes](https://open-meteo.com/en/docs), which map to short labels:

| Codes | Label |
|---|---|
| 0 | Clear |
| 1, 2 | Partly cloudy |
| 3 | Cloudy |
| 45, 48 | Fog |
| 51–57 | Drizzle |
| 61–67, 80–82 | Rain |
| 71–77, 85, 86 | Snow |
| 95–99 | Thunderstorm |
| Anything else | Unknown |

#### Settings

| Setting | Default |
|---|---|
| Fetch weather on the Kindle | On |
| Location | New York City, 40.7128, -74.0060 |
| Units | Fahrenheit |

While fetching is on, it overwrites any weather sent over HTTP at the next fetch. Turn it off to use a sender instead.

#### Code

`dash_weather.lua` holds the pure parts: building the URL, parsing the response, and mapping codes to labels. These are tested with saved responses, including missing fields and unknown codes. `main.lua` runs the schedule and the child process.

### Claude Code hook

`scripts/claude-hook.sh` runs on Claude Code's `Notification` and `Stop` hooks, set in `~/.claude/settings.json` beside the macOS notifications. It reads `KDASH_URL` and `KDASH_TOKEN` from `.env`, so the token never sits in the settings file.

| Event | Title | Body | Priority | `type` |
|---|---|---|---|---|
| `Notification` (permission prompt, idle waiting) | `Needs you: <project folder>` | Claude's notification text | `high` | `claude.attention` |
| `Stop` | `Done: <project folder>` | Claude's last reply, cut at 4000 characters | `normal` | `claude.stop` |

Both bodies end with the working directory, and `data` holds the first 8 characters of the session id and the directory. The hook runs with `async: true` and curl gives up after 4 seconds, so a closed dashboard or a sleeping Kindle never slows Claude Code; the message is simply skipped.

### AI usage

`scripts/ai-usage.sh` fetches what has an API, takes the rest from flags, and sends one `PUT /v1/state` with only the providers it has new values for. Keys come from the environment or `.env` (git-ignored) and are never printed. Run it by hand, or install the launchd job with `scripts/install-launchd.sh`: it runs the script at login and every 30 minutes (`com.abharosim.koreader-dash.ai-usage`, template in `scripts/launchd/`, log in `~/Library/Logs/koreader-dash-ai-usage.log`), and `--uninstall` removes it. The job passes `--allow-empty`, so with no keys set it logs that there was nothing to send and leaves the tiles alone.

| Tile | Source | Setup |
|---|---|---|
| DeepSeek | `GET https://api.deepseek.com/user/balance`, documented. Shows the balance, USD if the account has both currencies | `DEEPSEEK_API_KEY` |
| Claude | `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`: the 7-day and 5-hour figures Claude Code's `/usage` shows. **Undocumented**, so it may stop working; the tile then goes stale rather than showing a wrong number | `KDASH_CLAUDE_FROM_KEYCHAIN=1` (set by the launchd job): koreader-dash's own login from `scripts/claude-login.py` (browser OAuth with PKCE, scope `user:profile`, Keychain item `koreader-dash-claude-oauth`), refreshed and rotated by `scripts/lib/claude-oauth.sh` under a lock; without it, Claude Code's own login is read (never written) while still valid. Or `CLAUDE_OAUTH_TOKEN`. Sends `User-Agent: claude-code/<installed version>` and honours `429 Retry-After` (10 to 60 minutes). On failure the tile keeps its last numbers and gets `expires_at: 1` and `stale_label: "已过期"`, so it reads `已过期 07:10`; the next success clears both |
| Grok | Plan usage (Grok Bot, SuperGrok) has no API, so it's sent by hand: `--grok-pct 17.4 --grok-resets 2026-11-20T23:24:00Z` | none |
| xAI API | Spend this month and prepaid balance from the xAI management API. Hand flags work too: `--xai-spent 3.20 --xai-detail Nov`. A `gemini` object in the state blob is stored and not shown; there is no Gemini tile | `XAI_MANAGEMENT_KEY` and `XAI_TEAM_ID` (optional) |

Every provider takes `--<provider>-pct`, `-resets`, `-spent`, `-balance`, `-currency`, `-detail`, `-label`, `-headline` and `-clear`; an empty text value removes that field. Hand-set values count as updated now. `--dry-run` prints the JSON instead of sending it.

### Todo count

`senders/todo-mock` sends a made-up count by updating `todo.count`. A real source later only needs to do the same.

---

## 7. Build plan

### Milestone 0: test on the Kindle
A test build with the clock, keep-awake, and a `/ping` endpoint. **This comes first because inbound HTTP on an idle Kindle is the biggest unknown.**

- [ ] The screen stays on and the clock updates for 24 hours while fully charged.
- [ ] `/ping` responds 5 minutes, 1 hour and overnight after the last touch.
- [ ] Wi-Fi comes back after a router restart.
- [ ] The power button suspends the Kindle, and the plugin recovers on resume.
- [ ] Force-killing KOReader leaves the Kindle able to sleep normally after the next start.

If `/ping` proves unreliable while idle, stop and switch to the Kindle polling a small service on the Mac. The state and message formats stay the same.

### Milestone 1: state and inbox over HTTP
- [x] `dash_api.lua` and `dash_store.lua`, with automated tests.
- [ ] State values and the inbox working on the Kindle, including marking messages read.

### Milestone 2: senders
- [ ] Weather fetched on the Kindle.
- [ ] `kdash` and the mock todo sender.

### Milestone 3: reliability
- [ ] A 72-hour run with no crash or memory growth.
- [ ] Opening and closing books with the plugin installed.
- [ ] `MODULE.md`, `FEATURE.md` and setup instructions.

---

## 8. Decisions

| Question | Decision |
|---|---|
| Should Claude alerts stay in scope? | Yes, as inbox messages from a Claude Code hook (`scripts/claude-hook.sh`), with no plugin changes. |
| Where does the todo count come from? | A mock sender for now. The real source is still to be chosen. |
| What location should weather use? | New York City (40.7128, -74.0060). |
| Where should weather come from? | Fetched by the Kindle from Open-Meteo, rather than sent from the Mac. |
| How do AI usage tiles get data? | Pushed from the Mac into the state blob, like the todo count. Most of it needs keys that shouldn't live on the Kindle, and two of the four have no API at all. |
| Rotate pages to fit the usage tiles? | No. One row of four short tiles fits under the clock, with a smaller calendar, and the inbox keeps two messages per page. Everything stays visible at a glance, with no timed full-screen redraws. |

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Wi-Fi power saving makes the Kindle unreachable while idle | Tested in Milestone 0; polling is the fallback |
| Kindle system software takes over the screen | Tested in Milestone 0 |
| Ghosting builds up | Hourly full refresh, adjustable |
| Kindle clock drifts, since nothing here corrects it | Nothing in the repo checks the clock (`kdash doctor` was never built). A badly wrong clock can also make secure connections fail, which would stop weather. |
| Open-Meteo is down or changes its API | Fetches fail, the last forecast expires after 3 hours, and the screen says so |
| KOReader internals change | Target one release and use few internal APIs |
| Battery wear from always charging | Accepted for now; a smart plug could limit charging later |

---

## 10. Sources

- KOReader source: `plugins/autosuspend.koplugin/main.lua`, `plugins/keepalive.koplugin/main.lua`, `plugins/httpinspector.koplugin/main.lua`, `frontend/ui/message/simpletcpserver.lua`, `frontend/ui/uimanager.lua`, `frontend/ui/network/manager.lua`, `frontend/luasettings.lua`, `frontend/device/kindle/device.lua`
- [notificationlistener.koplugin](https://github.com/omer-faruq/notificationlistener.koplugin)
- [dtdisplay.koplugin](https://github.com/kktse/dtdisplay.koplugin)
