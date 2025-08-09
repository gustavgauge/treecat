<p align="center">
  <img src="https://raw.githubusercontent.com/gustavgauge/treecat/main/.assets/treecat.png" alt="TreeCat Logo" width="300">
</p>

A versatile command-line utility that creates a comprehensive text snapshot of a directory. It combines a `tree`-like view with the concatenated contents of your files, making it perfect for documentation, context-sharing, and AI model input.

## Features

- **Combined View**: Merges a directory `tree` structure with `cat`ed file contents into a single output.
- **Intelligent Filtering**: Automatically excludes common bloat files and directories (`.git`, `node_modules`, `build`, etc.) to keep snapshots clean.
- **Pattern Matching**: Precisely include or exclude files and directories using shell glob patterns.
- **Flexible Output**: Print to the console or redirect to a file for easy sharing.
- **Size & Line Limits**: Truncate each file by bytes or lines to keep snapshots concise.
- **Binary Handling**: Choose how non-text files are handled: `skip` (default), `hex`, or `base64`.
- **Git-Aware**: Optionally use `git ls-files` to respect `.gitignore` and submodules.
- **Symlink Support**: Optionally follow symlinks when scanning.
- **Deterministic Ordering**: Sorted by default for stable diffs; can preserve discovery order.
- **Pure Bash**: Uses standard Unix tools; `tree` is optional for the directory view.

## Use Cases

- **AI/LLM Input**: Generate a clean, complete context of a project to feed into models like GPT-4, Claude, or Gemini.
- **Code Reviews**: Share the full state of a project for more thorough and context-aware reviews.
- **Documentation**: Instantly create a comprehensive "blueprint" of a project's structure and source.
- **Archiving**: Create lightweight, text-based snapshots of a project at a specific point in time.

## Installation

### Prerequisites

For the directory visualization feature (`-t` or `-y`), you need to have the `tree` command installed.

```bash
# macOS
brew install tree

# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y tree
```

### Via `curl` (Recommended)

This command downloads the script to `/usr/local/bin`, making it available as a system-wide command. You may be prompted for your password.

```bash
sudo curl -sL https://raw.githubusercontent.com/gustavgauge/treecat/main/treecat.sh -o /usr/local/bin/treecat && sudo chmod +x /usr/local/bin/treecat
```

## Usage

Once installed, you can run `treecat` from any directory.

```bash
treecat [OPTIONS] [--] [DIR1 [DIR2 ...]]
```

### Options

| Option                  | Description                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `-t, --tree`            | Print directory tree before file contents.                                  |
| `-y, --only-tree`       | Only print the tree (no file contents).                                     |
| `-T, --no-tree`         | Skip the tree view (default).                                               |
| `-b, --bloat`           | Exclude common bloat files and directories (recommended).                   |
| `-i, --include PATTERN` | Include only files matching a shell pattern (can be repeated).              |
| `-x, --exclude PATTERN` | Exclude files matching a shell pattern (can be repeated).                   |
| `-n, --no-header`       | Omit the `BEGIN/END` markers around each file's content.                    |
| `-o, --output FILE`     | Write the snapshot to a file instead of standard output.                    |
| `--max-bytes N`         | Truncate each file after N bytes (per-file limit). `0` = unlimited.         |
| `--max-lines N`         | Truncate each file after N lines (per-file limit). `0` = unlimited.         |
| `--binary MODE`         | How to handle non-text files: `skip` (default), `hex`, or `base64`.         |
| `--follow-symlinks`     | Follow symlinks when scanning.                                              |
| `--git`                 | List files from Git (respects `.gitignore` and submodules); falls back to `find`. |
| `--no-sort`             | Do not sort file list; keep discovery order.                                |
| `--version`             | Print version and exit.                                                      |
| `-h, --help`            | Show help and exit.                                                          |

#### Notes

- **Pattern matching** uses Bash globs against relative paths (e.g., `src/**/*.ts`, `*/.venv/*`).
- **Excludes** match directory prefixes as well (e.g., `-x .venv` also excludes `.venv/...`).
- The `tree` command is optional; install via your package manager if you use `-t`/`-y`.

### Bloat Exclusions

Using the `-b` or `--bloat` flag will exclude a comprehensive list of common artifacts, caches, and environment-specific files.

<details>
<summary><strong>Click to see the full list of excluded patterns</strong></summary>

-   **General**: `.git`, `.DS_Store`, `logs`, `tmp`
-   **IDEs & Editors**: `.idea`, `.vscode`, `*.sublime-project`, `*.sublime-workspace`
-   **Build & Cache**: `build`, `dist`, `out`, `coverage`, `.next`, `__pycache__`
-   **Dependencies**: `node_modules`, `vendor`
-   **Language Specific**: `target` (Rust), `.venv`, `env` (Python), `.pytest_cache`, `.mypy_cache`, `.gradle` (Gradle), `bin`, `obj` (.NET), `*.tfstate*`, `.terraform` (Terraform)
-   **Sensitive Files**: `.env*`, `*.env`

</details>

## Examples

### Basic Snapshot

Create a snapshot of the current directory, including the tree view and excluding bloat, then save it to a file. This is the most common use case.
```bash
treecat -t -b -o project-snapshot.txt
```

### Tree-Only View

Generate a clean directory structure diagram for your `README.md`.
```bash
treecat -y -b src/
```

### Highly Specific Filtering

Snapshot only the Markdown and JavaScript files from the `docs` and `src` directories.
```bash
treecat -t -b -i '*.md' -i '*.js' docs src -o docs-and-src.txt
```

### Excluding Specific Files

Snapshot an entire project but explicitly exclude all test files.
```bash
treecat -t -b -x '*/test/*' -x '*_test.go'
```

### Respect .gitignore via Git

Use Git for file discovery, respecting `.gitignore` and submodules.
```bash
treecat -t -b --git -o project-snapshot.txt
```

### Limit Per-File Size

Truncate each file after 20 KB to keep snapshots small.
```bash
treecat -b --max-bytes 20000 -o small-snapshot.txt
```

### Include Binary Files

Emit binary files as Base64 (or hex) instead of skipping them.
```bash
treecat -b --binary base64 -o with-binaries.txt
```

### Follow Symlinks

```bash
treecat -b --follow-symlinks
```

### Preserve Discovery Order

Disable sorting if you prefer the natural discovery order.
```bash
treecat --no-sort
```

## Output Format

### With Headers (default)
```
### Directory structure (generated by treecat on 2025-08-01 08:35:00)
.
├── src/
│   ├── index.js
│   └── utils.js
└── README.md

===== BEGIN ./src/index.js =====
console.log('Hello, world!');
===== END ./src/index.js =====

===== BEGIN ./src/utils.js =====
export const helper = () => 'utility function';
===== END ./src/utils.js =====

===== BEGIN ./README.md =====
# My Project
This is the README file.
===== END ./README.md =====
```

## License

This script is released into the public domain. Use it, share it, and modify it as you wish.