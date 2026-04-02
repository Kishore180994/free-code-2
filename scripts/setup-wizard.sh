#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${CYAN}[*]${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}[+]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${RESET} %s\n" "$*"; }
fail()  { printf "${RED}[x]${RESET} %s\n" "$*"; exit 1; }

ZSHRC="$HOME/.zshrc"
SETTINGS_JSON="$HOME/.claude/settings.json"
CONFIG_START="# >>> free-code config >>>"
CONFIG_END="# <<< free-code config <<<"

# --- Dependency check ---
check_jq() {
  if ! command -v jq &>/dev/null; then
    warn "jq is required but not installed."
    if command -v brew &>/dev/null; then
      read -rp "  Install jq via Homebrew? [Y/n] " yn
      if [[ "${yn:-Y}" =~ ^[Yy]$ ]]; then
        brew install jq
      else
        fail "jq is required. Install it manually: brew install jq"
      fi
    else
      fail "jq is required. Install it: https://jqlang.github.io/jq/download/"
    fi
  fi
}

# --- Detection ---
DETECTED_CODEX=0; DETECTED_ANTHROPIC=0; DETECTED_OPENROUTER=0; DETECTED_OLLAMA=0
CODEX_INFO=""; ANTHROPIC_KEY=""; OPENROUTER_KEY=""; OLLAMA_MODELS=""

detect_codex() {
  [[ -f "$HOME/.codex/auth.json" ]] && DETECTED_CODEX=1 && CODEX_INFO="~/.codex/auth.json"
}

detect_anthropic() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]] && [[ "${ANTHROPIC_API_KEY:-}" == sk-ant-* ]]; then
    DETECTED_ANTHROPIC=1; ANTHROPIC_KEY="$ANTHROPIC_API_KEY"; return
  fi
  if [[ -f "$ZSHRC" ]]; then
    local key; key=$(grep -E '^\s*export\s+ANTHROPIC_API_KEY="sk-ant-' "$ZSHRC" 2>/dev/null | head -1 | sed 's/.*="//' | sed 's/".*//' || true)
    [[ -n "$key" ]] && DETECTED_ANTHROPIC=1 && ANTHROPIC_KEY="$key"
  fi
}

detect_openrouter() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]] && [[ "${OPENROUTER_API_KEY:-}" == sk-or-* ]]; then
    DETECTED_OPENROUTER=1; OPENROUTER_KEY="$OPENROUTER_API_KEY"; return
  fi
  if [[ -f "$ZSHRC" ]]; then
    local key; key=$(grep -E '^\s*export\s+OPENROUTER_API_KEY="sk-or-' "$ZSHRC" 2>/dev/null | head -1 | sed 's/.*="//' | sed 's/".*//' || true)
    [[ -n "$key" ]] && DETECTED_OPENROUTER=1 && OPENROUTER_KEY="$key"
  fi
}

detect_ollama() {
  if curl -s --max-time 2 http://localhost:11434/api/tags &>/dev/null; then
    DETECTED_OLLAMA=1
    OLLAMA_MODELS=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null | jq -r '.models[].name' 2>/dev/null || true)
  fi
}

mask_key() {
  local key="$1"
  [[ ${#key} -gt 12 ]] && echo "${key:0:10}...${key: -4}" || echo "****"
}

# --- Banner ---
print_banner() {
  printf "\n${BOLD}${CYAN}"
  cat << 'ART'
   ___                            _
  / _|_ __ ___  ___        ___ __| | ___
 | |_| '__/ _ \/ _ \_____ / __/ _` |/ _ \
 |  _| | |  __/  __/_____| (_| (_| |  __/
 |_| |_|  \___|\___|      \___\__,_|\___|
ART
  printf "${RESET}\n"
  printf "  ${BOLD}Setup Wizard${RESET} — Configure your AI provider\n\n"
}

# --- Show detected ---
show_detected() {
  printf "  ${BOLD}Detected Providers:${RESET}\n"
  local found=0
  if [[ $DETECTED_CODEX -eq 1 ]]; then
    printf "  ${GREEN}✓${RESET} ${BOLD}Codex${RESET} (GPT-5.4) — ${DIM}${CODEX_INFO}${RESET}\n"; found=1
  fi
  if [[ $DETECTED_ANTHROPIC -eq 1 ]]; then
    printf "  ${GREEN}✓${RESET} ${BOLD}Anthropic Claude${RESET} — ${DIM}$(mask_key "$ANTHROPIC_KEY")${RESET}\n"; found=1
  fi
  if [[ $DETECTED_OPENROUTER -eq 1 ]]; then
    printf "  ${GREEN}✓${RESET} ${BOLD}OpenRouter${RESET} — ${DIM}$(mask_key "$OPENROUTER_KEY")${RESET}\n"; found=1
  fi
  if [[ $DETECTED_OLLAMA -eq 1 ]]; then
    local count; count=$(echo "$OLLAMA_MODELS" | grep -c . 2>/dev/null || echo 0)
    printf "  ${GREEN}✓${RESET} ${BOLD}Ollama${RESET} (local) — ${DIM}${count} models${RESET}\n"; found=1
  fi
  [[ $found -eq 0 ]] && printf "  ${DIM}  No existing providers detected${RESET}\n"
  echo ""
}

# --- Menu ---
show_menu() {
  printf "  ${BOLD}Choose a provider:${RESET}\n\n"
  printf "  ${CYAN}1${RESET})  Anthropic Claude ${DIM}(requires API key — best quality)${RESET}\n"
  printf "  ${CYAN}2${RESET})  OpenRouter Free ${DIM}(qwen3-coder, nemotron — free, rate-limited)${RESET}\n"
  printf "  ${CYAN}3${RESET})  OpenRouter Paid ${DIM}(near-free, no rate limits — recommended)${RESET}\n"
  printf "  ${CYAN}4${RESET})  Codex ${DIM}(GPT-5.4 via ChatGPT auth)${RESET}\n"
  printf "  ${CYAN}5${RESET})  Ollama ${DIM}(local models, fully offline)${RESET}\n"
  echo ""
  while true; do
    read -rp "  Select [1-5]: " choice
    case "$choice" in 1|2|3|4|5) break ;; *) printf "  ${RED}Enter 1-5.${RESET}\n" ;; esac
  done
}

# --- Key prompts ---
get_openrouter_key() {
  if [[ $DETECTED_OPENROUTER -eq 1 ]]; then
    printf "\n  Found OpenRouter key: ${DIM}$(mask_key "$OPENROUTER_KEY")${RESET}\n"
    read -rp "  Use this key? [Y/n] " yn
    [[ "${yn:-Y}" =~ ^[Yy]$ ]] && return
  fi
  echo ""
  info "Get a free key at: ${BOLD}https://openrouter.ai/keys${RESET}"
  while true; do
    read -rp "  OpenRouter API key: " OPENROUTER_KEY
    [[ "$OPENROUTER_KEY" == sk-or-* ]] && break
    printf "  ${RED}Key should start with sk-or-v1-...${RESET}\n"
  done
}

get_anthropic_key() {
  if [[ $DETECTED_ANTHROPIC -eq 1 ]]; then
    printf "\n  Found Anthropic key: ${DIM}$(mask_key "$ANTHROPIC_KEY")${RESET}\n"
    read -rp "  Use this key? [Y/n] " yn
    [[ "${yn:-Y}" =~ ^[Yy]$ ]] && return
  fi
  echo ""
  info "Get a key at: ${BOLD}https://console.anthropic.com/settings/keys${RESET}"
  while true; do
    read -rp "  Anthropic API key: " ANTHROPIC_KEY
    [[ -n "$ANTHROPIC_KEY" ]] && break
    printf "  ${RED}Key cannot be empty.${RESET}\n"
  done
}

# --- Model fetching ---
MODELS_JSON=""

fetch_free_models() {
  info "Fetching free models from OpenRouter..."
  MODELS_JSON=$(curl -s --max-time 15 "https://openrouter.ai/api/v1/models" 2>/dev/null | \
    jq '[.data[] | select(.pricing.prompt == "0" and .pricing.completion == "0" and .context_length >= 65000) | {id: .id, ctx: .context_length}] | sort_by(-.ctx) | .[0:20]' 2>/dev/null || echo "[]")
  if [[ "$MODELS_JSON" == "[]" ]] || [[ -z "$MODELS_JSON" ]]; then
    warn "Could not fetch models. Using defaults."
    MODELS_JSON='[{"id":"qwen/qwen3-coder:free","ctx":262000},{"id":"nvidia/nemotron-3-super-120b-a12b:free","ctx":262144},{"id":"qwen/qwen3.6-plus-preview:free","ctx":1000000},{"id":"openai/gpt-oss-120b:free","ctx":131072},{"id":"stepfun/step-3.5-flash:free","ctx":256000},{"id":"z-ai/glm-4.5-air:free","ctx":131072}]'
  fi
}

fetch_paid_models() {
  info "Fetching near-free models from OpenRouter..."
  MODELS_JSON=$(curl -s --max-time 15 "https://openrouter.ai/api/v1/models" 2>/dev/null | \
    jq '[.data[] | select((.pricing.prompt | tonumber) > 0 and (.pricing.prompt | tonumber) < 0.000002 and .context_length >= 100000) | {id: .id, ctx: .context_length, cost_in: (.pricing.prompt | tonumber * 1000000 | . * 100 | round / 100), cost_out: (.pricing.completion | tonumber * 1000000 | . * 100 | round / 100)}] | sort_by(.cost_in) | .[0:20]' 2>/dev/null || echo "[]")
  if [[ "$MODELS_JSON" == "[]" ]] || [[ -z "$MODELS_JSON" ]]; then
    warn "Could not fetch. Using defaults."
    MODELS_JSON='[{"id":"z-ai/glm-4.7-flash","ctx":202752,"cost_in":0.06,"cost_out":0.40},{"id":"z-ai/glm-4-32b","ctx":128000,"cost_in":0.10,"cost_out":0.10},{"id":"z-ai/glm-4.7","ctx":202752,"cost_in":0.39,"cost_out":1.75}]'
  fi
}

display_models_free() {
  local count; count=$(echo "$MODELS_JSON" | jq 'length')
  printf "\n  ${BOLD}Available Free Models:${RESET} ${DIM}(context >= 65K)${RESET}\n\n"
  for i in $(seq 0 $((count - 1))); do
    local id ctx; id=$(echo "$MODELS_JSON" | jq -r ".[$i].id"); ctx=$(echo "$MODELS_JSON" | jq -r ".[$i].ctx")
    printf "  ${CYAN}%2d${RESET})  %-50s ${DIM}%sK ctx${RESET}\n" $((i + 1)) "$id" "$((ctx / 1000))"
  done
  echo ""
}

display_models_paid() {
  local count; count=$(echo "$MODELS_JSON" | jq 'length')
  printf "\n  ${BOLD}Near-Free Models:${RESET} ${DIM}(cost per 1M tokens)${RESET}\n\n"
  for i in $(seq 0 $((count - 1))); do
    local id cost_in cost_out ctx
    id=$(echo "$MODELS_JSON" | jq -r ".[$i].id"); ctx=$(echo "$MODELS_JSON" | jq -r ".[$i].ctx")
    cost_in=$(echo "$MODELS_JSON" | jq -r ".[$i].cost_in"); cost_out=$(echo "$MODELS_JSON" | jq -r ".[$i].cost_out")
    printf "  ${CYAN}%2d${RESET})  %-40s ${GREEN}\$%-6s${RESET}/${YELLOW}\$%-6s${RESET} ${DIM}%sK${RESET}\n" $((i + 1)) "$id" "$cost_in" "$cost_out" "$((ctx / 1000))"
  done
  echo ""
}

PICKED_MODEL=""
pick_model() {
  local label="$1" default="$2"
  local count; count=$(echo "$MODELS_JSON" | jq 'length')
  while true; do
    read -rp "  ${label} [default: ${default}]: " pick
    [[ -z "$pick" ]] && PICKED_MODEL="$default" && return
    if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le "$count" ]]; then
      PICKED_MODEL=$(echo "$MODELS_JSON" | jq -r ".[$((pick - 1))].id"); return
    fi
    [[ "$pick" == */* ]] && PICKED_MODEL="$pick" && return
    printf "  ${RED}Enter a number (1-${count}) or model ID.${RESET}\n"
  done
}

pick_ollama_model() {
  local label="$1"
  if [[ -z "$OLLAMA_MODELS" ]]; then
    read -rp "  ${label} (e.g. qwen3:14b): " PICKED_MODEL; return
  fi
  printf "\n  ${BOLD}Local Ollama Models:${RESET}\n\n"
  local i=1
  while IFS= read -r model; do
    printf "  ${CYAN}%2d${RESET})  %s\n" "$i" "$model"; i=$((i + 1))
  done <<< "$OLLAMA_MODELS"
  echo ""
  local count; count=$(echo "$OLLAMA_MODELS" | grep -c . || echo 0)
  while true; do
    read -rp "  ${label} [1-${count}]: " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le "$count" ]]; then
      PICKED_MODEL=$(echo "$OLLAMA_MODELS" | sed -n "${pick}p"); return
    fi
    [[ -n "$pick" ]] && PICKED_MODEL="$pick" && return
    printf "  ${RED}Enter a number or model name.${RESET}\n"
  done
}

# --- Config builders ---
MAIN_MODEL=""; FAST_MODEL=""; PROVIDER_NAME=""; CONFIG_BLOCK=""

build_anthropic_config() {
  PROVIDER_NAME="Anthropic Claude"
  CONFIG_BLOCK="export ANTHROPIC_API_KEY=\"${ANTHROPIC_KEY}\"
export ANTHROPIC_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_OPUS_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_SONNET_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"${FAST_MODEL}\"
export ANTHROPIC_SMALL_FAST_MODEL=\"${FAST_MODEL}\"
export CLAUDE_CODE_SUBAGENT_MODEL=\"${FAST_MODEL}\""
}

build_openrouter_config() {
  PROVIDER_NAME="OpenRouter"
  CONFIG_BLOCK="export OPENROUTER_API_KEY=\"${OPENROUTER_KEY}\"
export ANTHROPIC_BASE_URL=\"https://openrouter.ai/api\"
export ANTHROPIC_AUTH_TOKEN=\"\$OPENROUTER_API_KEY\"
export ANTHROPIC_API_KEY=\"\$OPENROUTER_API_KEY\"
export ANTHROPIC_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_OPUS_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_SONNET_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"${FAST_MODEL}\"
export ANTHROPIC_SMALL_FAST_MODEL=\"${FAST_MODEL}\"
export CLAUDE_CODE_SUBAGENT_MODEL=\"${FAST_MODEL}\""
}

build_codex_config() {
  PROVIDER_NAME="Codex (GPT-5.4)"
  CONFIG_BLOCK="export CLAUDE_CODE_USE_OPENAI=1
export OPENAI_MODEL=\"${MAIN_MODEL}\""
}

build_ollama_config() {
  PROVIDER_NAME="Ollama (Local)"
  CONFIG_BLOCK="export ANTHROPIC_BASE_URL=\"http://localhost:4000\"
export ANTHROPIC_API_KEY=\"sk-local-dummy\"
export ANTHROPIC_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_OPUS_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_SONNET_MODEL=\"${MAIN_MODEL}\"
export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"${FAST_MODEL}\"
export ANTHROPIC_SMALL_FAST_MODEL=\"${FAST_MODEL}\"
export CLAUDE_CODE_SUBAGENT_MODEL=\"${FAST_MODEL}\""
}

# --- Write ~/.zshrc ---
write_zshrc() {
  [[ ! -f "$ZSHRC" ]] && touch "$ZSHRC"
  local tmp; tmp=$(mktemp)
  local date_str; date_str=$(date +%Y-%m-%d)

  # Remove old config block
  if grep -q "$CONFIG_START" "$ZSHRC" 2>/dev/null; then
    sed "/$CONFIG_START/,/$CONFIG_END/d" "$ZSHRC" > "$tmp"
  else
    cp "$ZSHRC" "$tmp"
  fi

  # Remove any standalone unset line from previous manual setup
  grep -v "^unset ANTHROPIC_BASE_URL.*2>/dev/null" "$tmp" > "${tmp}.clean" 2>/dev/null || cp "$tmp" "${tmp}.clean"
  mv "${tmp}.clean" "$tmp"

  # Append new config
  cat >> "$tmp" << BLOCK

${CONFIG_START}
# Managed by free-code setup wizard. Do not edit manually.
# Provider: ${PROVIDER_NAME}  |  Generated: ${date_str}
# Re-run: free-code --setup  or  ./scripts/setup-wizard.sh
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL CLAUDE_CODE_SUBAGENT_MODEL OPENROUTER_API_KEY CLAUDE_CODE_USE_OPENAI OPENAI_MODEL 2>/dev/null
${CONFIG_BLOCK}
${CONFIG_END}
BLOCK

  mv "$tmp" "$ZSHRC"
  ok "Updated ~/.zshrc"
}

# --- Write ~/.claude/settings.json ---
write_settings() {
  mkdir -p "$HOME/.claude"
  [[ ! -f "$SETTINGS_JSON" ]] && echo '{}' > "$SETTINGS_JSON"
  local tmp; tmp=$(mktemp)

  if [[ "$choice" == "4" ]]; then
    jq 'del(.model) | .env = (.env // {} | del(.ANTHROPIC_MODEL, .ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL, .ANTHROPIC_SMALL_FAST_MODEL, .CLAUDE_CODE_SUBAGENT_MODEL))' "$SETTINGS_JSON" > "$tmp"
  else
    jq --arg main "$MAIN_MODEL" --arg fast "$FAST_MODEL" '
      .model = $main |
      .env = (.env // {} |
        .ANTHROPIC_MODEL = $main |
        .ANTHROPIC_DEFAULT_OPUS_MODEL = $main |
        .ANTHROPIC_DEFAULT_SONNET_MODEL = $main |
        .ANTHROPIC_DEFAULT_HAIKU_MODEL = $fast |
        .ANTHROPIC_SMALL_FAST_MODEL = $fast |
        .CLAUDE_CODE_SUBAGENT_MODEL = $fast
      )
    ' "$SETTINGS_JSON" > "$tmp"
  fi
  mv "$tmp" "$SETTINGS_JSON"
  ok "Updated ~/.claude/settings.json"
}

# --- Summary ---
print_summary() {
  echo ""
  printf "  ${BOLD}${GREEN}Setup Complete!${RESET}\n\n"
  printf "  ${BOLD}Provider:${RESET}    %s\n" "$PROVIDER_NAME"
  printf "  ${BOLD}Main model:${RESET}  %s\n" "$MAIN_MODEL"
  printf "  ${BOLD}Fast model:${RESET}  %s\n" "$FAST_MODEL"
  echo ""
  printf "  ${BOLD}Next steps:${RESET}\n"
  printf "  ${CYAN}▶${RESET} Run ${BOLD}source ~/.zshrc${RESET} or open a new terminal\n"
  printf "  ${CYAN}▶${RESET} Run ${BOLD}free-code${RESET} to start\n"
  if [[ "$choice" == "5" ]]; then
    echo ""
    printf "  ${YELLOW}Start Ollama + LiteLLM first:${RESET}\n"
    printf "  ${CYAN}▶${RESET} ${BOLD}ollama serve &${RESET}\n"
    printf "  ${CYAN}▶${RESET} ${BOLD}litellm --model ollama/${MAIN_MODEL} --port 4000 &${RESET}\n"
  fi
  echo ""
}

# ===== MAIN =====
print_banner
check_jq

info "Detecting providers..."
detect_codex; detect_anthropic; detect_openrouter; detect_ollama
echo ""

show_detected
show_menu

case "$choice" in
  1) # Anthropic
    get_anthropic_key
    printf "\n  ${BOLD}Main model:${RESET}\n"
    printf "  ${CYAN}1${RESET})  claude-sonnet-4-6 ${DIM}(fast, great quality)${RESET}\n"
    printf "  ${CYAN}2${RESET})  claude-opus-4-6 ${DIM}(best quality, slower)${RESET}\n"
    printf "  ${CYAN}3${RESET})  claude-haiku-4-5 ${DIM}(fastest, cheapest)${RESET}\n"
    read -rp "  Select [1]: " mp
    case "${mp:-1}" in 2) MAIN_MODEL="claude-opus-4-6" ;; 3) MAIN_MODEL="claude-haiku-4-5" ;; *) MAIN_MODEL="claude-sonnet-4-6" ;; esac
    printf "\n  ${BOLD}Fast model:${RESET}\n"
    printf "  ${CYAN}1${RESET})  claude-haiku-4-5 ${DIM}(recommended)${RESET}\n"
    printf "  ${CYAN}2${RESET})  claude-sonnet-4-6\n"
    read -rp "  Select [1]: " fp
    case "${fp:-1}" in 2) FAST_MODEL="claude-sonnet-4-6" ;; *) FAST_MODEL="claude-haiku-4-5" ;; esac
    build_anthropic_config ;;

  2) # OpenRouter Free
    get_openrouter_key; fetch_free_models; display_models_free
    pick_model "Main model" "qwen/qwen3-coder:free"; MAIN_MODEL="$PICKED_MODEL"; ok "Main: $MAIN_MODEL"
    echo ""; printf "  ${DIM}Pick fast model or Enter for same:${RESET}\n"
    pick_model "Fast model" "$MAIN_MODEL"; FAST_MODEL="$PICKED_MODEL"; ok "Fast: $FAST_MODEL"
    build_openrouter_config ;;

  3) # OpenRouter Paid
    get_openrouter_key; fetch_paid_models; display_models_paid
    pick_model "Main model" "z-ai/glm-4.7-flash"; MAIN_MODEL="$PICKED_MODEL"; ok "Main: $MAIN_MODEL"
    echo ""
    pick_model "Fast model" "z-ai/glm-4.7-flash"; FAST_MODEL="$PICKED_MODEL"; ok "Fast: $FAST_MODEL"
    build_openrouter_config ;;

  4) # Codex
    if [[ $DETECTED_CODEX -eq 0 ]]; then
      warn "Codex auth not found. Install: ${BOLD}npm install -g @openai/codex${RESET}"
      read -rp "  Continue anyway? [y/N] " yn
      [[ ! "${yn:-N}" =~ ^[Yy]$ ]] && exit 0
    else
      ok "Codex auth found"
    fi
    printf "\n  ${BOLD}Codex model:${RESET}\n"
    printf "  ${CYAN}1${RESET})  codexplan ${DIM}(GPT-5.4 high reasoning)${RESET}\n"
    printf "  ${CYAN}2${RESET})  codexspark ${DIM}(GPT-5.3 faster)${RESET}\n"
    read -rp "  Select [1]: " cp
    case "${cp:-1}" in 2) MAIN_MODEL="codexspark"; FAST_MODEL="codexspark" ;; *) MAIN_MODEL="codexplan"; FAST_MODEL="codexspark" ;; esac
    build_codex_config ;;

  5) # Ollama
    if [[ $DETECTED_OLLAMA -eq 0 ]]; then
      warn "Ollama not running. Start: ${BOLD}ollama serve &${RESET}"
      read -rp "  Continue anyway? [y/N] " yn
      [[ ! "${yn:-N}" =~ ^[Yy]$ ]] && exit 0
    fi
    if ! command -v litellm &>/dev/null; then
      warn "LiteLLM required (translates Anthropic API → Ollama)."
      read -rp "  Install LiteLLM? [Y/n] " yn
      [[ "${yn:-Y}" =~ ^[Yy]$ ]] && { pip install "litellm[proxy]" || fail "Install failed"; ok "LiteLLM installed"; }
    else ok "LiteLLM found"; fi
    pick_ollama_model "Main model"; MAIN_MODEL="$PICKED_MODEL"; ok "Main: $MAIN_MODEL"
    echo ""; pick_ollama_model "Fast model"; FAST_MODEL="$PICKED_MODEL"; ok "Fast: $FAST_MODEL"
    build_ollama_config ;;
esac

echo ""
info "Writing configuration..."
write_zshrc
write_settings
print_summary
