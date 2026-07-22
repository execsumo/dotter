# Architecture

Why this tool is shaped the way it is. For *how to use it* see [README.md](README.md);
for *how to work on it* see [handoff.md](handoff.md).

---

## The one-sentence model

A git repo that mirrors `$HOME`, a text file listing which paths are real, and
symlinks pointing from `$HOME` into the repo.

```
$HOME/.zshrc  ──symlink──>  ~/.dotfiles/.zshrc  ──git──>  github.com/you/dotfiles
                                   ▲
                            dotfiles.manifest
                          (the allow-list, in the repo)
```

Everything else is bookkeeping around that picture.

---

## Three design decisions

### 1. Git is the sync engine, not something we wrap

Git already provides bidirectional sync, conflict detection, history, and
rollback. The tool does not reimplement any of it. `sync` is literally
`git pull --ff-only` followed by `git push`, with guards around the states where
those commands fail badly.

**Consequence:** there is no "server", no daemon, no lock file, and no custom
conflict resolution. If two machines diverge, git says so and you fix it with
git. This is a deliberate refusal to build a distributed-systems problem.

**Consequence:** every machine is a peer. The old design had a designated source
machine that pushed and containers that only pulled. That asymmetry existed
because the *tooling* was asymmetric, not because the data was — git never
required it. Removing it removed a whole class of "I'm on the wrong laptop"
problems.

### 2. The manifest lives inside the repo it describes

This is forced, not stylistic. Two independent requirements pin it there:

- `add` must commit the manifest change and the file itself atomically. If they
  live in different repos, they drift.
- A fresh machine has *only* the cloned dotfiles repo. If the manifest lived
  anywhere else — say, baked into a container image — that machine couldn't
  link anything without also obtaining that other thing.

The manifest was previously owned by a consumer (vibebox) and shipped into its
image. That is exactly what made one machine special. Moving it into the data
repo is what makes "run this from anywhere" true rather than aspirational.

### 3. An allow-list, not a sync-everything

The manifest is a safety mechanism. `$HOME` is not a config directory — it is a
config directory *interleaved with* caches, sockets, credentials, and vendored
binaries, with no reliable marker distinguishing them.

Real incidents that produced this rule:

| What happened | Why the allow-list didn't save us | Fix |
|---|---|---|
| A CLI's config dir held `auth.json` with a live API key and OAuth tokens, plus 250MB of plugin binaries | It was allow-listed, but as a whole **directory** | Narrow to individual `file\|` entries |
| Another config dir swept in logs, unix sockets, and live UI session state | Same — `dir\|` entry | Narrow to the one real config file |
| A tracked dir was itself a git repo; git recorded a submodule gitlink and it cloned back **empty**, silently | Nothing detected it | `add` now refuses nested `.git` |

The `file` vs `dir` distinction carries real weight: **`dir` is a standing bet
that the owning tool will never write anything sensitive there again.** The tool
therefore treats `dir` as the dangerous case and audits before accepting one.

---

## Data model

### Manifest format

```
type|relpath|label
```

| Field | Meaning |
|---|---|
| `type` | `file` (symlinked individually) or `dir` (symlinked whole) |
| `relpath` | Path relative to `$HOME`. The repo mirrors `$HOME` exactly. |
| `label` | Human-readable description |

Blank lines and `#` comments are ignored, and are load-bearing in practice —
the manifest carries a rationale comment next to every entry that was narrowed
from `dir` to `file`, so the reason survives the person who found it.

**Why `|`, and why paths containing it are refused.** The format is line-based
and pipe-delimited. A path containing either delimiter would round-trip to a
*different* path: it commits fine, then becomes invisible to `link` and
`status` forever — a silent partial failure, the worst kind. Rather than invent
an escaping scheme for a case that should never arise, `add` refuses such paths.

### Repo layout

```
~/.dotfiles/
├── dotfiles.manifest    the allow-list
├── .gitignore           backstop: .DS_Store, *.log, *.sock, *.swp
├── .zshrc               mirrors $HOME/.zshrc
└── .config/rtk/         mirrors $HOME/.config/rtk/
```

Exact mirroring means `relpath` is the only identifier needed — no mapping table,
no per-machine config. It also means `$DOTFILES_DIR/$rel` and `$HOME/$rel` are
always computable from each other, which is what makes `is_linked` a one-liner.

---

## Control flow

All six commands are variations on: *read manifest → compute state → act → commit*.

```
add <path>       resolve to $HOME-relative
                 → reject unrepresentable (| or newline)
                 → reject if already inside repo via symlinked ancestor
                 → refuse nested .git (dir)
                 → audit + confirm (dir)
                 → warn + confirm if over 50MB (file)
                 → mv into repo, symlink back
                 → append manifest entry
                 → commit manifest + path only

link             for each manifest entry present in repo:
                 → already correctly linked? skip
                 → nested .git inside a dir entry? skip (likely empty gitlink)
                 → real file in the way? mv to *.bak
                 → symlink repo → $HOME

sync             dirty tree + -m? commit
                 → HEAD exists AND upstream exists? pull --ff-only
                 → push

status           per entry: linked / linkable / addable here / absent / conflicting
                 → scan for machine-specific absolute symlinks
                 → report dirty tree

audit [path...]  no path? every dir| entry in the manifest
                 → for each: re-run the add-time detection (secret/large/socket/
                   log/db/foreign-symlink/nested-git)
                 → --porcelain: relpath|flag|severity|detail, else prose

rm <path>        same file via symlinked ancestor? confirm, then delete
                 → restore real content to $HOME
                 → drop manifest entry
                 → commit manifest + path only
```

**`add` and `rm` stage narrowly, `sync -m` stages broadly.** `add`/`rm` commit
only the manifest plus the paths they touched, because a commit labelled
"remove X" must not silently carry your in-flight edits to unrelated config.
`sync -m` is the one place a blanket `git add -A` is correct, because there the
user explicitly asked to commit everything under that message.

---

## Invariants

The properties everything else is built to preserve:

1. **Real config files in `$HOME` are never silently destroyed.** `link` backs a
   conflicting real file up to `*.bak` before symlinking over it; `rm` restores
   real content before dropping the entry. Three carve-outs, stated because an
   overclaimed invariant is worse than an honest one: an existing `*.bak` is
   replaced by a newer backup, a symlink in the way is removed rather than
   backed up (it holds no content), and if a path resolves into the repo through
   a symlinked ancestor there is no separate local copy to preserve — `rm`
   detects that case and asks before deleting.
2. **A file is either a real file or a symlink into the repo — never a copy.**
   Copies drift; symlinks cannot.
3. **The manifest is the only source of truth for what is tracked.** Nothing
   walks the repo tree to infer intent.
4. **Silent success is a bug.** Failure modes that historically presented as
   "it worked" — the empty-gitlink clone, the checkout-nothing clone, the
   empty-manifest link — all now produce explicit warnings. A no-op that looks
   like a success is treated as worse than a crash.
5. **`add`/`link`/`sync`/`status`/`rm` require only git.** `gh` appears solely
   in `init`, only to create a repo that does not exist yet.

---

## `audit` re-checks tracked directories

`add` audits a directory once, at the moment you track it — but a `dir` entry
keeps accepting whatever the owning tool writes into it later. `dotfiles audit`
re-runs that same detection across tracked paths on demand (with no argument, it
sweeps every `dir` entry), so a config directory that has since grown an
`auth.json` or a 200MB blob gets caught before the next push.

It is deliberately one additive command on the core — a single authoritative
audit primitive, not a second copy of the detection patterns living somewhere
else, which would be exactly the kind of silent drift this project exists to
avoid. `--porcelain` emits `relpath|flag|severity|detail` so a script can consume
the same findings without re-implementing them.

## Platform constraints

**Targets are macOS and Linux.** Laptop (macOS), VPS (Linux), container (Linux).
There is no native Windows target — containers may run on a Windows *host*, but
the dotfiles never touch the Windows filesystem. No cross-platform abstraction
layer exists, on purpose.

**macOS ships bash 3.2** (2007, for GPLv3 licensing reasons) and that is the
floor. Forbidden throughout: `${VAR,,}` / `${VAR^^}`, `declare -A`, `mapfile` /
`readarray`, `&>>`.

One subtler trap, worth its own note because it cost real time: **bash 3.2
mis-parses a `case` block nested inside `$( )`**, failing with `syntax error
near unexpected token 'newline'`. This is why `foreign_symlinks` is a top-level
function rather than an inline scan — the `case` is then parsed once, at
definition, and merely *called* from inside the substitution.

The associative-array ban is why item lists are packed strings split with
`IFS='|' read`, rather than the map you would reach for in bash 4.

**HTTPS remotes only.** `gh auth login` installs a git credential helper for
HTTPS, so it works with no SSH key on the account. SSH fails with
`Permission denied (publickey)` on machines that never registered one — which is
every fresh container. The tool warns when `origin` is an SSH URL rather than
letting it fail later, confusingly.

---

## What is deliberately absent

| Not here | Why |
|---|---|
| Templating (per-machine variants) | Shell already has `if [ "$(uname)" = Darwin ]`. A templating language is a second, worse programming language. |
| Encryption / secret management | The allow-list keeps secrets out entirely. Encrypting them would invite tracking them. |
| Third-party dependencies | chezmoi and mackup were evaluated and rejected: they solve templating and encryption, which is the problem we do not have. |
| Conflict resolution | Git's is better than ours would be. |
| Auto-pruning of stray symlinks | Deleting symlinks written by *other* tools is not a call this tool should make unattended. `status` reports; you decide. |
| A daemon / file watcher | Sync is an intentional act. Ambient sync makes "what did that just push?" unanswerable. |

---

## Known limitations

- **Machine-specific absolute symlinks accumulate inside `dir` entries.**
  Externally-managed tooling writes them; they dangle everywhere else. No
  gitignore pattern catches them. `status` reports; pruning is manual.
- **The `add` audit matches filenames, not contents.** A credential inside a
  file named `config.toml` will not be flagged.
- **The audit is a snapshot.** It says nothing about what the owning tool writes
  next week. This is the residual risk of every `dir` entry and the reason the
  docs push toward `file`.
