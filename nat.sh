cat >/usr/local/sbin/vless_mktemp_nat.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# 在 VPS 上生成“走 WG-NAT 出口”的临时 VLESS+Reality 节点（通过 sockopt.mark 触发策略路由）
# 复用已有体系，不重新设置 WG / NAT / 路由：
#   - 复用主节点 Reality 参数：/usr/local/etc/xray/config.json
#   - 复用临时节点 runner / cleanup：
#       /usr/local/sbin/vless_run_temp.sh
#       /usr/local/sbin/vless_cleanup_one.sh
#   - 复用域名配置：
#       /etc/default/vless-reality 中的 PUBLIC_DOMAIN
#
# 用法：
#   MARK=2333 D=600 vless_mktemp_nat.sh
#   PORT_START=40000 PORT_END=60000 MARK=2333 D=600 vless_mktemp_nat.sh
#   SERVER_ADDR=nat.example.com MARK=2333 D=600 vless_mktemp_nat.sh
#   MAX_START_RETRIES=8 MARK=2333 D=600 vless_mktemp_nat.sh
#   PQ_GIB=50 MARK=2333 D=600 vless_mktemp_nat.sh
#   PQ_GIB=50 MARK=2333 D=$((60*86400)) vless_mktemp_nat.sh

fail(){ echo "❌ $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

[[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"
umask 077

TAG_PREFIX="${TAG_PREFIX:-vless-temp-nat}"

D="${D:-600}"
PQ_GIB="${PQ_GIB:-}"
WG_IF="${WG_IF:-wg-nat}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"
MAX_START_RETRIES="${MAX_START_RETRIES:-5}"

XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
MAIN_CFG="${MAIN_CFG:-/usr/local/etc/xray/config.json}"
SUB_FILE="${SUB_FILE:-/root/vless_reality_vision_url.txt}"
DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/default/vless-reality}"

RUNNER="${RUNNER:-/usr/local/sbin/vless_run_temp.sh}"
CLEANUP="${CLEANUP:-/usr/local/sbin/vless_cleanup_one.sh}"
HEALTHCHECK="${HEALTHCHECK:-/usr/local/sbin/wg_nat_healthcheck.sh}"
PQ_ADD="${PQ_ADD:-/usr/local/sbin/pq_add.sh}"

LOCK="/run/vless-temp.lock"
LOCK_FD=9

need curl
need python3
need openssl
need ss
need systemctl
need timeout
need getent

if ! [[ "$D" =~ ^[0-9]+$ ]] || (( D <= 0 )); then
  fail "D 必须是正整数秒，例如：D=600 vless_mktemp_nat.sh"
fi
if ! [[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] || (( MAX_START_RETRIES <= 0 )); then
  fail "MAX_START_RETRIES 必须是正整数，例如：MAX_START_RETRIES=8 MARK=2333 D=600 vless_mktemp_nat.sh"
fi
if ! [[ "$TABLE_ID" =~ ^[0-9]+$ ]] || (( TABLE_ID <= 0 )); then
  fail "TABLE_ID 必须是正整数"
fi
if ! [[ "$HANDSHAKE_MAX" =~ ^[0-9]+$ ]] || (( HANDSHAKE_MAX <= 0 )); then
  fail "HANDSHAKE_MAX 必须是正整数秒"
fi
if [[ -n "$PQ_GIB" ]]; then
  if ! [[ "$PQ_GIB" =~ ^[0-9]+$ ]] || (( PQ_GIB <= 0 )); then
    fail "PQ_GIB 必须是正整数，例如：PQ_GIB=50 MARK=2333 D=600 vless_mktemp_nat.sh"
  fi
  [[ -x "$PQ_ADD" ]] || fail "PQ_GIB 已设置，但找不到 pq_add.sh：$PQ_ADD"
fi

exec {LOCK_FD}>"$LOCK"
lock_acquire(){ flock -w 10 "$LOCK_FD" || fail "临时节点锁被占用，请稍后重试"; }
lock_release(){ flock -u "$LOCK_FD" || true; }
lock_acquire

cfg_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '
    $1==k {
      sub($1"=","")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }
  ' "$file"
}

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
if (( MARK_DEC <= 0 )); then
  fail "MARK 必须大于 0"
fi

urldecode(){
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.unquote(sys.argv[1]))
PY
}

urlencode(){
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

sanitize_one_line() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v p="$port" '
    {
      n=split($4,a,":")
      if (a[n] == p) {found=1; exit}
    }
    END { exit(found ? 0 : 1) }
  '
}

wait_unit_and_port_stable() {
  local unit="$1" port="$2" tries="${3:-40}" delay="${4:-0.25}" stable_needed="${5:-4}"
  local i state sub stable=0
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]] && port_is_listening "$port"; then
      stable=$((stable+1))
      if (( stable >= stable_needed )); then
        return 0
      fi
    else
      stable=0
    fi
    if [[ "$state" == "failed" || "$state" == "inactive" || "$state" == "deactivating" ]]; then
      return 1
    fi
    sleep "$delay"
  done
  return 1
}

pick_free_port() {
  declare -A USED=()
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] && USED["$p"]=1
  done < <(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')

  shopt -s nullglob
  for m in "$XRAY_DIR"/*.meta; do
    [[ -f "$m" ]] || continue
    p="$(awk -F= '$1=="PORT"{sub($1"=","");print;exit}' "$m" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && USED["$p"]=1
  done
  shopt -u nullglob

  local p
  for ((p=PORT_START; p<=PORT_END; p++)); do
    if [[ -z "${USED[$p]+x}" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

write_temp_files() {
  local port="$1" now="$2" exp="$3"

  cat >"$CFG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "${TAG}",
      "listen": "0.0.0.0",
      "port": ${port},
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
JSON

  cat >"$META" <<META
TAG=${TAG}
UUID=${UUID}
SERVER_ADDR=${SERVER_ADDR}
PORT=${port}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
SHORT_ID=${SHORT_ID}
PBK=${PBK}
LANDING=nat
MARK=${MARK_DEC}
TABLE_ID=${TABLE_ID}
EXPIRE_EPOCH=${exp}
CFG=${CFG}
META

  chmod 600 "$CFG" "$META" 2>/dev/null || true

  cat >"$UNIT" <<UNIT
[Unit]
Description=Xray temp VLESS NAT (${TAG})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RUNNER} ${TAG} ${CFG}
ExecStopPost=${CLEANUP} ${TAG}
Restart=no
SuccessExitStatus=0 124 143

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
}

[[ -x "$RUNNER"  ]] || fail "找不到 RUNNER：$RUNNER（先部署临时节点体系）"
[[ -x "$CLEANUP" ]] || fail "找不到 CLEANUP：$CLEANUP"
[[ -f "$MAIN_CFG" ]] || fail "找不到主配置：$MAIN_CFG（先装主 VLESS Reality）"

# 1) NAT 出口健康检查（生成临时节点前）
if [[ -x "$HEALTHCHECK" ]]; then
  echo "==> NAT 出口健康检查（生成临时节点前）..."
  HANDSHAKE_MAX="${HANDSHAKE_MAX}" WG_IF="${WG_IF}" MARK="${MARK_DEC}" TABLE_ID="${TABLE_ID}" \
    "$HEALTHCHECK" \
    || fail "wg-nat 出口不可用（常见原因：NAT 机 wg-exit 未启动 / UDP 51820 不通 / keepalive 未恢复）"
fi

# 2) 从主配置解析 Reality 参数：dest / sni / privateKey
readarray -t R < <(python3 - "$MAIN_CFG" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
for ib in cfg.get("inbounds",[]):
    ss=(ib.get("streamSettings") or {})
    if ss.get("security")=="reality":
        rs=ss.get("realitySettings") or {}
        dest=rs.get("dest","")
        sns=rs.get("serverNames") or []
        sni=sns[0] if sns else ""
        pk=rs.get("privateKey","")
        print(dest)
        print(sni)
        print(pk)
        sys.exit(0)
print("")
print("")
print("")
PY
)

REALITY_DEST="${R[0]:-}"
REALITY_SNI="${R[1]:-}"
REALITY_PRIVATE_KEY="${R[2]:-}"
[[ -n "$REALITY_DEST" && -n "$REALITY_SNI" && -n "$REALITY_PRIVATE_KEY" ]] || fail "解析主配置 Reality 参数失败"

# 3) 获取 PBK：优先 PBK env，否则从订阅文件提取 pbk=
PBK="${PBK:-}"
if [[ -z "$PBK" ]]; then
  [[ -f "$SUB_FILE" ]] || fail "PBK 未传且找不到：$SUB_FILE"
  PBK="$(grep -oE 'pbk=[^&]+' "$SUB_FILE" | head -n1 | cut -d= -f2 || true)"
fi
PBK="$(urldecode "$PBK")"
PBK="${PBK//[[:space:]]/}"
[[ -n "$PBK" ]] || fail "PBK 为空"

# 4) 获取客户端连接地址：
#    优先 SERVER_ADDR env
#    否则复用 /etc/default/vless-reality 中的 PUBLIC_DOMAIN
#    再不行才回退为公网 IP
SERVER_ADDR="${SERVER_ADDR:-}"

if [[ -z "$SERVER_ADDR" && -f "$DEFAULTS_FILE" ]]; then
  SERVER_ADDR="$(cfg_get "$DEFAULTS_FILE" PUBLIC_DOMAIN || true)"
fi

if [[ -n "$SERVER_ADDR" && "$SERVER_ADDR" != "your.domain.com" ]]; then
  if ! getent ahosts "$SERVER_ADDR" >/dev/null 2>&1; then
    fail "SERVER_ADDR/PUBLIC_DOMAIN 当前未解析：$SERVER_ADDR"
  fi
else
  SERVER_ADDR="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null | tr -d ' \r\n' || true)"
fi

[[ -n "$SERVER_ADDR" ]] || fail "获取连接地址失败；请手动传 SERVER_ADDR=你的域名"

# 5) 选端口（避免冲突）
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-60000}"

if ! [[ "$PORT_START" =~ ^[0-9]+$ ]] || ! [[ "$PORT_END" =~ ^[0-9]+$ ]] || \
   (( PORT_START < 1 || PORT_END > 65535 || PORT_START >= PORT_END )); then
  fail "PORT_START/PORT_END 无效（需要 1<=start<end<=65535），当前: ${PORT_START}-${PORT_END}"
fi

# 6) 生成 TAG / UUID / SHORT_ID
install -d -m 755 "$XRAY_DIR"
RAND="$(openssl rand -hex 2)"
TAG="${TAG_PREFIX}-$(date +%Y%m%d%H%M%S)-${RAND}"

if command -v xray >/dev/null 2>&1; then
  UUID="$(xray uuid)"
else
  UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

SHORT_ID="$(openssl rand -hex 8)"

CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
UNIT="/etc/systemd/system/${TAG}.service"

sanitize_one_line "$TAG" || fail "bad TAG"
sanitize_one_line "$UUID" || fail "bad UUID"
sanitize_one_line "$SERVER_ADDR" || fail "bad SERVER_ADDR"
sanitize_one_line "$REALITY_DEST" || fail "bad REALITY_DEST"
sanitize_one_line "$REALITY_SNI" || fail "bad REALITY_SNI"
sanitize_one_line "$SHORT_ID" || fail "bad SHORT_ID"
sanitize_one_line "$PBK" || fail "bad PBK"

START_OK=0
ATTEMPT=1
LAST_PORT=""
LAST_EXP=""

while (( ATTEMPT <= MAX_START_RETRIES )); do
  PORT="$(pick_free_port || true)"
  if [[ -z "${PORT:-}" ]]; then
    lock_release
    fail "在 ${PORT_START}-${PORT_END} 范围内没有空闲 TCP 端口了。"
  fi

  NOW="$(date +%s)"
  EXP="$((NOW + D))"
  LAST_PORT="$PORT"
  LAST_EXP="$EXP"

  write_temp_files "$PORT" "$NOW" "$EXP"

  if ! systemctl enable "${TAG}.service" >/dev/null 2>&1; then
    echo "⚠️ 无法 enable ${TAG}.service（可以稍后手动 systemctl enable ${TAG}.service）" >&2
  fi

  if [[ -n "$PQ_GIB" ]]; then
    if ! CREATE_EPOCH="$NOW" "$PQ_ADD" "$PORT" "$PQ_GIB" "$D" "$EXP"; then
      echo "❌ 绑定配额失败，正在回滚..." >&2
      lock_release
      FORCE=1 "$CLEANUP" "$TAG" >/dev/null 2>&1 || true
      exit 1
    fi
  fi

  systemctl start "${TAG}.service" >/dev/null 2>&1 || true

  if wait_unit_and_port_stable "${TAG}.service" "$PORT" 40 0.25 4; then
    START_OK=1
    break
  fi

  echo "⚠️ NAT 临时节点启动未稳定（尝试 ${ATTEMPT}/${MAX_START_RETRIES}，端口 ${PORT} 可能被占用或进程异常退出），准备自动重试..." >&2
  systemctl --no-pager --full status "${TAG}.service" >&2 || true
  journalctl -u "${TAG}.service" --no-pager -n 20 >&2 || true

  lock_release
  FORCE=1 "$CLEANUP" "$TAG" >/dev/null 2>&1 || true
  sleep 1
  lock_acquire

  ATTEMPT=$((ATTEMPT + 1))
done

lock_release

if (( START_OK != 1 )); then
  fail "启动 NAT 临时 VLESS 服务失败，已自动尝试 ${MAX_START_RETRIES} 次。"
fi

PBK_Q="$(urlencode "$PBK")"
LINK="vless://${UUID}@${SERVER_ADDR}:${LAST_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"

echo "✅ NAT 落地临时节点已生成：${TAG}"
echo "连接地址：${SERVER_ADDR}:${LAST_PORT}"
echo "WG 接口：${WG_IF}"
echo "MARK：${MARK_DEC}"
echo "TABLE_ID：${TABLE_ID}"
echo "有效期：${D} 秒"
echo "到期(北京时间)：$(TZ=Asia/Shanghai date -d "@${LAST_EXP}" '+%F %T')"
if [[ -n "$PQ_GIB" ]]; then
  echo "已绑定配额：${PQ_GIB}GiB"
fi
echo "VLESS 链接：${LINK}"
SH

chmod +x /usr/local/sbin/vless_mktemp_nat.sh
