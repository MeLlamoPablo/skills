#!/usr/bin/env bash
# Says when the repo of this skill (MeLlamoPablo/skills on GitHub) has a newer version of it. Prints nothing when the
# installed files are up to date.
# Usage: check-update.sh
# It compares the git hash of each installed file with the hash that the repo has for that file. It does not download or
# run code. The repo is public, so it needs only curl, and no CLI or sign-in for the host of the user's own repos.
set -euo pipefail

skill=$(dirname "$0")/..
files=$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github+json' \
	'https://api.github.com/repos/MeLlamoPablo/skills/git/trees/main:skills/summarize-pr?recursive=1' \
	| jq -r '.tree[] | select(.type == "blob") | "\(.sha)\t\(.path)"')

while IFS=$'\t' read -r sha path; do
	if [ "$(git hash-object --no-filters "$skill/$path" 2> /dev/null)" != "$sha" ]; then
		echo "summarize-pr has an update."
		exit 0
	fi
done <<< "$files"
