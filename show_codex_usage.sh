#!/usr/bin/env bash
set -euo pipefail

CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$HOME/.codex/auth.json}"
AUTH_FILE="${1:-$HOME/.codex/auth-poll.json}"
POOL_FILE="$AUTH_FILE"
USAGE_URL="https://chatgpt.com/backend-api/wham/usage"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

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

TMP_FILE="$(mktemp)"

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
' "$POOL_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$POOL_FILE"

CURRENT_ACCOUNT_ID="$(jq -r '.tokens.account_id' "$CURRENT_AUTH_FILE")"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Error: auth pool file not found: $AUTH_FILE" >&2
  exit 1
fi

# ----------------------------
# Helper functions
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

# ----------------------------
# Collect all results first, then sort
# ----------------------------
RESULTS_FILE="$(mktemp)"

jq -c '.[]' "$AUTH_FILE" | while IFS= read -r account; do
  access_token="$(jq -r '.tokens.access_token // empty' <<<"$account")"
  account_id="$(jq -r '.tokens.account_id // "unknown-account"' <<<"$account")"
  is_current="false"
  [[ "$account_id" == "$CURRENT_ACCOUNT_ID" ]] && is_current="true"

  if [[ -z "$access_token" ]]; then
    jq -n \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
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
        query_error: "missing access_token"
      }' >> "$RESULTS_FILE"
    echo >> "$RESULTS_FILE"
    continue
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
        query_error: "unable to query"
      }' >> "$RESULTS_FILE"
    echo >> "$RESULTS_FILE"
    continue
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
      secondary_reset_fmt: $secondary_reset_fmt
    }' >> "$RESULTS_FILE"
  echo >> "$RESULTS_FILE"
done

printf "${DIM}Codex usage from: %s${RESET}\n" "$AUTH_FILE"
printf "${DIM}Current auth: %s${RESET}\n\n" "$CURRENT_AUTH_FILE"

jq -s 'sort_by((if .is_current then 0 else 1 end), .primary_remaining_num)' "$RESULTS_FILE" | jq -c '.[]' | while IFS= read -r item; do
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

rm -f "$TMP_FILE" "$RESULTS_FILE" 2>/dev/null || true