# GitHub Feed

Your GitHub homepage feed on your desktop — pushes, pull requests, issues,
releases, stars, and forks from people you follow, in the bar and a panel.

## Setup

For the full homepage feed (everyone you follow, like github.com):

1. Create a fine-grained personal access token at
   <https://github.com/settings/tokens> (no extra permissions needed —
   public activity is readable without scopes).
2. In Noctalia → Plugins → GitHub Feed → Settings, set **GitHub username**
   to your login and paste the token into **Personal access token**.

Without a token the plugin still works: add any public GitHub users from
the panel and their public activity is shown instead.

## Usage

- The bar icon shows the number of feed items; click it to open the panel.
- In the panel, type a username (e.g. `octocat`) and press `+` to watch
  them. Click a user chip to stop watching them.
- Use the filter box to narrow the feed by user, repo, or keyword.
- Click a repository row to open it on github.com.

## Settings

| Key                  | Type   | Default | Notes                                                        |
| -------------------- | ------ | ------- | ------------------------------------------------------------ |
| `github_username`    | string | `""`    | Your GitHub login.                                           |
| `github_token`       | string | `""`    | Optional PAT; unlocks the homepage feed + higher rate limit. |
| `refresh_interval`   | int    | `30`    | Auto-refresh period in minutes (5–240).                      |
| `max_items`          | int    | `30`    | Maximum feed items kept (10–100).                            |
| `show_count_in_bar`  | bool   | `true`  | Show the item count beside the bar icon.                     |

## Notes

- Polls `GET /users/{you}/received_events` when authenticated (exactly what
  github.com shows), otherwise `GET /users/{user}/events/public` per
  watched user.
- Unauthenticated requests share GitHub's 60/hour rate limit; a token
  raises it to 5,000/hour.
