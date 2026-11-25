# Skills

Agent skills that I made.

| Skill | What it does |
| --- | --- |
| [summarize-pr](skills/summarize-pr/SKILL.md) | Builds a simplified overview of a pull request, so that a reviewer can check the direction of the PR without reading all of its code. In Claude Code, it publishes the overview as a Claude Artifact. In other agents, it opens the overview as a local HTML page. |

## Install

```
npx skills add MeLlamoPablo/skills -g
```

It asks which agents to install the skills into.

## Update

```
npx skills update -g
```

`summarize-pr` checks for updates each time it runs, and tells you when one is available.

## Requirements

`summarize-pr` needs `git`, `jq`, `curl` and Node.js. To read review threads and link to the PR, it also needs what the adapter of your host needs (a CLI that is signed in, or a token), as [its list of adapters](skills/summarize-pr/scripts/hosts/README.md) says. For a repo that no adapter serves, or a branch with no PR yet, it summarizes the branch with git alone. To check its charts, it also needs Chrome and `puppeteer-core`, which the skill installs the first time.
