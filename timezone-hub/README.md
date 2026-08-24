# Timezone Hub

Change your device's timezone and see it compared against other cities on a
live, scrollable hour-by-hour timeline — a bar clock, a full comparison
panel, and a settings page, all in one plugin for [Noctalia Shell](https://github.com/noctalia-dev/noctalia).

## Features

- **Bar widget** — your device's local time (with zone abbreviation), click
  to open the panel.
- **Timeline panel** — your device pinned as the first row, plus every city
  you add, each rendered as a horizontal strip of hour cells:
  - a vertical line marks the current moment, shared across every row
  - work hours are subtly highlighted (configurable range)
  - the first hour of a new day shows the weekday + date instead of a number
  - each row shows the offset relative to your device ("+6h", "-9h30", …)
- **Change your device timezone** from a searchable list of every IANA zone
  `timedatectl` knows about, or promote any comparison city to be your
  device's timezone with one click (the pin icon on its row).
- **Settings page** mirrors the panel's controls: manage comparison cities,
  12h/24h format, how many hours to show before/after now, and the work-hour
  highlight range.

## Requirements

- `timedatectl` (systemd) — used to detect/list/set timezones.
- `pkexec` (polkit) — used to authorize the actual timezone change, since
  that's a privileged, machine-wide setting. A polkit agent must be running
  for the auth prompt to appear (true by default on most desktop setups).

If you'd rather not get a password prompt every time, you can allow your own
user to change the timezone without authentication by adding a polkit rule,
e.g. `/etc/polkit-1/rules.d/49-timedate.rules`:

```js
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.timedate1.set-timezone" &&
      subject.isInGroup("wheel")) {
    return polkit.Result.YES;
  }
});
```

Adjust the group/user check to your own setup. This is optional — the
plugin works fine with the default `pkexec` prompt.

## Installation

### Option A — add this repo as a plugin source (recommended)

1. Open Settings (`Super`+`,`) → Plugins → **Sources**
2. Add source: `https://github.com/Ahmedhossamdev/noctalia-plugins`
3. Go to **Available**, find **Timezone Hub**, install it
4. Go to **Installed**, enable it
5. Go to Bar → add the widget to a section

### Option B — manual copy

```bash
mkdir -p ~/.config/noctalia/plugins
cp -r timezone-hub ~/.config/noctalia/plugins/
```

Restart Noctalia (`killall qs && qs -c noctalia-shell -d`), then in Settings
→ Plugins → **Installed**, enable **Timezone Hub** (it's picked up
automatically just by being in the plugins folder — no manual JSON editing
needed) and add its widget from the Bar tab.

## Notes on how the timeline is computed

QML's JS engine doesn't reliably resolve arbitrary IANA timezones on its
own, so — like the official World Clock plugin — this reads the UTC offset
and abbreviation for every configured zone from `date` (`TZ=<zone> date
+"%z|%Z"`), batched into a single process call per refresh (every 2 minutes,
plus right after you add/change a zone). Everything else — the hour grid,
the "now" line, day boundaries, work-hour shading — is pure arithmetic on
top of that cached offset, so the UI stays smooth between refreshes.
