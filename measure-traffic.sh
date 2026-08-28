#!/usr/bin/env bash
#
# measure-traffic.sh — send a batch of HTTP requests and measure response distribution
#
# Usage:
#   ./measure-traffic.sh [-n count] [-p path] [-H host] [-c custom-header] [-u gw-url]
#
# Examples:
#   ./measure-traffic.sh
#   ./measure-traffic.sh -n 50 -p /shop -H podinfo.lab
#   ./measure-traffic.sh -n 20 -p /shop -H podinfo.lab -c "X-Canary: always"
#
set -euo pipefail

COUNT=50
PATH_URL="/shop"
HOST_HEADER="podinfo.lab"
CUSTOM_HEADER=""

# Resolve default GW_URL: default to http://127.0.0.1 (or port 8080 if port-forwarded)
DEFAULT_URL="http://127.0.0.1"
if [[ -z "${GW_URL:-}" ]]; then
  if curl -sf -o /dev/null -m 1 "http://127.0.0.1:8080/" 2>/dev/null; then
    GW_URL="http://127.0.0.1:8080"
  else
    GW_URL="${DEFAULT_URL}"
  fi
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count)
      COUNT="$2"; shift 2 ;;
    -p|--path)
      PATH_URL="$2"; shift 2 ;;
    -H|--host)
      HOST_HEADER="$2"; shift 2 ;;
    -c|--header)
      CUSTOM_HEADER="$2"; shift 2 ;;
    -u|--url)
      GW_URL="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [-n count] [-p path] [-H host] [-c header] [-u url]

Options:
  -n, --count    Number of requests to send (default: 50)
  -p, --path     URL path to target (default: /shop)
  -H, --host     Host header value (default: podinfo.lab)
  -c, --header   Custom HTTP header (e.g. "X-Canary: always")
  -u, --url      Gateway URL (default: \$GW_URL or http://127.0.0.1)
  -h, --help     Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

printf "\n\033[1;32m==>\033[0m Sending %d requests to %s%s (Host: %s)...\n" \
  "$COUNT" "$GW_URL" "$PATH_URL" "$HOST_HEADER"
[[ -n "$CUSTOM_HEADER" ]] && printf "    Header: %s\n" "$CUSTOM_HEADER"

HEADER_ARGS=()
[[ -n "$CUSTOM_HEADER" ]] && HEADER_ARGS+=(-H "$CUSTOM_HEADER")

RESULTS=()
for i in $(seq 1 "$COUNT"); do
  RESP="$(curl -s -H "Host: ${HOST_HEADER}" "${HEADER_ARGS[@]}" "${GW_URL}${PATH_URL}" 2>/dev/null || echo '{"message":"CONNECTION_FAILED"}')"
  MSG="$(echo "$RESP" | jq -r '.message // .version // "UNKNOWN"' 2>/dev/null || echo "RAW_RESPONSE")"
  RESULTS+=("$MSG")
done

printf "\n\033[1mResults Summary:\033[0m\n"
printf "%s\n" "──────────────────────────────────────────"

printf "%s\n" "${RESULTS[@]}" | sort | uniq -c | while read -r c label; do
  pct=$(awk "BEGIN {printf \"%.1f\", ($c / $COUNT) * 100}")
  printf "  \033[1;32m%5d\033[0m (%5s%%)  %s\n" "$c" "$pct" "$label"
done
printf "%s\n\n" "──────────────────────────────────────────"
