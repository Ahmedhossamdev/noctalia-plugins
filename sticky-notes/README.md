# Sticky Notes

Quick, colourful sticky notes right from your bar — for
[Noctalia Shell](https://github.com/noctalia-dev/noctalia) v5 (Luau plugin
API).

## Features

- **Bar widget** — note icon with a live count badge; click to open the
  panel. The count is hidden while blur mode is on.
  - **Panel** — scrollable list of notes, each rendered as a coloured card
    with a preview of its content and its creation time.
    Saved notes are loaded before the add action becomes available, so opening
    the panel cannot briefly present an empty list.
  - **Multiple notes** with per-note color selection from a 7-swatch palette
    (yellow, pink, red, blue, green, orange, purple). The current color is
    marked with a primary-coloured ring around the swatch.
  - **Full-screen edit view** — click a note preview (or its edit button) to
    open the complete note in a selectable multiline input for quick copying
    and pasting. The draft is saved when you leave or submit the editor, which
    keeps scrolling stable in long notes. Empty notes are auto-deleted when
    you leave the editor, so the list never fills up with blanks.
  - **Web links** — notes containing an `http://`, `https://`, or `www.`
    address show an external-link button. Click it to open the link in your
    default browser.
  - **Pin notes** — starred notes float to the top of the list.
  - **Drag to arrange** — grab a note by its `≡` handle and drop it onto
    the thin line between cards to reorder within its group, or drop it
    into the other group's zone to pin/unpin in one gesture.
  - **Blur mode** — one-tap privacy toggle that hides every note behind a
    blur overlay (light / medium / heavy strengths, configurable).
  - **Auto-blur on open** (optional) — re-blurs the panel every time it
    opens, so a shoulder-surfer doesn't see your notes.
- **Ctrl+Enter** in the editor saves and closes the current note (same as
  the Done button). The shortcut can be turned off in settings.

## Installation

### Option A — add this repo as a plugin source (recommended)

1. Open Settings (`Super`+`,`) → Plugins → **Sources**
2. Add source: `https://github.com/Ahmedhossamdev/noctalia-plugins`
3. Go to **Available**, find **Sticky Notes**, install it
4. Go to **Installed**, enable it
5. Go to Bar → add the widget to a section

### Option B — manual copy

```bash
mkdir -p ~/.config/noctalia/plugins
cp -r sticky-notes ~/.config/noctalia/plugins/
```

Reload Noctalia's config (`noctalia msg config-reload`, or restart it),
then in Settings → Plugins → **Installed**, enable **Sticky Notes** and
add its widget from the Bar tab.

## IPC

```sh
# Open the panel
noctalia msg panel-toggle ahmedhossamdev/sticky-notes:panel
```

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Default note color | Yellow | Color used for newly created notes. |
| Note font size | 13 | Font size (10–20) for note previews and the editor. |
| Show note count in bar | on | Show the count badge next to the bar icon. |
| Auto-blur on open | off | Re-blur every time the panel opens. |
| Blur strength | Medium | Light / Medium / Heavy — visual weight of the blur overlay. |
| Save with Ctrl+Enter | on | Enable Ctrl+Enter in the editor to save and close. |
| Notes save folder | `~/Documents/sticky-notes` | Where notes are saved. `~` is expanded. |
| Save file format | Markdown (.md) | `md`, `txt`, or `json`. |

## Storage

Notes are saved as a single file inside the save folder, named after the
chosen format (`notes.md`, `notes.txt`, or `notes.json`). The default
folder is `~/Documents/sticky-notes` — a user-readable location, not the
opaque `pluginDataDir()` — so you can back up, sync, or read the file
outside Noctalia.

The Markdown format uses one `## Note N` section per note with a hidden
metadata comment carrying the note id, color, and timestamps. Editing the
file by hand is safe as long as the metadata comments are preserved.

## Notes

- Requires `plugin_api = 24` (declarative `ui.*` panel, `state.watch`
  pub/sub, `writeFile`/`readFile`, drag & drop, and Luau).
- Note previews use a high-contrast dark foreground, compact to their content,
  and show at most four lines. Long content is shortened with an ellipsis;
  click the card to view and select the complete note.
- The color palette is intentionally small (7 pastels + medium red +
  orange) rather than a full color wheel — sticky notes work best when
  colors are meaningfully distinct.
