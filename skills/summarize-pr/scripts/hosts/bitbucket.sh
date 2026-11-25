# Bitbucket Cloud (bitbucket.org), through its REST API 2.0 with curl. A public repo needs no sign-in. For a private repo,
# and to edit a description, set one of:
# - BITBUCKET_ACCESS_TOKEN: a repository, project or workspace access token with the pull request scopes.
# - BITBUCKET_EMAIL and BITBUCKET_API_TOKEN: the email of your Atlassian account and an API token of it with the
#   pull request scopes.
# Bitbucket Data Center has another API, so this adapter does not serve it.
# README.md in this folder describes each function and the files that it writes.

known_host() {
	[ "$1" = bitbucket.org ]
}

bb_api=https://api.bitbucket.org/2.0

# bb_curl <curl arguments>: curl with the credentials from the environment, if any. curl reads them from a config on a
# file descriptor, so they are not in the arguments that other processes can see.
bb_curl() {
	if [ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]; then
		curl -fsSL -K <(printf 'header = "Authorization: Bearer %s"\n' "$BITBUCKET_ACCESS_TOKEN") "$@"
	elif [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
		curl -fsSL -K <(printf 'user = "%s:%s"\n' "${BITBUCKET_EMAIL:?BITBUCKET_API_TOKEN needs BITBUCKET_EMAIL}" "$BITBUCKET_API_TOKEN") "$@"
	else
		curl -fsSL "$@"
	fi
}

bb_get() {
	bb_curl "$1" || {
		echo "Bitbucket refused $1. For a private repo, set BITBUCKET_ACCESS_TOKEN, or BITBUCKET_EMAIL and BITBUCKET_API_TOKEN." >&2
		return 1
	}
}

# Prints the values of all pages of a list, one JSON object per line.
bb_values() {
	local url=$1 page
	while [ -n "$url" ]; do
		page=$(bb_get "$url")
		jq -c '.values[]' <<< "$page"
		url=$(jq -r '.next // empty' <<< "$page")
	done
}

# "<workspace>/<repo>" of the PR.
bb_repo() {
	jq -r '.repoUrl | sub("^https?://[^/]+/"; "")' "$1/pr.json"
}

bb_pr_api() {
	echo "$bb_api/repositories/$(bb_repo "$1")/pullrequests/$(jq -r .number "$1/pr.json")"
}

# A source file links a line as `#lines-<n>` and a range as `#lines-<a>:<b>`. The anchors of lines in a PR's diff are
# not documented, so a link to a line in the diff opens the file. Bitbucket links "pull request #123" to that PR. Its
# Markdown has no alerts, so the summary link is a plain quote.
host_json() {
	cat <<- 'JSON'
	{
		"name": "Bitbucket",
		"prNoun": "pull request",
		"prUrl": "{repo}/pull-requests/{pr}",
		"prText": "{name}#{pr}",
		"changesUrl": "{repo}/pull-requests/{pr}/diff",
		"changedFileUrl": "{repo}/pull-requests/{pr}/diff#chg-{path}",
		"oldLineUrl": "{repo}/pull-requests/{pr}/diff#chg-{path}",
		"newLineUrl": "{repo}/pull-requests/{pr}/diff#chg-{path}",
		"fileUrl": "{repo}/src/{sha}/{path}",
		"lineUrl": "{repo}/src/{sha}/{path}#lines-{line}",
		"lineRangeUrl": "{repo}/src/{sha}/{path}#lines-{start}:{end}",
		"references": [
			{ "pattern": "pull request #(\\d+)", "url": "{repo}/pull-requests/$1" }
		],
		"markdownBreaks": false,
		"summaryLink": "> Review [the summary of this pull request]({url})"
	}
	JSON
}

pr_facts() {
	local repo id branch pr head
	case "${2:-}" in
		http://* | https://*)
			repo=$(url_path "$2" | cut -d/ -f1-2)
			id=$(sed -nE 's#.*/pull-requests/([0-9]+).*#\1#p' <<< "$2")
			;;
		*)
			repo=$(url_path "$host_url" | cut -d/ -f1-2)
			case "${2:-}" in
				'' | *[!0-9]*)
					branch=${2:-$(git symbolic-ref --short HEAD)}
					id=$(bb_get "$bb_api/repositories/$repo/pullrequests?q=$(jq -rn --arg branch "$branch" \
						'"source.branch.name=\"\($branch)\" AND state=\"OPEN\"" | @uri')" | jq -r '.values[0].id // empty')
					[ -n "$id" ] || { echo "Bitbucket has no open pull request for the branch $branch." >&2; return 1; }
					;;
				*) id=$2 ;;
			esac
			;;
	esac
	pr=$(bb_get "$bb_api/repositories/$repo/pullrequests/$id")
	# The PR has only the short SHA of its head commit.
	head=$(bb_get "$bb_api/repositories/$(jq -r .source.repository.full_name <<< "$pr")/commit/$(jq -r .source.commit.hash <<< "$pr")?fields=hash" | jq -r .hash)
	bb_values "$bb_api/repositories/$repo/pullrequests/$id/diffstat?pagelen=100" \
		| jq -r '"\(.lines_added // 0)\t\(.lines_removed // 0)\t\(.new.path // .old.path)"' > "$1/files.tsv"
	bb_get "$bb_api/repositories/$repo/pullrequests/$id/diff" > "$1/full.diff"
	jq --arg head "$head" --slurpfile files <(jq -R 'split("\t") | {additions: (.[0] | tonumber), deletions: (.[1] | tonumber)}' "$1/files.tsv") '{
		number: .id, title, body: (.summary.raw // .description // ""), url: .links.html.href,
		repoUrl: (.links.html.href | sub("/pull-requests/[0-9]+$"; "")),
		state: ({OPEN: "open", MERGED: "merged", DECLINED: "closed", SUPERSEDED: "closed"}[.state] // (.state | ascii_downcase)),
		author: {login: .author.nickname},
		baseRefName: .destination.branch.name, headRefName: .source.branch.name, headRefOid: $head,
		additions: ($files | map(.additions) | add // 0), deletions: ($files | map(.deletions) | add // 0),
		changedFiles: ($files | length)
	}' <<< "$pr" > "$1/pr.json"
}

# A thread is an inline comment and its replies, which point to their parent. Bitbucket does not say if the line of a
# comment changed after the comment, so settle_outdated follows the line in git. A comment's code link names the commit
# that the comment is on ("…/diff/<repo>:<head>..<base>?path=…"). Apps and teams are not "user" accounts.
review_threads() {
	local file="$1/threads.raw.json"
	bb_values "$(bb_pr_api "$1")/comments?pagelen=100" | jq -s '
		(map({key: (.id | tostring), value: .parent.id}) | from_entries) as $parent
		| def root: . as $id | ($parent[$id | tostring] // null) as $up | if $up == null then $id else ($up | root) end;
		[.[] | select(.deleted | not) | .thread = (.id | root)]
		| group_by(.thread) | map(sort_by(.created_on)) | map(select(.[0].inline != null and .[0].id == .[0].thread))
		| sort_by(.[0].created_on)
		| map(.[0].inline as $inline | {
			path: $inline.path,
			line: ($inline.to // $inline.from),
			startLine: ($inline.start_to // $inline.start_from),
			side: (if $inline.to == null then "old" else "new" end),
			isResolved: (.[0].resolution != null),
			isOutdated: null,
			at: {commit: (.[0].links.code.href // "" | capture(":(?<sha>[0-9a-f]+)\\.\\.").sha // ""), text: null},
			comments: map({
				author: (.user.nickname // .user.display_name // "ghost"),
				bot: (.user != null and .user.type != "user"),
				avatarUrl: .user.links.avatar.href,
				body: .content.raw,
				url: .links.html.href
			})
		})' > "$file"
	if [ "$(jq length "$file")" -gt 0 ]; then
		fetch_commit "$(jq -r .headRefOid "$1/pr.json")" "refs/heads/$(jq -r .headRefName "$1/pr.json")" 2> /dev/null ||
			echo "note: the head commit is not in the local repo, so each comment on an older commit counts as outdated." >&2
		settle_outdated "$file" "$(jq -r .headRefOid "$1/pr.json")" ""
	fi
	cat "$file"
	rm "$file"
}

viewer_login() {
	# Without credentials, Bitbucket has no signed-in user.
	[ -n "${BITBUCKET_ACCESS_TOKEN:-}${BITBUCKET_API_TOKEN:-}" ] || return 0
	bb_get "$bb_api/user" | jq -r .nickname
}

linked_refs() {
	local repo
	repo=$(bb_repo "$1")
	grep -oE 'https?://bitbucket\.org/[^/[:space:]]+/[^/[:space:]]+/pull-requests/[0-9]+' "$1/description.md" \
		| sed -E 's|^https?://[^/]+/([^/]+/[^/]+)/pull-requests/|\1 |' || true
	grep -oiE 'pull request #[0-9]+' "$1/description.md" | sed -E "s|.*#|$repo |" || true
}

linked_pr() {
	bb_get "$bb_api/repositories/$2/pullrequests/$3" | jq -r '"  \({OPEN: "open", MERGED: "merged", DECLINED: "closed", SUPERSEDED: "closed"}[.state] // .state) \(.links.html.href) \(.title)"'
}

pr_description() {
	bb_get "$(bb_pr_api "$1")" | jq -j '.summary.raw // .description // ""'
}

set_pr_description() {
	local body="$1/description-request.json"
	jq -n --rawfile description "$2" '{description: $description}' > "$body"
	write_call bb_curl -o /dev/null -X PUT -H 'Content-Type: application/json' --data-binary "@$body" "$(bb_pr_api "$1")"
}
