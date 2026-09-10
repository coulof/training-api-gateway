#!/usr/bin/env bash
#
# measure-resize-continuity.sh — Tests HTTP traffic continuity during live pod resizing.
#
# Usage:
#   ./measure-resize-continuity.sh [-u <URL>] [-d <seconds>] [-r <req/sec>]
#
# Examples:
#   # Continuous probing during in-place resize:
#   ./measure-resize-continuity.sh -u http://127.0.0.1:8080/version -d 20
#
#   # Probe via custom host header:
#   ./measure-resize-continuity.sh -u http://127.0.0.1:8080/version -H "Host: podinfo.lab" -d 15
#

set -euo pipefail

URL="${GW_URL:-http://127.0.0.1:8080}/version"
DURATION=15
RATE=10
HOST_HEADER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)
      URL="$2"
      shift 2
      ;;
    -d|--duration)
      DURATION="$2"
      shift 2
      ;;
    -r|--rate)
      RATE="$2"
      shift 2
      ;;
    -H|--header)
      HOST_HEADER="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [options]

Options:
  -u, --url <URL>        Target endpoint URL (default: \${GW_URL:-http://127.0.0.1:8080}/version)
  -d, --duration <sec>   Probe duration in seconds (default: 15)
  -r, --rate <req/sec>   Requests per second (default: 10)
  -H, --header <header>  Optional HTTP header (e.g. "Host: podinfo.lab")
  -h, --help             Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SLEEP_INTERVAL=$(awk -v r="$RATE" 'BEGIN { printf "%.3f", 1.0 / r }')

if [[ -t 1 ]]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi

printf "\n%s=================================================================%s\n" "$C_B" "$C_0"
printf "%s  HTTP Traffic Continuity Benchmark (In-Place Resize vs Restart)%s\n" "$C_B" "$C_0"
printf "%s=================================================================%s\n" "$C_B" "$C_0"
printf "  Target URL : %s\n" "$URL"
printf "  Duration   : %s seconds @ %s req/sec (interval: %ss)\n" "$DURATION" "$RATE" "$SLEEP_INTERVAL"
[[ -n "$HOST_HEADER" ]] && printf "  Header     : %s\n" "$HOST_HEADER"
printf "\n%sSending probes... (trigger your pod resize or rollout now)%s\n\n" "$C_Y" "$C_0"

TOTAL=0
SUCCESS=0
DROPPED=0
LATENCIES=()

END_TIME=$((SECONDS + DURATION))

HEADER_ARG=()
if [[ -n "$HOST_HEADER" ]]; then
  HEADER_ARG=(-H "$HOST_HEADER")
fi

while [[ $SECONDS -lt $END_TIME ]]; do
  START_TS=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  
  RES=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 1 --max-time 2 "${HEADER_ARG[@]}" "$URL" 2>/dev/null || echo "000 0.000")
  
  CODE=$(echo "$RES" | awk '{print $1}')
  TIME_SEC=$(echo "$RES" | awk '{print $2}')
  LAT_MS=$(awk -v t="$TIME_SEC" 'BEGIN { printf "%.1f", t * 1000 }')
  
  TOTAL=$((TOTAL + 1))
  
  if [[ "$CODE" == "200" ]]; then
    SUCCESS=$((SUCCESS + 1))
    LATENCIES+=("$LAT_MS")
    printf "  [%3d] %sHTTP %s%s | Latency: %6.1f ms\n" "$TOTAL" "$C_G" "$CODE" "$C_0" "$LAT_MS"
  else
    DROPPED=$((DROPPED + 1))
    printf "  [%3d] %sHTTP %s%s | Latency: %6.1f ms [DROPPED / ERROR]\n" "$TOTAL" "$C_R" "$CODE" "$C_0" "$LAT_MS"
  fi
  
  sleep "$SLEEP_INTERVAL"
done

printf "\n%s-----------------------------------------------------------------%s\n" "$C_B" "$C_0"
printf "%s  Continuity Test Results%s\n" "$C_B" "$C_0"
printf "%s-----------------------------------------------------------------%s\n" "$C_B" "$C_0"
printf "  Total Probes Sent    : %d\n" "$TOTAL"
printf "  Successful (200 OK)  : %s%d%s (%.1f%%)\n" "$C_G" "$SUCCESS" "$C_0" "$(awk -v s="$SUCCESS" -v t="$TOTAL" 'BEGIN { if (t>0) printf "%.1f", (s/t)*100; else print "0.0" }')"
printf "  Dropped / Errors     : %s%d%s (%.1f%%)\n" "$([[ $DROPPED -gt 0 ]] && echo "$C_R" || echo "$C_G")" "$DROPPED" "$C_0" "$(awk -v d="$DROPPED" -v t="$TOTAL" 'BEGIN { if (t>0) printf "%.1f", (d/t)*100; else print "0.0" }')"

if [[ ${#LATENCIES[@]} -gt 0 ]]; then
  AVG_LAT=$(printf '%s\n' "${LATENCIES[@]}" | awk '{sum+=$1} END {printf "%.1f", sum/NR}')
  printf "  Average Latency      : %s ms\n" "$AVG_LAT"
fi

echo
if [[ $DROPPED -eq 0 ]]; then
  printf "%s[PASS] Zero downtime achieved! In-place resize preserved active connections.%s\n\n" "$C_G" "$C_0"
else
  printf "%s[WARN] %d requests dropped during the window (typical of a restart/rollout, not in-place resize).%s\n\n" "$C_Y" "$DROPPED" "$C_0"
fi
