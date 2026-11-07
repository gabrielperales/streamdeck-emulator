#!/usr/bin/env bash
# Prints the CHANGELOG.md section for a version (without its heading), for use
# as GitHub release notes. Fails when the changelog has no such section.
#
#   .github/scripts/release-notes.sh 0.1.1 > notes.md
set -euo pipefail

version="${1#v}"
changelog="${2:-CHANGELOG.md}"

notes="$(awk -v version="$version" '
  index($0, "## [" version "]") == 1 { found = 1; next }   # this version
  found && /^## \[/ { exit }                               # the next one
  found && /^\[[^]]+\]: / { next }                         # link definitions
  found { print }
' "$changelog")"

# Trim leading and trailing blank lines.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$notes" ]; then
  echo "error: $changelog has no section for $version" >&2
  exit 1
fi

printf '%s\n' "$notes"
