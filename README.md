# noctalia-plugins

Personal plugin source for [Noctalia Shell](https://github.com/noctalia-dev/noctalia)
v5 (Luau plugin API, `plugin.toml` manifests).

## Add this as a plugin source

In Noctalia, open Settings (`Super`+`,`) → Plugins → **Sources**, and add:

```
https://github.com/Ahmedhossamdev/noctalia-plugins
```

Then go to **Available**, install a plugin, and enable it from **Installed**.

## Plugins

- [timezone-hub](./timezone-hub) — change your device timezone and compare
  it against other cities, with live times and a per-city hour-offset strip.
- [display-arrange](./display-arrange) — position each connected display
  relative to your primary (left / right / above / below) with live IPC
  control; layout is re-applied automatically on hotplug and startup.

## Structure

Each plugin lives in its own top-level directory with a `plugin.toml`
manifest, and is listed in [`catalog.toml`](./catalog.toml) so Noctalia can
discover it as an installable source.
