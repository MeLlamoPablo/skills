# GitLab (gitlab.com and self-managed servers), through the `glab` CLI, signed in to the host of the merge request:
# `glab auth login [--hostname <host>]`. README.md in this folder describes each function and the files that it writes.

known_host() {
	[ "$1" = gitlab.com ]
}

serves_host() {
	command -v glab > /dev/null && glab auth status --hostname "$1"
}

gl_hostname() {
	jq -r '.repoUrl | capture("^https?://(?<host>[^/]+)").host' "$1/pr.json"
}

# The URL-encoded path of the project, for the REST API. A project can be in nested groups.
gl_project() {
	jq -r '.repoUrl | sub("^https?://[^/]+/"; "") | @uri' "$1/pr.json"
}

# GitLab puts a `/-/` segment before project pages. It names the anchor of a file in the "Changes" tab after the SHA-1
# of its path. Its line anchors (`<SHA-1>_<old line>_<new line>`) need both line numbers, which the page does not have,
# so a link to a line opens the file. It links `#123` to an issue and `!123` to a merge request. It renders a line break
# in a comment as a space, as Markdown does. Its Markdown has alerts, which older servers show as a plain quote.
host_json() {
	cat <<- 'JSON'
	{
		"name": "GitLab",
		"prNoun": "merge request",
		"prUrl": "{repo}/-/merge_requests/{pr}",
		"prText": "{name}!{pr}",
		"changesUrl": "{repo}/-/merge_requests/{pr}/diffs",
		"changedFileUrl": "{repo}/-/merge_requests/{pr}/diffs#{sha1}",
		"oldLineUrl": "{repo}/-/merge_requests/{pr}/diffs#{sha1}",
		"newLineUrl": "{repo}/-/merge_requests/{pr}/diffs#{sha1}",
		"fileUrl": "{repo}/-/blob/{sha}/{path}",
		"lineUrl": "{repo}/-/blob/{sha}/{path}#L{line}",
		"lineRangeUrl": "{repo}/-/blob/{sha}/{path}#L{start}-{end}",
		"references": [
			{ "pattern": "#(\\d+)", "url": "{repo}/-/issues/$1" },
			{ "pattern": "!(\\d+)", "url": "{repo}/-/merge_requests/$1" },
			{ "pattern": "@([a-z\\d](?:[a-z\\d._-]*[a-z\\d])?)", "url": "{origin}/$1" }
		],
		"markdownBreaks": false,
		"summaryLink": "> [!TIP]\n> Review [the summary of this merge request]({url})"
	}
	JSON
}

pr_facts() {
	glab mr view ${2:+"$2"} -F json > "$1/mr.json"
	local base_sha head_sha
	base_sha=$(jq -r .diff_refs.base_sha "$1/mr.json")
	head_sha=$(jq -r .diff_refs.head_sha "$1/mr.json")
	# The MR API has no line counts, so they come from the diff, which needs both commits in the local repo. GitLab keeps
	# the head of each merge request at refs/merge-requests/<iid>/head, also for one from a fork.
	fetch_commit "$head_sha" "refs/merge-requests/$(jq -r .iid "$1/mr.json")/head"
	git_numstat "$base_sha" "$head_sha" > "$1/files.tsv"
	git diff "$base_sha" "$head_sha" > "$1/full.diff"
	jq --slurpfile files <(jq -R 'split("\t") | {additions: (.[0] | tonumber), deletions: (.[1] | tonumber)}' "$1/files.tsv") '{
		number: .iid, title, body: (.description // ""), url: .web_url,
		repoUrl: (.web_url | sub("/-/merge_requests/[0-9]+$"; "")),
		state: ({opened: "open", merged: "merged", closed: "closed", locked: "open"}[.state] // .state),
		author: {login: .author.username},
		baseRefName: .target_branch, headRefName: .source_branch, headRefOid: .diff_refs.head_sha,
		mergeBaseOid: .diff_refs.base_sha,
		additions: ($files | map(.additions) | add // 0), deletions: ($files | map(.deletions) | add // 0),
		changedFiles: ($files | length)
	}' "$1/mr.json" > "$1/pr.json"
	rm "$1/mr.json"
}

# The discussions whose first note is on the diff. System notes ("added 1 commit") are not comments. GitLab moves a note
# to the new head while its line still exists, so a note whose position is at an older head is outdated. A note does not
# say if its author is a bot, so the user API tells, for bots such as GitLab Duo and for the users of access tokens.
review_threads() {
	local host discussions bots='{}' id
	host=$(gl_hostname "$1")
	discussions=$(glab api --hostname "$host" --paginate --output ndjson \
		"projects/$(gl_project "$1")/merge_requests/$(jq -r .number "$1/pr.json")/discussions?per_page=100" \
		| jq -s 'map(select(.notes[0].type == "DiffNote") | .notes |= map(select(.system | not)) | select(.notes | length > 0))')
	for id in $(jq -r '[.[].notes[].author.id // empty] | unique[]' <<< "$discussions"); do
		bots=$(jq --arg id "$id" --argjson bot "$(glab api --hostname "$host" "users/$id" | jq '.bot == true')" '.[$id] = $bot' <<< "$bots")
	done
	jq --argjson bots "$bots" --arg head "$(jq -r .headRefOid "$1/pr.json")" --arg mr_url "$(jq -r .url "$1/pr.json")" '
		map(.notes[0].position as $position
		| ($position.line_range.end // $position) as $end
		| {
			path: ($position.new_path // $position.old_path),
			line: ($end.new_line // $end.old_line),
			startLine: (if $position.line_range then ($position.line_range.start.new_line // $position.line_range.start.old_line) else null end),
			side: (if $end.new_line == null then "old" else "new" end),
			isResolved: (.notes[0].resolved == true),
			isOutdated: ($position.head_sha != $head),
			comments: (.notes | map({
				author: (.author.username // "ghost"),
				bot: ($bots[.author.id // "" | tostring] == true),
				avatarUrl: .author.avatar_url,
				body,
				url: "\($mr_url)#note_\(.id)"
			}))
		})' <<< "$discussions"
}

viewer_login() {
	glab api --hostname "$(gl_hostname "$1")" user | jq -r .username
}

# GitLab writes "!N" for a merge request and "#N" for an issue, so only "!N" and merge request URLs count.
linked_refs() {
	local host project
	host=$(gl_hostname "$1")
	project=$(jq -r '.repoUrl | sub("^https?://[^/]+/"; "")' "$1/pr.json")
	grep -oE "https?://${host//./\\.}/[^[:space:]]+/-/merge_requests/[0-9]+" "$1/description.md" \
		| sed -E 's|^https?://[^/]+/(.+)/-/merge_requests/|\1 |' || true
	grep -oE '(^|[^[:alnum:]/&])![0-9]+' "$1/description.md" | sed -E "s|.*!|$project |" || true
}

linked_pr() {
	local json
	json=$(glab mr view "$3" --repo "https://$(gl_hostname "$1")/$2" -F json) || return 1
	jq -r '"  \({opened: "open", merged: "merged", closed: "closed", locked: "open"}[.state] // .state) \(.web_url) \(.title)"' <<< "$json"
}

pr_description() {
	glab mr view "$(jq -r .number "$1/pr.json")" --repo "$(jq -r .repoUrl "$1/pr.json")" -F json | jq -j '.description // ""'
}

set_pr_description() {
	write_call glab mr update "$(jq -r .number "$1/pr.json")" --repo "$(jq -r .repoUrl "$1/pr.json")" --description-file "$2"
}
