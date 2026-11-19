# Reusable workflows

`opencode-review-threads` publishes two reusable GitHub Actions workflows under `.github/workflows`. Call them as jobs with `uses`, then pass action configuration through `with` and provider credentials through `secrets`.

The examples below pin the reusable workflow definition to a full commit SHA. Inside the called workflow, `uses: $/.` references the action at the repository root from the same repository and running commit, so the workflow reference also pins the action implementation without a second checkout or a separate action revision input.

## Manual dispatch

`opencode-bot.yml` exposes `workflow_dispatch` with the same inputs as `workflow_call`. `prompt` must be non-empty for the job to run; an empty `model` triggers the probe chains. It can be dispatched from the Actions UI or by API clients and integrations authorized to dispatch GitHub Actions workflows.

## OpenCode bot

Use `opencode-bot.yml` for `/opencode` and `/oc` comments, direct manual dispatch, or another event with a fixed `prompt`.

<!-- prettier-ignore -->
```yaml
---
name: OpenCode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

concurrency:
  group: opencode-bot-${{ github.event.issue.number || github.event.pull_request.number || github.ref }}
  cancel-in-progress: false

jobs:
  opencode:
    if: >-
      !endsWith(github.actor, '[bot]')
      && (github.event_name == 'workflow_dispatch'
          || contains('OWNER,MEMBER,COLLABORATOR,CONTRIBUTOR', github.event.comment.author_association))
    permissions:
      contents: write
      issues: write
      pull-requests: write
      id-token: write
      actions: read
    uses: tonythethompson/opencode-review-threads/.github/workflows/opencode-bot.yml@v1
    with:
      model: opencode-go/kimi-k3
    secrets:https://github.com/notifications?query=repo%3Atonythethompson%2Fopencode-review-threads
      OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
```

The `concurrency` group serializes runs per issue or pull request; `cancel-in-progress: false` queues later triggers instead of cancelling a run that may be mid-commit.

For comment events, the reusable workflow accepts comments only from `OWNER`, `MEMBER`, `COLLABORATOR`, or `CONTRIBUTOR` author associations (`CONTRIBUTOR` covers org members whose private membership surfaces as `CONTRIBUTOR` in event payloads). On non-comment events, a non-empty `prompt` is required.

The caller-side `if:` gate is still required for bot actors. Comments from GitHub Apps such as `coderabbitai[bot]` or `amazon-q-developer[bot]` can carry `CONTRIBUTOR` association and pass the association check, but the reusable call then fails with `startup_failure` because bot-triggered events cannot satisfy the secrets and `id-token` requirements the call needs. Gating `github.actor` at the caller skips the run before the call is attempted; the reusable's internal checks never get a chance to reject it.

## Pull request review

Use `opencode-review.yml` for automatic reviews on `pull_request` events. Its `prompt` defaults to `/review-pr`.

<!-- prettier-ignore -->
```yaml
---
name: OpenCode review
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]

concurrency:
  group: opencode-review-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  review:
    permissions:
      contents: read
      issues: write
      pull-requests: write
      id-token: write
      actions: read
    uses: tonythethompson/opencode-review-threads/.github/workflows/opencode-review.yml@v1
    with:
      model: openrouter/openrouter/free
    secrets:
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
```

The `concurrency` group cancels the previous run when a new commit lands on the same pull request, so reviews cannot pile up on superseded commits.

The called workflow enforces its own trigger policy, so callers do not need a job-level `if:` gate. A review job runs only when all of these hold:

- the event is `pull_request` and the pull request's head branch belongs to the same repository (fork pull requests are skipped because GitHub withholds secrets from them anyway),
- the triggering actor is not a bot account (excludes `*[bot]`, `Copilot`, and `sender.type == 'Bot'`), so a synchronize caused by an automation push (including this action's own fix commits) does not launch a run that cannot pass the agent's permission check,
- the pull request author is a non-bot `OWNER`, `MEMBER`, `COLLABORATOR`, or `CONTRIBUTOR`, and the pull request is not a draft,
- or the caller set `model`, which bypasses the author/draft checks as an explicit opt-in (the actor check still applies because it is a runtime requirement, not a policy choice).

For `pull_request` events from public forks, GitHub withholds repository Actions secrets and makes `GITHUB_TOKEN` read-only; Dependabot pull requests have the same restrictions. Private-fork behavior can differ when repository settings explicitly allow secrets or write tokens.

To focus the review, override `prompt` with a supported review aspect, for example `prompt: /review-pr security performance`. See [Pull request reviews](pull-request-reviews.md) for review behavior and security guarantees.

## Inputs

Both reusable workflows expose the action configuration plus a runner input:

| Input                 | Default                                                             | Description                                                                                           |
| --------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `model`               | Probe the chains                                                    | Model in `provider/model` format.                                                                     |
| `models-review`       | -                                                                   | Probe chain for review runs (`<prefix>:<model>` or `provider/model`). Required when `model` is empty. |
| `models-fix`          | -                                                                   | Probe chain for non-review runs. Required when `model` is empty.                                      |
| `guard-path-leaks`    | `true`                                                              | Fail when a posted comment leaks a `@/` or `/tmp/` token.                                             |
| `setup-commands`      | `''`                                                                | Shell commands run after checkout to install the toolchain.                                           |
| `agent`               | `build`                                                             | Primary agent.                                                                                        |
| `share`               | `false`                                                             | Share the OpenCode session.                                                                           |
| `prompt`              | `''` for `opencode-bot.yml`; `/review-pr` for `opencode-review.yml` | Fixed prompt.                                                                                         |
| `use-github-token`    | `false`                                                             | Use the workflow token instead of the default App-token flow.                                         |
| `mentions`            | `/opencode,/oc`                                                     | Comma-separated trigger phrases.                                                                      |
| `variant`             | `''`                                                                | Provider-specific model variant.                                                                      |
| `oidc-base-url`       | `https://api.opencode.ai`                                           | OIDC exchange base URL.                                                                               |
| `opencode-version`    | `latest`                                                            | OpenCode version to install.                                                                          |
| `use-bundled-toolkit` | `true`                                                              | Use the bundled OpenCode toolkit.                                                                     |
| `timeout-minutes`     | `60`                                                                | Maximum OpenCode runtime in minutes.                                                                  |
| `runs-on`             | `ubuntu-latest`                                                     | Runner label for the called job.                                                                      |

Direct `workflow_dispatch` on `opencode-bot.yml` uses the same inputs.

GitHub.com's `$/path` self repository syntax resolves to the repository and commit of the workflow where it appears, including when that workflow is called from another repository. These workflows use `$/.` because the action is defined at the repository root. GitHub Enterprise Server does not support this syntax.

## Secrets

Pass only the provider secrets needed by the probe chain. The reusable workflows accept `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `OPENCODE_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, `DEEPSEEK_API_KEY`, `XAI_API_KEY`, `GROQ_API_KEY`, `CEREBRAS_API_KEY`, `MOONSHOT_API_KEY`, `MISTRAL_API_KEY`, and `MODEL_API_KEY` (Meta Model API, for `meta:` probe-chain entries). `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` enable `cf:` probe-chain entries, and `CONTEXT7_API_KEY` enables the bundled context7 MCP server. OpenCode's `cloudflare-workers-ai` provider reads `CLOUDFLARE_API_KEY` at runtime, so the workflows export that variable from `CLOUDFLARE_API_TOKEN` (a scoped Bearer token) unless `CLOUDFLARE_API_KEY` is passed explicitly.

`GH_TOKEN` is optional. When omitted, the reusable workflow falls back to the caller's `github.token`. With `use-github-token: true`, `opencode-bot.yml` requests `contents: write` so pushes succeed using that token.

## Permissions

`opencode-bot.yml` requests `contents: write`, `pull-requests: write`, `issues: write`, `id-token: write`, and `actions: read`. Its calling job must grant `contents: write` or the run fails at startup. `opencode-review.yml` requests `contents: read`, `pull-requests: write`, `issues: write`, `id-token: write`, and `actions: read`. A called workflow can only maintain or reduce the caller's `GITHUB_TOKEN` permissions: the caller must grant the requested permissions. A separately supplied `GH_TOKEN` is not governed by that `GITHUB_TOKEN` permission ceiling.

The examples keep `permissions`, `with`, and `secrets` under the calling job so their scopes are explicit: `permissions` controls the caller token, `with` configures the reusable workflow inputs, and `secrets` passes credentials.
