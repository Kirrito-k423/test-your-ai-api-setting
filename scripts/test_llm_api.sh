#!/usr/bin/env bash
set -u

ENV_FILE="${1:-.env}"
NETWORK_FAILURES=0
API_WARNINGS=0
PASSED=0
SKIPPED=0

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[FAIL] Missing required command: $1"
    exit 2
  fi
}

normalize_v1_base() {
  local base="${1%/}"
  if [[ "$base" =~ /v[0-9]+$ ]]; then
    printf "%s" "$base"
  else
    printf "%s/v1" "$base"
  fi
}

print_snippet() {
  local file="$1"
  local snippet
  snippet="$(tr '\n' ' ' < "$file" | sed 's/[[:space:]]\+/ /g' | head -c 280)"
  printf "%s" "$snippet"
}

print_hint_if_known() {
  local name="$1"
  local base_url="$2"
  local response_file="$3"

  if grep -qi 'SETTLEMENT_UNKNOWN_MODEL\|Settlement blocked' "$response_file"; then
    echo "       hint: network is reachable; this is a provider-side model/billing mapping issue."
    echo "       hint: check supported models in your account dashboard and active plan status."
    return
  fi

  if grep -qi 'invalid api key' "$response_file" && [[ "$base_url" == *"api.minimax.io"* ]]; then
    echo "       hint: this key may belong to Token Plan CN endpoint."
    echo "       hint: try MINIMAX_BASE_URL=https://api.minimaxi.com"
  fi

  if grep -qi 'model_not_found\|unknown model' "$response_file"; then
    echo "       hint: model may be unavailable for this provider/account."
  fi
}

test_openai_compatible_models() {
  local name="$1"
  local base_url="$2"
  local api_key="$3"

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    echo "[SKIP] $name: missing base url or api key."
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  local v1_base
  v1_base="$(normalize_v1_base "$base_url")"
  local url="$v1_base/models"
  local response_file
  response_file="$(mktemp)"

  local http_code
  http_code="$(
    curl -sS \
      --connect-timeout 10 \
      --max-time 35 \
      -o "$response_file" \
      -w "%{http_code}" \
      -H "Authorization: Bearer $api_key" \
      "$url"
  )"
  local curl_exit=$?

  if [[ $curl_exit -ne 0 ]]; then
    echo "[FAIL] $name: network error when calling $url"
    NETWORK_FAILURES=$((NETWORK_FAILURES + 1))
    rm -f "$response_file"
    return 1
  fi

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && grep -q '"data"' "$response_file"; then
    echo "[PASS] $name: HTTP $http_code, models endpoint reachable."
    PASSED=$((PASSED + 1))
  else
    echo "[WARN] $name: HTTP $http_code (endpoint reachable, API rejected request)."
    echo "       response: $(print_snippet "$response_file")"
    print_hint_if_known "$name" "$base_url" "$response_file"
    API_WARNINGS=$((API_WARNINGS + 1))
  fi

  rm -f "$response_file"
}

test_openai_compatible_chat() {
  local name="$1"
  local base_url="$2"
  local api_key="$3"
  local model="$4"

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    echo "[SKIP] $name: missing base url or api key."
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [[ -z "$model" ]]; then
    echo "[SKIP] $name: missing model."
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  local v1_base
  v1_base="$(normalize_v1_base "$base_url")"
  local url="$v1_base/chat/completions"
  local response_file
  response_file="$(mktemp)"

  local payload
  payload="$(cat <<EOF
{"model":"$model","messages":[{"role":"user","content":"ping"}],"max_tokens":16}
EOF
)"

  local http_code
  http_code="$(
    curl -sS \
      --connect-timeout 10 \
      --max-time 35 \
      -o "$response_file" \
      -w "%{http_code}" \
      -H "Authorization: Bearer $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$url"
  )"
  local curl_exit=$?

  if [[ $curl_exit -ne 0 ]]; then
    echo "[FAIL] $name: network error when calling $url"
    NETWORK_FAILURES=$((NETWORK_FAILURES + 1))
    rm -f "$response_file"
    return 1
  fi

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && grep -Eq '"choices"|"id"' "$response_file"; then
    echo "[PASS] $name: HTTP $http_code, chat completion endpoint reachable."
    PASSED=$((PASSED + 1))
  else
    echo "[WARN] $name: HTTP $http_code (endpoint reachable, API rejected request)."
    echo "       response: $(print_snippet "$response_file")"
    print_hint_if_known "$name" "$base_url" "$response_file"
    API_WARNINGS=$((API_WARNINGS + 1))
  fi

  rm -f "$response_file"
}

require_cmd curl

echo "Running LLM API connectivity checks..."
echo
test_openai_compatible_chat \
  "AICodeMirror(Chat Completions)" \
  "${AICM_BASE_URL:-}" \
  "${AICM_API_KEY:-}" \
  "${AICM_MODEL:-gpt-5.3-codex}"
test_openai_compatible_models \
  "MiniMax(OpenAI-Compatible)" \
  "${MINIMAX_BASE_URL:-https://api.minimaxi.com}" \
  "${MINIMAX_API_KEY:-}"

echo
echo "Summary: pass=$PASSED warn=$API_WARNINGS network_fail=$NETWORK_FAILURES skip=$SKIPPED"

if [[ "$NETWORK_FAILURES" -eq 0 ]]; then
  echo "Network connectivity check passed."
  if [[ "$API_WARNINGS" -gt 0 ]]; then
    echo "There are API-level warnings (key/model/plan), but network path is reachable."
  fi
  exit 0
fi

echo "Network connectivity check failed: $NETWORK_FAILURES endpoint(s) unreachable."
exit 1
