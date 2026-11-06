# Skills

Claude Code plugins with my skills.

| Plugin | What it does |
| --- | --- |
| [summarize-pr](plugins/summarize-pr/skills/summarize-pr/SKILL.md) | Builds a simplified overview of a pull request as a Claude Artifact, so that a reviewer can check the direction of the PR without reading all of its code. |

## Install

```
/plugin marketplace add MeLlamoPablo/skills
/plugin install summarize-pr@mellamopablo
```

To get updates automatically, open `/plugin`, go to **Marketplaces**, select `mellamopablo` and select **Enable auto-update**.

`summarize-pr` needs `gh` (signed in), `jq` and Node.js. To check its charts, it also needs Chrome and `puppeteer-core`, which the skill installs the first time.
