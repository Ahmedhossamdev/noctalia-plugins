# Display Arrange

Pick where each connected display sits relative to your primary one — left,
right, above, below — for [Noctalia Shell](https://github.com/noctalia-dev/noctalia)
v5 (Luau plugin API) on [niri](https://github.com/YaLTeR/niri) or [Hyprland](https://hyprland.org/).

## Features

- **Bar widget** — shows how many displays are currently connected, click to
  open the panel.
- **Panel** — one card per connected display: name, make/model, current
  resolution/scale, and its live logical position.
  - Pick which display is **primary** (always anchored at `0, 0`) with the
    star button on any non-primary card.
  - Point every other display **left / right / above / below** the primary
    with the four direction buttons — the exact x/y is computed from each
    display's logical size and applied immediately via the compositor's IPC.
- The layout is **re-applied automatically** whenever the set of connected
  displays changes (e.g. plugging in a monitor), and once on plugin/service
  startup — so your arrangement survives reconnects and shell restarts
  without needing to touch niri's config file.

## Requirements

- A supported Wayland compositor:
  - [niri](https://github.com/YaLTeR/niri) — drives `niri msg output ...` directly
  - [Hyprland](https://hyprland.org/) — drives `hyprctl keyword monitor ...` directly

## Installation

### Option A — add this repo as a plugin source (recommended)

1. Open Settings (`Super`+`,`) → Plugins → **Sources**
2. Add source: `https://github.com/Ahmedhossamdev/noctalia-plugins`
3. Go to **Available**, find **Display Arrange**, install it
4. Go to **Installed**, enable it
5. Go to Bar → add the widget to a section

### Option B — manual copy

```bash
mkdir -p ~/.config/noctalia/plugins
cp -r display-arrange ~/.config/noctalia/plugins/
```

Reload Noctalia's config (`noctalia msg config-reload`, or restart it), then
in Settings → Plugins → **Installed**, enable **Display Arrange** and add
its widget from the Bar tab.

## IPC

```sh
# Open the panel
noctalia msg panel-toggle ahmedhossamdev/display-arrange:panel
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Refresh interval | 10s | How often the service polls the compositor for connected-display changes. |
| Re-apply layout on hotplug | on | Automatically re-apply the saved arrangement when the connected-display set changes. |

## Notes

- Compositors may not persist runtime output-position changes — niri forgets
  them on restart/config-reload, and Hyprland's `hyprctl keyword` changes are
  temporary. This plugin doesn't edit config files; instead its service
  re-applies the saved layout every time it starts, which covers normal
  login/hotplug persistence without touching your compositor config.
- Each non-primary display is positioned **relative to the primary only**
  (not chained to its neighbors). If two displays are both set to, say,
  "right of primary", they'll land in the same spot — pick different
  directions, or make one of them primary instead.
- Manual/absolute x,y placement isn't exposed in the panel — only the four
  relative directions. If you need finer control, edit your compositor's
  config directly for a permanent layout.
- Requires `plugin_api = 24`.
