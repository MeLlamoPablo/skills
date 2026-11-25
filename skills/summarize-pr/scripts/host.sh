#!/usr/bin/env bash
# The one entry point to the host of a PR (the server that has the repo and its pull requests).
# Usage:
#   host.sh detect [<PR URL>]                         Prints the adapter that serves the repo, or the PR URL.
#   host.sh description <out>                         Prints the current description of the PR.
#   host.sh set-description <out> <file> [--dry-run]  Replaces the description of the PR with the contents of <file>.
#   host.sh link-summary <out> <page URL> [--dry-run] Puts a link to the summary page at the top of the description,
#                                                     one time.
# <out> is a folder that gather.sh wrote. --dry-run prints each call that would change the PR, and does not run it.
# An operation that the host can't do exits with 3.
#
# This file never names a host. Each host is one adapter, hosts/<name>.sh, and hosts/README.md is the contract that the
# adapters follow. gather.sh sources this file, and the steps of SKILL.md run it, so they also never name a host.

hosts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosts"

# The hostname of a git URL (https, ssh or "user@host:path"), in lowercase. Empty for a local path.
url_hostname() {
	printf '%s\n' "$1" | sed -E 's#^[a-zA-Z+]+://##; s#^[^@/]*@##; s#[:/].*$##' | tr '[:upper:]' '[:lower:]'
}

# The path of a git URL after the hostname, without the leading slash and without ".git".
url_path() {
	printf '%s\n' "$1" | sed -E 's#^[a-zA-Z+]+://##; s#^[^@/]*@##; s#^[^:/]*(:[0-9]+/|[:/])##; s#\.git$##'
}

# The remote of the current branch's upstream, else "origin", else the first remote. Empty without a remote.
default_remote() {
	local branch remote
	if branch=$(git symbolic-ref --quiet --short HEAD 2> /dev/null) && remote=$(git config "branch.$branch.remote") &&
		[ "$remote" != . ]; then
		echo "$remote"
	elif git remote | grep -qx origin; then
		echo origin
	else
		git remote | head -n 1
	fi
}

# select_host [<PR number, URL or branch>]: sets host_adapter (the name of an adapter), host_remote and host_url (the
# URL that the adapter serves: the PR URL, else the URL of the remote).
# The order: the SUMMARIZE_PR_HOST variable, then `git config summarize-pr.host`, then the first adapter that knows the
# hostname as a public host, then the first adapter whose CLI or server says that it serves the hostname (slower), then
# plain git.
select_host() {
	host_remote=$(default_remote)
	case "${1:-}" in
		http://* | https://*) host_url=$1 ;;
		*) host_url=$([ -z "$host_remote" ] || git remote get-url "$host_remote") ;;
	esac
	host_adapter=${SUMMARIZE_PR_HOST:-$(git config summarize-pr.host || true)}
	if [ -n "$host_adapter" ]; then
		if [ ! -f "$hosts_dir/$host_adapter.sh" ]; then
			echo "There is no adapter $hosts_dir/$host_adapter.sh. The adapters are: $(cd "$hosts_dir" && ls -- *.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
			return 1
		fi
		return 0
	fi
	local hostname check file
	hostname=$(url_hostname "$host_url")
	if [ -n "$hostname" ]; then
		for check in known_host serves_host; do
			for file in "$hosts_dir"/*.sh; do
				# A subshell, so that the functions of one adapter don't leak into the check of the next.
				if (source "$file" && declare -F "$check" > /dev/null && "$check" "$hostname") > /dev/null 2>&1; then
					host_adapter=$(basename "$file" .sh)
					return 0
				fi
			done
		done
	fi
	host_adapter=git
	echo "note: no adapter in $hosts_dir serves ${host_url:-this repo}, so the summary uses only git:" \
		"no review threads, no links to a host, no link in a description. To pick an adapter, run" \
		"git config summarize-pr.host <name>." >&2
}

# Sources the adapter that select_host picked, or the one in host.json.
load_host() {
	# shellcheck source=/dev/null
	source "$hosts_dir/$host_adapter.sh"
}

has_function() {
	declare -F "$1" > /dev/null
}

# Adapters run each call that changes the PR through write_call, so that --dry-run prints the call instead.
write_call() {
	if [ -n "${HOST_DRY_RUN:-}" ]; then
		printf 'dry run:'
		printf ' %q' "$@"
		printf '\n'
	else
		"$@"
	fi
}

# fetch_commit <sha> [<ref>]: makes sure that the local repo has the commit. Else it fetches <ref> (default: the SHA)
# from the remote of the repo. Diffs, line checks and check.mjs read the commits of the PR locally.
fetch_commit() {
	git cat-file -e "$1^{commit}" 2> /dev/null && return 0
	git fetch --quiet "${host_remote:?no git remote to fetch $1 from}" "${2:-$1}"
}

# git_numstat <base> <head>: prints files.tsv for the diff between two commits: "<additions>\t<deletions>\t<path>". A
# binary file has 0 lines, and a renamed file has its new path, as hosts list them.
git_numstat() {
	local additions deletions path
	git diff --numstat -z -M "$1" "$2" | while IFS=$'\t' read -r -d '' additions deletions path; do
		# -z writes a rename as "<additions>\t<deletions>\t\0<old path>\0<new path>\0".
		if [ -z "$path" ]; then
			IFS= read -r -d '' path
			IFS= read -r -d '' path
		fi
		printf '%s\t%s\t%s\n' "${additions/-/0}" "${deletions/-/0}" "$path"
	done
}

# map_lines <from> <to> <path> <first> <last>: follows the lines <first>..<last> of a file from one commit to another,
# the way GitHub and GitLab move a comment: lines added or removed above the range move it. Prints the numbers of the
# range at <to> as "<first> <last>". Fails when a line in the range changed, or the file is not at both commits.
map_lines() {
	git cat-file -e "$1:$3" 2> /dev/null && git cat-file -e "$2:$3" 2> /dev/null || return 1
	git diff -U0 --no-color --no-ext-diff "$1" "$2" -- "$3" | awk -v first="$4" -v last="$5" '
		# A hunk header is "@@ -<start>[,<count>] +<start>[,<count>] @@", and a missing count is 1. Hunks come in order.
		# An old count of 0 means lines added after old line <start>, which change the range only when they land inside it.
		/^@@ / {
			split(substr($2, 2), old, ","); split(substr($3, 2), new, ",")
			start = old[1] + 0; removed = (2 in old) ? old[2] + 0 : 1; added = (2 in new) ? new[2] + 0 : 1
			if (removed == 0 ? (start >= last) : (start > last)) exit
			if (removed == 0 ? (start >= first) : (start + removed > first)) { changed = 1; exit }
			shift += added - removed
		}
		END { if (changed) exit 1; print first + shift, last + shift }'
}

# settle_outdated <threads file> <head sha> <merge base sha or empty>: some hosts do not say if the line of a comment
# changed after the comment. Their adapters write such a thread with "isOutdated": null and "at": {"commit": <the commit
# that the thread's line numbers count in, or "">, "text": <the line as the comment saw it, or null>}. The thread follows
# its lines from that commit to the head (to the merge base for an "old" thread) with map_lines: it is current, at its
# new line numbers, unless one of its lines changed. When the commit is not in the local repo, only a thread whose line
# has the same text at the same number is current. Else the thread is outdated, because the page can't place it.
settle_outdated() {
	local file=$1 head=$2 base=$3 settled='{}' index now commit path first last found
	while IFS=$'\t' read -r index now commit path first last; do
		# A tab is whitespace to read, which would merge an empty field with the next one, so no commit is "-".
		if [ "$commit" != - ] && git cat-file -e "$commit^{commit}" 2> /dev/null; then
			if found=$(map_lines "$commit" "$now" "$path" "$first" "$last"); then
				settled=$(jq --arg i "$index" --arg lines "$found" '.[$i] = {lines: ($lines | split(" ") | map(tonumber))}' <<< "$settled")
			fi
		elif git cat-file -e "$now:$path" 2> /dev/null; then
			found=$(git show "$now:$path" | sed -n "${last}p")
			settled=$(jq --arg i "$index" --arg text "$found" '.[$i] = {text: $text}' <<< "$settled")
		fi
	done < <(jq -r --arg head "$head" --arg base "$base" 'to_entries[] | .key as $i | .value | select(.isOutdated == null)
		| (if .side == "new" then $head else $base end) as $now | (.at.commit // "") as $commit
		| select($now != "" and ($commit == "" or ($now | startswith($commit) | not)))
		| [$i, $now, (if $commit == "" then "-" else $commit end), .path, (.startLine // .line), .line] | @tsv' "$file")
	jq --argjson settled "$settled" --arg head "$head" --arg base "$base" 'to_entries | map(.key as $i | .value
		| if .isOutdated == null then
			(if .side == "new" then $head else $base end) as $now | (.at.commit // "") as $commit | $settled["\($i)"] as $found
			| if $now != "" and $commit != "" and ($now | startswith($commit)) then .isOutdated = false
			elif $found.lines != null then
				.isOutdated = false | .line = $found.lines[1] | .startLine = (if .startLine == null then null else $found.lines[0] end)
			else .isOutdated = ($found.text == null or .at.text == null or $found.text != .at.text) end
		else . end
		| del(.at))' "$file" > "$file.tmp"
	mv "$file.tmp" "$file"
}

# summary_link_pattern <host.json>: the regex of the summary link block, made from the block in host.json, so that the
# block that link-summary writes and the block that gather.sh leaves out of description.md can't drift apart. Prints
# nothing when the host takes no such block.
summary_link_pattern() {
	jq -r '.summaryLink // empty
		| split("{url}")
		| map(gsub("(?<c>[\\\\.*+?^$()\\[\\]{}|/])"; "\\\(.c)") | gsub("\n"; "\\r?\\n"))
		| "^" + join("[^\\s)>]+") + "(\\r?\\n)*"' "$1"
}

# The name of the host, for messages.
host_name() {
	jq -r .name "$1/host.json"
}

# Runs one operation of the usage above on the PR of a gather.sh folder, with the adapter that gather.sh used.
host_operation() {
	local operation=$1 out=${2:?Usage: host.sh $1 <out> …}
	host_adapter=$(jq -r .adapter "$out/host.json")
	load_host
	case "$operation" in
		description)
			has_function pr_description || { echo "$(host_name "$out") can't read the description of a PR." >&2; return 3; }
			pr_description "$out"
			;;
		set-description)
			local file=${3:?Usage: host.sh set-description <out> <file> [--dry-run]}
			has_function set_pr_description || { echo "$(host_name "$out") can't edit the description of a PR." >&2; return 3; }
			set_pr_description "$out" "$file"
			;;
		link-summary)
			local url=${3:?Usage: host.sh link-summary <out> <page URL> [--dry-run]} block current pattern file
			block=$(jq -r --arg url "$url" '.summaryLink // empty | gsub("\\{url\\}"; $url)' "$out/host.json")
			if [ -z "$block" ] || ! has_function pr_description || ! has_function set_pr_description; then
				echo "$(host_name "$out") can't take a link to the summary in the description of the PR." >&2
				return 3
			fi
			current=$(pr_description "$out")
			pattern=$(summary_link_pattern "$out/host.json")
			if jq -en --arg body "$current" --arg pattern "$pattern" '$body | test($pattern)' > /dev/null; then
				echo "The description already links to the summary."
				return 0
			fi
			# The rest of the description stays as the author wrote it.
			file="$out/description-with-summary-link.md"
			printf '%s\n\n%s\n' "$block" "$current" > "$file"
			set_pr_description "$out" "$file"
			[ -n "${HOST_DRY_RUN:-}" ] || echo "The description now starts with a link to the summary."
			;;
		*)
			echo "Unknown operation: $operation" >&2
			return 2
			;;
	esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -euo pipefail
	operation=${1:?Usage: host.sh detect|description|set-description|link-summary …}
	shift
	args=()
	for arg in "$@"; do
		if [ "$arg" = --dry-run ]; then HOST_DRY_RUN=1; else args+=("$arg"); fi
	done
	if [ "$operation" = detect ]; then
		select_host "${args[0]:-}"
		echo "$host_adapter"
	else
		host_operation "$operation" ${args[@]+"${args[@]}"}
	fi
fi
