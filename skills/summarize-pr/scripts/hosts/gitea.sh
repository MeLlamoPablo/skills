# Gitea and Forgejo (Codeberg, gitea.com and self-hosted servers), through their REST API (/api/v1) with curl. A public
# repo needs no sign-in. For a private repo, and to edit a description, set GITEA_TOKEN (or FORGEJO_TOKEN) to an access
# token of the server with the repository scope. The `tea` CLI has no call for each read here, so the adapter uses the
# API, and asks tea only which servers the user signed in to.
# README.md in this folder describes each function and the files that it writes.

known_host() {
	[ "$1" = codeberg.org ] || [ "$1" = gitea.com ]
}

serves_host() {
	if command -v tea > /dev/null && tea logins list 2> /dev/null | grep -qiF "://$1"; then
		return 0
	fi
	# Gitea and Forgejo answer this without a sign-in. Other hosts have no such path.
	curl -fsS --max-time 5 "https://$1/api/v1/version" | jq -e '.version | type == "string"'
}

gt_token() {
	printf '%s' "${GITEA_TOKEN:-${FORGEJO_TOKEN:-}}"
}

# gt_curl <curl arguments>: curl with the token from the environment, if any. curl reads it from a config on a file
# descriptor, so it is not in the arguments that other processes can see.
gt_curl() {
	if [ -n "$(gt_token)" ]; then
		curl -fsSL -K <(printf 'header = "Authorization: token %s"\n' "$(gt_token)") "$@"
	else
		curl -fsSL "$@"
	fi
}

gt_get() {
	gt_curl "$1" || {
		echo "The server refused $1. For a private repo, set GITEA_TOKEN." >&2
		return 1
	}
}

# Prints the items of all pages of a list, one JSON object per line. A page has at most 50 items on default servers.
gt_items() {
	local page=1 separator='?' items
	[[ $1 != *\?* ]] || separator='&'
	while :; do
		items=$(gt_get "$1${separator}limit=50&page=$page")
		jq -c '.[]' <<< "$items"
		[ "$(jq length <<< "$items")" -ge 50 ] || return 0
		page=$((page + 1))
	done
}

# The API root and "<owner>/<repo>" of the PR.
gt_api() {
	jq -r '.repoUrl | capture("^(?<root>https?://[^/]+)").root + "/api/v1"' "$1/pr.json"
}
gt_repo() {
	jq -r '.repoUrl | sub("^https?://[^/]+/"; "")' "$1/pr.json"
}
gt_pr_api() {
	echo "$(gt_api "$1")/repos/$(gt_repo "$1")/pulls/$(jq -r .number "$1/pr.json")"
}

# Gitea names the anchor of a file in "Files changed" after the SHA-1 of its path, and adds `R<line>` for a line of
# the head commit and `L<line>` for a line of the merge base. `#123` is an issue or a pull request: they share the
# numbers, and the issue URL opens either. Gitea renders a line break in a comment as a line break by default, and has
# alerts since 1.22. Its name is the name of the server ("codeberg.org"), because Gitea and Forgejo look the same here.
host_json() {
	jq -n --arg name "$(jq -r '.repoUrl | capture("^https?://(?<host>[^/]+)").host' "$1/pr.json")" '{
		name: $name,
		prNoun: "pull request",
		prUrl: "{repo}/pulls/{pr}",
		prText: "{name}#{pr}",
		changesUrl: "{repo}/pulls/{pr}/files",
		changedFileUrl: "{repo}/pulls/{pr}/files#diff-{sha1}",
		oldLineUrl: "{repo}/pulls/{pr}/files#diff-{sha1}L{line}",
		newLineUrl: "{repo}/pulls/{pr}/files#diff-{sha1}R{line}",
		fileUrl: "{repo}/src/commit/{sha}/{path}",
		lineUrl: "{repo}/src/commit/{sha}/{path}#L{line}",
		lineRangeUrl: "{repo}/src/commit/{sha}/{path}#L{start}-L{end}",
		references: [
			{pattern: "#(\\d+)", url: "{repo}/issues/$1"},
			{pattern: "@([a-z\\d](?:[a-z\\d._-]*[a-z\\d])?)", url: "{origin}/$1"}
		],
		markdownBreaks: true,
		summaryLink: "> [!TIP]\n> Review [the summary of this pull request]({url})"
	}'
}

pr_facts() {
	local url api repo number branch pr
	case "${2:-}" in
		http://* | https://*) url=$2 ;;
		*) url=$host_url ;;
	esac
	api="https://$(url_hostname "$url")/api/v1"
	repo=$(url_path "$url" | cut -d/ -f1-2)
	case "${2:-}" in
		http://* | https://*) number=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<< "$2") ;;
		'' | *[!0-9]*)
			branch=${2:-$(git symbolic-ref --short HEAD)}
			number=$(gt_items "$api/repos/$repo/pulls?state=open" | jq -rs --arg branch "$branch" \
				'map(select(.head.ref == $branch)) | first.number // empty')
			[ -n "$number" ] || { echo "$(url_hostname "$url") has no open pull request for the branch $branch." >&2; return 1; }
			;;
		*) number=$2 ;;
	esac
	pr=$(gt_get "$api/repos/$repo/pulls/$number")
	gt_items "$api/repos/$repo/pulls/$number/files" | jq -r '"\(.additions)\t\(.deletions)\t\(.filename)"' > "$1/files.tsv"
	gt_get "$api/repos/$repo/pulls/$number.diff" > "$1/full.diff"
	jq --slurpfile files <(jq -R 'split("\t") | {additions: (.[0] | tonumber), deletions: (.[1] | tonumber)}' "$1/files.tsv") '{
		number, title, body: (.body // ""), url: .html_url,
		repoUrl: (.html_url | sub("/pulls/[0-9]+$"; "")),
		state: (if .merged then "merged" else .state end),
		author: {login: .user.login},
		baseRefName: .base.ref, headRefName: .head.ref, headRefOid: .head.sha, mergeBaseOid: .merge_base,
		additions: (.additions // ($files | map(.additions) | add) // 0),
		deletions: (.deletions // ($files | map(.deletions) | add) // 0),
		changedFiles: (.changed_files // ($files | length))
	}' <<< "$pr" > "$1/pr.json"
}

# The API lists review comments by review, with no replies: the comments on one line are one thread, as on the PR page.
# `position` is the line in the commit that the comment is on (`commit_id`), and `original_position` the line in the
# merge base. The API does not say if a line changed after its comment, so settle_outdated follows the line from that
# commit to the head. The merge base that an old-side comment saw is not given, so settle_outdated compares the last line
# of its diff hunk with the line at the same number in the current merge base. Gitea marks no account as a bot.
review_threads() {
	local file="$1/threads.raw.json" pr_api
	pr_api=$(gt_pr_api "$1")
	gt_items "$pr_api/reviews" | jq -r 'select(.comments_count > 0 and .state != "PENDING") | .id' | while read -r review; do
		gt_get "$pr_api/reviews/$review/comments" | jq -c '.[]'
	done | jq -s --arg head "$(jq -r .headRefOid "$1/pr.json")" '
		map(. + {side: (if .position > 0 then "new" else "old" end), line: (if .position > 0 then .position else .original_position end)})
		| group_by([.path, .side, .line]) | map(sort_by(.created_at)) | sort_by(.[0].created_at)
		| map(.[0] as $first | {
			path: $first.path, line: $first.line, startLine: null, side: $first.side,
			isResolved: ($first.resolver != null),
			isOutdated: (if $first.commit_id == $head then false else null end),
			at: {commit: (if $first.side == "new" then $first.commit_id else "" end), text: ($first.diff_hunk | split("\n") | last | .[1:])},
			comments: map({author: .user.login, bot: false, avatarUrl: .user.avatar_url, body, url: .html_url})
		})' > "$file"
	if jq -e 'any(.isOutdated == null)' "$file" > /dev/null; then
		# Gitea keeps the head of each pull request at refs/pull/<number>/head, also for one from a fork.
		fetch_commit "$(jq -r .headRefOid "$1/pr.json")" "refs/pull/$(jq -r .number "$1/pr.json")/head" 2> /dev/null ||
			echo "note: the head commit is not in the local repo, so each comment on an older commit counts as outdated." >&2
		settle_outdated "$file" "$(jq -r .headRefOid "$1/pr.json")" "$(jq -r '.mergeBaseOid // ""' "$1/pr.json")"
	fi
	jq 'map(del(.at))' "$file"
	rm "$file"
}

viewer_login() {
	# Without a token, the server has no signed-in user.
	[ -n "$(gt_token)" ] || return 0
	gt_get "$(gt_api "$1")/user" | jq -r .login
}

linked_refs() {
	local host repo
	host=$(jq -r '.repoUrl | capture("^https?://(?<host>[^/]+)").host' "$1/pr.json")
	repo=$(gt_repo "$1")
	grep -oE "https?://${host//./\\.}/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+" "$1/description.md" \
		| sed -E 's|^https?://[^/]+/([^/]+/[^/]+)/pulls/|\1 |' || true
	# "&" skips HTML entities such as "&#39;".
	grep -oE '(^|[^[:alnum:]/&])#[0-9]+' "$1/description.md" | sed -E "s|.*#|$repo |" || true
}

linked_pr() {
	local response status
	response=$(gt_curl -sS -w '\n%{http_code}' "$(gt_api "$1")/repos/$2/pulls/$3" 2> /dev/null || true)
	status=$(tail -n 1 <<< "$response")
	case "$status" in
		200) sed '$d' <<< "$response" | jq -r '"  \(if .merged then "merged" else .state end) \(.html_url) \(.title)"' ;;
		# An issue number has no pull request.
		404) echo "  not a PR: $2#$3" ;;
		*) echo "Reading pull request $2#$3 failed with HTTP $status." >&2; return 1 ;;
	esac
}

pr_description() {
	gt_get "$(gt_pr_api "$1")" | jq -j '.body // ""'
}

set_pr_description() {
	local body="$1/description-request.json"
	jq -n --rawfile description "$2" '{body: $description}' > "$body"
	write_call gt_curl -o /dev/null -X PATCH -H 'Content-Type: application/json' --data-binary "@$body" "$(gt_pr_api "$1")"
}
