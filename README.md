# dotter

A deliberately boring dotfiles manager: plain bash, plain git, plain symlinks.

Your config files live in a git repo. A manifest lists which ones. The `dotfiles`
command moves them into the repo, symlinks them back, and keeps every machine in
sync with `git pull` / `git push`. That is the whole idea.

**No templating language. No encryption. No third-party dependencies.** If you
need those, use [chezmoi](https://chezmoi.io). This exists for the case where you
don't, and where a tool you can read in one sitting is worth more than features
you won't use.

## Install

Single self-contained script — copy it onto your `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/execsumo/dotter/main/bin/dotfiles \
  -o ~/.local/bin/dotfiles && chmod +x ~/.local/bin/dotfiles
```

Requires bash, git, and coreutils. Works on macOS and Linux. `gh` is optional —
used only to *create* a dotfiles repo that doesn't exist yet.

## Quick start

On your first machine:

```bash
dotfiles init --repo https://github.com/<you>/dotfiles
dotfiles add ~/.zshrc ~/.gitconfig ~/.tmux.conf
dotfiles sync
```

On every other machine — laptop, VPS, container:

```bash
dotfiles init --repo https://github.com/<you>/dotfiles
dotfiles link
```

There is no "source of truth" machine. Every machine is a peer: `add` from
wherever you happen to be, `sync` to share it, `link` to apply it.

## Commands

| Command | What it does |
|---|---|
| `dotfiles init [--repo URL] [--yes]` | Clone the repo, or create it. Seeds the manifest and a `.gitignore`. |
| `dotfiles add [--label T] [--yes] <path>...` | Move a file/dir into the repo, symlink it back, record it in the manifest, commit. Audits directories first. |
| `dotfiles link` (alias `apply`) | Symlink every manifest entry present in the repo but not yet linked here. Backs up conflicts as `*.bak`. |
| `dotfiles sync [-m MESSAGE]` | Pull remote changes, then push local commits. With `-m`, commits the working tree first. |
| `dotfiles status` | Per-entry link state, plus repo health warnings. |
| `dotfiles rm [--yes] <path>...` (alias `remove`) | Untrack: restore the real file to `$HOME`, drop the manifest entry. |
| `dotfiles help` / `version` | Also available as `-h`, `--help`, `--version`. |

`--yes` may be shortened to `-y`; `init` also accepts `--non-interactive` as a
synonym. `--yes` skips confirmation prompts, which is what makes the tool usable
from a script; without a TTY and without it, prompts decline rather than hang.

`DOTFILES_DIR` overrides the repo location (default `~/.dotfiles`).

Only `init` ever touches `gh`. Everything else is git-only, so a bare VPS works.

## The manifest

Lives at `<repo>/dotfiles.manifest`, **inside the dotfiles repo** — so it is
readable and editable from any machine that cloned it.

```
type|relpath|label
```

- `type` — `file` or `dir`. Files are symlinked individually; directories whole.
- `relpath` — path relative to `$HOME`. The repo mirrors `$HOME` exactly.
- `label` — human-readable description.

`#` comments and blank lines are ignored. `dotfiles add` appends to it for you,
but it is a plain text file — edit it by hand whenever that's easier.

### Why an allow-list, and not "just sync the whole home directory"

This is the design's load-bearing safety property, not a formatting convenience.
Every entry is something you named on purpose.

**Prefer `file|` entries. Treat `dir|` as a risk.** A whole-directory entry
tracks not just what's in it today but whatever the owning tool writes there
tomorrow. Real things this caught, the hard way:

- A CLI's config directory held `auth.json` with a live API key and OAuth
  tokens, plus 250MB of bundled plugin binaries. It committed fine and then hit
  GitHub's 100MB blob limit on push.
- Another config directory swept in log files, unix sockets, and live UI session
  state alongside its one actual config file.

The fix in both cases was the same: narrow the `dir|` entry to individual
`file|` entries naming only the known-safe config files.

`dotfiles add <dir>` therefore audits before it accepts — it reports size, file
count, credential-shaped filenames, oversized files, sockets, logs, databases,
and non-portable symlinks, then makes you confirm. **That audit is a snapshot,
not a guarantee.** It cannot know what the tool will write next week.

## Behaviours worth knowing

These are all deliberate, and each one is the scar tissue of a real failure.

**Nested git repos are refused.** If a directory contains its own `.git`, `add`
refuses. Moving a live git repo inside another makes git record it as a
*submodule gitlink* — a bare commit hash, not file content. It pushes and clones
back as an empty directory, with no error at any point. Disconnect it first
(move its `.git` aside) if you really want it tracked.

**A directory's own `.gitignore` keeps working.** If a tracked directory ships
one, it travels with the directory and keeps applying once nested in the
dotfiles repo. The tool doesn't try to reinvent exclusion rules its owner
already maintains.

**Real files are backed up, not overwritten.** `link` moves a pre-existing real
file to `<name>.bak` before symlinking over it. Precisely: an older `<name>.bak`
is replaced by the newer backup, and a symlink in the way is removed rather than
backed up (it holds no content of its own).

**HTTPS remotes only.** `gh auth login` installs a git credential helper for
HTTPS, so this works with no SSH key on the account. SSH remotes fail with
`Permission denied (publickey)` on machines that never registered one — which is
every fresh container. The tool warns if `origin` is an SSH URL.

**`sync` survives half-initialised repos.** A repo can legitimately have zero
commits, or commits but no upstream tracking branch, after an interrupted run.
A bare `git pull --ff-only` hard-fails in both states and, under `set -e`, takes
the whole script down. `sync` checks for both and warns instead.

**The branch is always `main`.** Never inherited from `init.defaultBranch`.

**bash 3.2 compatible.** macOS still ships bash 3.2 (2007), so: no `${VAR,,}`,
no `declare -A`, no `mapfile`/`readarray`. There is a subtler one too — bash 3.2
mis-parses a `case` block nested inside `$( )`, which is why the symlink scan
lives in its own function.

## Known limitations

- **Machine-specific absolute symlinks need manual pruning.** Directory entries
  can accumulate symlinks pointing at absolute paths outside `$HOME`, written by
  externally-managed tooling. They dangle on every other machine. No gitignore
  pattern catches these, so `dotfiles status` reports them and you delete them
  by hand. Auto-deleting someone else's symlinks is not a call this tool makes.
- **No conflict resolution.** `sync` is `pull --ff-only` then `push`. If two
  machines edited the same file and diverged, it tells you and stops — resolve
  it with git, in the repo, like any other merge.
- **No secret scanning.** The `add` audit matches on *filenames*, not contents.
  A credential in a file named `config.toml` will not be caught.

## Documentation

| Doc | For |
|---|---|
| README.md (this file) | Installing and using it |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Why it is shaped this way — design decisions, invariants, what is deliberately absent |
| [handoff.md](handoff.md) | Working on it — dev setup, house rules, bash 3.2 traps, open gaps |
| [REVIEW.md](REVIEW.md) | Findings from an independent review pass |

## Consumers

vibebox's container onboarding calls this tool for its dotfiles step:

```bash
dotfiles init --repo "https://github.com/${GH_USER}/dotfiles"
dotfiles link
```

That's the whole integration — the same two commands you'd run anywhere else.
