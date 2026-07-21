# Plan: a TUI for dotter

Status: **proposed, awaiting sign-off.** Not yet implemented.

---

## The constraint this plan is built around

dotter's README states the product position plainly: *"No templating language. No
encryption. No third-party dependencies… If you need those, use chezmoi."* and
*"a tool you can read in one sitting."* ARCHITECTURE.md lists a daemon/file
watcher under **What is deliberately absent**.

A TUI is adjacent to exactly the feature creep the project defines itself
against. So the load-bearing decision is not *what the TUI looks like* but
*where it lives*.

**Decision: a separate, optional wrapper.** `bin/dotfiles` is not touched. Every
action the TUI takes is a real `dotfiles add` / `rm` / `sync` / `link`
invocation — the TUI is a *view and a launcher*, never a second implementation
of the logic.

This preserves every stated invariant:

| Invariant | How it survives |
|---|---|
| Zero deps for the core | TUI is a separate file; bare VPS/container path is unchanged |
| `curl` one file to install | Unchanged for `bin/dotfiles`; TUI is a second, opt-in `curl` |
| bash 3.2 floor | Applies to both files |
| Manifest is the only source of truth | TUI reads it, never infers from the repo tree |
| `add`/`rm` stage narrowly | TUI shells out; staging logic is untouched |
| Silent success is a bug | TUI must surface the CLI's own output, not swallow it |

---

## Shape

One additive core command, plus two new opt-in files:

```
bin/dotfiles        + ONE new command: `audit [--porcelain]`. No existing
                      function modified. Still zero deps, still bash 3.2.
bin/dotfiles-scan   NEW  non-interactive data producer. Machine-readable output.
bin/dotfiles-tui    NEW  interactive fzf UI. Calls dotfiles + dotfiles-scan.
```

**Why `audit` has to be in core.** The audit heuristics (`audit_dir`,
`foreign_symlinks`) live inside `bin/dotfiles`, and the file ends in a bare
`main "$@"` (line 896) — it is not sourceable. So a scanner that stayed
strictly outside core would have to *duplicate* the credential / large-file /
socket / nested-git detection. That forks safety-critical logic into two copies
that drift, in a tool whose entire identity is that safety net.

Exposing the heuristics as a machine-readable subcommand is the additive fix. It
follows handoff.md's own "Adding a command" recipe, and it closes the gap
handoff.md names as **"the single largest residual risk in the design"** —
*"No re-audit of existing `dir` entries."* Both the scanner and the TUI then
consume one authoritative audit primitive.

The gate is therefore **additive-only**, not zero-diff: a new `cmd_audit`, a
dispatch case, a usage row. No existing function touched.

**Why the scanner is still its own file:** it is scriptable, pipeable, CI-able,
and testable without a terminal, and it splits the remaining work into two
genuinely independent specs.

### Dependency decision (flagged — your call)

The TUI needs a list-picker with a preview pane. Options:

- **fzf (recommended).** Single static binary, ubiquitous, `brew install fzf`.
  Multi-select, preview windows, and `reload()` bindings cover all four screens
  natively. **Not currently installed on this machine.** The wrapper detects its
  absence and prints the install line rather than failing obscurely.
- **Hand-rolled bash 3.2 ANSI.** Zero deps even for the TUI. But a four-screen
  interactive UI in raw `read -rsn1` + cursor escapes, on the bash version that
  already mis-parses `case` inside `$()`, is precisely the fragility the
  separate-wrapper choice was meant to avoid. Not recommended.

Everything below assumes fzf. Say the word if you'd rather take the zero-dep
route and I'll re-cut the specs.

---

## The four screens

### 1. Browse + toggle tracked files
The manifest, live, with per-entry link state from `dotfiles status`.

```
  [x] .zshrc            file  linked        shell config
  [x] .gitconfig        file  linked        git identity
  [ ] .tmux.conf        file  not linked    tmux
  [!] .config/nvim/     dir   linked        editor        240MB, 1 credential-shaped file

  <enter> link   <d> rm   <n> narrow   <tab> multi-select   <q> quit
```
Preview pane shows the entry's audit summary. Actions shell out to
`dotfiles link` / `dotfiles rm`. Destructive actions still route through the
CLI's own confirmation — the TUI does not pass `--yes` on the user's behalf.

### 2. Discover candidates in `$HOME`
Scan for well-known config paths not yet in the manifest, ranked, each annotated
with the audit flags it would trigger. Multi-select → one `dotfiles add` call
per selection. Directories show their audit inline **before** you select them,
which is strictly better than today's after-the-fact prompt.

### 3. Narrow a `dir` entry to `file` entries
The highest-value screen, aimed straight at the documented residual risk. Pick a
`dir|` entry, see every file inside it flagged by the existing `audit_dir`
heuristics, multi-select the ones that are genuinely config, and the TUI emits
the `rm` + `add` sequence to replace one `dir|` line with N `file|` lines —
including the rationale comment the manifest format already carries for exactly
this case (ARCHITECTURE.md: *"the manifest carries a rationale comment next to
every entry that was narrowed from `dir` to `file`"*).

### 4. Sync / status dashboard
`dotfiles status` rendered live: dirty tree, upstream divergence, stray
machine-specific symlinks, `dir` entries that have grown since they were added.
`<s>` runs `dotfiles sync`, output streamed, not swallowed.

---

## Work split — three phases

### Phase 0 (me, first): the audit primitive

`dotfiles audit [<relpath>...] [--porcelain]` in `bin/dotfiles`.

Safety-critical and small, so it is not delegated — I would have to fully verify
it myself regardless, which is exactly the case where delegation stops paying.
It also has to exist *before* fan-out so both delegates build against a real
contract rather than a stub that may not match reality.

```
dotfiles audit                      # audit every dir| entry in the manifest
dotfiles audit <relpath>            # audit one path
dotfiles audit --porcelain          # machine-readable, one finding per line

porcelain format:  relpath|flag|severity|detail
flags:     secret | large | socket | log | db | foreign-symlink | nested-git
severity:  high | low
```

Human-readable output keeps `audit_dir`'s existing prose exactly as-is.

### Phases A and B (parallel delegates)

Two independent specs, two git worktrees, no shared files.

| | Delegate | Deliverable |
|---|---|---|
| **Unit A** | `agy` (Antigravity) | `bin/dotfiles-tui` — all four screens, fzf choreography, shells out to the CLI |
| **Unit B** | `cline` | `bin/dotfiles-scan` — candidate discovery in `$HOME`; `test/run-scan-tests.sh` |

They meet at a contract that is **already real** by the time they launch:

```
dotfiles-scan candidates            -> kind|relpath|flags|label   (genuinely new)
dotfiles-scan expand <relpath>      -> file|relpath|flags|size    (thin wrapper)
dotfiles-scan audit <relpath>       -> relpath|flag|severity|detail (thin wrapper)
# expand/audit delegate to `dotfiles audit --porcelain`. Only `candidates`
# — discovering unlisted $HOME configs — is new logic.
# exit 0 on a successful scan; findings to stdout, errors to stderr
```

**Why external CLIs rather than Claude subagents:** both units are long-horizon
writes that benefit from worktree isolation and live supervision, and routing
them to external vendors spreads token load off the Claude budget.

**Why external CLIs rather than Claude subagents:** both units are long-horizon
writes that benefit from isolation and live supervision, and routing them to
external vendors spreads token load off the Claude budget. Unit A gets `agy`
(more design judgment in the fzf choreography); Unit B gets `cline` (mechanical,
sharply specified, test-driven).

---

## Definition of Done

Shared by both specs and re-run independently by me before anything integrates.

**Phase 0 (audit primitive):**
- `bash test/run-tests.sh` — all 19 existing tests still pass
- `git diff bin/dotfiles` touches **no existing function** — only a new
  `cmd_audit`, a dispatch case, and a usage row (hard gate)
- A fixture dir with `auth.json`, a 60MB file, a socket, and a nested `.git`
  emits the corresponding porcelain flags
- New tests added to `test/run-tests.sh` proving the *unsafe* cases are caught

**Both delegated units:**
- `bash -n <file>` passes
- `bash test/run-tests.sh` — all existing tests still pass
- `git diff --stat` shows **zero changes to `bin/dotfiles`** (hard gate — the
  audit command already landed in Phase 0; delegates consume it, never edit it)
- No banned bash 4 constructs: `${VAR,,}`, `${VAR^^}`, `declare -A`, `mapfile`, `readarray`, `&>>`
- No `case` block inside `$( )`
- Runs clean under bash 3.2 (`/bin/bash` on macOS)

**Unit B additionally:**
- `test/run-scan-tests.sh` passes, sandboxed `$HOME`, no network
- Each of the three subcommands emits the exact contract format above
- `expand` and `audit` produce output byte-identical to the underlying
  `dotfiles audit --porcelain` — proving they wrap rather than reimplement
- `candidates` never proposes a path already in the manifest

**Unit A additionally:**
- Absent fzf → prints the install instruction and exits non-zero. Never a stack trace.
- Every mutating action is an observable `dotfiles` subprocess call, verified by
  a `DOTFILES_TUI_DRY_RUN=1` mode that prints the commands instead of running them
- No TTY → exits with a clear message rather than hanging
- The CLI's own confirmation prompts are reached, not bypassed

---

## Docs to update at integration

- `README.md` — new optional-install section; the TUI is not required
- `ARCHITECTURE.md` — record *why* the TUI is a wrapper and not core; this is
  the kind of decision the doc exists to preserve
- `handoff.md` — close the "no re-audit of existing dir entries" gap, note the
  fzf dependency boundary

---

## Explicitly out of scope

- Any change to `bin/dotfiles` beyond the additive `audit` command in Phase 0 —
  no existing function is modified
- Any change to the manifest format (handoff.md: *"Don't, casually"*)
- A daemon, watcher, or ambient sync — ARCHITECTURE.md rules these out
- Bundling fzf, or vendoring a TUI toolkit
