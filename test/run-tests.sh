#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/bin/dotfiles"

FAILURES=0
TOTAL=0

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export DOTFILES_DIR="$TEST_DIR/dotfiles"
  export REMOTE_DIR="$TEST_DIR/remote.git"
  
  mkdir -p "$HOME"
  git init --bare "$REMOTE_DIR" >/dev/null 2>&1
  
  export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
  git config --global user.name "Test User"
  git config --global user.email "test@example.com"
  
  echo -n "TEST: $name ... "
  
  local out
  if out="$( (set -e; $func) 2>&1 )"; then
    echo "PASS"
  else
    echo "FAIL"
    echo "$out" | sed 's/^/  /'
    FAILURES=$((FAILURES + 1))
  fi
  
  rm -rf "$TEST_DIR"
}

# --- TESTS ---

test_bash_4_syntax() {
  if grep -vE '^[[:space:]]*#' "$BIN" | grep -E '(\$\{.*,,|\$\{.*\^\^|declare -A|mapfile|readarray|&>>)'; then
    echo "Found bash 4+ syntax"
    return 1
  fi
}

test_add_nested_git() {
  mkdir -p "$HOME/bad-dir/.git"
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  "$BIN" add "$HOME/bad-dir" >/dev/null || true
  if [ -d "$DOTFILES_DIR/bad-dir" ]; then
    echo "bad-dir was moved to repo!"
    return 1
  fi
}

test_add_plain_file() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "content" > "$HOME/myfile"
  "$BIN" add "$HOME/myfile" >/dev/null
  
  [ -f "$DOTFILES_DIR/myfile" ] || return 1
  [ -L "$HOME/myfile" ] || return 1
  grep -q "file|myfile|myfile" "$DOTFILES_DIR/dotfiles.manifest" || return 1
  [ "$(cat "$HOME/myfile")" = "content" ] || return 1
}

test_link_preserves_bak() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$DOTFILES_DIR"
  echo "repo-content" > "$DOTFILES_DIR/file1"
  echo "file|file1|file1" >> "$DOTFILES_DIR/dotfiles.manifest"
  
  echo "local-content" > "$HOME/file1"
  "$BIN" link >/dev/null
  
  [ -f "$HOME/file1.bak" ] || return 1
  [ "$(cat "$HOME/file1.bak")" = "local-content" ] || return 1
  [ -L "$HOME/file1" ] || return 1
}

test_link_idempotent() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "repo" > "$DOTFILES_DIR/file1"
  echo "file|file1|file1" >> "$DOTFILES_DIR/dotfiles.manifest"
  
  "$BIN" link >/dev/null
  "$BIN" link >/dev/null
  [ -L "$HOME/file1" ] || return 1
}

test_sync_no_commits() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  "$BIN" sync >/dev/null
}

test_sync_no_upstream() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "foo" > "$HOME/foo"
  "$BIN" add "$HOME/foo" >/dev/null
  "$BIN" sync >/dev/null
}

test_init_branch_main() {
  git config --global init.defaultBranch master
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  local branch
  branch="$(git -C "$DOTFILES_DIR" branch --show-current)"
  [ "$branch" = "main" ] || return 1
}

test_init_gitignore() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  local gi="$DOTFILES_DIR/.gitignore"
  [ -f "$gi" ] || return 1
  grep -q "\.DS_Store" "$gi" || return 1
  grep -q "\*\.log" "$gi" || return 1
  grep -q "\*\.sock" "$gi" || return 1
  grep -q "\*\.swp" "$gi" || return 1
}

test_ssh_warning() {
  "$BIN" init --repo "git@github.com:foo/bar.git" >out 2>&1 || true
  grep -q "HTTPS" out || return 1
  
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  git -C "$DOTFILES_DIR" remote set-url origin "git@github.com:foo/bar.git"
  "$BIN" sync >out 2>&1 || true
  grep -q "SSH remote" out || return 1
}

test_rm_restores() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "content" > "$HOME/file1"
  "$BIN" add "$HOME/file1" >/dev/null
  
  "$BIN" rm --yes "$HOME/file1" >/dev/null
  
  [ -f "$HOME/file1" ] || return 1
  [ ! -L "$HOME/file1" ] || return 1
  [ "$(cat "$HOME/file1")" = "content" ] || return 1
  
  if grep -q "file1" "$DOTFILES_DIR/dotfiles.manifest"; then
    return 1
  fi
}

test_add_outside_home() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "content" > "$TEST_DIR/outside"
  "$BIN" add "$TEST_DIR/outside" >out 2>&1 || true
  grep -q "outside \$HOME" out || return 1
}

test_nested_gitignore() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/dir1"
  echo "secret" > "$HOME/dir1/secret"
  echo "secret" > "$HOME/dir1/.gitignore"
  
  "$BIN" add --yes "$HOME/dir1" >/dev/null
  
  if git -C "$DOTFILES_DIR" ls-files | grep -q "secret$"; then
    return 1
  fi
}

# Regression: ~/.pi was a symlink to ~/.dotfiles/.pi, so a file reached through
# it was the SAME file as the repo copy. rm reported "leaving it alone" and then
# deleted it via rm -rf on the repo path. It must now detect this and confirm.
test_rm_symlinked_parent() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$DOTFILES_DIR/pidir"
  echo "payload" > "$DOTFILES_DIR/pidir/hooks.ts"
  ln -s "$DOTFILES_DIR/pidir" "$HOME/pidir"
  printf 'file|pidir/hooks.ts|Pi hooks\n' >> "$DOTFILES_DIR/dotfiles.manifest"

  # Declining the prompt (no tty, no --yes) must leave the file intact.
  "$BIN" rm "$HOME/pidir/hooks.ts" >out 2>&1 || true
  grep -q "symlinked parent" out || { echo "did not detect symlinked parent"; return 1; }
  [ -f "$DOTFILES_DIR/pidir/hooks.ts" ] || { echo "file destroyed despite declining"; return 1; }
  [ "$(cat "$DOTFILES_DIR/pidir/hooks.ts")" = "payload" ] || return 1
  return 0
}

test_add_symlinked_parent() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$DOTFILES_DIR/pidir"
  echo "payload" > "$DOTFILES_DIR/pidir/hooks.ts"
  ln -s "$DOTFILES_DIR/pidir" "$HOME/pidir"

  "$BIN" add --yes "$HOME/pidir/hooks.ts" >out 2>&1 || true
  grep -q "already resolves into the repo" out || { echo "not detected"; return 1; }
  [ -f "$DOTFILES_DIR/pidir/hooks.ts" ] || { echo "file lost by self-move"; return 1; }
  [ "$(cat "$DOTFILES_DIR/pidir/hooks.ts")" = "payload" ] || return 1
  return 0
}

test_pipe_rejected() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  touch "$HOME/my|file"
  "$BIN" add "$HOME/my|file" >out 2>&1 || true
  grep -q "cannot track it" out || return 1
  if [ -f "$DOTFILES_DIR/dotfiles.manifest" ]; then
    if grep -q "|my|" "$DOTFILES_DIR/dotfiles.manifest"; then
      echo "Manifest was corrupted"
      return 1
    fi
  fi
  return 0
}

test_intra_repo_symlink() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$DOTFILES_DIR/dir1"
  touch "$DOTFILES_DIR/dir1/target"
  ln -s "$DOTFILES_DIR/dir1/target" "$DOTFILES_DIR/dir1/link1"
  "$BIN" status >out 2>&1 || true
  if grep -q "Machine-specific" out; then
    echo "Intra-repo absolute symlink was falsely flagged"
    return 1
  fi
  
  ln -s "/tmp/nowhere" "$DOTFILES_DIR/dir1/link2"
  "$BIN" status >out 2>&1 || true
  if ! grep -q "Machine-specific" out; then
    echo "Foreign symlink was NOT flagged"
    return 1
  fi
}

test_init_prefers_main() {
  git clone "$REMOTE_DIR" "$TEST_DIR/remote-setup" >/dev/null 2>&1
  cd "$TEST_DIR/remote-setup"
  touch f && git add f && git commit -qm "init"
  git branch main
  git branch apple
  git push -q origin main apple
  git -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/nonexistent
  cd - >/dev/null
  
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  local branch
  branch="$(git -C "$DOTFILES_DIR" branch --show-current)"
  [ "$branch" = "main" ] || return 1
}

test_add_normal_file_newline_check() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "content" > "$HOME/normalfile"
  "$BIN" add "$HOME/normalfile" >out 2>&1 || true
  if grep -q "reject" out || grep -q "cannot track it" out; then
    echo "Normal file was rejected by newline check"
    return 1
  fi
  [ -f "$DOTFILES_DIR/normalfile" ] || return 1
}

# Builds a directory carrying one instance of every category the audit detects.
# Used by both the porcelain tests and the drift guard below.
make_risky_dir() {
  local d="$1"
  mkdir -p "$d/nested"
  echo '{"token":"x"}' > "$d/auth.json"
  echo 'real config'   > "$d/config.toml"
  echo 'noise'         > "$d/app.log"
  : > "$d/store.sqlite3"
  # Sparse: 60MB apparent size without writing 60MB.
  dd if=/dev/null of="$d/blob.bin" bs=1 count=0 seek=60000000 2>/dev/null
  ln -s /opt/elsewhere/thing "$d/nested/stray"
}

audit_porcelain() {
  "$BIN" audit --porcelain "$@" 2>/dev/null || true
}

test_audit_flags_every_category() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"

  local out
  out="$(audit_porcelain "$HOME/risky")"

  local flag
  for flag in secret large log db foreign-symlink; do
    if ! printf '%s\n' "$out" | awk -F'|' -v f="$flag" '$2==f' | grep -q .; then
      echo "missing flag: $flag"
      printf '%s\n' "$out"
      return 1
    fi
  done

  # Format contract: exactly 4 pipe-delimited fields, severity from a fixed set.
  if printf '%s\n' "$out" | awk -F'|' 'NF!=4 || ($3!="high" && $3!="low")' | grep -q .; then
    echo "malformed porcelain line"
    printf '%s\n' "$out"
    return 1
  fi

  # Paths must come back $HOME-relative, never absolute.
  if printf '%s\n' "$out" | awk -F'|' '$4 ~ /^\//' | grep -q .; then
    echo "absolute path leaked into detail field"
    return 1
  fi
}

test_audit_nested_git_high() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/proj/.git"
  local out
  out="$(audit_porcelain "$HOME/proj")"
  printf '%s\n' "$out" | grep -q '|nested-git|high|' || return 1
}

test_audit_clean_dir_silent() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  mkdir -p "$HOME/tidy"
  echo 'setting = 1' > "$HOME/tidy/config.toml"
  local out
  out="$(audit_porcelain "$HOME/tidy")"
  if [ -n "$out" ]; then
    echo "clean dir produced findings: $out"
    return 1
  fi
}

# With no dir| entries there is nothing to re-audit. That must SAY so — a silent
# exit 0 here reads as "audited everything, all clear", which is the exact
# failure mode this tool treats as worse than a crash.
test_audit_empty_is_not_silent() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  echo "content" > "$HOME/plainfile"
  "$BIN" add "$HOME/plainfile" >/dev/null
  # Capture first, then grep: `grep -q` exits on match and SIGPIPEs the
  # producer, which `pipefail` would report as a failed pipeline.
  local out
  out="$("$BIN" audit 2>&1)"
  printf '%s\n' "$out" | grep -qi "nothing to re-audit" || return 1
}

test_audit_no_args_covers_dir_entries() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"
  mkdir -p "$DOTFILES_DIR/risky"
  cp "$HOME/risky/auth.json" "$DOTFILES_DIR/risky/"
  echo "dir|risky|risky" >> "$DOTFILES_DIR/dotfiles.manifest"
  local out
  out="$(audit_porcelain)"
  printf '%s\n' "$out" | grep -q '^risky|secret|high|' || return 1
}

# The drift guard. audit_dir() (prose, used by `add`) and audit_findings()
# (porcelain, used by `audit`) carry separate copies of the detection patterns —
# a deliberate trade so the highest-stakes code path stayed untouched. This
# asserts they still agree, so a pattern added to one and not the other fails
# here instead of silently going unreported on one path.
test_audit_agrees_with_add_audit() {
  "$BIN" init --repo "$REMOTE_DIR" >/dev/null
  make_risky_dir "$HOME/risky"

  local prose porcelain
  prose="$(printf 'no\n' | "$BIN" add "$HOME/risky" 2>&1 || true)"
  porcelain="$(audit_porcelain "$HOME/risky")"

  has_flag() { printf '%s\n' "$porcelain" | awk -F'|' -v f="$1" '$2==f' | grep -q .; }

  # Each pair: a phrase audit_dir prints, and the flag audit_findings emits.
  if printf '%s\n' "$prose" | grep -qi "credential"; then
    has_flag secret || { echo "add flagged credentials; audit did not"; return 1; }
  else
    echo "add did not flag credentials on the fixture"; return 1
  fi

  if printf '%s\n' "$prose" | grep -qi "over ${LARGE_FILE_MB:-50}MB\|files over"; then
    has_flag large || { echo "add flagged large files; audit did not"; return 1; }
  else
    echo "add did not flag large files on the fixture"; return 1
  fi

  if printf '%s\n' "$prose" | grep -qi "logs/databases"; then
    has_flag log || has_flag db || { echo "add flagged logs/db; audit did not"; return 1; }
  fi

  if printf '%s\n' "$prose" | grep -qi "symlinks to absolute paths"; then
    has_flag foreign-symlink || { echo "add flagged stray symlinks; audit did not"; return 1; }
  fi
}

# The additive gate from the plan: `audit` must not have disturbed the commands
# that existed before it.
test_audit_did_not_change_command_surface() {
  local out
  out="$("$BIN" help)"
  local c
  for c in init add link sync status rm; do
    printf '%s\n' "$out" | grep -qE "^  $c " || { echo "usage lost: $c"; return 1; }
  done
  printf '%s\n' "$out" | grep -q "audit" || return 1
}

run_test "Audit flags every category" test_audit_flags_every_category
run_test "Audit reports nested .git as high" test_audit_nested_git_high
run_test "Audit stays silent on a clean dir" test_audit_clean_dir_silent
run_test "Audit with nothing to check says so" test_audit_empty_is_not_silent
run_test "Audit with no args covers dir entries" test_audit_no_args_covers_dir_entries
run_test "Audit agrees with add-time audit" test_audit_agrees_with_add_audit
run_test "Audit did not change command surface" test_audit_did_not_change_command_surface
run_test "Pipe in filename rejected" test_pipe_rejected
run_test "Intra-repo absolute symlink not flagged" test_intra_repo_symlink
run_test "Init prefers main over alphabetically-earlier branch" test_init_prefers_main
run_test "Add normal file passes newline check" test_add_normal_file_newline_check
run_test "Bash 4+ syntax absent" test_bash_4_syntax
run_test "Nested .git is refused" test_add_nested_git
run_test "Add plain file" test_add_plain_file
run_test "Link preserves as .bak" test_link_preserves_bak
run_test "Link is idempotent" test_link_idempotent
run_test "Sync no commits" test_sync_no_commits
run_test "Sync no upstream" test_sync_no_upstream
run_test "Init branch main explicitly" test_init_branch_main
run_test "Init gitignore seeded" test_init_gitignore
run_test "SSH remote warning" test_ssh_warning
run_test "Rm restores file" test_rm_restores
run_test "Add outside HOME rejected" test_add_outside_home
run_test "Nested gitignore honored" test_nested_gitignore
run_test "rm refuses silent delete via symlinked parent" test_rm_symlinked_parent
run_test "add refuses path already inside repo via symlink" test_add_symlinked_parent

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL tests failed."
  exit 1
else
  echo "All tests passed."
  exit 0
fi
