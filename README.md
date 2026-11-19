# opencode-review-threads

Run an [OpenCode](https://opencode.ai/) agent from GitHub Actions, including issue and pull request comments, pull request reviews, and manually dispatched tasks.

[![CI](https://github.com/tonythethompson/opencode-review-threads/actions/workflows/ci.yml/badge.svg)](https://github.com/tonythethompson/opencode-review-threads/actions/workflows/ci.yml)

Originally forked from [dceoy/opencode-action](https://github.com/dceoy/opencode-action). Everything upstream provides still works; this action adds structured reviews and resilience features on top:

- **Model probe chains** — `model` is optional. When empty, `models-review`/`models-fix` fallback chains are probed in order across the providers you have credentials for (Cloudflare Workers AI, OpenCode Zen, OpenRouter, Anthropic, OpenAI, Google, Groq, Mistral, DeepSeek, xAI, Cerebras, Moonshot, and bare `provider/model` entries selected unprobed) and the first reachable model wins. No chains are bundled: model selection is always an explicit caller choice. See [Model probe chains](#model-probe-chains).
- **Incremental re-reviews** — after a submitted bot review, the next run diffs only from that review's head commit instead of the pull request base, so findings already posted on unchanged code are not re-raised on every push. See [Pull request reviews](docs/pull-request-reviews.md#incremental-reviews).
- **Verified install** — the OpenCode release asset's sha256 digest is checked before extraction instead of piping the installer to a shell.
- **Deadline, retry, and salvage** — the agent budget is anchored to job start; a failed run salvages local-only agent commits onto the updated remote and retries once within the same budget.
- **Comment leak guard** — `guard-path-leaks` snapshots PR comments and fails the job if a posted comment leaks `@/` or `/tmp/` path tokens.
- **`setup-commands` input** — the reusable workflows run caller-supplied shell commands after checkout so the agent has the repo's toolchain.
- **Bundled GitHub runbook** — `.opencode/github-commands.md` documents review/thread posting, thread resolution, and the `@path` rules, and is wired through config `instructions` so it reaches the agent (including in review-only isolation).

## Quick start

### 1. Add a provider secret

In **Settings → Secrets and variables → Actions**, add the API key for your model provider. The example below uses `OPENCODE_API_KEY`.

### 2. Add the workflow

Create `.github/workflows/opencode.yml`:

<!-- prettier-ignore -->
```yaml
---
name: OpenCode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
jobs:
  opencode:
    if: contains(github.event.comment.body, '/oc') || contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false
      - name: Run OpenCode
        uses: tonythethompson/opencode-review-threads@e4ebbcfd7fa7ff642c32367b5817d7ef304cd1d8  # v1.4.2
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ github.token }}
        with:
          model: opencode-go/kimi-k3
```

### 3. Comment on an issue or pull request

```text
/opencode explain this issue
```

The shorter `/oc` trigger also works:

```text
/oc fix this
```

The default setup exchanges the workflow OIDC token for an OpenCode GitHub App token, which requires `id-token: write`.

## Reusable workflows

For smaller caller workflows, this repository provides reusable workflows for OpenCode tasks and pull request reviews:

| Workflow                                                       | Purpose                                                                 |
| -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [`opencode-bot.yml`](.github/workflows/opencode-bot.yml)       | Run OpenCode from trusted comments, manual dispatch, or a fixed prompt. |
| [`opencode-review.yml`](.github/workflows/opencode-review.yml) | Run the bundled `/review-pr` flow for `pull_request` events.            |

See [Reusable workflows](docs/reusable-workflows.md) for caller examples, inputs, secrets, and permission requirements.

## Models and secrets

Set `model` to a `provider/model` value and pass the corresponding API key:

| Provider        | Example model                | Secret               |
| --------------- | ---------------------------- | -------------------- |
| OpenCode        | `opencode-go/kimi-k3`        | `OPENCODE_API_KEY`   |
| OpenRouter      | `openrouter/openrouter/free` | `OPENROUTER_API_KEY` |
| Anthropic       | `anthropic/claude-opus-5`    | `ANTHROPIC_API_KEY`  |
| OpenAI          | `openai/gpt-5.6-sol`         | `OPENAI_API_KEY`     |
| Custom provider | `myprovider/my-model`        | Provider-specific    |

The provider account must have sufficient credits or quota. For providers not built into OpenCode, see [Custom providers](docs/custom-providers.md).

### Model probe chains

When `model` is left empty, the action probes a comma-separated fallback chain and selects the first reachable entry. `models-review` applies to review runs (`pull_request` triggers, `/review-pr`, and `/oc review`); `models-fix` applies to everything else. Entries are:

- `cf:<model>` — probed through the Cloudflare Workers AI OpenAI-compatible endpoint; requires `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. Selected as `cloudflare-workers-ai/<model>` and registered on the built-in provider.
- `meta:<model>` — probed through the Meta Model API OpenAI-compatible endpoint (`https://api.meta.ai/v1`); requires `MODEL_API_KEY`. Selected as `model_api/<model>` and registered as a custom `@ai-sdk/openai-compatible` provider (Muse Ember and Muse Spark limits built in).
- `zen:<model>` — probed through the opencode.ai Zen gateway; requires `OPENCODE_API_KEY`. Selected as `opencode/<model>`. `zengo:<model>` targets the Zen Go gateway and is selected as `opencode-go/<model>`.
- `<provider>:<model>` — probed through the provider's OpenAI-compatible endpoint (or its native API for `anthropic:` and `google:`); requires the provider's API-key env var. Selected as `<provider>/<model>`. Supported prefixes: `anthropic` (alias `claude`), `openai`, `openrouter`, `google` (alias `gemini`; accepts `GOOGLE_GENERATIVE_AI_API_KEY`, `GEMINI_API_KEY`, or `GOOGLE_API_KEY`), `groq`, `mistral`, `deepseek`, `xai`, `cerebras`, `moonshotai` (alias `moonshot`), `github-copilot` (alias `copilot`), `opencode`, `opencode-go`, and `cloudflare-workers-ai`.
- `<provider>/<model>` — selected without probing; the caller supplies the provider's credentials. Model IDs containing `:` (such as OpenRouter's `...:free` suffix) stay bare entries, since a probe prefix never contains `/`.

No chains are bundled: when `model` is empty, the run requires a `models-review`/`models-fix` chain and fails fast otherwise. Free-tier model catalogs rotate constantly, so model selection is always an explicit caller choice rather than a maintained default. The job also fails if no chain entry answers, so pin `model` when you need a guaranteed selection.

## Inputs

| Input                 | Default                   | Description                                                                                                                                                                                          |
| --------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`               | Probe the chains          | Model in `provider/model` format. Empty probes `models-review`/`models-fix`.                                                                                                                         |
| `models-review`       | -                         | Comma-separated probe chain for review runs. Required when `model` is empty. Entries: `<prefix>:<model>` (probed) or bare `provider/model` (trusted). See [Model probe chains](#model-probe-chains). |
| `models-fix`          | -                         | Comma-separated probe chain for non-review runs. Required when `model` is empty. Same entry syntax as `models-review`.                                                                               |
| `guard-path-leaks`    | `true`                    | Fail the job when a comment posted by this run leaks a `@/` or `/tmp/` path token.                                                                                                                   |
| `job-started-at`      | Run step start            | Epoch the job started; anchors the shared agent deadline so the single retry cannot overrun the budget.                                                                                              |
| `agent`               | `build`                   | Primary agent. A slash command can override it.                                                                                                                                                      |
| `prompt`              | Event comment             | Fixed prompt to use instead of the triggering comment.                                                                                                                                               |
| `mentions`            | `/opencode,/oc`           | Comma-separated trigger phrases.                                                                                                                                                                     |
| `variant`             | -                         | Provider-specific reasoning effort; leave empty unless supported. See [Custom providers](docs/custom-providers.md#variants-for-custom-providers).                                                    |
| `share`               | `false`                   | Share the OpenCode session.                                                                                                                                                                          |
| `use-github-token`    | `false`                   | Use the workflow token instead of the default App-token flow.                                                                                                                                        |
| `opencode-version`    | `latest`                  | OpenCode version to install. `/review-pr` requires 1.2.14+.                                                                                                                                          |
| `use-bundled-toolkit` | `true`                    | Use the bundled agents, commands, skills, and configuration.                                                                                                                                         |
| `timeout-minutes`     | `60`                      | Stop OpenCode after this many minutes.                                                                                                                                                               |
| `oidc-base-url`       | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.                                                                                                                                              |

Direct `workflow_dispatch` uses the same inputs as `workflow_call`; a non-empty `prompt` is required to run the job, and an empty `model` triggers the probe chains.

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

Outputs are `opencode-version`, `model`, and `cache-hit`. `cache-hit` is empty on review-only runs (`prompt: /review-pr`), which always skip the cache and install fresh. The installed binary is verified against the sha256 digest published on the OpenCode release, and a failed run retries once after attempting to salvage locally committed agent work onto the updated remote.

## Pull request reviews

Set `prompt: /review-pr` to run the bundled read-only review through a dedicated permission-constrained primary agent. The command loads the internal `pr-review` skill, which builds a change/risk map, dispatches fresh read-only child sessions, independently validates candidate findings, and posts confirmed findings inline when they can be anchored to changed lines. Use `/review-pr` rather than loading `pr-review` directly when the enforced read-only boundary is required.

An unscoped review creates a small set of dynamic, risk-driven discovery tasks instead of routing to fixed specialist agents. Explicit aspects such as `security`, `tests`, `docs`, `performance`, or `simplify` constrain the selected review lenses. Discovery and validation run in separate fresh child sessions; the current OpenCode v1-compatible implementation uses one hidden `review-worker` definition for those sessions.

See [Pull request reviews](docs/pull-request-reviews.md) for setup, supported review aspects, submission behavior, and security guarantees.

## Merge-readiness passes

`/oc fix`, `/oc autopilot`, and `prompt: /autopilot` all load the bundled `autopilot` skill for one disciplined merge-readiness pass: merge conflicts first, then unresolved review threads and other feedback, then failing CI. A scoped `/oc fix <target>` narrows the pass to named feedback. The pass can edit the working tree (auto-committed and pushed by the action) and replies/resolves review threads via `gh`; escalation for security or judgment calls is reported in the summary comment rather than guessed. When `CONTEXT7_API_KEY` is provided, the agent can consult current third-party library docs before fixing API-related failures.
