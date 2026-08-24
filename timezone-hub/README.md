# Timezone Hub

Change your device's timezone and compare it against other cities — a bar
clock and a comparison panel, for [Noctalia Shell](https://github.com/noctalia-dev/noctalia)
v5 (Luau plugin API).

## Features

- **Bar widget** — your device's local time (with zone abbreviation, or a
  chosen comparison city's time instead), click to open the panel.
- **Panel** — your device pinned as the first row, plus every city you add:
  - live time, UTC offset, and delta vs your device ("+6h", "-9h30", …)
  - a compact hour-offset strip per row (current hour highlighted, work
    hours shaded — configurable range)
  - drag the grip to reorder comparison cities
- **Change your device timezone** from a searchable list of every IANA zone
  `timedatectl` knows about, or promote any comparison city to be your
  device's timezone with one click (the pin icon on its row).
- **Star a row** to pick which zone the bar widget mirrors (defaults to
  your device).
- Settings (Settings → Plugins → Timezone Hub): 12h/24h format, how many
  hours to show before/after now in the strip, and the work-hour highlight
  range.

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

Reload Noctalia's config (`noctalia msg config-reload`, or restart it), then
in Settings → Plugins → **Installed**, enable **Timezone Hub** and add its
widget from the Bar tab.

## IPC

```sh
# Open the panel
noctalia msg panel-toggle ahmedhossamdev/timezone-hub:panel

# Manage comparison cities
noctalia msg plugin ahmedhossamdev/timezone-hub:service all add "America/Los_Angeles"
noctalia msg plugin ahmedhossamdev/timezone-hub:service all remove "UTC"
noctalia msg plugin ahmedhossamdev/timezone-hub:service all list
```

## Notes

- Requires `plugin_api = 24` (argv-array `noctalia.runAsync()` for safe
  `pkexec`/`timedatectl` execution, IANA-zone time formatting, and panel
  drag & drop).
- The hour view is a **fixed, non-scrolling strip** rather than a
  scrollable 24-hour grid with a "now" line — Noctalia's v5 declarative
  panel UI (`ui.*`) only supports vertical scrolling, with no canvas or
  overlay positioning, so a horizontally-scrollable timeline isn't
  buildable there. The strip shows a configurable window of hours around
  now instead, with the current hour highlighted.
- Comparison cities are stored under the plugin's data directory and
  survive plugin updates; scalar preferences (time format, hour window,
  work-hour range) live in the shell's own Settings → Plugins page.
- This plugin previously targeted Noctalia's legacy v4 (QML-based) plugin
  format. It has been rewritten against the current v5 API
  (`plugin.toml` + Luau).
