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
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' \
    || git config wt.default-branch 2>/dev/null \
    || { printf 'error: cannot detect default branch; set wt.default-branch\n' >&2; return 1; }
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

  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then
      worktree_path="${line#worktree }"
    elif [[ -z "$line" && -n "$worktree_path" ]]; then
      local wt_real marker="" display

      wt_real="$(realpath "$worktree_path" 2>/dev/null || printf '%s' "$worktree_path")"

      if [[ "$wt_real" == "$current_real" ]]; then
        if (( is_first )); then
          marker=" [base]"
        else
          marker=" *"
        fi
      fi

      if (( full_path )); then
        printf '%s%s\n' "$worktree_path" "$marker"
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

  local branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ai|--no-ai) ;;  # handled in Phase 3
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
    builtin cd "${selected%% *}"
  else
    # 3-stage matching: exact → single prefix → multiple prefix (error)
    local -a paths=()
    local line
    while IFS= read -r line; do
      paths+=("${line%% *}")
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
  [[ "${1:-}" == "-f" ]] && force=1

  local branch wt_path
  branch="$(git branch --show-current 2>/dev/null)" \
    || { printf 'error: cannot determine current branch\n' >&2; return 1; }
  wt_path="$(realpath "$(pwd)")"

  # pre-del hook (non-zero exit cancels)
  _wt_run_hook pre-del "$branch" "$wt_path" || return 1

  # Confirm unless -f
  if (( ! force )); then
    printf 'delete worktree "%s" and branch "%s"? [y/N] ' \
      "$(basename "$wt_path")" "$branch"
    local ans
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { printf 'cancelled\n'; return 0; }
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

  if ! git -C "$base" diff --quiet 2>/dev/null \
    || ! git -C "$base" diff --cached --quiet 2>/dev/null; then
    printf 'error: base repository has uncommitted changes; stash or commit first\n' >&2
    return 1
  fi

  git -C "$base" checkout "$branch"
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
