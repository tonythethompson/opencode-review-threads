#!/usr/bin/env bash
# Select the model for this run and emit the inline OpenCode configuration.
# Functions are sourceable for tests.
#
# When MODEL is set it is used verbatim (provider/model) and no endpoint is
# probed. Otherwise the caller-supplied comma-separated chain for the run kind
# is walked and the first reachable entry wins. No chains are bundled: a run
# with neither MODEL nor a matching chain fails fast:
#   cf:<model>           probe Cloudflare Workers AI; needs
#                        CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN;
#                        selected as cloudflare-workers-ai/<model>
#   meta:<model>         probe the Meta Model API; needs MODEL_API_KEY;
#                        selected as model_api/<model> and registered as a
#                        custom @ai-sdk/openai-compatible provider pointing
#                        at https://api.meta.ai/v1 (alias: model_api:)
#   zen:<model>          probe the opencode.ai Zen gateway; needs
#                        OPENCODE_API_KEY; selected as opencode/<model>
#   zengo:<model>        probe the opencode.ai Zen Go gateway; needs
#                        OPENCODE_API_KEY; selected as opencode-go/<model>
#   <provider>:<model>   probe any other supported provider; needs that
#                        provider's API-key env var; selected as
#                        <provider>/<model>. Supported providers:
#                        anthropic, openai, openrouter, google (alias gemini),
#                        groq, mistral, deepseek, xai, cerebras, moonshotai
#                        (alias moonshot), github-copilot (alias copilot),
#                        opencode, opencode-go, cloudflare-workers-ai
#   <provider>/<model>   selected without probing; the caller is responsible for
#                        the provider credentials in env
#
# Env in:  MODEL (optional), PROMPT, MENTIONS, GITHUB_EVENT_PATH,
#          GITHUB_EVENT_NAME, MODELS_REVIEW, MODELS_FIX, provider credentials
#          (OPENCODE_API_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN,
#          GITHUB_TOKEN, ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY,
#          GOOGLE_GENERATIVE_AI_API_KEY, GEMINI_API_KEY, GOOGLE_API_KEY,
#          GROQ_API_KEY, MISTRAL_API_KEY, DEEPSEEK_API_KEY, XAI_API_KEY,
#          CEREBRAS_API_KEY, MOONSHOT_API_KEY, MODEL_API_KEY), ACTION_PATH,
#          GITHUB_WORKSPACE,
#          RUNNER_TEMP, OPENCODE_CONFIG_CONTENT (optional caller-provided base
#          config that the emitted config is merged over)
# Out:     $GITHUB_OUTPUT  -> model
#          $GITHUB_ENV     -> OPENCODE_CONFIG_CONTENT, OPENCODE_PROBE_CONFIG_FILE
#
# The emitted config is also written to a file so review-only mode can re-import
# this action-generated (trusted) config after caller-supplied overrides are
# unset; see run-opencode.sh.

# A run counts as a review when the event is a pull_request trigger (the
# review workflow), when the effective prompt is the bundled /review-pr
# command, or when it is a `/oc review`-style request (the mention is already
# stripped by opencode_effective_prompt).
opencode_probe_is_review() {
  local effective_prompt="${1:-}" event_name="${2:-}"
  [[ "${event_name}" == "pull_request" ]] && return 0
  [[ "${effective_prompt}" =~ ^/review-pr([[:space:]]|$) ]] && return 0
  [[ "${effective_prompt}" =~ ^review([[:space:]]|$) ]] && return 0
  return 1
}

# OpenAI-compatible probe shared by every provider exposing
# {base}/chat/completions: POST a 1-token completion and require HTTP success.
opencode_probe_openai_compat() {
  local base="${1}" key="${2}" model="${3}"
  curl -sf --max-time 15 -X POST "${base}/chat/completions" \
    -H "Authorization: Bearer ${key}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    > /dev/null 2>&1
}

opencode_probe_cf() {
  local model="${1}"
  opencode_probe_openai_compat \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1" \
    "${CLOUDFLARE_API_TOKEN}" "${model}"
}

opencode_probe_zen() {
  local model="${1}"
  opencode_probe_openai_compat "https://opencode.ai/zen/v1" "${OPENCODE_API_KEY}" "${model}"
}

opencode_probe_anthropic() {
  local model="${1}"
  curl -sf --max-time 15 -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
    > /dev/null 2>&1
}

opencode_probe_google() {
  local model="${1}" key="${2}"
  curl -sf --max-time 15 -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
    -H "x-goog-api-key: ${key}" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"parts":[{"text":"ping"}]}]}' \
    > /dev/null 2>&1
}

# Provider table for colon-prefixed chain entries, one per line:
#   <prefix>|<provider id>|<probe spec>|<env spec>
# probe spec: an OpenAI-compatible base URL, or a bespoke kind
#   (anthropic|google). env spec: '~' separates alternatives, '+' joins
#   vars that must all be set. The bearer key for the generic probe is the
#   last '+'-joined var of the satisfied alternative.
opencode_probe_provider_table() {
  cat << 'TABLE'
cf|cloudflare-workers-ai|https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1|CLOUDFLARE_ACCOUNT_ID+CLOUDFLARE_API_TOKEN
meta|model_api|https://api.meta.ai/v1|MODEL_API_KEY
model_api|model_api|https://api.meta.ai/v1|MODEL_API_KEY
cloudflare-workers-ai|cloudflare-workers-ai|https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1|CLOUDFLARE_ACCOUNT_ID+CLOUDFLARE_API_TOKEN
zen|opencode|https://opencode.ai/zen/v1|OPENCODE_API_KEY
opencode|opencode|https://opencode.ai/zen/v1|OPENCODE_API_KEY
zengo|opencode-go|https://opencode.ai/zen/go/v1|OPENCODE_API_KEY
opencode-go|opencode-go|https://opencode.ai/zen/go/v1|OPENCODE_API_KEY
anthropic|anthropic|anthropic|ANTHROPIC_API_KEY
claude|anthropic|anthropic|ANTHROPIC_API_KEY
google|google|google|GOOGLE_GENERATIVE_AI_API_KEY~GEMINI_API_KEY~GOOGLE_API_KEY
gemini|google|google|GOOGLE_GENERATIVE_AI_API_KEY~GEMINI_API_KEY~GOOGLE_API_KEY
openai|openai|https://api.openai.com/v1|OPENAI_API_KEY
openrouter|openrouter|https://openrouter.ai/api/v1|OPENROUTER_API_KEY
groq|groq|https://api.groq.com/openai/v1|GROQ_API_KEY
mistral|mistral|https://api.mistral.ai/v1|MISTRAL_API_KEY
deepseek|deepseek|https://api.deepseek.com|DEEPSEEK_API_KEY
xai|xai|https://api.x.ai/v1|XAI_API_KEY
cerebras|cerebras|https://api.cerebras.ai/v1|CEREBRAS_API_KEY
moonshotai|moonshotai|https://api.moonshot.ai/v1|MOONSHOT_API_KEY
moonshot|moonshotai|https://api.moonshot.ai/v1|MOONSHOT_API_KEY
copilot|github-copilot|https://api.githubcopilot.com|GITHUB_TOKEN
github-copilot|github-copilot|https://api.githubcopilot.com|GITHUB_TOKEN
TABLE
}

# Print "<provider>\t<spec>\t<envs>" for a chain-entry prefix, nothing when the
# prefix is unknown.
opencode_probe_lookup() {
  local prefix="${1}"
  opencode_probe_provider_table | awk -F'|' -v p="${prefix}" \
    '$1 == p { print $2 "\t" $3 "\t" $4; found=1; exit } END { exit !found }'
}

# True when an env spec is satisfied: at least one '~' alternative whose every
# '+'-joined var is set.
opencode_probe_env_ok() {
  local envs="${1}" alt var ok
  local -a alts vars
  IFS='~' read -r -a alts <<< "${envs}"
  for alt in "${alts[@]}"; do
    IFS='+' read -r -a vars <<< "${alt}"
    ok=0
    for var in "${vars[@]}"; do
      [[ -n "${!var:-}" ]] || {
        ok=1
        break
      }
    done
    [[ "${ok}" -eq 0 ]] && return 0
  done
  return 1
}

# Bearer key for a satisfied env spec: the last '+'-joined var of the first
# satisfied alternative (for CLOUDFLARE that is CLOUDFLARE_API_TOKEN, not the
# account id). Prints nothing when no alternative is satisfied.
opencode_probe_env_key() {
  local envs="${1}" alt var ok last
  local -a alts vars
  IFS='~' read -r -a alts <<< "${envs}"
  for alt in "${alts[@]}"; do
    IFS='+' read -r -a vars <<< "${alt}"
    ok=0
    for var in "${vars[@]}"; do
      [[ -n "${!var:-}" ]] || {
        ok=1
        break
      }
    done
    if [[ "${ok}" -eq 0 ]]; then
      last="${vars[$((${#vars[@]} - 1))]}"
      printf '%s' "${!last}"
      return 0
    fi
  done
  return 1
}

# Space-separated "provider:model" pairs that must be registered in the emitted
# config because the provider is custom or the model id is not cataloged:
# cloudflare-workers-ai (@cf/... ids) and model_api (Meta Model API ids).
opencode_probe_custom_models() {
  local chains="${1}" entry pair out=""
  local -a entries
  IFS=',' read -r -a entries <<< "${chains}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    case "${entry}" in
      cf:* | cloudflare-workers-ai:*) pair="cloudflare-workers-ai:${entry#*:}" ;;
      cloudflare-workers-ai/*) pair="cloudflare-workers-ai:${entry#*/}" ;;
      meta:* | model_api:*) pair="model_api:${entry#*:}" ;;
      model_api/*) pair="model_api:${entry#*/}" ;;
      *) continue ;;
    esac
    case " ${out} " in
      *" ${pair} "*) ;;
      *) out+="${out:+ }${pair}" ;;
    esac
  done
  printf '%s' "${out}"
}

# Instruction entries for the emitted config. A repository that ships its own
# .opencode/github-commands.md wins; otherwise the bundled runbook is referenced
# by absolute path so nothing is written into the workspace (an injected file
# could otherwise end up committed by the agent). "github-commands.md" is
# always included alongside the bundled runbook: in review-only mode relative
# instructions resolve under the installed global config dir, where the bundled
# runbook is placed. With use-bundled-toolkit disabled, only a repository's own
# runbook is referenced.
opencode_probe_instructions() {
  local workspace="${1:-}" action_path="${2:-}" bundled_toolkit="${3:-true}"
  if [[ -n "${workspace}" && -f "${workspace}/.opencode/github-commands.md" ]]; then
    printf '.opencode/github-commands.md'
    [[ "${bundled_toolkit}" == "true" ]] && printf ' github-commands.md'
    printf '\n'
  elif [[ "${bundled_toolkit}" == "true" ]]; then
    printf '%s/.opencode/github-commands.md github-commands.md\n' "${action_path}"
  else
    printf '\n'
  fi
}

# Emit the inline config shared by every selection: context7 MCP, the GitHub
# command runbook instructions, and custom provider/model registrations
# (cloudflare-workers-ai and Meta model_api ids). Caller-provided
# OPENCODE_CONFIG_CONTENT is
# used as a merge base when present.
opencode_emit_config() {
  local model="${1}" custom_models="${2:-}" instructions="${3}"
  local base="${OPENCODE_CONFIG_CONTENT:-"{}"}"
  jq -n \
    --arg model "${model}" \
    --arg custom "${custom_models}" \
    --arg instructions "${instructions}" \
    --argjson base "${base}" '
    ($instructions | split(" ") | map(select(length > 0))) as $instr
    | ($custom | split(" ") | map(select(length > 0))
      | map(split(":") | {provider: .[0], model: (.[1:] | join(":"))})) as $pairs
    | (reduce $pairs[] as $p ({};
        .[$p.provider].models[$p.model] =
          (if $p.provider == "model_api" then
            (if $p.model | startswith("muse-ember") then
              {name: "Muse Ember", limit: {context: 1048576, output: 524288}}
            elif $p.model | startswith("muse-spark") then
              {name: "Muse Spark", limit: {context: 1048576, output: 131072}}
            else {name: $p.model, limit: {context: 1048576, output: 131072}} end)
          else {name: $p.model} end))) as $custom_models
    | (if $custom_models["model_api"] then
        $custom_models
        | .["model_api"] = ({
            "npm": "@ai-sdk/openai-compatible",
            "name": "Meta Model API",
            "options": {
              "baseURL": "https://api.meta.ai/v1",
              "apiKey": "{env:MODEL_API_KEY}"
            }
          } + .["model_api"])
      else $custom_models end) as $registered_models
    | ({
        "mcp": {
          "context7": {
            "type": "remote",
            "url": "https://mcp.context7.com/mcp",
            "oauth": false,
            "headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" },
            "enabled": true
          }
        },
        "model": $model
      }
      | if ($registered_models | length) > 0 then
          .provider = $registered_models
        else . end) as $emitted
    | ($base * $emitted)
    | .instructions = ((($base.instructions // []) + $instr) + $instr | unique)
    | . + { "$schema": "https://opencode.ai/config.json" }'
}

_opencode_probe_choose() {
  local model="${1}" custom_models="${2:-}" instructions config_json probe_file
  instructions="$(opencode_probe_instructions \
    "${GITHUB_WORKSPACE:-}" "${ACTION_PATH:-}" "${USE_BUNDLED_TOOLKIT:-true}")"
  config_json="$(opencode_emit_config "${model}" "${custom_models}" "${instructions}")" || {
    echo "::error::Failed to render OpenCode config for model '${model}'."
    exit 1
  }
  probe_file="${RUNNER_TEMP:-$(mktemp -d)}/opencode-probe-config.json"
  printf '%s\n' "${config_json}" > "${probe_file}"
  {
    printf 'model=%s\n' "${model}"
  } >> "${GITHUB_OUTPUT}"
  {
    printf 'OPENCODE_CONFIG_CONTENT<<EOF\n'
    printf '%s\n' "${config_json}"
    printf 'EOF\n'
    printf 'OPENCODE_PROBE_CONFIG_FILE=%s\n' "${probe_file}"
  } >> "${GITHUB_ENV}"
  echo "::notice::Selected model ${model}"
  exit 0
}

# Probe one colon-prefixed chain entry. Prints the selected provider/model on
# stdout on success; warnings go to stderr. Returns nonzero when the prefix is
# unknown, credentials are missing, or the endpoint probe fails.
opencode_probe_entry() {
  local entry="${1}" prefix model row provider spec envs key
  prefix="${entry%%:*}"
  model="${entry#*:}"
  row="$(opencode_probe_lookup "${prefix}")" || {
    echo "::warning::Unrecognized provider prefix '${prefix}:' - skipping" >&2
    return 1
  }
  provider="${row%%$'\t'*}"
  spec="$(cut -f2 <<< "${row}")"
  envs="$(cut -f3 <<< "${row}")"
  if ! opencode_probe_env_ok "${envs}"; then
    echo "::warning::Skipping ${entry} - credentials not set (${envs//~/ or })" >&2
    return 1
  fi
  case "${spec}" in
    anthropic)
      opencode_probe_anthropic "${model}"
      ;;
    google)
      key="$(opencode_probe_env_key "${envs}")"
      opencode_probe_google "${model}" "${key}"
      ;;
    *)
      key="$(opencode_probe_env_key "${envs}")"
      if [[ "${spec}" == *'$'* ]]; then eval "spec=\"${spec}\""; fi
      opencode_probe_openai_compat "${spec}" "${key}" "${model}"
      ;;
  esac || {
    echo "::warning::${entry} unavailable - trying next" >&2
    return 1
  }
  printf '%s/%s' "${provider}" "${model}"
}

_opencode_probe_main() {
  local script_dir chain_kind chain entries entry model custom_models selected
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=scripts/opencode-action-lib.sh
  source "${script_dir}/opencode-action-lib.sh"

  custom_models="$(opencode_probe_custom_models "${MODELS_REVIEW:-},${MODELS_FIX:-}")"

  if [[ -n "${MODEL:-}" ]]; then
    if [[ "${MODEL}" != */* ]]; then
      echo "::error::Invalid model '${MODEL}'. Model must be in the format 'provider/model'."
      exit 1
    fi
    # Register explicit cloudflare-workers-ai and model_api ids on their
    # provider even when they are not part of a probe chain.
    case "${MODEL}" in
      cloudflare-workers-ai/* | model_api/*)
        model="${MODEL%%/*}:${MODEL#*/}"
        case " ${custom_models} " in
          *" ${model} "*) ;;
          *) custom_models+="${custom_models:+ }${model}" ;;
        esac
        ;;
    esac
    echo "::notice::Using explicit model ${MODEL} (probing skipped)"
    _opencode_probe_choose "${MODEL}" "${custom_models}"
  fi

  opencode_effective_prompt "${PROMPT:-}" "${MENTIONS:-}" "${GITHUB_EVENT_PATH:-}"
  if opencode_probe_is_review "${OPENCODE_EFFECTIVE_PROMPT:-}" "${GITHUB_EVENT_NAME:-}"; then
    chain_kind="review"
    chain="${MODELS_REVIEW:-}"
  else
    chain_kind="fix"
    chain="${MODELS_FIX:-}"
  fi
  if [[ -z "${chain}" ]]; then
    echo "::error::No model configured. Set the 'model' input or a 'models-${chain_kind}' probe chain."
    exit 1
  fi
  echo "::notice::Probing ${chain_kind} chain: ${chain}"

  IFS=',' read -r -a entries <<< "${chain}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "${entry}" ]] || continue
    # A colon-prefixed entry has the form <prefix>:<model> where the prefix
    # itself never contains '/'; a bare provider/model stays trusted even when
    # the model id contains ':' (e.g. openrouter's ':free' suffixes).
    if [[ "${entry}" == *:* && "${entry%%:*}" != */* ]]; then
      if selected="$(opencode_probe_entry "${entry}")"; then
        _opencode_probe_choose "${selected}" "${custom_models}"
      fi
    elif [[ "${entry}" == */* ]]; then
      echo "::notice::${entry} is selected without probing"
      _opencode_probe_choose "${entry}" "${custom_models}"
    else
      echo "::warning::Unrecognized chain entry '${entry}' - expected <prefix>:<model> or <provider>/<model>"
    fi
  done

  echo "::error::No model in the ${chain_kind} chain was reachable. Set the 'model' input to select one explicitly."
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_probe_main
fi
