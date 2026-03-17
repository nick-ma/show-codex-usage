#!/usr/bin/env bash
set -euo pipefail

CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$HOME/.codex/auth.json}"

MODE="show"
AUTH_FILE="$HOME/.codex/auth-poll.json"

if [[ $# -ge 1 ]]; then
  case "$1" in
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

# ----------------------------
# Upsert current auth.json into auth-poll.json
# ----------------------------
if [[ ! -f "$CURRENT_AUTH_FILE" ]]; then
  echo "Error: current auth file not found: $CURRENT_AUTH_FILE" >&2
  exit 1
fi

if [[ ! -f "$POOL_FILE" ]]; then
  echo '[]' > "$POOL_FILE"
fi

jq -e '
  type == "object"
  and .tokens
  and .tokens.account_id
  and (.tokens.account_id | type == "string")
  and (.tokens.account_id | length > 0)
' "$CURRENT_AUTH_FILE" > /dev/null

jq -e 'type == "array"' "$POOL_FILE" > /dev/null

TMP_UPSERT_FILE="$(mktemp)"

jq --slurpfile new_auth "$CURRENT_AUTH_FILE" '
  . as $pool
  | $new_auth[0] as $new
  | $new.tokens.account_id as $account_id
  | if any($pool[]?; .tokens.account_id == $account_id) then
      map(
        if .tokens.account_id == $account_id
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

CURRENT_ACCOUNT_ID="$(jq -r '.tokens.account_id' "$CURRENT_AUTH_FILE")"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Error: auth pool file not found: $AUTH_FILE" >&2
  exit 1
fi

# ----------------------------
# Helpers
# ----------------------------
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

fetch_usage_for_account() {
  local raw_account="$1"

  local access_token account_id is_current response
  local email plan_type limit_reached
  local primary_used primary_reset secondary_used secondary_reset
  local primary_remaining secondary_remaining
  local primary_reset_fmt secondary_reset_fmt
  local primary_remaining_num

  access_token="$(jq -r '.tokens.access_token // empty' <<<"$raw_account")"
  account_id="$(jq -r '.tokens.account_id // "unknown-account"' <<<"$raw_account")"
  is_current="false"
  [[ "$account_id" == "$CURRENT_ACCOUNT_ID" ]] && is_current="true"

  if [[ -z "$access_token" ]]; then
    jq -n \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        account_id: $account_id,
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

  response="$(
    curl -sS "$USAGE_URL" \
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
      || true
  )"

  if [[ -z "$response" ]] || ! jq -e . >/dev/null 2>&1 <<<"$response"; then
    jq -n \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
      --arg raw_auth "$(jq -c . <<<"$raw_account")" \
      '{
        account_id: $account_id,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "unable to query",
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
  ' <<<"$response")"

  plan_type="$(jq -r '
    .plan_type //
    .account.plan_type //
    .subscription.plan_type //
    .plan.type //
    "unknown"
  ' <<<"$response")"

  limit_reached="$(jq -r '
    .rate_limit.limit_reached //
    .limit_reached //
    false
  ' <<<"$response")"

  primary_used="$(jq -r '
    .rate_limit.primary_window.used_percent //
    .primary_window.used_percent //
    "-"
  ' <<<"$response")"

  primary_reset="$(jq -r '
    .rate_limit.primary_window.reset_at //
    .primary_window.reset_at //
    empty
  ' <<<"$response")"

  secondary_used="$(jq -r '
    .rate_limit.secondary_window.used_percent //
    .secondary_window.used_percent //
    "-"
  ' <<<"$response")"

  secondary_reset="$(jq -r '
    .rate_limit.secondary_window.reset_at //
    .secondary_window.reset_at //
    empty
  ' <<<"$response")"

  primary_remaining="$(remaining_percent "$primary_used")"
  secondary_remaining="$(remaining_percent "$secondary_used")"
  primary_reset_fmt="$(format_reset_at "$primary_reset")"
  secondary_reset_fmt="$(format_reset_at "$secondary_reset")"

  primary_remaining_num="$primary_remaining"
  if [[ "$primary_remaining_num" == "-" || -z "$primary_remaining_num" ]]; then
    primary_remaining_num="9999"
  fi

  jq -n \
    --arg account_id "$account_id" \
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
      account_id: $account_id,
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
  jq -s 'sort_by((if .is_current then 0 else 1 end), .primary_remaining_num)' "$RESULTS_FILE"
}

render_show_mode() {
  printf "${DIM}Codex usage from: %s${RESET}\n" "$AUTH_FILE"
  printf "${DIM}Current auth: %s${RESET}\n\n" "$CURRENT_AUTH_FILE"

  sort_results_to_json | jq -c '.[]' | while IFS= read -r item; do
    local email plan_type limit_reached primary_remaining primary_reset_fmt
    local secondary_remaining secondary_reset_fmt is_current query_error
    local primary_remaining_colored secondary_remaining_colored

    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    primary_remaining="$(jq -r '.primary_remaining' <<<"$item")"
    primary_reset_fmt="$(jq -r '.primary_reset_fmt' <<<"$item")"
    secondary_remaining="$(jq -r '.secondary_remaining' <<<"$item")"
    secondary_reset_fmt="$(jq -r '.secondary_reset_fmt' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    query_error="$(jq -r '.query_error // empty' <<<"$item")"

    primary_remaining_colored="$(colorize_remaining "$primary_remaining")"
    secondary_remaining_colored="$(colorize_remaining "$secondary_remaining")"

    if [[ "$is_current" == "true" ]]; then
      printf "Account: %s [%s] ${BOLD}${GREEN}[Current Using]${RESET}\n" "$email" "$plan_type"
    else
      printf "Account: %s [%s]\n" "$email" "$plan_type"
    fi

    if [[ -n "$query_error" ]]; then
      printf "Rate Limit: ${RED}%s${RESET}\n\n" "$query_error"
      continue
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
    local item email plan_type is_current limit_reached
    local p5 p1w qerr line prefix

    item="$(jq -c ".[$idx]" <<<"$json")"
    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    p5="$(jq -r '.primary_remaining' <<<"$item")"
    p1w="$(jq -r '.secondary_remaining' <<<"$item")"
    qerr="$(jq -r '.query_error // empty' <<<"$item")"

    prefix="  "
    [[ "$idx" -eq "$selected" ]] && prefix="> "

    line="${prefix}${email} [${plan_type}]"

    if [[ "$is_current" == "true" ]]; then
      line="${line} ${BOLD}${GREEN}[Current Using]${RESET}"
    fi

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
  local sorted_json selected count key item target_account_id
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
      CURRENT_ACCOUNT_ID="$(jq -r '.tokens.account_id' "$CURRENT_AUTH_FILE")"
      target_account_id="$(jq -r '.account_id' <<<"$item")"

      printf "${GREEN}${BOLD}Switched.${RESET}\n"
      printf "Current account_id: %s\n" "$target_account_id"
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

# ----------------------------
# Main
# ----------------------------
build_results

if [[ "$MODE" == "switch" ]]; then
  switch_mode
else
  render_show_mode
fi