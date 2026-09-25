#!/usr/bin/env bash
# linux-host-health -- inspect one Linux host.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${HEALTH_CONF:-$SCRIPT_DIR/health.conf}"
JSON_OUT=""
QUIET=0

usage() {
  cat <<'EOF'
Usage: check.sh [options]

Options:
  -c FILE    Config file (default: ./health.conf or $HEALTH_CONF)
  -j FILE    Also write JSON to FILE
  -q         Quiet: print only FAIL/WARN lines
  -h         Help

Exit codes:
  0  all checks passed
  1  one or more WARN
  2  one or more FAIL
  3  usage / config error
EOF
}

while getopts ":c:j:qh" opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    j) JSON_OUT="$OPTARG" ;;
    q) QUIET=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 3 ;;
  esac
done

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_FAIL_PCT="${DISK_FAIL_PCT:-90}"
LOAD_WARN_MULT="${LOAD_WARN_MULT:-1}"
LOAD_FAIL_MULT="${LOAD_FAIL_MULT:-2}"
MEM_WARN_PCT="${MEM_WARN_PCT:-85}"
MEM_FAIL_PCT="${MEM_FAIL_PCT:-95}"
AUTH_FAIL_WARN="${AUTH_FAIL_WARN:-10}"
AUTH_WINDOW_MIN="${AUTH_WINDOW_MIN:-60}"
CHECK_UNITS="${CHECK_UNITS:-1}"
CHECK_LISTENERS="${CHECK_LISTENERS:-1}"
CHECK_AUTH="${CHECK_AUTH:-1}"

PASS=0
WARN=0
FAIL=0
JSON_CHECKS=""

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

record() {
  local level="$1"
  local key="$2"
  local msg="$3"

  case "$level" in
    PASS) PASS=$((PASS + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
  esac

  if [[ "$QUIET" -eq 0 || "$level" == "WARN" || "$level" == "FAIL" ]]; then
    printf '%-5s %s\n' "$level" "$msg"
  fi

  local piece
  piece=$(printf '{"check":"%s","level":"%s","message":"%s"}' \
    "$(json_escape "$key")" \
    "$(json_escape "$level")" \
    "$(json_escape "$msg")")
  if [[ -z "$JSON_CHECKS" ]]; then
    JSON_CHECKS="$piece"
  else
    JSON_CHECKS="${JSON_CHECKS},${piece}"
  fi
}

ncpus() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

skip_mount() {
  case "$1" in
    /snap/*|/sys/*|/proc/*|/dev/*|/run/*) return 0 ;;
    /init|/mnt/wslg|/mnt/wslg/*) return 0 ;;
    /usr/lib/wsl/*|/usr/lib/modules/*) return 0 ;;
  esac
  return 1
}

check_identity() {
  local host os kernel
  host="$(hostname -f 2>/dev/null || hostname)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os="${PRETTY_NAME:-$ID}"
  else
    os="unknown"
  fi
  kernel="$(uname -r)"
  record PASS identity "host=${host} os=${os} kernel=${kernel}"
}

check_uptime() {
  local up
  up="$(uptime -p 2>/dev/null || awk '{print $1}' /proc/uptime)"
  record PASS uptime "$up"
}

check_load() {
  local cpus l1 l5 l15 warn_at fail_at level
  cpus="$(ncpus)"
  read -r l1 l5 l15 _ < /proc/loadavg
  warn_at="$(awk -v c="$cpus" -v m="$LOAD_WARN_MULT" 'BEGIN { printf "%.2f", c * m }')"
  fail_at="$(awk -v c="$cpus" -v m="$LOAD_FAIL_MULT" 'BEGIN { printf "%.2f", c * m }')"
  level=PASS
  awk -v l="$l1" -v f="$fail_at" 'BEGIN { exit !(l + 0 >= f + 0) }' && level=FAIL
  if [[ "$level" == "PASS" ]]; then
    awk -v l="$l1" -v w="$warn_at" 'BEGIN { exit !(l + 0 >= w + 0) }' && level=WARN
  fi
  record "$level" load "load1=${l1} load5=${l5} load15=${l15} cpus=${cpus} warn_at=${warn_at} fail_at=${fail_at}"
}

check_memory() {
  local total avail used_pct level
  total="$(awk '/MemTotal:/ { print $2 }' /proc/meminfo)"
  avail="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)"
  if [[ -z "$avail" ]]; then
    avail="$(awk '/MemFree:/ { print $2 }' /proc/meminfo)"
  fi
  used_pct="$(awk -v t="$total" -v a="$avail" 'BEGIN { printf "%d", (t - a) * 100 / t }')"
  level=PASS
  if (( used_pct >= MEM_FAIL_PCT )); then
    level=FAIL
  elif (( used_pct >= MEM_WARN_PCT )); then
    level=WARN
  fi
  record "$level" memory "used=${used_pct}% total_kb=${total} available_kb=${avail} warn_pct=${MEM_WARN_PCT} fail_pct=${MEM_FAIL_PCT}"
}

check_disks() {
  local any=0 pct mp level
  while read -r pct mp; do
    skip_mount "$mp" && continue
    any=1
    pct="${pct%%%}"
    level=PASS
    if (( pct >= DISK_FAIL_PCT )); then
      level=FAIL
    elif (( pct >= DISK_WARN_PCT )); then
      level=WARN
    fi
    record "$level" disk "mount=${mp} used=${pct}% warn_pct=${DISK_WARN_PCT} fail_pct=${DISK_FAIL_PCT}"
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR > 1 && $6 !~ /^\/snap/ { print $5, $6 }')
  if [[ "$any" -eq 0 ]]; then
    record WARN disk "no local filesystems reported by df"
  fi
}

check_units() {
  [[ "$CHECK_UNITS" == "1" ]] || return 0
  if ! command -v systemctl >/dev/null 2>&1; then
    record WARN units "systemctl not available"
    return 0
  fi
  local failed
  failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{ print $1 }' | paste -sd, -)"
  if [[ -z "$failed" ]]; then
    record PASS units "no failed systemd units"
  else
    record FAIL units "failed=${failed}"
  fi
}

check_listeners() {
  [[ "$CHECK_LISTENERS" == "1" ]] || return 0
  local ports ssh="no" count=0
  if command -v ss >/dev/null 2>&1; then
    ports="$(ss -tuln 2>/dev/null | awk 'NR > 1 {
      split($5, a, ":")
      p=a[length(a)]
      if (p != "" && p != "*") print p
    }' | sort -n | uniq)"
  elif command -v netstat >/dev/null 2>&1; then
    ports="$(netstat -tuln 2>/dev/null | awk 'NR > 2 {
      n=split($4, a, ":")
      print a[n]
    }' | sort -n | uniq)"
  else
    record WARN listeners "ss/netstat not available"
    return 0
  fi
  if [[ -n "$ports" ]]; then
    count="$(printf '%s\n' "$ports" | grep -c . || true)"
    printf '%s\n' "$ports" | grep -qx '22' && ssh="yes"
  fi
  record PASS listeners "port_count=${count} ssh=${ssh} ports=$(printf '%s' "$ports" | tr '\n' ',' | sed 's/,$//')"
}

check_auth() {
  [[ "$CHECK_AUTH" == "1" ]] || return 0
  local count=0 log="" level
  for candidate in /var/log/auth.log /var/log/secure; do
    if [[ -r "$candidate" ]]; then
      log="$candidate"
      break
    fi
  done
  if command -v journalctl >/dev/null 2>&1; then
    count="$(journalctl --since "${AUTH_WINDOW_MIN} min ago" --no-pager 2>/dev/null | grep -ciE 'failed password|authentication failure' || true)"
    log="${log:-journalctl}"
  elif [[ -n "$log" ]]; then
    count="$(grep -ciE 'failed password|authentication failure' "$log" || true)"
  else
    record WARN auth "no readable auth log and no journalctl"
    return 0
  fi
  level=PASS
  if (( count >= AUTH_FAIL_WARN )); then
    level=WARN
  fi
  record "$level" auth "failed_auth_approx=${count} window_min=${AUTH_WINDOW_MIN} source=${log} warn_at=${AUTH_FAIL_WARN}"
}

echo "linux-host-health  $(date -Is)"
echo "config            ${CONFIG}"
echo

check_identity
check_uptime
check_load
check_memory
check_disks
check_units
check_listeners
check_auth

echo
printf 'summary  PASS=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"

if [[ -n "$JSON_OUT" ]]; then
  printf '{"generated":"%s","pass":%s,"warn":%s,"fail":%s,"checks":[%s]}\n' \
    "$(date -Is)" "$PASS" "$WARN" "$FAIL" "$JSON_CHECKS" > "$JSON_OUT"
  echo "json     ${JSON_OUT}"
fi

if (( FAIL > 0 )); then
  exit 2
fi
if (( WARN > 0 )); then
  exit 1
fi
exit 0
