# GitHub Feed

Your GitHub homepage feed on your desktop — pushes, pull requests, issues,
releases, stars, and forks from people you follow, in the bar and a panel.

## Setup

Zero configuration if you use the GitHub CLI — the plugin signs in as
whoever `gh` is logged in as and shows **your** homepage feed (everyone
you follow, like github.com):

```sh
gh auth login
```

That's it. Your avatar appears in the panel header, and every event shows
the actor's avatar (cached locally, downloaded once).

To use a different account without touching `gh`, set **GitHub username**
and **Personal access token** in Noctalia → Plugins → GitHub Feed →
Settings (a fine-grained token with no extra permissions is enough).
Settings always override the `gh` login.

## Usage

- The bar icon shows the number of feed items; click it to open the panel.
- In the panel, type a username (e.g. `octocat`) and press `+` to watch
  them. Click a user chip to stop watching them.
- Use the filter box to narrow the feed by user, repo, or keyword.
- Click a repository row to open it on github.com.

## Settings

| Key                  | Type   | Default | Notes                                                        |
| -------------------- | ------ | ------- | ------------------------------------------------------------ |
| `github_username`    | string | `""`    | Override account; empty = whoever `gh` is logged in as.      |
| `github_token`       | string | `""`    | Override token; empty = `gh auth token`.                    |
| `refresh_interval`   | int    | `30`    | Auto-refresh period in minutes (5–240).                      |
| `max_items`          | int    | `30`    | Maximum feed items kept (10–100).                            |
| `show_count_in_bar`  | bool   | `true`  | Show the item count beside the bar icon.                     |

## Notes

- Polls `GET /users/{you}/received_events` when signed in (exactly what
  github.com shows), otherwise `GET /users/{user}/events/public` per
  watched user. Watching extra users from the panel always works and is
  merged into your feed.
