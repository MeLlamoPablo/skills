# Host adapters

The skill reads a PR from its host (the server that has the repo and its pull requests) only through these adapters. Each one is a bash file, `<name>.sh`, that `host.sh` sources. Nothing else in the skill names a host, so to support a host, add an adapter here, and change nothing else.

| Adapter | Hosts | Needs |
| --- | --- | --- |
| `github.sh` | github.com, `*.ghe.com`, GitHub Enterprise Server | `gh`, signed in to the host |
| `gitlab.sh` | gitlab.com, self-managed GitLab | `glab`, signed in to the host |
| `bitbucket.sh` | Bitbucket Cloud (bitbucket.org) | `curl`. For a private repo or to edit a description: `BITBUCKET_ACCESS_TOKEN`, or `BITBUCKET_EMAIL` and `BITBUCKET_API_TOKEN` |
| `gitea.sh` | Gitea and Forgejo: codeberg.org, gitea.com, self-hosted servers | `curl`. For a private repo or to edit a description: `GITEA_TOKEN` (or `FORGEJO_TOKEN`) |
| `git.sh` | Any repo, also with no host or before a PR exists | `git` only |

All adapters also need `git` and `jq`. Not supported yet, because no public server could test them: Bitbucket Data Center (another API than Bitbucket Cloud) and Azure DevOps.

## How `host.sh` picks an adapter

1. The `SUMMARIZE_PR_HOST` variable, for one run: `SUMMARIZE_PR_HOST=git gather.sh …`.
2. `git config summarize-pr.host <name>`, for one repo.
3. The first adapter whose `known_host` accepts the hostname of the PR URL (when the PR argument is a URL), else of the remote of the current branch (else `origin`). This check is fast: it only compares names.
4. The first adapter whose `serves_host` accepts that hostname. This check can ask a CLI or the server, so it runs only when no adapter knows the hostname. It finds self-hosted servers.
5. `git.sh`, with a note that says what the page will not have.

`host.sh detect [<PR URL>]` prints the adapter that this order picks.

## Functions

An adapter defines these functions. `<out>` is the folder that `gather.sh` writes. When a function runs, `pr.json` in `<out>` exists, except for `known_host`, `serves_host` and `pr_facts`. A function fails (exits with a non-zero status) only for a real error, such as a network error or an expired sign-in: `watch.sh` then tries again, and gives up after 5 failures in a row.

| Function | Required | Does |
| --- | --- | --- |
| `known_host <hostname>` | no | Succeeds when the hostname is a public host of the adapter (for example `github.com`). It must not use the network. |
| `serves_host <hostname>` | no | Succeeds when a CLI or the server says that the hostname is a host of the adapter. It runs for unknown hostnames only. |
| `pr_facts <out> [<PR>]` | yes | Writes `pr.json`, `files.tsv` and `full.diff` (see [Files](#files)). `<PR>` is what the user gave: a number, a URL or a branch. Without it, the PR of the current branch. |
| `host_json <out>` | yes | Prints the host description (see [host.json](#hostjson)). `gather.sh` adds `adapter`. |
| `review_threads <out>` | no | Prints the review threads on the diff (see [threads.json](#threadsjson)). Without it, there are none. |
| `viewer_login <out>` | no | Prints the login of the signed-in user, in the same form as `author.login` in `pr.json`. Prints nothing when no user is signed in. Without it, the skill never edits a description. |
| `linked_refs <out>` | no | Prints `<repo> <number>` for each PR that `description.md` links to, one per line, with `<repo>` in the form that `linked_pr` takes. |
| `linked_pr <out> <repo> <number>` | with `linked_refs` | Prints `  <state> <url> <title>` (two spaces first, `<state>` as in `pr.json`), or `  not a PR: <repo>#<number>` when the number is an issue. |
| `preview_url <out>` | no | Prints the URL of the production preview of the PR, or nothing. |
| `pr_description <out>` | no | Prints the current description of the PR, as Markdown. |
| `set_pr_description <out> <file>` | no | Replaces the description with the contents of `<file>`. Run the call that changes the PR through `write_call`, so that `--dry-run` prints it. |

`host.sh` also gives adapters these helpers:

- `host_url` and `host_remote`: the URL that the adapter was picked for, and the name of the git remote.
- `url_hostname <url>` and `url_path <url>`: the hostname, and the path after it without `.git`, of an https, ssh or `user@host:path` URL.
- `fetch_commit <sha> [<ref>]`: fetches `<ref>` from the remote when the commit is not in the local repo.
- `git_numstat <base> <head>`: prints `files.tsv` from git.
- `settle_outdated <threads file> <head> <merge base>`: for a host whose API does not say if a comment's line changed (see [threads.json](#threadsjson)).
- `write_call <command…>`: runs a command that changes the PR, or prints it with `--dry-run`.

## Files

### pr.json

```json
{
	"number": 47,
	"title": "Sign in with PKCE",
	"body": "The description, as Markdown.",
	"url": "https://example.com/acme/api/pull/47",
	"repoUrl": "https://example.com/acme/api",
	"state": "open",
	"author": { "login": "max" },
	"baseRefName": "main",
	"headRefName": "pkce",
	"headRefOid": "<40 hex characters>",
	"mergeBaseOid": "<40 hex characters>",
	"additions": 126,
	"deletions": 22,
	"changedFiles": 20
}
```

- `number`, `url` and `repoUrl` are null when there is no PR (`git.sh`). `repoUrl` is the web page of the repo, and the page puts it in `data-repo-url`.
- `state` is `open`, `merged` or `closed`. A declined or superseded PR is `closed`. `watch.sh` stops when the state is not `open`.
- `author.login` is null when it is not known.
- `mergeBaseOid` is optional. Give it when the host knows it: `check.mjs` reads the code at the merge base, and else it uses `origin/<baseRefName>`.
- `additions`, `deletions` and `changedFiles` are the counts that the host shows, else the sums of `files.tsv`.

`gather.sh` checks this shape and names the adapter when it is wrong.

### files.tsv and full.diff

`files.tsv` has one line for each changed file: `<additions>\t<deletions>\t<path>`, with the new path of a renamed file and 0 lines for a binary file. `full.diff` is the unified git diff of the PR (from the merge base to the head).

### threads.json

`review_threads` prints a JSON array. `gather.sh` adds `startedByHuman` (the first comment is not by a bot) and writes it as `threads.json`.

```json
[
	{
		"path": "src/auth.ts",
		"line": 42,
		"startLine": 40,
		"side": "new",
		"isResolved": false,
		"isOutdated": false,
		"comments": [
			{
				"author": "max",
				"bot": false,
				"avatarUrl": "https://example.com/avatar.png",
				"body": "The comment, as Markdown.",
				"url": "https://example.com/acme/api/pull/47#comment-1"
			}
		]
	}
]
```

- `line` is the last line of the thread's range, and `startLine` the first one, or null for one line. `side` is `new` for a line of the head commit and `old` for a line of the merge base.
- `isOutdated` is true when the code of the thread changed after the thread, so that it is not in the diff anymore. When the API does not say it, write `"isOutdated": null` and `"at": {"commit": <the commit that the thread's line numbers count in, or "">, "text": <that line as the comment saw it, or null>}`, then run `settle_outdated` on the file. It follows the thread's lines from that commit to the head (to the merge base for `old`), as GitHub and GitLab move a comment when lines above it are added or removed, and gives the thread its new line numbers. The thread is outdated when one of its lines changed. Without the commit in the local repo, it is current only when its line has the same text at the same number.
- `author` is the name that the page shows. `bot` is true for a bot or an app (AI reviewers are), so the page leaves out the threads that bots start. When the host does not mark bots, write false: the agent marks an AI reviewer's user account by hand.
- `avatarUrl` is a public image URL, or null. `gather.sh` downloads it into `avatars.json` as `{"<author>": {"src": "data:…", "bot": false}}`, because the page can't load external images.
- `url` opens the comment, and starts with `repoUrl` and `/`. `check.mjs` checks this.

### host.json

`host_json` prints how the page links to the host. `gather.sh` writes it, with `adapter` added, and the page carries it in its `#host` block.

| Key | Value |
| --- | --- |
| `adapter` | The name of the adapter. `gather.sh` adds it, and `host.sh` and `watch.sh` use it to call the same adapter again. |
| `name` | The name of the host, for link titles ("Open on GitLab"). |
| `prNoun` | What the host calls a PR ("merge request"), for the title of the PR link. |
| `prUrl` | The PR page. |
| `prText` | The text of the PR link at the top of the page, for example `{name}#{pr}`. |
| `changesUrl` | The list of changes of the PR. |
| `changedFileUrl` | One file in that list. |
| `oldLineUrl`, `newLineUrl` | One line of the merge base (`old`) or of the head (`new`) in that list. |
| `fileUrl` | A file at the head commit. |
| `lineUrl`, `lineRangeUrl` | A line, or a range of lines, of a file at the head commit. |
| `references` | An array of `{"pattern", "url"}`: a regex of a short reference in a comment (`#(\\d+)`), and the URL that it links to, where `$1` is the first group of the pattern. Can be empty. |
| `markdownBreaks` | true when the host shows a line break in a comment as a line break, false when it shows a space, as Markdown does. |
| `summaryLink` | The Markdown block that links to the summary page from the top of the description, with `{url}` for the page URL. Use a block that the host renders well (for example an alert, when the host has them). `link-summary` writes it, and `gather.sh` leaves a block of this form out of `description.md`, both from this one value. |

Each URL is a template, or null when the host can't make that link. The page then shows no link there: a test name and a diff header stay plain text, a chart box has no link, and with a null `prUrl` the header has no PR link. A null line URL falls back to `changedFileUrl`, then to `changesUrl`, and a null `lineRangeUrl` or `lineUrl` to `fileUrl`. `prNoun`, `prText` and `summaryLink` can be null too.

A template fills these slots:

| Slot | Value |
| --- | --- |
| `{repo}` | `repoUrl` |
| `{origin}` | The scheme and host of `repoUrl` (`https://gitlab.com`) |
| `{name}` | The last segment of `repoUrl` (the repo name) |
| `{pr}` | The PR number |
| `{sha}` | The head commit |
| `{path}` | The path of the file |
| `{line}`, `{start}`, `{end}` | A line, and the first and last line of a range |
| `{sha1}`, `{sha256}` | The SHA-1 or SHA-256 of the path, in hex, for hosts that name file anchors so |

### Other files

`preview_url` writes `preview-url.txt`, and `linked_pr` the lines of `linked-prs.txt`. `gather.sh` writes `description.md`, `avatars.json` and `removed-tests.txt` itself.

## Testing an adapter

- Run `bash host.sh detect` in a clone of a repo on the host, and `bash gather.sh <folder> <PR>` against a public PR that has review threads: resolved, outdated, and by bots.
- Run `bash host.sh link-summary <folder> <URL> --dry-run`: it reads the description and prints the call that would replace it, without a change.
- Copy `host.json` into a page and run `check.mjs` on it.
