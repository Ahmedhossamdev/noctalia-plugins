# Display Arrange

Pick where each connected display sits relative to your primary one — left,
right, above, below — and rotate it Windows-style (Landscape / Portrait /
Landscape flipped / Portrait flipped) — for
[Noctalia Shell](https://github.com/noctalia-dev/noctalia) v5 (Luau plugin
API) on [niri](https://github.com/YaLTeR/niri) or [Hyprland](https://hyprland.org/).

## Plugin

| Field | Value |
| --- | --- |
| ID | `ahmedhossamdev/display-arrange` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

## Requirements

- Install `notify-send` on `PATH` (provided by libnotify) for the Keep/Revert
  desktop notification.
- Use one of these supported Wayland compositors:
  - `niri` on `PATH`, with `NIRI_SOCKET` available. The plugin uses
    `niri msg --json outputs` to read outputs and `niri msg output <name> ...`
    to apply mode, scale, transform, and position changes.
  - `hyprland` with `hyprctl` on `PATH` and
    `HYPRLAND_INSTANCE_SIGNATURE` available. The plugin uses
    `hyprctl monitors -j` to read outputs and `hyprctl keyword monitor ...`
    to apply changes.

## Usage

Enable **Display Arrange**, add its `bar` widget to a bar, then click the
widget to open the `panel` entry. You can also toggle the panel directly:

```sh
noctalia msg panel-toggle ahmedhossamdev/display-arrange:panel
```

- **Bar widget** — shows how many displays are currently connected, click to
  open the panel.
- **Panel** — one card per connected display: name, make/model, current
  resolution/scale/orientation, and its live logical position.
  - Pick which display is **primary** (always anchored at `0, 0`) with the
    star button on any non-primary card.
  - Point every other display **left / right / above / below** the primary
    with the four direction buttons — the exact x/y is computed from each
    display's logical size and applied immediately via the compositor's IPC.
  - **Orientation** — cycle each display through Landscape → Portrait →
    Landscape (flipped) → Portrait (flipped). Applied via
    `niri msg output <name> transform <…>` on niri and
    `hyprctl keyword monitor <name>,transform,<0-7>` on Hyprland (after the
    main `monitor` keyword, as Hyprland requires).
  - **Display mode** — Extend / PC screen only / Second screen only
    (Duplicate/mirror is shown but disabled: neither compositor supports
    enabling mirroring at runtime — use your compositor config for that).
  - **Safe confirmation** — each display change opens a desktop notification
    with **Keep** and **Revert** buttons. Related changes made while that
    notification is open are confirmed together. If neither action is selected
    within 30 seconds, the plugin restores the previous layout automatically.
- The layout is **re-applied automatically** whenever the connected-display
  set or enabled state changes (for example, when reconnecting a monitor), and
  once on plugin/service startup — so your arrangement survives reconnects and
  shell restarts without needing to touch your compositor's config file.

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

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_interval` | `int` | `10` | Seconds between checks of connected displays and the live layout. |
| `auto_reapply` | `bool` | `true` | Re-apply the saved arrangement after hotplug or when the compositor's live layout drifts from it. |

## Notes

- Neither compositor persists runtime changes — niri forgets them on
  restart/config-reload, and Hyprland's `hyprctl keyword` changes are
  temporary. This plugin doesn't edit config files; instead its service
  re-applies the saved layout (position + mode + scale + orientation) every
  time it starts, which covers normal login/hotplug persistence without
  touching your compositor config. To make it permanent, copy the applied
  values into `config.kdl` (`output { position, transform, … }`) or
  `hyprland.conf` (`monitor=…,transform,…`) respectively.
- Saved state is written to `noctalia.pluginDataDir()/data.json`. It contains
  the selected primary display, display mode, and each display's direction,
  mode, scale, and orientation.
- The plugin spawns only the declared compositor command (`niri` or `hyprctl`)
  and `notify-send`; it makes no network calls.
- Each non-primary display is positioned **relative to the primary only**
  (not chained to its neighbors). If two displays are both set to, say,
  "right of primary", they'll land in the same spot — pick different
  directions, or make one of them primary instead.
- Manual/absolute x,y placement isn't exposed in the panel — only the four
  relative directions. If you need finer control, edit your compositor's
  config directly for a permanent layout.
- Requires `plugin_api = 24`.
