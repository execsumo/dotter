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

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES of $TOTAL tests failed."
  exit 1
else
  echo "All tests passed."
  exit 0
fi
