#!/usr/bin/env bash
set -Eeuo pipefail

# Auto-generated from the old VPS audit snapshot the user pasted in chat.
# Goal:
#   - recreate all non-self users on the new VPS
#   - preserve remaining TTL (D)
#   - preserve remaining quota (PQ_GIB = old LIMIT - old TOTAL)
#   - set IP_LIMIT=3 for every user
#   - prefer the old port first; if occupied, fall back to automatic allocation in 40000-50050
#
# Requirements on the new VPS:
#   1) Main VLESS-Reality stack already installed
#   2) /usr/local/sbin/vless_mktemp.sh exists
#   3) /usr/local/sbin/vless_mktemp_nat.sh exists for NAT users
#   4) NAT path is already healthy for wg-nat users
#
# Notes:
#   - For normal users, id uses the old tag suffix so the recreated tag stays identical.
#   - For NAT users, id uses the full old tag so the recreated tag stays identical.
#   - The creation scripts do rollback on failure; this wrapper will then try a fallback port range.
#   - MARK/WG_IF/TABLE_ID can be overridden when needed.

IP_LIMIT="${IP_LIMIT:-3}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"

# NAT defaults from the new NAT script; override if your new VPS uses different values.
MARK="${MARK:-2333}"
WG_IF="${WG_IF:-wg-nat}"
TABLE_ID="${TABLE_ID:-100}"

FALLBACK_PORT_START="${FALLBACK_PORT_START:-40000}"
FALLBACK_PORT_END="${FALLBACK_PORT_END:-50050}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need /usr/local/sbin/vless_mktemp.sh
need /usr/local/sbin/vless_mktemp_nat.sh
need /usr/local/sbin/vless_audit.sh
need /usr/local/sbin/pq_audit.sh

normal_ok=0
nat_ok=0
failed=0

create_normal() {
  local port="$1" id="$2" ttl="$3" left_gib="$4"
  echo
  echo "==> normal old_port=${port} id=${id} D=${ttl} PQ_GIB=${left_gib}"
  if PORT_START="$port" PORT_END="$port" id="$id" IP_LIMIT="$IP_LIMIT" IP_STICKY_SECONDS="$IP_STICKY_SECONDS" PQ_GIB="$left_gib" D="$ttl" /usr/local/sbin/vless_mktemp.sh; then
    normal_ok=$((normal_ok + 1))
    return 0
  fi
  echo "   exact old port ${port} unavailable, retrying in ${FALLBACK_PORT_START}-${FALLBACK_PORT_END} ..."
  if PORT_START="$FALLBACK_PORT_START" PORT_END="$FALLBACK_PORT_END" id="$id" IP_LIMIT="$IP_LIMIT" IP_STICKY_SECONDS="$IP_STICKY_SECONDS" PQ_GIB="$left_gib" D="$ttl" /usr/local/sbin/vless_mktemp.sh; then
    normal_ok=$((normal_ok + 1))
    return 0
  fi
  echo "   FAILED: normal id=${id}" >&2
  failed=$((failed + 1))
  return 0
}

create_nat() {
  local port="$1" id="$2" ttl="$3" left_gib="$4"
  echo
  echo "==> nat old_port=${port} id=${id} D=${ttl} PQ_GIB=${left_gib}"
  if MARK="$MARK" WG_IF="$WG_IF" TABLE_ID="$TABLE_ID" PORT_START="$port" PORT_END="$port" id="$id" IP_LIMIT="$IP_LIMIT" IP_STICKY_SECONDS="$IP_STICKY_SECONDS" PQ_GIB="$left_gib" D="$ttl" /usr/local/sbin/vless_mktemp_nat.sh; then
    nat_ok=$((nat_ok + 1))
    return 0
  fi
  echo "   exact old port ${port} unavailable, retrying in ${FALLBACK_PORT_START}-${FALLBACK_PORT_END} ..."
  if MARK="$MARK" WG_IF="$WG_IF" TABLE_ID="$TABLE_ID" PORT_START="$FALLBACK_PORT_START" PORT_END="$FALLBACK_PORT_END" id="$id" IP_LIMIT="$IP_LIMIT" IP_STICKY_SECONDS="$IP_STICKY_SECONDS" PQ_GIB="$left_gib" D="$ttl" /usr/local/sbin/vless_mktemp_nat.sh; then
    nat_ok=$((nat_ok + 1))
    return 0
  fi
  echo "   FAILED: nat id=${id}" >&2
  failed=$((failed + 1))
  return 0
}

echo "Starting migration..."
echo "IP_LIMIT=${IP_LIMIT} IP_STICKY_SECONDS=${IP_STICKY_SECONDS}"
echo "NAT: MARK=${MARK} WG_IF=${WG_IF} TABLE_ID=${TABLE_ID}"

echo "\n### normal users ###"
create_normal 40000 "20260304002508-2881" 6541320 "73.35"
create_normal 40001 "20260304002911-6a7e" 5504760 "130.25"
create_normal 40006 "20260304010413-4bcf" 1618860 "52.64"
create_normal 40011 "20260304014048-70b5" 929880 "137.58"
create_normal 40013 "20260304014530-3255" 411780 "137.11"
create_normal 40014 "20260304014945-9dad" 1621620 "84.34"
create_normal 40015 "20260304015110-81c7" 7669680 "26.99"
create_normal 40022 "20260304022043-4dc8" 586680 "134.62"
create_normal 40024 "20260304023454-db06" 673920 "123.39"
create_normal 40026 "20260304024136-12fd" 22792740 "999.51"
create_normal 40028 "20260304025238-1781" 7759800 "100.00"
create_normal 40029 "20260304025454-025f" 934320 "3.57"
create_normal 40031 "20260304025925-4eca" 1193820 "50.00"
create_normal 40034 "20260305231704-79bb" 1353240 "46.59"

echo "\n### nat users ###"
create_nat 40002 "vless-temp-nat-20260304005214-6e02" 840540 "1.11"
create_nat 40003 "vless-temp-nat-20260304013509-bb6e" 1361520 "33.95"
create_nat 40004 "vless-temp-nat-20260304011050-50df" 2396880 "34.83"
create_nat 40005 "vless-temp-nat-20260304010259-e8fc" 1618800 "17.69"
create_nat 40007 "vless-temp-nat-20260304012037-dd54" 669480 "12.68"
create_nat 40008 "vless-temp-nat-20260304012449-5dc8" 5421720 "41.70"
create_nat 40009 "vless-temp-nat-20260304012856-f6e7" 1361160 "46.89"
create_nat 40010 "vless-temp-nat-20260304013724-cf00" 3176100 "30.93"
create_nat 40012 "vless-temp-nat-20260315022456-f4d0" 2570520 "49.81"
create_nat 40016 "vless-temp-nat-20260304015359-ae1a" 930660 "47.63"
create_nat 40017 "vless-temp-nat-20260304015859-a6c2" 12594960 "49.99"
create_nat 40018 "vless-temp-nat-20260304184835-757a" 1682760 "86.79"
create_nat 40019 "vless-temp-nat-20260304020543-d7b3" 2400180 "0.97"
create_nat 40021 "vless-temp-nat-20260304021429-71b4" 31258320 "69.13"
create_nat 40023 "vless-temp-nat-20260304022944-a705" 1364820 "68.72"
create_nat 40025 "vless-temp-nat-20260304023643-adcd" 5944440 "57.26"
create_nat 40027 "vless-temp-nat-20260304024957-f651" 11388420 "48.87"
create_nat 40032 "vless-temp-nat-20260304030551-e44c" 7242180 "31.65"
create_nat 40033 "vless-temp-nat-20260304031057-2fc0" 1626480 "47.57"
create_nat 40036 "vless-temp-nat-20260304184204-97a1" 1682340 "6.98"
create_nat 40037 "vless-temp-nat-20260304184601-c6f5" 10063380 "49.86"

echo
echo "Done. normal_ok=${normal_ok} nat_ok=${nat_ok} failed=${failed}"
echo
echo "Current service audit:"
/usr/local/sbin/vless_audit.sh || true
echo
echo "Current quota audit:"
/usr/local/sbin/pq_audit.sh || true

if (( failed > 0 )); then
  echo
  echo "Some users failed to create. Re-run only failed entries after fixing the reason above." >&2
fi
