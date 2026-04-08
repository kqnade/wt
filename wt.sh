# wt.sh — git worktree manager
# source this file from your shell rc
#
# Usage: source /path/to/wt.sh

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# Return absolute path of the base (main) repository root
_wt_base() {
  command -v realpath > /dev/null 2>&1 \
    || { printf 'error: realpath is required but not found\n' >&2; return 1; }
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || { printf 'error: not a git repository\n' >&2; return 1; }
  dirname "$(realpath "$common_dir")"
}

# True when cwd is a linked worktree (not the main checkout)
_wt_in_worktree() {
  local git_dir git_common_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"              || return 1
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$git_dir" != "$git_common_dir" ]]
}

# Translate branch name to a directory-safe string (/ → -)
_wt_branch_to_dir() {
  printf '%s\n' "${1//\//-}"
}

# Return the default branch name (origin/HEAD > wt.default-branch config)
_wt_default_branch() {
  local ref
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" \
    && { printf '%s\n' "${ref#refs/remotes/origin/}"; return 0; }
  git config wt.default-branch 2>/dev/null \
    || { printf 'error: cannot detect default branch; set wt.default-branch\n' >&2; return 1; }
}

# Read a wt.* config value: local git config > ~/.config/wt/config > global git config
_wt_config() {
  local key="$1" default="${2:-}"
  local val
  val="$(git config --local "$key" 2>/dev/null)" && { printf '%s\n' "$val"; return 0; }
  local cfg_file="${HOME}/.config/wt/config"
  if [[ -f "$cfg_file" ]]; then
    val="$(git config -f "$cfg_file" "$key" 2>/dev/null)" && { printf '%s\n' "$val"; return 0; }
  fi
  val="$(git config --global "$key" 2>/dev/null)" && { printf '%s\n' "$val"; return 0; }
  [[ -n "$default" ]] && printf '%s\n' "$default"
  return 1
}

# Guard: must be in a git repo
_wt_require_git() {
  git rev-parse --git-dir > /dev/null 2>&1 \
    || { printf 'error: not a git repository\n' >&2; return 1; }
}

# Run a hook if it exists; sets WT_BRANCH in the hook environment.
# Returns 0 if hook is absent or succeeds; returns hook's exit code otherwise.
_wt_run_hook() {
  local hook="$1" branch="${2:-}" wt_path="${3:-$(pwd)}"
  local base hook_file
  base="$(_wt_base 2>/dev/null)" || return 0   # best-effort; no repo = no hooks
  hook_file="${base}/.wt/hooks/${hook}"
  [[ -x "$hook_file" ]] || return 0
  ( cd "$wt_path" && WT_BRANCH="$branch" "$hook_file" )
}

# Guard: must be in a linked worktree (not base)
_wt_require_worktree() {
  _wt_in_worktree \
    || { printf 'error: run this command from inside a worktree, not the base repo\n' >&2; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# wt ls
# ─────────────────────────────────────────────────────────────────────────────
_wt_ls() {
  _wt_require_git || return 1

  local full_path=0
  [[ "${1:-}" == "--full-path" ]] && full_path=1

  local current_real
  current_real="$(realpath "$(pwd)" 2>/dev/null || pwd)"

  local worktree_path is_first=1
  local wt_real marker display

  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then
      worktree_path="${line#worktree }"
    elif [[ -z "$line" && -n "$worktree_path" ]]; then
      marker=""

      wt_real="$(realpath "$worktree_path" 2>/dev/null || printf '%s' "$worktree_path")"

      if [[ "$wt_real" == "$current_real" ]]; then
        if (( is_first )); then
          marker=" [base]"
        else
          marker=" *"
        fi
      fi

      if (( full_path )); then
        # Use tab to separate path from marker so paths with spaces stay intact
        printf '%s\t%s\n' "$worktree_path" "$marker"
      else
        display="$(basename "$worktree_path")"
        [[ "$display" == *@* ]] && display="${display#*@}"
        printf '%s%s\n' "$display" "$marker"
      fi

      is_first=0
      worktree_path=""
    fi
  done < <(git worktree list --porcelain)
}

# ─────────────────────────────────────────────────────────────────────────────
# wt new
# ─────────────────────────────────────────────────────────────────────────────
_wt_new() {
  _wt_require_git || return 1

  local branch="" ai=0 no_ai=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ai)    ai=1 ;;
      --no-ai) no_ai=1 ;;
      -*)  printf 'error: unknown option: %s\n' "$1" >&2; return 1 ;;
      *)
        if [[ -z "$branch" ]]; then
          branch="$1"
        else
          printf 'error: unexpected argument: %s\n' "$1" >&2; return 1
        fi
        ;;
    esac
    shift
  done

  [[ -z "$branch" ]] && branch="wip-$RANDOM"

  # Validate branch name
  git check-ref-format --branch "$branch" > /dev/null 2>&1 \
    || { printf 'error: invalid branch name: %s\n' "$branch" >&2; return 1; }

  local dir_branch
  dir_branch="$(_wt_branch_to_dir "$branch")"

  local base_root
  base_root="$(_wt_base)" || return 1

  local wt_path
  wt_path="$(dirname "$base_root")/$(basename "$base_root")@${dir_branch}"

  # pre-new hook (non-zero exit cancels)
  _wt_run_hook pre-new "$branch" "$base_root" || return 1

  # Conflict checks
  if [[ -e "$wt_path" ]]; then
    printf 'error: path already exists: %s\n' "$wt_path" >&2; return 1
  fi
  if git rev-parse --verify "$branch" > /dev/null 2>&1; then
    printf 'error: branch already exists: %s\n' "$branch" >&2; return 1
  fi

  git worktree add "$wt_path" -b "$branch" || return 1
  printf '✓ worktree created: %s\n' "$wt_path"

  # post-new hook
  _wt_run_hook post-new "$branch" "$wt_path"

  # AI startup: --ai > wt.ai config > --no-ai
  local use_ai=0
  if (( ai )); then
    use_ai=1
  elif (( ! no_ai )); then
    [[ "$(_wt_config wt.ai false)" == "true" ]] && use_ai=1
  fi

  if (( use_ai )); then
    local ai_cmd
    ai_cmd="$(_wt_config wt.ai-cmd claude)"
    ( cd "$wt_path" && exec "$ai_cmd" )
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# wt cd
# ─────────────────────────────────────────────────────────────────────────────
_wt_cd() {
  _wt_require_git || return 1

  local target="${1:-}"

  if [[ -z "$target" ]]; then
    # Interactive: fzf
    command -v fzf > /dev/null 2>&1 \
      || { printf 'error: fzf is required for interactive selection\n' >&2; return 1; }
    local selected
    selected="$(_wt_ls --full-path | fzf --prompt='worktree> ')"
    [[ -z "$selected" ]] && return 0
    builtin cd "${selected%%$'\t'*}"
  else
    # 3-stage matching: exact → single prefix → multiple prefix (error)
    local -a paths=()
    local line
    while IFS= read -r line; do
      paths+=("${line%%$'\t'*}")
    done < <(_wt_ls --full-path)

    local exact_match=""
    local -a prefix_matches=()
    local p name

    for p in "${paths[@]}"; do
      name="$(basename "$p")"
      [[ "$name" == *@* ]] && name="${name#*@}"
      if [[ "$name" == "$target" ]]; then
        exact_match="$p"
        break
      elif [[ "$name" == "$target"* ]]; then
        prefix_matches+=("$p")
      fi
    done

    if [[ -n "$exact_match" ]]; then
      builtin cd "$exact_match"
    elif (( ${#prefix_matches[@]} == 1 )); then
      builtin cd "${prefix_matches[0]}"
    elif (( ${#prefix_matches[@]} > 1 )); then
      printf 'error: ambiguous match for %q — candidates:\n' "$target" >&2
      for p in "${prefix_matches[@]}"; do
        name="$(basename "$p")"
        [[ "$name" == *@* ]] && name="${name#*@}"
        printf '  %s\n' "$name" >&2
      done
      return 1
    else
      printf 'error: no worktree matching %q\n' "$target" >&2
      return 1
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# wt del
# ─────────────────────────────────────────────────────────────────────────────
_wt_del() {
  _wt_require_git    || return 1
  _wt_require_worktree || return 1

  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) force=1 ;;
      *)  printf 'error: unknown option: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done

  local branch wt_path
  branch="$(git branch --show-current 2>/dev/null)" \
    || { printf 'error: cannot determine current branch\n' >&2; return 1; }
  wt_path="$(realpath "$(pwd)")"

  # pre-del hook (non-zero exit cancels)
  _wt_run_hook pre-del "$branch" "$wt_path" || return 1

  # Confirm unless -f or wt.confirm=false
  if (( ! force )); then
    local confirm
    confirm="$(_wt_config wt.confirm true)"
    if [[ "$confirm" != "false" ]]; then
      printf 'delete worktree "%s" and branch "%s"? [y/N] ' \
        "$(basename "$wt_path")" "$branch"
      local ans
      read -r ans
      [[ "$ans" =~ ^[Yy]$ ]] || { printf 'cancelled\n'; return 0; }
    fi
  fi

  local base
  base="$(_wt_base)" || return 1
  builtin cd "$base"

  if (( force )); then
    # -f: force both git worktree remove and git branch -D
    git worktree remove --force "$wt_path" || return 1
    git branch -D "$branch"
  else
    git worktree remove "$wt_path" || return 1
    git branch -d "$branch" || return 1
  fi

  printf '✓ deleted: %s (branch: %s)\n' "$(basename "$wt_path")" "$branch"
}

# ─────────────────────────────────────────────────────────────────────────────
# wt home
# ─────────────────────────────────────────────────────────────────────────────
_wt_home() {
  _wt_require_git || return 1
  local base
  base="$(_wt_base)" || return 1
  builtin cd "$base"
}

# ─────────────────────────────────────────────────────────────────────────────
# wt use
# ─────────────────────────────────────────────────────────────────────────────
_wt_use() {
  _wt_require_git      || return 1
  _wt_require_worktree || return 1

  local branch
  branch="$(git branch --show-current 2>/dev/null)"
  [[ -n "$branch" ]] || { printf 'error: detached HEAD state\n' >&2; return 1; }

  local base
  base="$(_wt_base)" || return 1

  if [[ -n "$(git -C "$base" status --porcelain 2>/dev/null)" ]]; then
    printf 'error: base repository has uncommitted changes; stash or commit first\n' >&2
    return 1
  fi

  # Use --detach: git forbids the same branch being checked out in two
  # worktrees simultaneously.  Detached HEAD puts the base at the same
  # commit without holding a branch ref, letting the worktree keep it.
  git -C "$base" checkout --detach "$branch"
}

# ─────────────────────────────────────────────────────────────────────────────
# wt extract
# ─────────────────────────────────────────────────────────────────────────────
_wt_extract() {
  _wt_require_git || return 1

  if _wt_in_worktree; then
    printf 'error: wt extract must be run from the base repository\n' >&2; return 1
  fi

  # dirty check before the two-step operation (wt new → git checkout default)
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    printf 'error: base repository has uncommitted changes; stash or commit first\n' >&2
    return 1
  fi

  local branch
  branch="$(git branch --show-current 2>/dev/null)"
  [[ -n "$branch" ]] || { printf 'error: detached HEAD state\n' >&2; return 1; }

  local default_branch
  default_branch="$(_wt_default_branch)" || return 1

  if [[ "$branch" == "$default_branch" ]]; then
    printf 'error: cannot extract the default branch (%s)\n' "$default_branch" >&2; return 1
  fi

  local dir_branch base_root wt_path
  dir_branch="$(_wt_branch_to_dir "$branch")"
  base_root="$(_wt_base)" || return 1
  wt_path="$(dirname "$base_root")/$(basename "$base_root")@${dir_branch}"

  if [[ -e "$wt_path" ]]; then
    printf 'error: path already exists: %s\n' "$wt_path" >&2; return 1
  fi

  # Switch base off the branch FIRST: git forbids adding a worktree for a
  # branch that is still checked out in the current (base) checkout.
  git checkout "$default_branch" || return 1

  git worktree add "$wt_path" "$branch" || {
    # Roll back: restore the branch in base so the user isn't left on default
    git checkout "$branch" 2>/dev/null
    return 1
  }
  printf '✓ worktree created: %s\n' "$wt_path"

  _wt_run_hook post-new "$branch" "$wt_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# wt copy
# ─────────────────────────────────────────────────────────────────────────────
_wt_copy() {
  _wt_require_git      || return 1
  _wt_require_worktree || return 1
  [[ $# -gt 0 ]] || { printf 'usage: wt copy <path> [...]\n' >&2; return 1; }

  local base wt_path
  base="$(_wt_base)"          || return 1
  wt_path="$(realpath "$(pwd)")"

  local src abs_src
  for src in "$@"; do
    abs_src="$(realpath "${base}/${src}" 2>/dev/null)" \
      || { printf 'error: cannot resolve path: %s\n' "$src" >&2; continue; }
    if [[ "$abs_src" != "$base" && "$abs_src" != "${base}/"* ]]; then
      printf 'error: path escapes base repo: %s\n' "$src" >&2; continue
    fi
    if [[ ! -e "$abs_src" ]]; then
      printf 'error: not found in base repo: %s\n' "$src" >&2; continue
    fi
    cp -r "$abs_src" "${wt_path}/${src}" \
      && printf '✓ copied: %s\n' "$src" \
      || printf 'error: failed to copy: %s\n' "$src" >&2
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# wt link
# ─────────────────────────────────────────────────────────────────────────────
_wt_link() {
  _wt_require_git      || return 1
  _wt_require_worktree || return 1
  [[ $# -gt 0 ]] || { printf 'usage: wt link <path> [...]\n' >&2; return 1; }

  local base wt_path
  base="$(_wt_base)"          || return 1
  wt_path="$(realpath "$(pwd)")"

  local src abs_src
  for src in "$@"; do
    abs_src="$(realpath "${base}/${src}" 2>/dev/null)" \
      || { printf 'error: cannot resolve path: %s\n' "$src" >&2; continue; }
    if [[ "$abs_src" != "$base" && "$abs_src" != "${base}/"* ]]; then
      printf 'error: path escapes base repo: %s\n' "$src" >&2; continue
    fi
    if [[ ! -e "$abs_src" ]]; then
      printf 'error: not found in base repo: %s\n' "$src" >&2; continue
    fi
    ln -sf "$abs_src" "${wt_path}/${src}" \
      && printf '✓ linked: %s → %s\n' "$src" "$abs_src" \
      || printf 'error: failed to link: %s\n' "$src" >&2
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# wt invoke
# ─────────────────────────────────────────────────────────────────────────────
_wt_invoke() {
  _wt_require_git || return 1
  local hook="${1:-}"
  [[ -n "$hook" ]] || { printf 'usage: wt invoke <hook>\n' >&2; return 1; }
  # Reject names containing / to prevent running binaries outside .wt/hooks/
  [[ "$hook" != */* ]] \
    || { printf 'error: hook name must not contain /: %s\n' "$hook" >&2; return 1; }

  local base
  base="$(_wt_base)" || return 1
  local hook_file="${base}/.wt/hooks/${hook}"

  if [[ ! -f "$hook_file" ]]; then
    printf 'error: hook not found: %s\n' "$hook_file" >&2; return 1
  fi
  if [[ ! -x "$hook_file" ]]; then
    printf 'error: hook is not executable: %s\n' "$hook_file" >&2; return 1
  fi

  local branch wt_path
  branch="$(git branch --show-current 2>/dev/null || printf '')"
  wt_path="$(realpath "$(pwd)")"

  ( cd "$wt_path" && WT_BRANCH="$branch" "$hook_file" )
}

# ─────────────────────────────────────────────────────────────────────────────
# wt clean
# ─────────────────────────────────────────────────────────────────────────────
_wt_clean() {
  _wt_require_git || return 1

  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1

  local default_branch
  default_branch="$(_wt_default_branch 2>/dev/null || printf '')"

  local -a cand_paths=() cand_branches=()
  local worktree_path branch prunable is_first=1

  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then
      worktree_path="${line#worktree }"
      branch=""
      prunable=0
    elif [[ "$line" == "branch "* ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ "$line" == "prunable"* ]]; then
      prunable=1
    elif [[ -z "$line" && -n "$worktree_path" ]]; then
      if (( ! is_first )); then
        local candidate=0

        # 1. prunable (git-internal)
        (( prunable )) && candidate=1

        # 2. merged PR via gh
        if (( ! candidate )) && [[ -n "$branch" ]] && command -v gh > /dev/null 2>&1; then
          if gh pr list --state merged --json headRefName --jq '.[].headRefName' 2>/dev/null \
              | grep -qxF "$branch"; then
            candidate=1
          fi
        fi

        # 3. locally merged into default branch
        if (( ! candidate )) && [[ -n "$branch" && -n "$default_branch" ]]; then
          if git branch --merged "$default_branch" 2>/dev/null \
              | sed 's/^[[:space:]*]*//' \
              | grep -qxF "$branch"; then
            candidate=1
          fi
        fi

        if (( candidate )); then
          cand_paths+=("$worktree_path")
          cand_branches+=("$branch")
        fi
      fi
      is_first=0
      worktree_path=""
      branch=""
      prunable=0
    fi
  done < <(git worktree list --porcelain)

  if (( ${#cand_paths[@]} == 0 )); then
    printf 'nothing to clean\n'; return 0
  fi

  printf 'candidates for removal:\n'
  local i
  for (( i=0; i<${#cand_paths[@]}; i++ )); do
    printf '  %s  (branch: %s)\n' \
      "$(basename "${cand_paths[$i]}")" "${cand_branches[$i]:-detached}"
  done

  if (( dry_run )); then
    printf '(dry-run: no changes made)\n'; return 0
  fi

  local confirm
  confirm="$(_wt_config wt.confirm true)"

  for (( i=0; i<${#cand_paths[@]}; i++ )); do
    local p="${cand_paths[$i]}" b="${cand_branches[$i]}"
    if [[ "$confirm" != "false" ]]; then
      printf 'remove %s? [y/N] ' "$(basename "$p")"
      local ans
      read -r ans
      [[ "$ans" =~ ^[Yy]$ ]] || { printf 'skipped\n'; continue; }
    fi
    git worktree remove "$p" 2>/dev/null \
      || git worktree remove --force "$p" 2>/dev/null \
      || { printf 'error: failed to remove worktree: %s\n' "$p" >&2; continue; }
    if [[ -n "$b" ]]; then
      git branch -d "$b" 2>/dev/null \
        || printf 'warning: branch %s not fully merged; skipping branch delete\n' "$b" >&2
    fi
    printf '✓ removed: %s\n' "$(basename "$p")"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
wt() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] && shift

  case "$cmd" in
    new)     _wt_new     "$@" ;;
    ls)      _wt_ls      "$@" ;;
    cd)      _wt_cd      "$@" ;;
    del)     _wt_del     "$@" ;;
    home)    _wt_home    "$@" ;;
    use)     _wt_use     "$@" ;;
    extract) _wt_extract "$@" ;;
    copy)    _wt_copy    "$@" ;;
    link)    _wt_link    "$@" ;;
    invoke)  _wt_invoke  "$@" ;;
    clean)   _wt_clean   "$@" ;;
    *)
      printf '%s\n' \
        "usage: wt <command> [args]" \
        "" \
        "commands:" \
        "  new [branch] [--ai|--no-ai]  create a new worktree" \
        "  ls [--full-path]             list worktrees for this repo" \
        "  cd [branch]                  cd into a worktree (fzf if no arg)" \
        "  del [-f]                     delete current worktree and branch" \
        "  home                         cd to base repository" \
        "  use                          checkout this branch in the base repo" \
        "  extract                      move current branch into a new worktree" \
        "  copy <path> [...]            copy file/dir from base into this worktree" \
        "  link <path> [...]            symlink file/dir from base into this worktree" \
        "  invoke <hook>                manually run a hook" \
        "  clean [--dry-run]            remove merged/prunable worktrees" >&2
      return 1
      ;;
  esac
}
