# Working on dotter

Current state, how to develop and test, and what to watch out for.
For *usage* see [README.md](README.md); for *why it is shaped this way* see
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## Status

**Working and in use.** Extracted from vibebox's `dotfiles-init.sh` +
`scripts/onboard`, which are now retired.

| | |
|---|---|
| Version | 1.0.0 (`dotfiles version`) |
| Implementation | `bin/dotfiles`, single file, ~1090 lines of bash |
| Tests | `test/run-tests.sh`, 26 tests, all passing on bash 3.2 |
| Consumers | vibebox (`scripts/onboard`) |
| Published | `https://raw.githubusercontent.com/execsumo/dotter/main/bin/dotfiles` |

**On branch `feat/tui` (not yet merged to `main`):** an optional TUI and the
`dotfiles audit` command it is built on. See "The TUI feature" below before
resuming — that section is the handoff for this work.

---

## Layout

| Path | What it is |
|---|---|
| `bin/dotfiles` | The core tool. No lib/, no sourcing, no runtime deps. |
| `bin/dotfiles-scan` | **(feat/tui)** Optional. Non-interactive data producer for the TUI: `candidates`, `expand`, `audit`. Zero deps. |
| `bin/dotfiles-tui` | **(feat/tui)** Optional. fzf-based interactive UI over the CLI. The only component that depends on fzf. |
| `test/run-tests.sh` | Sandboxed core suite. No network, no `gh`, no credentials. |
| `test/run-scan-tests.sh` | **(feat/tui)** Scanner suite. |
| `test/run-tui-tests.sh` | **(feat/tui)** TUI dry-run suite. |
| `README.md` | User-facing: install, commands, safety behaviours. |
| `ARCHITECTURE.md` | Design rationale, invariants, platform constraints. |
| `PLAN-TUI.md` | **(feat/tui)** The design + delegation plan for the TUI feature. |
| `REVIEW.md` | Code findings from an independent review pass. Historical record. |
| `DOC-REVIEW.md` | Doc-accuracy findings from an independent review pass. Historical record. |

`bin/dotfiles` is deliberately one file: it is installed by fetching a single
URL, and a multi-file layout would turn that into a packaging problem. The two
TUI files are *separate* opt-in fetches for exactly this reason — they never
enter the core install path.

---

## Developing

```bash
bash -n bin/dotfiles          # syntax check — do this first, it is instant
bash test/run-tests.sh        # full suite, ~15s
```

The suite builds a throwaway `$HOME` and a local bare repo as a fake remote per
test, so it never touches your real dotfiles and needs no network.

### Testing by hand

Sandbox everything through the two env vars the tool reads:

```bash
SB=$(mktemp -d)
export HOME="$SB/home" DOTFILES_DIR="$SB/home/.dotfiles"
export GIT_CONFIG_GLOBAL="$SB/gitconfig"     # keeps your real git config out of it
mkdir -p "$HOME"
printf '[user]\n\tname=T\n\temail=t@e.com\n' > "$GIT_CONFIG_GLOBAL"
git init --bare -q "$SB/remote.git"

/full/path/to/bin/dotfiles init --repo "$SB/remote.git" --yes
```

Two traps that have bitten, both of them *test* bugs that looked like *tool* bugs:

- **Use an absolute path to `bin/dotfiles`.** `~/projects/...` expands against
  the overridden `$HOME` and silently resolves to nothing.
- **A second machine needs `sync` on the first.** `add` only commits locally.
  Cloning "machine 2" before pushing gives you an empty repo and a confusing
  green run.

---

## House rules

### bash 3.2 or it does not ship

macOS ships bash 3.2 and it is the floor. Banned: `${VAR,,}`, `${VAR^^}`,
`declare -A`, `mapfile`, `readarray`, `&>>`. A test enforces this by grep, but
it cannot catch everything — the subtler ones:

- **No `case` block inside `$( )`.** bash 3.2 mis-parses it
  (`syntax error near unexpected token 'newline'`). Put it in a top-level
  function and call *that* from the substitution — see `foreign_symlinks`.
- **`"${ARR[@]}"` on an empty array is an unbound-variable error under `set -u`.**
  Guard with `[ ${#ARR[@]} -gt 0 ]`, or avoid arrays (this file mostly does).
- **`$(printf '\n')` is the empty string.** Command substitution strips trailing
  newlines. A `case` pattern built that way degenerates to `*""*`, which matches
  everything. Use `$'\n'`. This shipped once and rejected every `add`.

### Prompting

`confirm()` reads from `/dev/tty`, never stdin. Every caller sits inside a
`while read` loop whose stdin is the item list — reading stdin there eats the
next path instead of prompting. If you add a prompt, use `confirm`.

### Staging

`add` and `rm` stage **only** the manifest plus the paths they touched. Never
`git add -A` in those paths: a commit labelled "remove X" must not carry the
user's unrelated in-flight config edits. `sync -m` is the sole place a blanket
add is correct, because the user asked for exactly that.

### Silent success is the enemy

The failure mode this tool exists to prevent is "it reported success and did
nothing." Three shipped bugs were of that shape (empty-gitlink clone,
checkout-nothing clone, empty-manifest link). If a code path can do nothing,
make it *say* so.

---

## Adding a command

1. Write `cmd_<name>()` near the others. Start with `require_repo`, plus
   `require_identity` if it commits.
2. Read the manifest via `manifest_lines`, never by re-parsing the file.
3. Add the dispatch case in `main()` and a row in `usage()`.
4. Add a test. If it changes safety behaviour, add a test that proves the
   *unsafe* case is still caught — a fix that just disables a check passes a
   naive test.
5. Update `README.md` (what it does) and `ARCHITECTURE.md` (why) if the model
   changed.

---

## Changing the manifest format

Don't, casually. It is written by `add`, read by `link`/`status`/`rm`, and
hand-edited by users. Any change must handle files written by an older version —
there is no migration mechanism and no version field. Adding a *fourth* field is
the cheapest compatible change: readers either split on `IFS='|'`
(`manifest_lines` consumers, `manifest_type_of`) or use `awk -F'|'`
(`manifest_remove`), and all of them ignore trailing fields.

---

## The TUI feature (branch `feat/tui`) — resume here

An optional terminal UI for browsing and managing tracked dotfiles, plus the
`dotfiles audit` command it stands on. Built as a **separate opt-in wrapper**,
not baked into the core: `bin/dotfiles` stays zero-dep, single-file, bash 3.2.
Every TUI action shells out to the real CLI — it is a view and a launcher, never
a second implementation of the logic. `PLAN-TUI.md` holds the full rationale.

### What shipped, and its state

All three phases are **done and verified** on `feat/tui`:

1. **`dotfiles audit [--porcelain] [<path>...]`** — core, additive only (a new
   `cmd_audit` + dispatch case + usage row; no existing function touched). With
   no argument it re-audits every `dir|` entry — closing the "single largest
   residual risk" gap that used to sit at the bottom of this list. Porcelain
   emits `relpath|flag|severity|detail`. `audit_findings`/`audit_emit`/
   `audit_source_of` are the engine; the human path still renders via the
   untouched `audit_dir`. A **drift-guard test** asserts the two agree on a
   fixture — if a detection pattern is added to one and not the other, it fails.
2. **`bin/dotfiles-scan`** — `candidates` (unlisted `$HOME` configs, suppressing
   anything already tracked), `expand <rel>` (files under a dir entry, with
   per-file flags — resolves via the repo, since a tracked dir in `$HOME` is a
   symlink and `find` won't descend it), `audit <rel>` (byte-identical
   pass-through to `dotfiles audit --porcelain`). Zero deps.
3. **`bin/dotfiles-tui`** — four fzf screens: browse+toggle, discover, narrow a
   `dir` entry to `file` entries, sync/status. Guards fzf-absence and no-TTY
   with a clean message + non-zero exit. `DOTFILES_TUI_DRY_RUN=1` prints
   `WOULD-RUN:` for every mutation instead of executing — the verification hook.

### How it was built (for context on the commits)

Phase 0 (`audit`) was done by hand. Phases 2–3 were delegated to a coding agent
in an isolated worktree; each deliverable went through a verify-and-correct loop
(the relpath-resolution bug in the TUI mutations, the symlink `expand` bug in the
scanner, and a round of TUI polish — `q`-to-quit binding, `set -u` EXIT-trap
guards, discover preview path — were all caught in verification, not shipped).

### If you resume this

- **Merge to `main` when ready.** `feat/tui` is a linear fast-forward over the
  last `main` commit. Before merging, confirm the core still installs from a
  single URL — the two TUI files must stay *out* of vibebox's fetch path.
- **fzf is the TUI's one dependency.** The core and the scanner have none. Keep
  it that way; a bare VPS/container must still run `dotfiles` + `dotfiles-scan`.
- **The three suites:** `bash test/run-tests.sh` (26), `test/run-scan-tests.sh`,
  `test/run-tui-tests.sh`. All green at handoff.
- **Known rough edges, non-blocking:** the fzf *preview pane* can't be captured
  by herdr's `pane read` (a snapshot limitation, not a bug — verify preview
  commands standalone). Capital-letter action keys in the status screen aren't
  bound (only lowercase; `--expect` is case-sensitive) — cosmetic vs the header.

---

## Consumers

vibebox's `scripts/onboard` calls:

```bash
dotfiles init --repo "https://github.com/${GH_USER}/dotfiles"
dotfiles link
```

Its Dockerfile fetches `bin/dotfiles` from `main` via `ARG DOTTER_REF`. So:

- **`main` must stay working** — an unbuildable `main` breaks vibebox image builds.
- **Pin `DOTTER_REF` to a tag** if you want reproducible vibebox builds.
- **Breaking the CLI surface breaks consumers.** `init --repo`, `link`, and the
  `--yes` flag are the contract.

---

## Gaps / next steps

Nothing blocking. In rough priority order:

- **The Docker build path is unverified.** The install step was validated by
  fetching the published URL and running `dotfiles version`, but no
  `docker build` has actually run against the new Dockerfile — there was no
  Docker daemon on the machine where this was extracted. Worth one build.
- **No `doctor` command.** `status` already reports stray symlinks and a dirty
  tree; a dedicated command could also check remote reachability, credential
  helper presence, and `dir` entries that have grown since they were added.
- **The `add` audit is filename-based.** Content scanning for
  high-entropy strings would catch a credential in a plausibly-named file.
- **Merge `feat/tui` to `main`.** The TUI feature is done and verified but lives
  on a branch (see "The TUI feature" above). Merging is the next concrete step.
- ~~No re-audit of existing `dir` entries.~~ **Closed on `feat/tui`** by
  `dotfiles audit`, which re-runs the add-time audit across every tracked
  directory on demand.
