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
| Tests | `test/run-tests.sh`, 27 tests, all passing on bash 3.2 |
| Consumers | vibebox (`scripts/onboard`) |
| Published | `https://raw.githubusercontent.com/execsumo/dotter/main/bin/dotfiles` |

**`dotfiles audit`** — re-run the add-time audit against tracked paths (with no
argument, every `dir` entry) — is in `main`. An optional fzf TUI plus a
companion scanner were built on top of it and then **dropped** as more overhead
than they were worth (separate installs, an `fzf` dependency, a curated
discover list that went stale); the `audit` command they introduced was kept.

---

## Layout

| Path | What it is |
|---|---|
| `bin/dotfiles` | The core tool. No lib/, no sourcing, no runtime deps. |
| `test/run-tests.sh` | Sandboxed core suite. No network, no `gh`, no credentials. |
| `README.md` | User-facing: install, commands, safety behaviours. |
| `ARCHITECTURE.md` | Design rationale, invariants, platform constraints. |
| `REVIEW.md` | Code findings from an independent review pass. Historical record. |
| `DOC-REVIEW.md` | Doc-accuracy findings from an independent review pass. Historical record. |

`bin/dotfiles` is deliberately one file: it is installed by fetching a single
URL, and a multi-file layout would turn that into a packaging problem.

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

## The `audit` command

`dotfiles audit [--porcelain] [<path>...]` re-runs the add-time safety audit
against tracked paths; with no argument it sweeps every `dir|` entry. It is
core, additive only (a `cmd_audit` + dispatch case + usage row; no existing
function was touched). Porcelain emits `relpath|flag|severity|detail`.
`audit_findings`/`audit_emit`/`audit_source_of` are the engine; the human path
still renders via the untouched `audit_dir`. A **drift-guard test** in
`run-tests.sh` asserts the two agree on a fixture — if a detection pattern is
added to one and not the other, it fails.

This closed the old "no re-audit of existing `dir` entries" gap.

### The dropped TUI (history)

An optional fzf TUI (`bin/dotfiles-tui`) and a companion scanner
(`bin/dotfiles-scan`) were built on top of `audit`, then removed. They asked for
more than they returned: two extra installs beyond the single-URL core, an `fzf`
dependency the tool otherwise avoids, and a "discover" screen backed by a
hardcoded allow-list of ~35 config names that went stale against a real
toolset. The `audit` command they were built on was kept; everything else was
dropped. If a lightweight interactive layer is ever wanted again, the lesson is
to fold the two genuinely-useful operations — discover (scan `$HOME`, not a
fixed list) and narrow (split a `dir` entry into `file` entries) — into the core
CLI as plain subcommands rather than a separate fzf wrapper.

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
- ~~No re-audit of existing `dir` entries.~~ **Closed** by `dotfiles audit`,
  which re-runs the add-time audit across every tracked directory on demand.
