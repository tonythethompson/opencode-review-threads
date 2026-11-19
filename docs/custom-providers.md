# Custom providers

Use this guide for model providers that are not built into OpenCode, typically ones exposing an OpenAI-compatible API.

## Configure the provider

Add `opencode.json` to the repository root for normal mention-driven runs:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "myprovider": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "My Provider",
      "options": {
        "baseURL": "https://api.example.com/v1",
        "apiKey": "{env:MYPROVIDER_API_KEY}"
      },
      "models": {
        "my-model": {
          "name": "My Model"
        }
      }
    }
  }
}
```

Replace the placeholders as follows:

- `myprovider`: a unique provider ID. The same value is used as the prefix of the action's `model` input.
- `npm`: use `@ai-sdk/openai-compatible` for APIs implementing `/v1/chat/completions`. Use `@ai-sdk/openai` instead when the provider requires `/v1/responses`.
- `options.baseURL`: the provider's API base URL.
- `options.apiKey`: an environment-variable reference for the provider credential.
- `models`: the exact model IDs accepted by the provider. Add one entry for each model that the workflow may select.

OpenCode replaces an unset `{env:VARIABLE}` reference with an empty string, so ensure the corresponding workflow secret is configured.

## Configure the workflow

Create the provider API key as a GitHub Actions secret, expose it to the action step, and select the model using `provider/model` format:

```yaml
env:
  MYPROVIDER_API_KEY: ${{ secrets.MYPROVIDER_API_KEY }}
with:
  model: myprovider/my-model
```

For local interactive use, OpenCode can store a custom provider credential through `/connect`. GitHub Actions should use an environment variable backed by an Actions secret instead of an interactive login.

## Variants for custom providers

The action does not reproduce OpenCode's configuration precedence or plugin discovery in shell. A nonempty `variant` is validated against the bundled `.opencode/opencode.jsonc` registry only when the action can conservatively establish that this registry is authoritative. Otherwise the requested value is passed to OpenCode unchanged.

In practice:

- an empty `variant` is always accepted;
- models absent from the bundled registry are passed through without compatibility validation;
- models declared without a `variants` key are passed through with a warning because compatibility is unknown;
- a bundled model with an explicit `variants` object is rejected early only when the bundled registry is authoritative and the requested value is not declared;
- normal project runs are treated conservatively because project, global, plugin, config-directory, managed, remote, or future OpenCode configuration sources may affect the effective provider/model metadata;
- review-only runs can use the bundled registry for fail-fast validation only inside the action's isolated GitHub-hosted environment; self-hosted or externally managed runner state is passed through rather than reconstructed.

This policy intentionally does not enumerate supported OpenCode config filenames or plugin-directory layouts. Sources such as `config.json`, `opencode.json`, `opencode.jsonc`, singular or plural plugin directories, `$HOME/.opencode`, and future external/config-directory mechanisms therefore do not need to be mirrored here for the action to avoid an incorrect rejection.

A passed-through `variant` that the provider rejects surfaces as an OpenCode/provider error. The action never substitutes or normalizes the requested variant. If a run with a variant fails in an unclear way, retry with an empty `variant` to confirm whether the variant is the cause.

## Limitations and security

The bundled `/review-pr` mode installs a fresh trusted OpenCode configuration and disables project and caller-supplied configuration. Custom providers defined in the repository's `opencode.json` are therefore unavailable to `/review-pr`; use a built-in provider for isolated review runs. Provider registrations the action itself generates are trusted: `cf:` and `meta:` probe-chain models are emitted into the run's config before isolation and re-imported for review-only runs, so `cloudflare-workers-ai/*` and `model_api/*` selections remain valid there.

Treat project provider configuration as trusted input before exposing a provider secret. The configuration controls `baseURL` and optional request headers, so an untrusted change could redirect the credential to another endpoint. Restrict workflow triggers and secret access accordingly.

## References

- [OpenCode custom provider documentation](https://opencode.ai/docs/providers/#custom-provider)
- [OpenCode configuration variables](https://opencode.ai/docs/config/#variables)
