# GitHub and GitHub Enterprise, through the `gh` CLI, signed in to the host of the PR: `gh auth login [--hostname <host>]`.
# README.md in this folder describes each function and the files that it writes.

known_host() {
	# GitHub Enterprise Cloud with data residency has a subdomain of ghe.com.
	[ "$1" = github.com ] || [[ $1 == *.ghe.com ]]
}

serves_host() {
	command -v gh > /dev/null && gh auth status --hostname "$1"
}

# "<host>/<owner>/<repo>" of the PR, the form that `gh --repo` takes for any GitHub host.
gh_repo() {
	jq -r '.repoUrl | sub("^https?://"; "")' "$1/pr.json"
}

gh_hostname() {
	jq -r '.repoUrl | capture("^https?://(?<host>[^/]+)").host' "$1/pr.json"
}

# GitHub names the anchor of a file in the "Files changed" tab after the SHA-256 of its path, and adds `R<line>` for a
# line of the head commit and `L<line>` for a line of the merge base. It links `#123` to that pull request or issue, and
# renders a line break in a comment as a line break.
host_json() {
	cat <<- 'JSON'
	{
		"name": "GitHub",
		"prNoun": "pull request",
		"prUrl": "{repo}/pull/{pr}",
		"prText": "{name}#{pr}",
		"changesUrl": "{repo}/pull/{pr}/files",
		"changedFileUrl": "{repo}/pull/{pr}/files#diff-{sha256}",
		"oldLineUrl": "{repo}/pull/{pr}/files#diff-{sha256}L{line}",
		"newLineUrl": "{repo}/pull/{pr}/files#diff-{sha256}R{line}",
		"fileUrl": "{repo}/blob/{sha}/{path}",
		"lineUrl": "{repo}/blob/{sha}/{path}#L{line}",
		"lineRangeUrl": "{repo}/blob/{sha}/{path}#L{start}-L{end}",
		"references": [
			{ "pattern": "#(\\d+)", "url": "{repo}/issues/$1" },
			{ "pattern": "@([a-z\\d](?:[a-z\\d-]*[a-z\\d])?)", "url": "{origin}/$1" }
		],
		"markdownBreaks": true,
		"summaryLink": "> [!TIP]\n> Review [the summary of this PR]({url})"
	}
	JSON
}

pr_facts() {
	gh pr view ${2:+"$2"} --json number,title,body,url,state,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles \
		| jq '.state |= ascii_downcase | .author = {login: .author.login} | .repoUrl = (.url | sub("/pull/[0-9]+$"; ""))' \
		> "$1/pr.json"
	local number repo
	number=$(jq -r .number "$1/pr.json")
	repo=$(gh_repo "$1")
	gh pr view "$number" --repo "$repo" --json files --jq '.files[] | "\(.additions)\t\(.deletions)\t\(.path)"' > "$1/files.tsv"
	gh pr diff "$number" --repo "$repo" > "$1/full.diff"
}

# GitHub Apps (AI reviewers) are "Bot" authors. GitHub shows their logins with a "[bot]" suffix, so the page does too.
review_threads() {
	local repo number
	repo=$(gh_repo "$1")
	number=$(jq -r .number "$1/pr.json")
	gh api graphql --hostname "$(gh_hostname "$1")" -F owner="$(cut -d/ -f2 <<< "$repo")" -F name="$(cut -d/ -f3 <<< "$repo")" \
		-F number="$number" -f query='
	query($owner: String!, $name: String!, $number: Int!) {
		repository(owner: $owner, name: $name) {
			pullRequest(number: $number) {
				reviewThreads(first: 100) {
					totalCount
					nodes {
						path line startLine diffSide isResolved isOutdated
						comments(first: 100) { nodes { author { __typename login avatarUrl(size: 40) } body url } }
					}
				}
			}
		}
	}' --jq '.data.repository.pullRequest.reviewThreads
		| if .totalCount > (.nodes | length) then error("more than 100 review threads; add pagination to hosts/github.sh") end
		| .nodes | map({
			path, line, startLine,
			side: (if .diffSide == "LEFT" then "old" else "new" end),
			isResolved, isOutdated,
			comments: (.comments.nodes | map({
				author: (if .author == null then "ghost" elif .author.__typename == "Bot" then "\(.author.login)[bot]" else .author.login end),
				bot: (.author.__typename == "Bot"),
				avatarUrl: .author.avatarUrl,
				body, url
			}))
		})'
}

# FramerStudio's deploy workflow keeps the preview links of a PR in one comment that it updates on each push:
# https://github.com/framer/FramerStudio/blob/master/tools/ci/deploy-comment.sh
# The page links only the production preview. In other repos, this prints nothing.
preview_url() {
	local repo number
	repo=$(gh_repo "$1")
	number=$(jq -r .number "$1/pr.json")
	gh api --hostname "$(gh_hostname "$1")" --paginate --slurp \
		"repos/$(cut -d/ -f2-3 <<< "$repo")/issues/$number/comments?per_page=100" | jq -r '
		[.[][] | select(.user.login == "github-actions[bot]" and (.body | startswith("<!-- PR_PREVIEW_TAG -->")))]
		| first.body // "" | capture("\\[production preview\\]\\((?<url>[^)]+)\\)").url'
}

viewer_login() {
	gh api user --hostname "$(gh_hostname "$1")" --jq .login
}

linked_refs() {
	local host repo
	host=$(gh_hostname "$1")
	repo=$(gh_repo "$1" | cut -d/ -f2-3)
	grep -oE "https?://${host//./\\.}/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+" "$1/description.md" \
		| sed -E 's|^https?://[^/]+/([^/]+/[^/]+)/pull/|\1 |' || true
	# "&" skips HTML entities such as "&#39;".
	grep -oE '(^|[^[:alnum:]/&])#[0-9]+' "$1/description.md" | sed -E "s|.*#|$repo |" || true
}

linked_pr() {
	local line
	if ! line=$(gh pr view "$3" --repo "$(gh_hostname "$1")/$2" --json state,url,title \
		--jq '"  \(.state | ascii_downcase) \(.url) \(.title)"' 2>&1); then
		# An issue number gets "Could not resolve to a PullRequest". Any other error (network, rate limit) fails.
		grep -q 'Could not resolve to a ' <<< "$line" || { echo "$line" >&2; return 1; }
		line="  not a PR: $2#$3"
	fi
	echo "$line"
}

pr_description() {
	gh pr view "$(jq -r .number "$1/pr.json")" --repo "$(gh_repo "$1")" --json body --jq .body
}

set_pr_description() {
	write_call gh pr edit "$(jq -r .number "$1/pr.json")" --repo "$(gh_repo "$1")" --body-file "$2"
}
