# Documentation Review Findings

## 1. Command surface
- **Claim**: Command surface documented in `README.md` table and `usage()` (`README.md`, `bin/dotfiles`)
- **Verdict**: MISLEADING
- **Evidence**: The code supports several aliases and flags that are entirely undocumented:
  - `cmd_add` and `cmd_rm` parse `-y` as an alias for `--yes`.
  - `cmd_init` parses `--non-interactive` as an alias for `--yes`.
  - `main` parses `remove` as an alias for `rm`.
  - `main` parses `-h`, `--help`, and `--version` (though `usage()` mentions `help | version` casually, the explicit flags are omitted).
- **Suggested Correction**: Update the README table and `usage()` to document `-y` alongside `--yes`, `remove` alongside `rm`, and `--non-interactive` for `init`. Add explicit `--help`, `-h`, and `--version` options to `usage()`.

## 2. Dependencies
- **Claim**: "add/link/sync/status/rm require only git. gh appears solely in init, only to create a repo that does not exist yet." (`ARCHITECTURE.md`, `README.md`)
- **Verdict**: TRUE

## 3. Data Safety
- **Claim**: "Nothing in $HOME is ever destroyed." (`ARCHITECTURE.md`)
- **Verdict**: FALSE
- **Evidence**: 
  - `cmd_link` silently removes foreign symlinks (`rm -f "$dest"`) without backing them up.
  - `cmd_link` moves files to `.bak` (`mv "$dest" "${dest}.bak"`). If a `.bak` file already exists, it is silently overwritten and destroyed.
  - `cmd_rm` restores the file to `$HOME`, but destroys the tracked copy using `rm -rf "$src"`. If the repo is inside `$HOME` (as is the default `~/.dotfiles`), a path under `$HOME` is destroyed.
- **Suggested Correction**: Change to "Real files in $HOME are never overwritten without backup. Conflicts are moved to `.bak` (overwriting any previous backup) and foreign symlinks are replaced."

## 4. Staging
- **Claim**: "add and rm stage only the manifest plus the paths they touched." (`ARCHITECTURE.md`)
- **Verdict**: TRUE

## 5. Invariants
- **Claim**: Invariants list, specifically: "1. Nothing in `$HOME` is ever destroyed." (`ARCHITECTURE.md`)
- **Verdict**: FALSE
- **Evidence**: See section 3 above. Foreign symlinks and existing `.bak` files are destroyed.
- **Suggested Correction**: "1. Real config files in `$HOME` are never destroyed. `link` backs conflicts up to `*.bak` (overwriting any previous backup); `rm` restores real content before dropping the entry."

## 6. Bash compatibility
- **Claim**: "bash 3.2 compatible" and "no ${VAR,,}, no declare -A, no mapfile/readarray." (`README.md`, `ARCHITECTURE.md`, `handoff.md`)
- **Verdict**: TRUE

## 7. Numerical claims
- **Claim**: "~860 lines of bash", "17 tests", "Version 1.0.0" (`handoff.md`)
- **Verdict**: TRUE

## 8. Control flow diagram
- **Claim**: Control flow steps for `add` and `link` (`ARCHITECTURE.md`)
- **Verdict**: MISLEADING
- **Evidence**: The control flow omits steps for both `add` and `link`:
  - For `add`, the diagram omits the file size check (`> 50MB`) for individual file types which happens after the directory audit check.
  - For `link`, the diagram jumps straight to "already correctly linked?" but omits the explicit nested `.git` check for directory entries, where `cmd_link` skips the entry if a nested repo is found.
- **Suggested Correction**: Update the diagrams. For `add`, insert `→ check file size limits (file)` before the `mv` step. For `link`, insert `→ nested .git inside dir? skip` after the `already correctly linked?` check.

## 9. Manifest format readers
- **Claim**: "parsers use \`IFS='|' read -r type rel label\` and would ignore it" (`handoff.md`)
- **Verdict**: FALSE
- **Evidence**: While `label` is ignored, not all readers use `IFS='|' read -r type rel label`. 
  - `manifest_remove` parses the manifest using `awk -F'|' -v rel="$rel" ...`.
  - `manifest_type_of` uses `while IFS='|' read -r t r _`.
- **Suggested Correction**: "all shell readers use `IFS='|'` (or `awk`) and ignore the label."

## 10. "Behaviours worth knowing"
- **Claim**: "Nothing is ever overwritten. \`link\` moves a pre-existing real file to \`<name>.bak\` before symlinking over it." (`README.md`)
- **Verdict**: FALSE
- **Evidence**: Existing `<name>.bak` files are silently overwritten by the `mv` command in `cmd_link`, and foreign symlinks are removed (`rm -f`). 
- **Suggested Correction**: "Real files are backed up. `link` moves a pre-existing real file to `<name>.bak` (replacing any older backup) before symlinking over it. Foreign symlinks are replaced."

## 11. Directory `.gitignore`
- **Claim**: "A directory's own `.gitignore` keeps working. If a tracked directory ships one, it travels with the directory and keeps applying once nested in the dotfiles repo." (`README.md`)
- **Verdict**: TRUE
