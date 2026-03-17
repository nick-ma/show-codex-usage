#!/usr/bin/env bash
set -euo pipefail

VERSION="1.1.1"

CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$HOME/.codex/auth.json}"

MODE="show"
AUTH_FILE="$HOME/.codex/auth-poll.json"

if [[ $# -ge 1 ]]; then
  case "$1" in
    version|--version|-v)
      printf "%s\n" "$VERSION"
      exit 0
      ;;
    switch)
      MODE="switch"
      shift
      ;;
    show)
      MODE="show"
      shift
      ;;
  esac
fi

if [[ $# -ge 1 ]]; then
  AUTH_FILE="$1"
fi

POOL_FILE="$AUTH_FILE"
USAGE_URL="https://chatgpt.com/backend-api/wham/usage"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
REVERSE='\033[7m'

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

cleanup() {
  [[ -n "${TMP_UPSERT_FILE:-}" && -f "${TMP_UPSERT_FILE:-}" ]] && rm -f "$TMP_UPSERT_FILE"
  [[ -n "${RESULTS_FILE:-}" && -f "${RESULTS_FILE:-}" ]] && rm -f "$RESULTS_FILE"
}
trap cleanup EXIT

get_auth_mode() {
  jq -r '.auth_mode // "apikey"' <<<"$1"
}

get_auth_identity() {
  local raw="$1"
  local mode
  mode="$(get_auth_mode "$raw")"

  case "$mode" in
    chatgpt)
      jq -r '.tokens.account_id // empty' <<<"$raw"
      ;;
    apikey)
      jq -r '.OPENAI_API_KEY // empty' <<<"$raw"
      ;;
    *)
      echo ""
      ;;
  esac
}

get_auth_label() {
  local raw="$1"
  local mode
  mode="$(get_auth_mode "$raw")"

  case "$mode" in
    chatgpt)
      jq -r '.tokens.account_id // "unknown-account"' <<<"$raw"
      ;;
    apikey)
      local key
      key="$(jq -r '.OPENAI_API_KEY // ""' <<<"$raw")"
      if [[ -z "$key" ]]; then
        echo "unknown-apikey"
      else
        printf "apikey:%s...%s" "${key:0:8}" "${key: -4}"
      fi
      ;;
    *)
      echo "unknown-auth"
      ;;
  esac
}

is_current_auth() {
  local raw="$1"
  local id
  id="$(get_auth_identity "$raw")"
  [[ -n "$id" && "$id" == "$CURRENT_AUTH_IDENTITY" ]]
}

validate_current_auth_file() {
  jq -e '
    type == "object"
    and (
      (
        (.auth_mode // "apikey") == "chatgpt"
        and .tokens
        and .tokens.account_id
        and (.tokens.account_id | type == "string")
        and (.tokens.account_id | length > 0)
      )
      or
      (
        (.auth_mode // "apikey") == "apikey"
        and .OPENAI_API_KEY
        and (.OPENAI_API_KEY | type == "string")
        and (.OPENAI_API_KEY | length > 0)
      )
    )
  ' "$CURRENT_AUTH_FILE" > /dev/null
}

if [[ ! -f "$CURRENT_AUTH_FILE" ]]; then
  echo "Error: current auth file not found: $CURRENT_AUTH_FILE" >&2
  exit 1
fi

if [[ ! -f "$POOL_FILE" ]]; then
  echo '[]' > "$POOL_FILE"
fi

validate_current_auth_file
jq -e 'type == "array"' "$POOL_FILE" > /dev/null

TMP_UPSERT_FILE="$(mktemp)"

jq --slurpfile new_auth "$CURRENT_AUTH_FILE" '
  def auth_identity($a):
    if (($a.auth_mode // "apikey")) == "chatgpt" then
      ($a.tokens.account_id // "")
    elif (($a.auth_mode // "apikey")) == "apikey" then
      ($a.OPENAI_API_KEY // "")
    else
      ""
    end;

  . as $pool
  | $new_auth[0] as $new
  | auth_identity($new) as $new_id
  | if ($new_id | length) == 0 then
      .
    elif any($pool[]?; auth_identity(.) == $new_id) then
      map(
        if auth_identity(.) == $new_id
        then $new
        else .
        end
      )
    else
      . + [$new]
    end
' "$POOL_FILE" > "$TMP_UPSERT_FILE"

mv "$TMP_UPSERT_FILE" "$POOL_FILE"
unset TMP_UPSERT_FILE

CURRENT_AUTH_RAW="$(cat "$CURRENT_AUTH_FILE")"
CURRENT_AUTH_MODE="$(get_auth_mode "$CURRENT_AUTH_RAW")"
CURRENT_AUTH_IDENTITY="$(get_auth_identity "$CURRENT_AUTH_RAW")"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Error: auth pool file not found: $AUTH_FILE" >&2
  exit 1
fi

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

parse_to_epoch() {
  local value="${1:-}"

  [[ -z "$value" || "$value" == "null" ]] && return 1

  if is_number "$value"; then
    echo "$value"
    return 0
  fi

  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s
    return 0
  fi

  if date -u -d "$value" +%s >/dev/null 2>&1; then
    date -u -d "$value" +%s
    return 0
  fi

  return 1
}

format_abs_time() {
  local epoch="$1"

  if date -u -r "$epoch" "+%Y-%m-%d %H:%M UTC" >/dev/null 2>&1; then
    date -u -r "$epoch" "+%Y-%m-%d %H:%M UTC"
    return 0
  fi

  if date -u -d "@$epoch" "+%Y-%m-%d %H:%M UTC" >/dev/null 2>&1; then
    date -u -d "@$epoch" "+%Y-%m-%d %H:%M UTC"
    return 0
  fi

  echo "$epoch"
}

format_relative_time() {
  local epoch="$1"
  local now diff sign days hours mins

  now="$(date -u +%s)"
  diff=$(( epoch - now ))
  sign=""

  if (( diff < 0 )); then
    diff=$(( -diff ))
    sign="-"
  fi

  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  mins=$(( (diff % 3600) / 60 ))

  if (( days > 0 )); then
    echo "${sign}${days}d ${hours}hr"
  elif (( hours > 0 )); then
    echo "${sign}${hours}hr ${mins}m"
  else
    echo "${sign}${mins}m"
  fi
}

format_reset_at() {
  local raw="${1:-}"
  local epoch abs rel

  if ! epoch="$(parse_to_epoch "$raw")"; then
    echo "-"
    return
  fi

  abs="$(format_abs_time "$epoch")"
  rel="$(format_relative_time "$epoch")"
  echo "${rel} (${abs})"
}

remaining_percent() {
  local used="${1:-}"

  if [[ -z "$used" || "$used" == "null" || "$used" == "-" ]]; then
    echo "-"
    return
  fi

  if ! [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "-"
    return
  fi

  awk -v u="$used" 'BEGIN {
    r = 100 - u
    if (r < 0) r = 0
    if (r == int(r)) printf "%d", r
    else printf "%.1f", r
  }'
}

colorize_remaining() {
  local val="${1:-}"

  if [[ -z "$val" || "$val" == "-" ]]; then
    printf "%s" "$val"
    return
  fi

  if ! [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%s" "$val"
    return
  fi

  awk -v v="$val" -v red="$RED" -v yellow="$YELLOW" -v green="$GREEN" -v reset="$RESET" '
    BEGIN {
      if (v <= 10)      printf "%s%s%%%s", red, v, reset;
      else if (v <= 25) printf "%s%s%%%s", yellow, v, reset;
      else              printf "%s%s%%%s", green, v, reset;
    }
  '
}

http_error_text() {
  local code="${1:-}"
  case "$code" in
    401) echo "HTTP 401 Unauthorized" ;;
    403) echo "HTTP 403 Forbidden" ;;
    404) echo "HTTP 404 Not Found" ;;
    429) echo "HTTP 429 Too Many Requests" ;;
    500) echo "HTTP 500 Internal Server Error" ;;
    502) echo "HTTP 502 Bad Gateway" ;;
    503) echo "HTTP 503 Service Unavailable" ;;
    *) echo "HTTP $code" ;;
  esac
}

fetch_usage_for_account() {
  local raw_account="$1"
  local auth_mode identity display_name is_current
  local access_token account_id email plan_type limit_reached
  local primary_used primary_reset secondary_used secondary_reset
  local primary_remaining secondary_remaining
  local primary_reset_fmt secondary_reset_fmt
  local primary_remaining_num
  local response_body http_code tmp_body

  auth_mode="$(get_auth_mode "$raw_account")"
  identity="$(get_auth_identity "$raw_account")"
  display_name="$(get_auth_label "$raw_account")"
  is_current="false"
  is_current_auth "$raw_account" && is_current="true"

  if [[ "$auth_mode" == "apikey" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$display_name" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "apikey",
        limit_reached: "n/a",
        primary_remaining_num: 9998,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "usage check skipped for apikey auth",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  access_token="$(jq -r '.tokens.access_token // empty' <<<"$raw_account")"
  account_id="$(jq -r '.tokens.account_id // "unknown-account"' <<<"$raw_account")"

  if [[ -z "$access_token" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "missing access_token",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  tmp_body="$(mktemp)"
  http_code="$(
    curl -sS \
      -o "$tmp_body" \
      -w '%{http_code}' \
      "$USAGE_URL" \
      -H 'accept: */*' \
      -H 'accept-language: en-GB,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,en-US;q=0.6,ja;q=0.5' \
      -H "authorization: Bearer $access_token" \
      -H 'priority: u=1, i' \
      -H 'referer: https://chatgpt.com/codex/settings/usage' \
      -H 'sec-ch-ua: "Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"' \
      -H 'sec-ch-ua-arch: "arm"' \
      -H 'sec-ch-ua-bitness: "64"' \
      -H 'sec-ch-ua-full-version: "146.0.7680.80"' \
      -H 'sec-ch-ua-full-version-list: "Chromium";v="146.0.7680.80", "Not-A.Brand";v="24.0.0.0", "Google Chrome";v="146.0.7680.80"' \
      -H 'sec-ch-ua-mobile: ?0' \
      -H 'sec-ch-ua-model: ""' \
      -H 'sec-ch-ua-platform: "macOS"' \
      -H 'sec-ch-ua-platform-version: "26.3.1"' \
      -H 'sec-fetch-dest: empty' \
      -H 'sec-fetch-mode: cors' \
      -H 'sec-fetch-site: same-origin' \
      -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
      -H 'x-openai-target-path: /backend-api/wham/usage' \
      || echo "000"
  )"
  response_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body"

  if [[ "$http_code" != "200" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg query_error "$(http_error_text "$http_code")" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: $query_error,
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  if [[ -z "$response_body" ]] || ! jq -e . >/dev/null 2>&1 <<<"$response_body"; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg identity "$identity" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        identity: $identity,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "invalid response body",
        raw_auth: ($raw_auth | fromjson)
      }'
    return
  fi

  email="$(jq -r '
    .email //
    .account.email //
    .user.email //
    .viewer.email //
    .account_email //
    "unknown"
  ' <<<"$response_body")"

  plan_type="$(jq -r '
    .plan_type //
    .account.plan_type //
    .subscription.plan_type //
    .plan.type //
    "unknown"
  ' <<<"$response_body")"

  limit_reached="$(jq -r '
    .rate_limit.limit_reached //
    .limit_reached //
    false
  ' <<<"$response_body")"

  primary_used="$(jq -r '
    .rate_limit.primary_window.used_percent //
    .primary_window.used_percent //
    "-"
  ' <<<"$response_body")"

  primary_reset="$(jq -r '
    .rate_limit.primary_window.reset_at //
    .primary_window.reset_at //
    empty
  ' <<<"$response_body")"

  secondary_used="$(jq -r '
    .rate_limit.secondary_window.used_percent //
    .secondary_window.used_percent //
    "-"
  ' <<<"$response_body")"

  secondary_reset="$(jq -r '
    .rate_limit.secondary_window.reset_at //
    .secondary_window.reset_at //
    empty
  ' <<<"$response_body")"

  primary_remaining="$(remaining_percent "$primary_used")"
  secondary_remaining="$(remaining_percent "$secondary_used")"
  primary_reset_fmt="$(format_reset_at "$primary_reset")"
  secondary_reset_fmt="$(format_reset_at "$secondary_reset")"

  primary_remaining_num="$primary_remaining"
  if [[ "$primary_remaining_num" == "-" || -z "$primary_remaining_num" ]]; then
    primary_remaining_num="9999"
  fi

  jq -n \
    --arg auth_mode "$auth_mode" \
    --arg account_id "$account_id" \
    --arg identity "$identity" \
    --arg is_current "$is_current" \
    --arg email "$email" \
    --arg plan_type "$plan_type" \
    --arg limit_reached "$limit_reached" \
    --arg primary_remaining "$primary_remaining" \
    --arg primary_remaining_num "$primary_remaining_num" \
    --arg primary_reset_fmt "$primary_reset_fmt" \
    --arg secondary_remaining "$secondary_remaining" \
    --arg secondary_reset_fmt "$secondary_reset_fmt" \
    --arg raw_auth "$(jq -c . <<<"$raw_account")" \
    '{
      auth_mode: $auth_mode,
      account_id: $account_id,
      identity: $identity,
      is_current: ($is_current == "true"),
      email: $email,
      plan_type: $plan_type,
      limit_reached: $limit_reached,
      primary_remaining_num: ($primary_remaining_num | tonumber),
      primary_remaining: $primary_remaining,
      primary_reset_fmt: $primary_reset_fmt,
      secondary_remaining: $secondary_remaining,
      secondary_reset_fmt: $secondary_reset_fmt,
      raw_auth: ($raw_auth | fromjson)
    }'
}

build_results() {
  RESULTS_FILE="$(mktemp)"
  jq -c '.[]' "$AUTH_FILE" | while IFS= read -r account; do
    fetch_usage_for_account "$account" >> "$RESULTS_FILE"
    echo >> "$RESULTS_FILE"
  done
}

sort_results_to_json() {
  jq -s 'sort_by((if .is_current then 0 else 1 end), .primary_remaining_num, .email)' "$RESULTS_FILE"
}

render_show_mode() {
  printf "${DIM}Codex usage from: %s${RESET}\n" "$AUTH_FILE"
  printf "${DIM}Current auth: %s${RESET}\n\n" "$CURRENT_AUTH_FILE"

  sort_results_to_json | jq -c '.[]' | while IFS= read -r item; do
    local email plan_type limit_reached primary_remaining primary_reset_fmt
    local secondary_remaining secondary_reset_fmt is_current query_error
    local primary_remaining_colored secondary_remaining_colored auth_mode

    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    primary_remaining="$(jq -r '.primary_remaining' <<<"$item")"
    primary_reset_fmt="$(jq -r '.primary_reset_fmt' <<<"$item")"
    secondary_remaining="$(jq -r '.secondary_remaining' <<<"$item")"
    secondary_reset_fmt="$(jq -r '.secondary_reset_fmt' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    query_error="$(jq -r '.query_error // empty' <<<"$item")"
    auth_mode="$(jq -r '.auth_mode // "apikey"' <<<"$item")"

    primary_remaining_colored="$(colorize_remaining "$primary_remaining")"
    secondary_remaining_colored="$(colorize_remaining "$secondary_remaining")"

    if [[ "$is_current" == "true" ]]; then
      printf "Account: %s [%s] (%s) ${BOLD}${GREEN}[Current Using]${RESET}" "$email" "$plan_type" "$auth_mode"
    else
      printf "Account: %s [%s] (%s)" "$email" "$plan_type" "$auth_mode"
    fi

    if [[ -n "$query_error" ]]; then
      printf "  ${RED}%s${RESET}\n" "$query_error"
      printf "\n"
      continue
    else
      printf "\n"
    fi

    if [[ "$limit_reached" == "true" ]]; then
      printf "Rate Limit: ${RED}%s${RESET}\n" "$limit_reached"
    else
      printf "Rate Limit: ${GREEN}%s${RESET}\n" "$limit_reached"
    fi

    printf "  5h remaining: %b  reset at: %s\n" "$primary_remaining_colored" "$primary_reset_fmt"
    printf "  1w remaining: %b  reset at: %s\n" "$secondary_remaining_colored" "$secondary_reset_fmt"
    printf "\n"
  done
}

draw_switch_ui() {
  local selected="$1"
  local json="$2"
  local count idx

  count="$(jq 'length' <<<"$json")"

  printf "\033[H\033[J"
  printf "${BOLD}Select account to switch${RESET}  ${DIM}(↑/↓ move, Enter confirm, q quit)${RESET}\n\n"

  for (( idx=0; idx<count; idx++ )); do
    local item email plan_type is_current limit_reached auth_mode
    local p5 p1w qerr line prefix

    item="$(jq -c ".[$idx]" <<<"$json")"
    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    p5="$(jq -r '.primary_remaining' <<<"$item")"
    p1w="$(jq -r '.secondary_remaining' <<<"$item")"
    qerr="$(jq -r '.query_error // empty' <<<"$item")"
    auth_mode="$(jq -r '.auth_mode // "apikey"' <<<"$item")"

    prefix="  "
    [[ "$idx" -eq "$selected" ]] && prefix="> "

    line="${prefix}${email} [${plan_type}] (${auth_mode})"

    if [[ -n "$qerr" ]]; then
      line="${line}  ${RED}${qerr}${RESET}"
    else
      local p5c p1wc
      p5c="$(colorize_remaining "$p5")"
      p1wc="$(colorize_remaining "$p1w")"

      if [[ "$limit_reached" == "true" ]]; then
        line="${line}  RL:${RED}true${RESET}  5h:${p5c}  1w:${p1wc}"
      else
        line="${line}  RL:${GREEN}false${RESET}  5h:${p5c}  1w:${p1wc}"
      fi
    fi

    if [[ "$is_current" == "true" ]]; then
      line="${line} ${BOLD}${GREEN}[Current Using]${RESET}"
    fi

    if [[ "$idx" -eq "$selected" ]]; then
      printf "${REVERSE}%b${RESET}\n" "$line"
    else
      printf "%b\n" "$line"
    fi
  done

  printf "\n${DIM}Current auth file: %s${RESET}\n" "$CURRENT_AUTH_FILE"
  printf "${DIM}Auth pool file: %s${RESET}\n" "$AUTH_FILE"
}

switch_mode() {
  local sorted_json selected count key item target_label
  sorted_json="$(sort_results_to_json)"
  count="$(jq 'length' <<<"$sorted_json")"

  if [[ "$count" -eq 0 ]]; then
    echo "No accounts found in $AUTH_FILE" >&2
    exit 1
  fi

  selected=0

  while true; do
    draw_switch_ui "$selected" "$sorted_json"

    IFS= read -rsn1 key || true

    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      printf "\nCancelled.\n"
      break
    fi

    if [[ "$key" == "" ]]; then
      item="$(jq -c ".[$selected]" <<<"$sorted_json")"
      printf "\033[H\033[J"
      printf "Switching current account...\n"

      jq '.raw_auth' <<<"$item" > "$CURRENT_AUTH_FILE"

      CURRENT_AUTH_RAW="$(cat "$CURRENT_AUTH_FILE")"
      CURRENT_AUTH_MODE="$(get_auth_mode "$CURRENT_AUTH_RAW")"
      CURRENT_AUTH_IDENTITY="$(get_auth_identity "$CURRENT_AUTH_RAW")"
      target_label="$(jq -r '.email' <<<"$item")"

      printf "${GREEN}${BOLD}Switched.${RESET}\n"
      printf "Current account: %s\n" "$target_label"
      printf "Updated auth file: %s\n" "$CURRENT_AUTH_FILE"
      break
    fi

    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 key || true
      case "$key" in
        "[A")
          (( selected > 0 )) && selected=$((selected - 1))
          ;;
        "[B")
          (( selected < count - 1 )) && selected=$((selected + 1))
          ;;
      esac
    fi
  done
}

build_results

if [[ "$MODE" == "switch" ]]; then
  switch_mode
else
  render_show_mode
fi