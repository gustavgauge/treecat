#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TREECAT="$ROOT_DIR/treecat.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

assert_fails_with() {
  local expected="$1"
  shift
  local output
  if output=$("$@" 2>&1); then
    fail "expected command to fail: $*"
  fi
  assert_contains "$output" "$expected"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/src" "$tmpdir/node_modules/pkg"
printf 'hello\nworld\n' > "$tmpdir/README.md"
printf 'console.log("ok");\n' > "$tmpdir/src/app.js"
printf 'ignored\n' > "$tmpdir/node_modules/pkg/index.js"
printf '\0\1\2' > "$tmpdir/blob.bin"

version=$("$TREECAT" --version)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected version: $version"

output=$("$TREECAT" -b "$tmpdir")
assert_contains "$output" "BEGIN README.md"
assert_contains "$output" "hello"
assert_not_contains "$output" "node_modules/pkg/index.js"
assert_not_contains "$output" "blob.bin"

output=$("$TREECAT" -i '*.md' "$tmpdir")
assert_contains "$output" "README.md"
assert_not_contains "$output" "src/app.js"

output=$("$TREECAT" --max-lines 1 "$tmpdir/README.md")
assert_contains "$output" "hello"
assert_not_contains "$output" "world"

output=$("$TREECAT" "$tmpdir/src/app.js")
assert_contains "$output" "BEGIN app.js"
assert_contains "$output" 'console.log("ok");'
assert_not_contains "$output" "README.md"

output=$("$TREECAT" -t "$tmpdir/src/app.js")
assert_contains "$output" "### Directory structure"
assert_contains "$output" "app.js"
assert_not_contains "$output" "$tmpdir/src/app.js"
assert_contains "$output" "BEGIN app.js"

output=$("$TREECAT" -y "$tmpdir")
assert_contains "$output" "$(basename "$tmpdir")"
assert_not_contains "$output" "$tmpdir"

output=$("$TREECAT" --summary -b "$tmpdir")
assert_contains "$output" "### AI context summary"
assert_contains "$output" "Estimated tokens:"
assert_contains "$output" "README.md"
assert_contains "$output" "src/app.js"
assert_not_contains "$output" "hello"
assert_not_contains "$output" "node_modules/pkg/index.js"

output=$("$TREECAT" --tokens --max-lines 1 "$tmpdir/README.md")
assert_contains "$output" "### AI context summary"
assert_contains "$output" "README.md"
assert_contains "$output" "Estimated emitted lines: 1"

output=$("$TREECAT" --binary hex "$tmpdir")
assert_contains "$output" "BEGIN blob.bin (hex)"
assert_contains "$output" "000102"

assert_fails_with "--include requires an argument" "$TREECAT" --include
assert_fails_with "--max-bytes must be a non-negative integer" "$TREECAT" --max-bytes nope
assert_fails_with "--binary must be one of" "$TREECAT" --binary raw

echo "All tests passed"
