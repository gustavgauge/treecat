#!/usr/bin/env bash
# treecat.sh (enhanced)
# Create a snapshot of a directory structure and its file contents.
# Combines a 'tree' view with concatenated file contents, with smart
# filtering, size/line limits, and better portability.

set -euo pipefail

VERSION="1.2.0"

usage() {
  cat <<'EOF'
Usage: treecat [OPTIONS] [--] [DIR1 [DIR2 ...]]

Description:
  Creates a comprehensive text snapshot of a project. It combines a
  directory tree view with the content of text files, making it easy to
  share, document, or feed into AI models.

Options:
  -t, --tree                  Print directory tree before file contents.
  -y, --only-tree             Only print the tree (no file contents), respecting bloat exclusions.
  -T, --no-tree               Skip the tree view (default).
  -b, --bloat                 Exclude common bloat (node_modules, .git, build, dist, .venv, target, etc.).
  -i, --include PATTERN       Include only files matching shell PATTERN (can be repeated).
  -x, --exclude PATTERN       Exclude files matching shell PATTERN (can be repeated).
  -n, --no-header             Omit BEGIN/END markers around each file's content.
  -o, --output FILE           Write snapshot to FILE instead of stdout.
      --max-bytes N           Truncate each file after N bytes (per-file limit). 0 = unlimited.
      --max-lines N           Truncate each file after N lines (per-file limit). 0 = unlimited.
      --binary MODE           How to handle non-text files: skip (default) | hex | base64
      --follow-symlinks       Follow symlinks when scanning.
      --git                   List files from Git (respects .gitignore); falls back to find if not a repo.
      --no-sort               Do not sort file list; keep discovery order.
      --version               Print version and exit.
  -h, --help                  Show this help and exit.

Notes:
  - Pattern matching uses Bash globs against relative paths (e.g., 'src/**/*.ts', '*/.venv/*').
  - Excludes match directory prefixes as well (e.g., '-x .venv' also excludes '.venv/...').
  - Requires 'tree' for the tree view (install via your package manager).
EOF
}

########################################
# Defaults
show_tree=false
only_tree=false
headers=true
exclude_bloat=false
follow_symlinks=false
use_git=false
no_sort=false
max_bytes=0
max_lines=0
binary_mode="skip" # skip|hex|base64

declare -a includes=()
declare -a excludes=()
output=""
declare -a search_dirs=()

########################################
# Parse options
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -t|--tree)              show_tree=true; shift ;;
    -y|--only-tree)         only_tree=true; shift ;;
    -T|--no-tree)           show_tree=false; shift ;;
    -b|--bloat)             exclude_bloat=true; shift ;;
    -i|--include)           includes+=("$2"); shift 2 ;;
    -x|--exclude)           excludes+=("$2"); shift 2 ;;
    -n|--no-header)         headers=false; shift ;;
    -o|--output)            output="$2"; shift 2 ;;
        --max-bytes)        max_bytes="$2"; shift 2 ;;
        --max-lines)        max_lines="$2"; shift 2 ;;
        --binary)           binary_mode="$2"; shift 2 ;;
        --follow-symlinks)  follow_symlinks=true; shift ;;
        --git)              use_git=true; shift ;;
        --no-sort)          no_sort=true; shift ;;
        --version)          echo "$VERSION"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    --)                     shift; search_dirs+=("$@"); break ;;
    -*)                     echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)                      search_dirs+=("$1"); shift ;;
  esac
done
[[ ${#search_dirs[@]} -eq 0 ]] && search_dirs=(".")

# Redirect output early
if [[ -n "$output" ]]; then
  exec >"$output"
fi

########################################
# Define bloat patterns
# Patterns are bash globs evaluated against relative paths like 'src/file.js'.
declare -a bloat_patterns=()
if [[ "$exclude_bloat" == true ]]; then
  bloat_patterns=(
    # General
    '.git' '.DS_Store' 'logs' 'tmp'

    # IDEs & Editors
    '.idea' '.vscode' '*.sublime-project' '*.sublime-workspace'

    # Build & Cache Outputs
    'build' 'dist' 'out' 'coverage' '.next' '__pycache__'

    # Dependencies
    'node_modules' 'vendor'

    # Language & Framework Specific
    'target' '.venv' 'env' '.pytest_cache' '.mypy_cache' '.gradle' 'bin' 'obj' '*.tfstate*' '.terraform'

    # Sensitive Files
    '.env*' '*.env'
  )
fi

########################################
# Helpers
is_text_like() {
  local f="$1"; local mt
  mt=$(file -b --mime-type -- "$f" 2>/dev/null || true)
  [[ $mt == text/* || $mt == application/json ]] && return 0 || return 1
}

print_tree() {
  if command -v tree >/dev/null 2>&1; then
    local tree_opts=(-a)
    if [[ ${#bloat_patterns[@]} -gt 0 ]]; then
      # Convert glob list to a single tree -I alternation
      local ignore_pattern; ignore_pattern=$(printf "|%s" "${bloat_patterns[@]}"); ignore_pattern=${ignore_pattern:1}
      tree_opts+=(-I "$ignore_pattern")
    fi
    echo "### Directory structure (generated by treecat on $(date +%Y-%m-%d\ %H:%M:%S))"
    tree "${tree_opts[@]}" "${search_dirs[@]}"
    echo
  else
    echo "WARNING: 'tree' command not found; skipping directory tree view." >&2
    echo "         On macOS: brew install tree" >&2
    echo "         On Debian/Ubuntu: sudo apt-get install -y tree" >&2
  fi
}

get_size_bytes() {
  # Cross-platform file size in bytes (Linux/BSD/macOS)
  local f="$1"
  if stat -f%z "$f" >/dev/null 2>&1; then
    stat -f%z "$f"
  else
    stat -c%s "$f"
  fi
}

print_file_with_limits() {
  local f="$1"
  if [[ "$headers" == true ]]; then
    printf '\n===== BEGIN %s =====\n' "$f"
  fi

  if (( max_bytes > 0 )); then
    # Print up to max_bytes safely
    dd if="$f" bs=1 count="$max_bytes" status=none
  elif (( max_lines > 0 )); then
    awk -v m="$max_lines" 'NR<=m{print; if(NR==m) exit 0}' -- "$f"
  else
    cat -- "$f"
  fi

  if [[ "$headers" == true ]]; then
    printf '\n===== END %s =====\n' "$f"
  fi
}

should_skip_by_patterns() {
  # $1: relative path
  local p="$1"; shift
  local -a pats=("$@")
  local pat
  for pat in "${pats[@]}"; do
    # Match exact
    [[ $p == $pat ]] && return 0
    # Match as directory prefix (treat bare names as prefixes too)
    [[ $p == $pat/* ]] && return 0
    # If the pattern has no slash, allow matching anywhere in the path
    if [[ $pat != */* ]]; then
      [[ $p == */$pat || $p == */$pat/* ]] && return 0
    fi
    # Plain glob match already covered by [[ $p == $pat ]]
  done
  return 1
}

########################################
# (1) Directory tree
if [[ "$show_tree" == true || "$only_tree" == true ]]; then
  print_tree
  [[ "$only_tree" == true ]] && exit 0
fi

########################################
# (2) Build raw file list
raw_files=()

if [[ "$use_git" == true ]] && command -v git >/dev/null 2>&1; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Use git ls-files to respect .gitignore and include submodules
    while IFS= read -r -d '' f; do raw_files+=("$f"); done < <(
      git ls-files -z --recurse-submodules -- "${search_dirs[@]}" 2>/dev/null || true
    )
  fi
fi

if [[ ${#raw_files[@]} -eq 0 ]]; then
  # Fallback to find
  # Build find options
  find_cmd=(find)
  $follow_symlinks && find_cmd+=(-L)
  find_cmd+=("${search_dirs[@]}")

  # Prune bloat early for performance (best effort)
  if [[ ${#bloat_patterns[@]} -gt 0 ]]; then
    find_cmd+=(\()
    for pat in "${bloat_patterns[@]}"; do
      find_cmd+=(-path "*/$pat" -o -name "$pat" -o)
    done
    unset 'find_cmd[${#find_cmd[@]}-1]'
    find_cmd+=(\) -prune -o)
  fi

  find_cmd+=(-type f -print0)

  while IFS= read -r -d '' f; do raw_files+=("$f"); done < <("${find_cmd[@]}" 2>/dev/null)
fi

# Normalize to relative, sort if requested
rel_files=()
for f in "${raw_files[@]}"; do
  case "$f" in
    ./*) rel_files+=("${f#./}") ;;
    *)   rel_files+=("$f") ;;
  esac
done

if [[ "$no_sort" == false ]]; then
  # Stable POSIX sort, C locale for speed
  mapfile -t rel_files < <(printf '%s\n' "${rel_files[@]}" | LC_ALL=C sort)
fi

########################################
# (3) Apply include/exclude patterns
files=()
for p in "${rel_files[@]}"; do
  # Bloat exclusions
  if (( ${#bloat_patterns[@]} )); then
    if should_skip_by_patterns "$p" "${bloat_patterns[@]}"; then
      continue
    fi
  fi
  # User excludes
  if (( ${#excludes[@]} )); then
    if should_skip_by_patterns "$p" "${excludes[@]}"; then
      continue
    fi
  fi
  # User includes (if any, must match)
  if (( ${#includes[@]} )); then
    if ! should_skip_by_patterns "$p" "${includes[@]}"; then
      continue
    fi
  fi
  files+=("$p")
done

########################################
# (4) Output file contents
for p in "${files[@]}"; do
  # Skip empty files fast
  [[ -s "$p" ]] || continue

  if is_text_like "$p"; then
    print_file_with_limits "$p"
  else
    case "$binary_mode" in
      skip)   ;; # do nothing
      hex)
        if [[ "$headers" == true ]]; then printf '\n===== BEGIN %s (hex) =====\n' "$p"; fi
        xxd -p -c 16 -- "$p"
        if [[ "$headers" == true ]]; then printf '\n===== END %s (hex) =====\n' "$p"; fi
        ;;
      base64)
        if [[ "$headers" == true ]]; then printf '\n===== BEGIN %s (base64) =====\n' "$p"; fi
        base64 -- "$p"
        if [[ "$headers" == true ]]; then printf '\n===== END %s (base64) =====\n' "$p"; fi
        ;;
      *) echo "Unknown --binary mode: $binary_mode" >&2; exit 1 ;;
    esac
  fi

done
