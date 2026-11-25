#!/usr/bin/env bash
# Collects the facts a summarize-pr page needs about a PR into one folder.
# Usage: gather.sh <out-dir> [<PR number, URL or branch>]
# Without a PR argument, it uses the PR of the current branch.
#
# The calls to the host of the PR are in one adapter per host, hosts/<name>.sh, which host.sh picks (see host.sh and
# hosts/README.md). Each adapter writes the same files in the same shapes, so this script and the page never name a
# host. With no adapter for the repo, or with SUMMARIZE_PR_HOST=git, the facts come from git alone.
set -euo pipefail

out=${1:?Usage: gather.sh <out-dir> [<PR number, URL or branch>]}
pr=${2:-}
mkdir -p "$out"
scripts=$(dirname "$0")
# shellcheck source=host.sh
source "$scripts/host.sh"

select_host "$pr"
load_host
pr_facts "$out" "$pr"
# A wrong shape in pr.json would only show later as a broken page, so name the adapter that wrote it now.
if ! jq -e '
	(.number | type == "number" or . == null) and (.title | type == "string") and (.body | type == "string")
	and (.url | type == "string" or . == null) and (.repoUrl | type == "string" or . == null)
	and (.state | IN("open", "merged", "closed")) and (.author.login | type == "string" or . == null)
	and (.baseRefName | type == "string") and (.headRefName | type == "string")
	and (.headRefOid | test("^[0-9a-f]{40}$")) and (.mergeBaseOid | . == null or test("^[0-9a-f]{40}$"))
	and ([.additions, .deletions, .changedFiles] | all(type == "number"))' "$out/pr.json" > /dev/null; then
	echo "hosts/$host_adapter.sh wrote a pr.json that does not match hosts/README.md:" >&2
	cat "$out/pr.json" >&2
	exit 1
fi
host_json "$out" | jq --arg adapter "$host_adapter" '{adapter: $adapter} + .' > "$out/host.json"

# The skill puts a link to the page at the top of the description. It is not the author's text, so the page leaves it out,
# and watch.sh does not see it as a change.
summary_link=$(summary_link_pattern "$out/host.json")
jq -r --arg link "$summary_link" '.body | if $link == "" then . else sub($link; "") end | sub("\\s+$"; "")' "$out/pr.json" \
	> "$out/description.md"

# A thread that a bot started is an AI reviewer's thread, which the page leaves out.
if has_function review_threads; then review_threads "$out"; else echo '[]'; fi \
	| jq 'map(.startedByHuman = (.comments[0].bot | not))' > "$out/threads.json"

# The artifact host blocks external images, so avatars.mjs embeds these in the page as data URIs. Bots get square avatars.
avatars='{}'
while IFS=$'\t' read -r author bot url; do
	type=$(curl -fsSL -o "$out/avatar.tmp" -w '%{content_type}' "$url")
	avatars=$(jq --arg author "$author" --argjson bot "$bot" --arg data "data:${type%%;*};base64,$(base64 < "$out/avatar.tmp" | tr -d '\n')" \
		'.[$author] = {src: $data, bot: $bot}' <<< "$avatars")
done < <(jq -r '[.[].comments[] | select(.avatarUrl != null) | [.author, .bot, .avatarUrl]] | unique[] | @tsv' "$out/threads.json")
rm -f "$out/avatar.tmp"
printf '%s\n' "$avatars" > "$out/avatars.json"

if has_function preview_url; then preview_url "$out"; fi > "$out/preview-url.txt"

head_sha=$(jq -r .headRefOid "$out/pr.json")
echo "Host: $(jq -r .name "$out/host.json") (hosts/$host_adapter.sh). Copy host.json into the #host block of the page."
jq -r 'if .number == null
	then "No PR: the branch \(.headRefName) against \(.baseRefName)\n\(.title)"
	else "PR \(.number): \(.title)\n\(.url)" end
	+ "\n\(.headRefName) → \(.baseRefName), head \(.headRefOid)\n+\(.additions) −\(.deletions) in \(.changedFiles) files"' "$out/pr.json"
author=$(jq -r '.author.login // "unknown"' "$out/pr.json")
viewer=$(if has_function viewer_login; then viewer_login "$out"; fi)
if [ -n "$summary_link" ] && [ -n "$viewer" ] && [ "$author" = "$viewer" ]; then
	has_link=$(jq -r --arg link "$summary_link" 'if .body | test($link) then "yes" else "no" end' "$out/pr.json")
	echo "Author: $author (you). Summary link in the description: $has_link"
else
	echo "Author: $author"
fi
echo "Production preview (the sidebar links it): $(grep . "$out/preview-url.txt" || echo none)"
jq -r '"Review threads: \(length). Open, started by humans, on the current diff (the page must show these): \(map(select(.startedByHuman and (.isOutdated | not) and (.isResolved | not))) | length)"' "$out/threads.json"
jq -r '.[] | select(.startedByHuman and (.isOutdated | not) and (.isResolved | not)) | "  \(.path):\(.line) by \(.comments[0].author) \(.comments[0].url)"' "$out/threads.json"

node "$scripts/removed-tests.mjs" "$out/full.diff" > "$out/removed-tests.txt"
echo "Tests that the PR removes (the page must show these, or the tests that replace them): $(wc -l < "$out/removed-tests.txt" | tr -d ' ')"
sed 's/^/  /' "$out/removed-tests.txt"

# A merged PR that this PR was stacked on is in the base branch now, so the page mentions it only as history.
echo "PRs that the description links to:"
if has_function linked_refs; then linked_refs "$out"; fi | sort -u | while read -r linked_repo linked_number; do
	# A lookup that fails fails the run, so that watch.sh checks again instead of seeing a changed list.
	linked_pr "$out" "$linked_repo" "$linked_number" || exit 1
done | tee "$out/linked-prs.txt"

# Chart and test links point to line numbers in the head commit, so read the code there.
if [ "$(git rev-parse HEAD)" != "$head_sha" ]; then
	echo "warning: the local HEAD is not the PR head $head_sha. Read line numbers with: git show $head_sha:<path>"
fi
