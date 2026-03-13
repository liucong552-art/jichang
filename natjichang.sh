cat >/usr/local/sbin/vless_mktemp_nat.sh <<'__NAT_MKTEMP__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# 在 VPS 上生成“走 WG-NAT 出口”的临时 VLESS+Reality 节点（通过 sockopt.mark 触发策略路由）
# 适配最新版 vless-reality 体系：
#   - 复用主节点 Reality 参数 / PBK / PUBLIC_DOMAIN
#   - 状态写入 /var/lib/vless-reality/temp，供 vless_audit.sh 扫描
#   - 配额直接接入 quota-lib，超过 30 天时与最新版一样按 30 天周期重置
#   - 复用 runner / cleanup / restore / 审计体系
#
# 用法：
#   MARK=2333 D=600 vless_mktemp_nat.sh
#   PORT_START=40000 PORT_END=60000 MARK=2333 D=600 vless_mktemp_nat.sh
#   id=tmp001 MARK=2333 D=600 vless_mktemp_nat.sh
#   PQ_GIB=50 MARK=2333 D=600 vless_mktemp_nat.sh
#   PQ_GIB=50 MARK=2333 D=$((60*86400)) vless_mktemp_nat.sh
#   IP_LIMIT=3 MARK=2333 D=600 vless_mktemp_nat.sh
#   IP_LIMIT=3 IP_STICKY_SECONDS=300 MARK=2333 D=600 vless_mktemp_nat.sh
#   SERVER_ADDR=nat.example.com MARK=2333 D=600 vless_mktemp_nat.sh

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

fail(){ vr_die "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

vr_require_root_debian12
vr_ensure_runtime_dirs
umask 077

D="${D:-600}"
PQ_GIB="${PQ_GIB:-}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
WG_IF="${WG_IF:-wg-nat}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"
MAX_START_RETRIES="${MAX_START_RETRIES:-12}"
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
SERVER_ADDR="${SERVER_ADDR:-}"
TAG_PREFIX="${TAG_PREFIX:-vless-temp-nat}"
HEALTHCHECK="${HEALTHCHECK:-/usr/local/sbin/wg_nat_healthcheck.sh}"

RUNNER="/usr/local/sbin/vless_run_temp.sh"
CLEANUP="/usr/local/sbin/vless_cleanup_one.sh"

need python3
need openssl
need ss
need systemctl
need timeout
need getent

[[ "$D" =~ ^[0-9]+$ ]] && (( D > 0 )) || fail "D 必须是正整数秒，例如：D=600 vless_mktemp_nat.sh"
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] && (( MAX_START_RETRIES > 0 )) || fail "MAX_START_RETRIES 必须是正整数"
[[ "$PORT_START" =~ ^[0-9]+$ ]] && [[ "$PORT_END" =~ ^[0-9]+$ ]] && (( PORT_START >= 1 && PORT_END <= 65535 && PORT_START <= PORT_END )) || fail "PORT_START/PORT_END 无效"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] || fail "IP_LIMIT 必须是非负整数"
[[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( IP_STICKY_SECONDS > 0 )) || fail "IP_STICKY_SECONDS 必须是正整数"
[[ "$TABLE_ID" =~ ^[0-9]+$ ]] && (( TABLE_ID > 0 )) || fail "TABLE_ID 必须是正整数"
[[ "$HANDSHAKE_MAX" =~ ^[0-9]+$ ]] && (( HANDSHAKE_MAX > 0 )) || fail "HANDSHAKE_MAX 必须是正整数秒"
[[ -x "$RUNNER" ]] || fail "找不到 RUNNER：$RUNNER（先部署最新版临时节点体系）"
[[ -x "$CLEANUP" ]] || fail "找不到 CLEANUP：$CLEANUP"

if [[ -n "$PQ_GIB" ]]; then
  PQ_LIMIT_BYTES="$(vr_parse_gib_to_bytes "$PQ_GIB")" || fail "PQ_GIB 必须是正数"
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( PQ_LIMIT_BYTES > 0 )) || fail "PQ_GIB 转换失败"
else
  PQ_LIMIT_BYTES=""
fi

norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then
    raw="${raw#0x}"
    echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
  else
    fail "MARK 格式不合法：$1"
  fi
}
MARK_DEC="$(norm_mark "$MARK_RAW")"
(( MARK_DEC > 0 )) || fail "MARK 必须大于 0"

RAW_ID="${id:-${TAG_PREFIX}-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)}"
SAFE_ID="$(vr_safe_tag "$RAW_ID")"
if [[ "$SAFE_ID" == vless-temp-* ]]; then
  TAG="$SAFE_ID"
else
  TAG="vless-temp-${SAFE_ID}"
fi

EXIST_META="$(vr_temp_meta_file "$TAG")"
if [[ -f "$EXIST_META" ]]; then
  EXIST_EXPIRE="$(vr_meta_get "$EXIST_META" EXPIRE_EPOCH || true)"
  if [[ "$EXIST_EXPIRE" =~ ^[0-9]+$ ]] && (( EXIST_EXPIRE <= $(date +%s) )); then
    FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  else
    fail "临时节点 ${TAG} 已存在"
  fi
fi

# 与最新版主节点保持一致：Reality 参数、PBK、连接域名全部复用主体系
mapfile -t MAIN_INFO < <(vr_read_main_reality)
REALITY_PRIVATE_KEY="${MAIN_INFO[0]:-}"
REALITY_DEST="${MAIN_INFO[1]:-}"
REALITY_SNI="${MAIN_INFO[2]:-}"
MAIN_PORT="${MAIN_INFO[3]:-}"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_DEST" ]] || fail "无法从主节点读取 Reality 参数"
[[ -n "$REALITY_SNI" ]] || REALITY_SNI="${REALITY_DEST%%:*}"

PUBLISHED_DOMAIN="$(vr_current_public_domain)"
[[ -n "$PUBLISHED_DOMAIN" ]] || fail "无法获取主节点 PUBLIC_DOMAIN"

PBK_IN="${PBK:-}"
if [[ -z "$PBK_IN" ]]; then
  PBK_IN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
fi
if [[ -z "$PBK_IN" ]]; then
  PBK_IN="$(vr_main_url_published_pbk 2>/dev/null || true)"
fi
[[ -n "$PBK_IN" ]] || fail "无法获取主节点 PBK，请先运行 /root/onekey_reality_ipv4.sh 或手动传入 PBK=<...>"
PBK_RAW="$(vr_urldecode "$PBK_IN")"

if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR="$PUBLISHED_DOMAIN"
fi
[[ -n "$SERVER_ADDR" ]] || fail "无法获取连接域名/地址"
getent ahosts "$SERVER_ADDR" >/dev/null 2>&1 || fail "SERVER_ADDR/PUBLIC_DOMAIN 当前未解析：$SERVER_ADDR"

# NAT 出口健康检查（生成临时节点前）
if [[ -x "$HEALTHCHECK" ]]; then
  echo "==> NAT 出口健康检查（生成临时节点前）..."
  HANDSHAKE_MAX="$HANDSHAKE_MAX" WG_IF="$WG_IF" MARK="$MARK_DEC" TABLE_ID="$TABLE_ID" \
    "$HEALTHCHECK" \
    || fail "wg-nat 出口不可用（常见原因：NAT 机 wg-exit 未启动 / UDP 51820 不通 / keepalive 未恢复）"
fi

collect_used_ports() {
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
  for meta in "$VR_TEMP_STATE_DIR"/*.env "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    vr_meta_get "$meta" PORT || true
  done
  if [[ "$MAIN_PORT" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$MAIN_PORT"
  fi
}

rollback_current() {
  FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
}

validate_full_state() {
  local meta="$1" port="$2"
  [[ -f "$meta" ]] || return 1
  [[ -f "$(vr_temp_cfg_file "$TAG")" ]]
  [[ -f "$(vr_temp_unit_file "$TAG")" ]]
  [[ -f "$(vr_temp_url_file "$TAG")" ]]
  [[ -n "$(vr_meta_get "$meta" EXPIRE_EPOCH || true)" ]]
  [[ -n "$(vr_meta_get "$meta" PORT || true)" ]]
  [[ "$(vr_meta_get "$meta" LANDING || true)" == "nat" ]]
  [[ "$(vr_meta_get "$meta" SERVER_ADDR || true)" == "$SERVER_ADDR" ]]
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta
    qmeta="$(vr_quota_meta_file "$port")"
    [[ -f "$qmeta" ]]
    [[ -n "$(vr_meta_get "$qmeta" ORIGINAL_LIMIT_BYTES || true)" ]]
    [[ -n "$(vr_meta_get "$qmeta" SAVED_USED_BYTES || true)" ]]
    [[ -n "$(vr_meta_get "$qmeta" LIMIT_BYTES || true)" ]]
  fi
  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(vr_iplimit_meta_file "$port")"
    [[ -f "$imeta" ]]
    [[ -n "$(vr_meta_get "$imeta" IP_LIMIT || true)" ]]
    [[ -n "$(vr_meta_get "$imeta" IP_STICKY_SECONDS || true)" ]]
  fi
  /usr/local/sbin/vless_audit.sh --tag "$TAG" >/dev/null 2>&1
}

if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
  export VR_TEMP_LOCK_HELD=1
fi

ATTEMPT=0
while (( ATTEMPT < MAX_START_RETRIES )); do
  ATTEMPT=$((ATTEMPT + 1))

  mapfile -t USED_PORTS < <(collect_used_ports | awk '/^[0-9]+$/ {print}' | sort -n -u)
  declare -A USED=()
  for p in "${USED_PORTS[@]}"; do
    USED["$p"]=1
  done

  PORT=""
  CANDIDATE="$PORT_START"
  while (( CANDIDATE <= PORT_END )); do
    if [[ -z "${USED[$CANDIDATE]+x}" ]]; then
      PORT="$CANDIDATE"
      break
    fi
    CANDIDATE=$((CANDIDATE + 1))
  done
  [[ -n "$PORT" ]] || fail "在 ${PORT_START}-${PORT_END} 范围内没有空闲端口"

  UUID="$(/usr/local/bin/xray uuid)"
  SHORT_ID="$(openssl rand -hex 8)"
  CREATE_EPOCH="$(date +%s)"
  EXPIRE_EPOCH=$((CREATE_EPOCH + D))
  CFG="$(vr_temp_cfg_file "$TAG")"
  META="$(vr_temp_meta_file "$TAG")"
  UNIT_FILE="$(vr_temp_unit_file "$TAG")"
  URL_FILE="$(vr_temp_url_file "$TAG")"

  cat >"$CFG" <<CONF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "${TAG}",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "routeOnly": true,
        "destOverride": ["http","tls","quic"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    {
      "tag": "nat",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": { "mark": ${MARK_DEC} }
      }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["${TAG}"], "outboundTag": "nat" }
    ]
  }
}
CONF
  chmod 600 "$CFG" 2>/dev/null || true

  vr_write_meta "$META" \
    "TAG=${TAG}" \
    "ID=${SAFE_ID}" \
    "PORT=${PORT}" \
    "PUBLIC_DOMAIN=${PUBLISHED_DOMAIN}" \
    "SERVER_ADDR=${SERVER_ADDR}" \
    "UUID=${UUID}" \
    "CREATE_EPOCH=${CREATE_EPOCH}" \
    "EXPIRE_EPOCH=${EXPIRE_EPOCH}" \
    "DURATION_SECONDS=${D}" \
    "REALITY_DEST=${REALITY_DEST}" \
    "REALITY_SNI=${REALITY_SNI}" \
    "SHORT_ID=${SHORT_ID}" \
    "PBK=${PBK_RAW}" \
    "PQ_GIB=${PQ_GIB}" \
    "PQ_LIMIT_BYTES=${PQ_LIMIT_BYTES}" \
    "IP_LIMIT=${IP_LIMIT}" \
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}" \
    "LANDING=nat" \
    "WG_IF=${WG_IF}" \
    "MARK=${MARK_DEC}" \
    "TABLE_ID=${TABLE_ID}"

  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Temporary VLESS NAT ${TAG}
After=network-online.target vless-managed-restore.service
Wants=network-online.target
ConditionPathExists=${CFG}
ConditionPathExists=${META}

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/sbin/vless_run_temp.sh ${TAG} ${CFG}
ExecStopPost=/usr/local/sbin/vless_cleanup_one.sh ${TAG} --from-stop-post
Restart=no
SuccessExitStatus=0 124 143

[Install]
WantedBy=multi-user.target
UNIT

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    if ! vr_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "$D" "$EXPIRE_EPOCH"; then
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    if ! vr_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG"; then
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  systemctl daemon-reload
  systemctl enable "${TAG}.service" >/dev/null 2>&1 || true

  if ! systemctl start "${TAG}.service"; then
    rollback_current
    USED["$PORT"]=1
    continue
  fi

  if ! vr_wait_unit_and_port "${TAG}.service" "$PORT" 3 12; then
    rollback_current
    USED["$PORT"]=1
    continue
  fi

  PBK_Q="$(vr_urlencode "$PBK_RAW")"
  VLESS_URL="vless://${UUID}@${SERVER_ADDR}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"
  printf '%s\n' "$VLESS_URL" >"$URL_FILE"
  chmod 600 "$URL_FILE" 2>/dev/null || true

  if ! validate_full_state "$META" "$PORT"; then
    if systemctl is-active --quiet "${TAG}.service" 2>/dev/null && vr_port_is_listening "$PORT"; then
      echo "⚠ validate_full_state 失败，但节点已成功启动；为避免重复创建，跳过重试" >&2
    else
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  echo "✅ NAT 落地临时节点创建成功"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "TTL: $(vr_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(vr_beijing_time "$EXPIRE_EPOCH")"
  echo "SERVER_ADDR: ${SERVER_ADDR}"
  echo "PUBLIC_DOMAIN: ${PUBLISHED_DOMAIN}"
  echo "WG_IF: ${WG_IF}"
  echo "MARK: ${MARK_DEC}"
  echo "TABLE_ID: ${TABLE_ID}"
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    echo "PQ: $(vr_human_bytes "$PQ_LIMIT_BYTES")"
  fi
  if (( IP_LIMIT > 0 )); then
    echo "IP_LIMIT: ${IP_LIMIT}"
    echo "IP_STICKY_SECONDS: ${IP_STICKY_SECONDS}"
  fi
  echo "URL: ${VLESS_URL}"
  exit 0
done

fail "启动 NAT 临时 VLESS 服务失败，已回滚（尝试次数: ${MAX_START_RETRIES}）"
__NAT_MKTEMP__

chmod +x /usr/local/sbin/vless_mktemp_nat.sh
