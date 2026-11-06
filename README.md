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

`summarize-pr` needs `gh` (signed in), `jq` and Node.js. To check its charts, it also needs Chrome and `puppeteer-core`, which the skill installs the first time.
