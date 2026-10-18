# Blog

`blog` publishes a Hugo blog whose posts are written in an Obsidian vault.
It copies the posts, and the images they show, from the vault into the
site, builds the site to check it, then commits the posts and images and
pushes them. The hosting (GitHub Pages, through the site repository's own
workflow) builds and deploys on every push. Home Manager installs it on
macOS and Linux; Git and Hugo are used from PATH.

```sh
blog status              # settings, tools, repository and pending changes
blog sync --dry-run      # what a sync would change
blog sync                # copy posts and images into the site
blog build               # build the site into a temporary folder
blog publish             # sync, build, commit and push
blog publish --no-build --message "Fix a typo"
```

## Settings

`$XDG_CONFIG_HOME/blog/config.toml`, written by the Home Manager module
from the host's data volume and the vault's location; `--config FILE`
reads another file.

| Key | Meaning |
| --- | --- |
| `site` | The Hugo site; posts go to `content/posts`, images to `static/images` |
| `posts` | The vault's posts folder |
| `images` | The vault's attachments folder |
| `branch` | The branch `publish` works on and pushes (default `main`) |
| `remote` | Where it pushes (default `origin`) |
| `backups` | How many runs of replaced posts to keep (default 5, 0 for none) |

An unknown key is an error, so a typo cannot pass for a default.

## Commands

| Command | What it does |
| --- | --- |
| `status` | The settings, Hugo's version, the branch, unpushed commits, uncommitted site files, and what a sync would change |
| `sync` | Makes the site's posts mirror the vault's and copies the images they show |
| `build` | Runs Hugo into a temporary folder and counts the pages |
| `publish` | Sync, build, commit the posts and images folders, push the branch |

`sync` and `publish` take `-n`/`--dry-run`, which shows the plan and
writes nothing. Exit status: 0 on success, 1 when a step fails, 2 for a
usage error or invalid settings, 130 when interrupted.

## How Posts Are Copied

- Markdown is copied with Obsidian's image embeds rewritten for Hugo:
  `![[chart.png|Load over time]]` becomes
  `![Load over time](/images/chart.png)`. A size such as `|300` is not
  alternative text, so the file's stem is used; a link without `!` stays a
  link. Other files in the posts folder are copied as they are.
- Each image a post shows is copied from the vault's images folder.
  Images nothing points at stay in the site, which has its own (a logo,
  for instance).
- A post the vault no longer has is removed from the site. A copy of every
  post and image replaced or removed is kept under
  `$XDG_STATE_HOME/blog/backups/`.

## Safety

- The whole sync is planned before anything is written. A missing image, an
  embed with a folder in its name, or a post that is not UTF-8 stops it.
- A vault with no posts is refused: it is far likelier unmounted or not yet
  synced than empty, and mirroring it would empty the site.
- Links and special files in the vault are skipped and reported, never
  followed, so nothing outside the vault reaches the published site. Hidden
  files and folders are left alone on both sides.
- Every file is written to a temporary file beside it and renamed into
  place. One sync or publish runs at a time, under a lock the system
  releases if the process dies.
- `publish` refuses another checked-out branch, commits only the posts and
  images folders (other staged work stays staged), and never forces a push.
  A failed build stops it before the commit.

## Limits

- An embed inside a code block is rewritten too.
- Embeds name images by file name alone, so two images with the same name in
  different vault folders cannot both be published.
- The check build uses the local Hugo, which can differ from the version the
  hosting builds with.

## Tests

`nix build .#blog -L` runs the tests in `tests/`, which create their own
vault, site repository and bare remote, drive the real Git and use a fake
Hugo. Without Nix, from this directory:
`python3 -m unittest discover -s tests -t .`.
