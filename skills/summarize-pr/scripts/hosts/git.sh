# Plain git: summarizes a branch against its base with only the local repo. host.sh uses it when no other adapter serves
# the repo, and you can pick it for a branch that has no PR yet: SUMMARIZE_PR_HOST=git.
# The PR argument is a branch (default: the current branch), or "<base>...<branch>". Without a base, the base is
# `git config summarize-pr.base`, else the default branch of the remote, else main or master.
# There is no PR, so pr.json has no number and no URL, and there are no review threads, no links to a host and no
# description to edit. README.md in this folder describes each function and the files that it writes.

host_json() {
	cat <<- 'JSON'
	{
		"name": "git",
		"prNoun": null,
		"prUrl": null,
		"prText": null,
		"changesUrl": null,
		"changedFileUrl": null,
		"oldLineUrl": null,
		"newLineUrl": null,
		"fileUrl": null,
		"lineUrl": null,
		"lineRangeUrl": null,
		"references": [],
		"markdownBreaks": false,
		"summaryLink": null
	}
	JSON
}

git_default_base() {
	local base
	if base=$(git config summarize-pr.base); then
		echo "$base"
	elif [ -n "${host_remote:-}" ] && base=$(git symbolic-ref --quiet --short "refs/remotes/$host_remote/HEAD"); then
		echo "$base"
	else
		for base in main master; do
			git rev-parse --verify --quiet "$base^{commit}" > /dev/null && { echo "$base"; return 0; }
		done
		echo "Can't tell the base branch. Pass <base>...<branch>, or run: git config summarize-pr.base <branch>" >&2
		return 1
	fi
}

pr_facts() {
	local base branch head merge_base commits
	case "${2:-}" in
		*...*) base=${2%%...*} branch=${2#*...} ;;
		*) base=$(git_default_base) branch=${2:-$(git symbolic-ref --short HEAD)} ;;
	esac
	head=$(git rev-parse --verify "$branch^{commit}")
	merge_base=$(git merge-base "$base" "$head")
	if [ "$branch" = "$(git symbolic-ref --quiet --short HEAD)" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
		echo "note: the summary has only the commits of $branch, not the uncommitted changes." >&2
	fi
	git_numstat "$merge_base" "$head" > "$1/files.tsv"
	git diff "$merge_base" "$head" > "$1/full.diff"
	# The commit messages are the author's words, oldest first. A branch of one commit has its subject as the title.
	commits=$(git rev-list --count "$merge_base..$head")
	jq -n --slurpfile files <(jq -R 'split("\t") | {additions: (.[0] | tonumber), deletions: (.[1] | tonumber)}' "$1/files.tsv") \
		--arg title "$(if [ "$commits" = 1 ]; then git log -1 --format=%s "$head"; else echo "$branch"; fi)" \
		--arg body "$(if [ "$commits" = 1 ]; then git log -1 --format=%b "$head"; else git log --reverse --format='### %s%n%n%b' "$merge_base..$head"; fi)" \
		--arg author "$(git log --reverse --format=%an "$merge_base..$head" | sed -n 1p)" \
		--arg state "$(if [ "$merge_base" = "$head" ]; then echo merged; else echo open; fi)" \
		--arg base "$base" --arg branch "$branch" --arg head "$head" --arg merge_base "$merge_base" '{
		number: null, title: $title, body: $body, url: null, repoUrl: null, state: $state,
		author: {login: (if $author == "" then null else $author end)},
		baseRefName: $base, headRefName: $branch, headRefOid: $head, mergeBaseOid: $merge_base,
		additions: ($files | map(.additions) | add // 0), deletions: ($files | map(.deletions) | add // 0),
		changedFiles: ($files | length)
	}' > "$1/pr.json"
}
