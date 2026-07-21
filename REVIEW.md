# REVIEW.md

## Defects Found (Fixed in 8ad7957)

1. **Syntax error in command substitution under Bash 3.2**
   - **Reproduction:** Run `dotfiles status` or `dotfiles add <directory>` on macOS (Bash 3.2). The script crashed with a syntax error (`unexpected token 'newline'`) because of `case "$t" in /*)` inside a command substitution in `cmd_status` and `audit_dir`. Bash 3.2 requires balanced parentheses `(/*)` in this context.
   - **Severity:** High (crashed core commands).
   - **Status:** Fixed in 8ad7957.

2. **`dotfiles init` cloned empty repo instead of explicitly branching `main`**
   - **Reproduction:** Run `dotfiles init --repo <url-to-empty-bare-repo>`. The script used `git clone`, which silently inherited the system's `init.defaultBranch` (often `master`) instead of explicitly creating `main`.
   - **Severity:** Medium.
   - **Status:** Fixed in 8ad7957.

3. **`dotfiles link` reported success on an empty manifest**
   - **Reproduction:** Run `dotfiles link` on a fresh/absent manifest or a clone that checked out nothing. It would cheerfully walk an empty repo and report "Everything already linked" instead of indicating something is wrong.
   - **Severity:** Medium.
   - **Status:** Fixed in 8ad7957.

## New Defects Found

4. **`cmd_status` no longer ignores intra-repo absolute symlinks**
   - **Reproduction:** Run `dotfiles status` in a repository containing an absolute symlink that points to another file inside the dotfiles repository (e.g. `foo -> /Users/user/.dotfiles/bar`).
   - **Why:** The new `foreign_symlinks` helper in `cmd_status` is called with only `$HOME` as the allowed prefix (`stray="$(foreign_symlinks "$DOTFILES_DIR" "$HOME")"`). The old code explicitly ignored both `"$DOTFILES_DIR"/*` and `"$HOME"/*`. As a result, valid intra-repo absolute symlinks are now falsely flagged as "Machine-specific absolute symlinks".
   - **Severity:** Low.

5. **`cmd_init` may check out the wrong branch on a fresh clone**
   - **Reproduction:** Initialize a remote repository with `main` and another alphabetically earlier branch (e.g., `apple`). Clone the repository when its `HEAD` is unborn or points to a non-existent branch.
   - **Why:** The new fallback logic in `cmd_init` runs `git_d for-each-ref ... refs/remotes/origin | head -1` and blindly checks out whatever branch comes first alphabetically (e.g. `apple` instead of `main`), rather than preferring the default branch or specifically falling back to `main`.
   - **Severity:** Low.

6. **Missing validation for paths with `|`**
   - **Reproduction:** Run `dotfiles add "my|file"`. The script appends `file|my|file|label` to the manifest.
   - **Why:** The pipe character (`|`) is the manifest delimiter, and it is not sanitized or escaped. This breaks the awk/IFS parsers, corrupting the manifest.
   - **Severity:** High (corrupts manifest).

(Note: No empty-array expansions like `"${ARR[@]}"` were found in the script).
