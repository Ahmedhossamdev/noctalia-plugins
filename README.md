# noctalia-plugins

Personal plugin source for [Noctalia Shell](https://github.com/noctalia-dev/noctalia).

## Add this as a plugin source

In Noctalia, open Settings (`Super`+`,`) → Plugins → **Sources**, and add:

```
https://github.com/Ahmedhossamdev/noctalia-plugins
```

Then go to **Available**, install a plugin, and enable it from **Installed**.

## Plugins

- [timezone-hub](./timezone-hub) — change your device timezone and compare
  it against other cities on a live, scrollable hour-by-hour timeline.

## Structure

Each plugin lives in its own top-level directory with a `manifest.json`, and
is listed in [`registry.json`](./registry.json) so Noctalia can discover it
as an installable source.
