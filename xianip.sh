#!/usr/bin/env bash
# xianip_rebuilt_v2.sh — Debian 12 完全重构版 v2
# 主节点忠实于 jichang.sh；后续模块全部从零重建
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"

curl_fs() {
  curl -fsSL --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}
check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then echo "❌ 请以 root 运行"; exit 1; fi
  local cn
  cn=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [[ "$cn" != "bookworm" ]]; then echo "❌ 仅支持 Debian 12，当前: ${cn:-未知}"; exit 1; fi
}
need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux logrotate
  for c in curl openssl python3 nft timeout ss flock; do
    command -v "$c" >/dev/null 2>&1 || { echo "❌ 缺少: $c"; exit 1; }
  done
}
download_upstreams() {
  mkdir -p "$UP_BASE"
  curl_fs "${REPO_BASE}/xray-install-release.sh" -o "${UP_BASE}/xray-install-release.sh"
  chmod +x "${UP_BASE}/xray-install-release.sh"
}

install_update_all() {
  cat >/usr/local/bin/update-all << 'UPDEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "❌ 需要 root"; exit 1; fi
cn=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
if [ "$cn" != "bookworm" ]; then echo "❌ 仅支持 bookworm"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3 && apt-get full-upgrade -y
apt-get --purge autoremove -y && apt-get autoclean -y && apt-get clean -y
BF=/etc/apt/sources.list.d/backports.list
[ -f "$BF" ] && cp "$BF" "${BF}.bak.$(date +%F-%H%M%S)"
echo 'deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware' >"$BF"
apt-get update -o Acquire::Retries=3
arch="$(dpkg --print-architecture)"
case "$arch" in amd64) i=linux-image-amd64;h=linux-headers-amd64;; arm64) i=linux-image-arm64;h=linux-headers-arm64;; *) echo "❌ 不支持: $arch";exit 1;; esac
apt-get -t bookworm-backports install -y "$i" "$h"
echo "⚠️ 重启后切换新内核: reboot"
UPDEOF
  chmod +x /usr/local/bin/update-all
}

# ==================== 2. VLESS Reality 主节点 ====================
install_vless_script() {
  cat >/root/onekey_reality_ipv4.sh << 'MAINEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"

curl4() {
  curl -4fsS --connect-timeout 3 --max-time 8 --retry 3 --retry-delay 1 "$@"
}
is_public_ipv4() {
  local ip="${1:-}"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = (sys.argv[1] or "").strip()
try:
    addr = ipaddress.ip_address(ip)
    if addr.version == 4 and addr.is_global:
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
}
get_public_ipv4() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
    if [[ -n "$ip" ]] && is_public_ipv4 "$ip"; then
      echo "$ip"; return 0
    fi
  done
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r' || true)"
  if [[ -n "$ip" ]] && is_public_ipv4 "$ip"; then
    echo "$ip"; return 0
  fi
  return 1
}
check_debian12() {
  if [ "$(id -u)" -ne 0 ]; then echo "❌ 请以 root 身份运行"; exit 1; fi
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [ "$codename" != "bookworm" ]; then
    echo "❌ 仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"; exit 1
  fi
}
install_xray_from_local_or_repo() {
  mkdir -p "$UP_BASE"
  local xray_installer="$UP_BASE/xray-install-release.sh"
  if [ ! -x "$xray_installer" ]; then
    echo "⬇ 从仓库获取 Xray 安装脚本..."
    curl4 -L "$REPO_BASE/xray-install-release.sh" -o "$xray_installer"
    chmod +x "$xray_installer"
  fi
  echo "⚙ 安装 / 更新 Xray-core..."
  "$xray_installer" install --without-geodata
  if [ ! -x /usr/local/bin/xray ]; then
    echo "❌ 未找到 /usr/local/bin/xray"; exit 1
  fi
}
force_xray_run_as_root() {
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/99-run-as-root.conf <<'DROPIN'
[Service]
User=root
Group=root
DROPIN
  systemctl daemon-reload
}
urlencode() {
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

check_debian12

VLESS_CONF="/etc/default/vless-reality"
if [[ ! -f "$VLESS_CONF" ]]; then
  echo "❌ 未找到 $VLESS_CONF，请先创建"
  echo '   PUBLIC_DOMAIN=your.domain.com'
  echo '   CAMOUFLAGE_DOMAIN=www.apple.com'
  echo '   REALITY_DEST=www.apple.com:443'
  echo '   REALITY_SNI=www.apple.com'
  echo '   PORT=443'
  echo '   NODE_NAME=VLESS-REALITY-IPv4'
  exit 1
fi
cfg_get() {
  awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$VLESS_CONF"
}
PUBLIC_DOMAIN="$(cfg_get PUBLIC_DOMAIN)"
CAMOUFLAGE_DOMAIN="$(cfg_get CAMOUFLAGE_DOMAIN)"
REALITY_DEST="$(cfg_get REALITY_DEST)"
REALITY_SNI="$(cfg_get REALITY_SNI)"
PORT="$(cfg_get PORT)"
NODE_NAME="$(cfg_get NODE_NAME)"
: "${CAMOUFLAGE_DOMAIN:=www.apple.com}"
: "${REALITY_DEST:=${CAMOUFLAGE_DOMAIN}:443}"
: "${REALITY_SNI:=${CAMOUFLAGE_DOMAIN}}"
: "${PORT:=443}"
: "${NODE_NAME:=VLESS-REALITY-IPv4}"
if [[ -z "$PUBLIC_DOMAIN" ]]; then
  echo "❌ PUBLIC_DOMAIN 未设置"; exit 1
fi

SERVER_IP="$(get_public_ipv4 || true)"
if [[ -z "$SERVER_IP" ]]; then
  echo "❌ 无法检测到公网 IPv4"; exit 1
fi
DNS_IP="$(python3 - "$PUBLIC_DOMAIN" <<'PY'
import socket, sys
try:
    r = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
    if r: print(r[0][4][0])
except Exception:
    pass
PY
)" || true
if [[ -z "$DNS_IP" ]]; then
  echo "❌ 无法解析 PUBLIC_DOMAIN=$PUBLIC_DOMAIN 的 A 记录"; exit 1
fi
if [[ "$DNS_IP" != "$SERVER_IP" ]]; then
  echo "❌ PUBLIC_DOMAIN A 记录 ($DNS_IP) 不指向本机 ($SERVER_IP)"; exit 1
fi

echo "服务器 IPv4:  $SERVER_IP"
echo "公共域名:     $PUBLIC_DOMAIN"
echo "伪装域名:     $CAMOUFLAGE_DOMAIN"
echo "Reality dest: $REALITY_DEST"
echo "Reality SNI:  $REALITY_SNI"
echo "端口:         $PORT"
sleep 2

echo "=== 1. 启用 BBR ==="
cat >/etc/sysctl.d/99-bbr.conf <<SYS
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-bbr.conf || true

echo "=== 2. 安装 / 更新 Xray-core ==="
install_xray_from_local_or_repo
force_xray_run_as_root
systemctl stop xray.service 2>/dev/null || true

echo "=== 3. 生成 UUID 与 Reality 密钥 ==="
UUID=$(/usr/local/bin/xray uuid)
KEY_OUT=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(printf '%s\n' "$KEY_OUT" | awk '/^PrivateKey:/{print $2;exit} /^Private key:/{print $3;exit}')
PUBLIC_KEY=$(printf '%s\n' "$KEY_OUT" | awk '/^PublicKey:/{print $2;exit} /^Public key:/{print $3;exit} /^Password:/{print $2;exit}')
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "❌ 无法解析 Reality 密钥："; echo "$KEY_OUT"; exit 1
fi
SHORT_ID=$(openssl rand -hex 8)

CONFIG_DIR=/usr/local/etc/xray
mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  cp -a "$CONFIG_DIR/config.json" "$CONFIG_DIR/config.json.bak.$(date +%F-%H%M%S)"
fi

cat >"$CONFIG_DIR/config.json" <<CONF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DEST",
          "xver": 0,
          "serverNames": [ "$REALITY_SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
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
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
CONF
chown root:root "$CONFIG_DIR/config.json" 2>/dev/null || true
chmod 600 "$CONFIG_DIR/config.json" 2>/dev/null || true

systemctl daemon-reload
systemctl enable xray.service >/dev/null 2>&1 || true
systemctl restart xray.service

STABLE_OK=0
for attempt in 1 2 3 4 5; do
  sleep 2
  if ! systemctl is-active --quiet xray.service; then continue; fi
  if ! ss -tlnH | grep -q ":${PORT} "; then continue; fi
  STABLE_OK=1; break
done
if [[ "$STABLE_OK" != "1" ]]; then
  echo "❌ xray 启动失败或端口未监听" >&2
  systemctl --no-pager --full status xray.service >&2 || true
  journalctl -u xray.service --no-pager -n 120 >&2 || true
  exit 1
fi
systemctl --no-pager --full status xray.service || true

PBK_Q="$(urlencode "$PUBLIC_KEY")"
VLESS_URL="vless://${UUID}@${PUBLIC_DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${NODE_NAME}"

if base64 --help 2>/dev/null | grep -q -- "-w"; then
  echo "$VLESS_URL" | base64 -w0 >/root/v2ray_subscription_base64.txt
else
  echo "$VLESS_URL" | base64 | tr -d '\n' >/root/v2ray_subscription_base64.txt
fi
echo "$VLESS_URL" >/root/vless_reality_vision_url.txt
chmod 600 /root/v2ray_subscription_base64.txt /root/vless_reality_vision_url.txt 2>/dev/null || true

echo
echo "================== 节点信息 =================="
echo "$VLESS_URL"
echo
echo "Base64 订阅："
cat /root/v2ray_subscription_base64.txt
echo
echo "保存位置："
echo "  /root/vless_reality_vision_url.txt"
echo "  /root/v2ray_subscription_base64.txt"
echo "✅ VLESS+Reality+Vision 安装完成 (PUBLIC_DOMAIN=${PUBLIC_DOMAIN})"
MAINEOF
  chmod +x /root/onekey_reality_ipv4.sh
}

# ==================== 3. 临时 VLESS 节点系统（从零重建） ====================
install_temp_vless_system() {

  cat >/usr/local/sbin/vless_cleanup_one.sh << 'CLEANEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

TAG="${1:?need TAG}"
UNIT_NAME="${TAG}.service"
XRAY_DIR="/usr/local/etc/xray"
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
FORCE="${FORCE:-0}"

LOCK="/run/vless-temp.lock"
if [[ "${VLESS_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9 || { echo "[cleanup_one] lock busy, skip: ${TAG}"; exit 0; }
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXP="$(meta_get EXPIRE_EPOCH "$META" || true)"
  if [[ -n "${EXP:-}" && "$EXP" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    if (( EXP > NOW )); then
      echo "[cleanup_one] ${TAG} 未到期，跳过"; exit 0
    fi
  fi
fi

echo "[cleanup_one] 清理: ${TAG}"
PORT="$(meta_get PORT "$META" 2>/dev/null || true)"

AS="$(systemctl show -p ActiveState --value "$UNIT_NAME" 2>/dev/null || true)"
if [[ "$AS" == "active" || "$AS" == "activating" ]]; then
  timeout 8 systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || \
    systemctl kill "$UNIT_NAME" >/dev/null 2>&1 || true
fi
systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true

if [[ -n "${PORT:-}" && "$PORT" =~ ^[0-9]+$ ]]; then
  /usr/local/sbin/pq_del.sh "$PORT" 2>/dev/null || true
  /usr/local/sbin/iplimit_del.sh "$PORT" 2>/dev/null || true
fi

rm -f "$CFG" "$META" "/etc/systemd/system/${UNIT_NAME}" 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
echo "[cleanup_one] 完成: ${TAG}"
CLEANEOF
  chmod +x /usr/local/sbin/vless_cleanup_one.sh

  cat >/usr/local/sbin/vless_run_temp.sh << 'RUNEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

TAG="${1:?need TAG}"
CFG="${2:?need config path}"
XRAY_BIN=$(command -v xray || echo /usr/local/bin/xray)
[[ -x "$XRAY_BIN" ]] || { echo "[run_temp] xray not found" >&2; exit 1; }

XRAY_DIR="/usr/local/etc/xray"
META="${XRAY_DIR}/${TAG}.meta"
[[ -f "$META" ]] || { echo "[run_temp] meta not found: $META" >&2; exit 1; }

EXPIRE_EPOCH="$(meta_get EXPIRE_EPOCH "$META" || true)"
if [[ -z "${EXPIRE_EPOCH:-}" || ! "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "[run_temp] bad EXPIRE_EPOCH" >&2; exit 1
fi

NOW=$(date +%s)
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  echo "[run_temp] $TAG already expired"
  FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" 2>/dev/null || true
  exit 0
fi

echo "[run_temp] $TAG for ${REMAIN}s (expire $EXPIRE_EPOCH)"
exec timeout "$REMAIN" "$XRAY_BIN" run -c "$CFG"
RUNEOF
  chmod +x /usr/local/sbin/vless_run_temp.sh

  cat >/usr/local/sbin/vless_mktemp.sh << 'MKEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${D:?用法: D=秒 vless_mktemp.sh}"
if ! [[ "$D" =~ ^[0-9]+$ ]] || (( D <= 0 )); then
  echo "❌ D 必须是正整数秒" >&2; exit 1
fi

LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9

curl4() { curl -4fsS --connect-timeout 3 --max-time 8 --retry 3 --retry-delay 1 "$@"; }
is_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    a = ipaddress.ip_address((sys.argv[1] or "").strip())
    sys.exit(0 if a.version == 4 and a.is_global else 1)
except Exception:
    sys.exit(1)
PY
}
get_public_ipv4() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com"; do
    ip="$(curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
    if [[ -n "$ip" ]] && is_public_ipv4 "$ip"; then echo "$ip"; return 0; fi
  done
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r' || true)"
  if [[ -n "$ip" ]] && is_public_ipv4 "$ip"; then echo "$ip"; return 0; fi
  return 1
}
urlencode() { python3 - "$1" <<'PY'
import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}
urldecode() { python3 - "$1" <<'PY'
import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))
PY
}
sanitize_one_line() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

XRAY_BIN=$(command -v xray || echo /usr/local/bin/xray)
[ -x "$XRAY_BIN" ] || { echo "❌ 未找到 xray"; exit 1; }

XRAY_DIR="/usr/local/etc/xray"
MAIN_CFG="${XRAY_DIR}/config.json"
[[ -f "$MAIN_CFG" ]] || { echo "❌ 未找到主配置 ${MAIN_CFG}"; exit 1; }

mapfile -t arr < <(python3 - "$MAIN_CFG" << 'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
ibs=cfg.get("inbounds",[])
if not ibs: print(""); print(""); print("")
else:
    ib=ibs[0]
    rs=ib.get("streamSettings",{}).get("realitySettings",{})
    print(rs.get("privateKey",""))
    print(rs.get("dest",""))
    sns=rs.get("serverNames",[])
    print(sns[0] if sns else "")
PY
)
REALITY_PRIVATE_KEY="${arr[0]:-}"
REALITY_DEST="${arr[1]:-}"
REALITY_SNI="${arr[2]:-}"
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_DEST" ]]; then
  echo "❌ 无法从 ${MAIN_CFG} 解析 Reality 配置" >&2; exit 1
fi
[[ -z "$REALITY_SNI" ]] && REALITY_SNI="${REALITY_DEST%%:*}"

PBK_INPUT="${PBK:-}"
PBK="$PBK_INPUT"
if [[ -z "$PBK" && -f /root/vless_reality_vision_url.txt ]]; then
  LINE=$(sed -n '1p' /root/vless_reality_vision_url.txt 2>/dev/null || true)
  if [[ -n "$LINE" ]]; then
    PBK=$(grep -o 'pbk=[^&]*' <<< "$LINE" | head -n1 | cut -d= -f2)
  fi
fi
if [[ -z "$PBK" ]]; then
  echo "❌ 未能获取 pbk，请先运行 onekey_reality_ipv4.sh 或手动传入 PBK=" >&2; exit 1
fi
PBK_RAW="$(urldecode "$PBK")"
PBK="$PBK_RAW"

PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
MAX_START_RETRIES="${MAX_START_RETRIES:-3}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
PQ_GIB="${PQ_GIB:-0}"

if ! [[ "$PORT_START" =~ ^[0-9]+$ ]] || ! [[ "$PORT_END" =~ ^[0-9]+$ ]] || \
   (( PORT_START < 1 || PORT_END > 65535 || PORT_START >= PORT_END )); then
  echo "❌ PORT_START/PORT_END 无效" >&2; exit 1
fi

declare -A USED_PORTS=()
while read -r p; do
  [[ -n "$p" ]] && USED_PORTS["$p"]=1
done < <(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')
shopt -s nullglob
for f in "${XRAY_DIR}"/vless-temp-*.meta; do
  p="$(awk -F= '$1=="PORT"{sub($1"=","");print;exit}' "$f" 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
done
shopt -u nullglob

PORT="$PORT_START"
while (( PORT <= PORT_END )); do
  [[ -z "${USED_PORTS[$PORT]+x}" ]] && break
  PORT=$((PORT+1))
done
(( PORT <= PORT_END )) || { echo "❌ 无空闲端口" >&2; exit 1; }

UUID="$("$XRAY_BIN" uuid)"
SHORT_ID="$(openssl rand -hex 8)"
if [[ -n "${id:-}" ]]; then
  TAG="vless-temp-${id}"
else
  TAG="vless-temp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
fi
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"

if [[ -f "$META" ]]; then
  echo "❌ 节点 ${TAG} 已存在，请换 id 或先清理" >&2; exit 1
fi

SERVER_ADDR="$(get_public_ipv4 || true)"
[[ -z "$SERVER_ADDR" ]] && { echo "❌ 无法获取公网 IPv4" >&2; exit 1; }

NOW=$(date +%s)
EXP=$((NOW + D))

mkdir -p "$XRAY_DIR"

cat >"$CFG" <<TCFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
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
          "serverNames": [ "${REALITY_SNI}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
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
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
TCFG

sanitize_one_line "$TAG" || { echo "❌ bad TAG"; exit 1; }
sanitize_one_line "$UUID" || { echo "❌ bad UUID"; exit 1; }
sanitize_one_line "$SERVER_ADDR" || { echo "❌ bad SERVER_ADDR"; exit 1; }
sanitize_one_line "$REALITY_DEST" || { echo "❌ bad REALITY_DEST"; exit 1; }
sanitize_one_line "$REALITY_SNI" || { echo "❌ bad REALITY_SNI"; exit 1; }
sanitize_one_line "$SHORT_ID" || { echo "❌ bad SHORT_ID"; exit 1; }
sanitize_one_line "$PBK" || { echo "❌ bad PBK"; exit 1; }

cat >"$META" <<TMETA
TAG=$TAG
UUID=$UUID
PORT=$PORT
SERVER_ADDR=$SERVER_ADDR
EXPIRE_EPOCH=$EXP
CREATED_EPOCH=$NOW
DURATION_SECONDS=$D
REALITY_DEST=$REALITY_DEST
REALITY_SNI=$REALITY_SNI
SHORT_ID=$SHORT_ID
PBK=$PBK
PQ_GIB=$PQ_GIB
IP_LIMIT=$IP_LIMIT
IP_STICKY_SECONDS=$IP_STICKY_SECONDS
TMETA
chmod 600 "$CFG" "$META" 2>/dev/null || true

UNIT="/etc/systemd/system/${TAG}.service"
cat >"$UNIT" <<TUNIT
[Unit]
Description=Temp VLESS $TAG
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/vless_run_temp.sh $TAG $CFG
ExecStopPost=/usr/local/sbin/vless_cleanup_one.sh $TAG
Restart=no
SuccessExitStatus=124 143

[Install]
WantedBy=multi-user.target
TUNIT

systemctl daemon-reload

rollback() {
  echo "❌ 回滚 ${TAG}..." >&2
  VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" 2>/dev/null || true
  exit 1
}

START_OK=0
for try in $(seq 1 "$MAX_START_RETRIES"); do
  systemctl enable "$TAG".service >/dev/null 2>&1 || true
  systemctl start "$TAG".service 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet "$TAG".service && ss -tlnH | grep -q ":${PORT} "; then
    START_OK=1; break
  fi
  systemctl stop "$TAG".service 2>/dev/null || true
  sleep 1
done
if [[ "$START_OK" != "1" ]]; then rollback; fi

if [[ "$PQ_GIB" =~ ^[0-9]+$ ]] && (( PQ_GIB > 0 )); then
  if ! /usr/local/sbin/pq_add.sh "$PORT" "$PQ_GIB" "$NOW" "$D"; then
    echo "❌ 配额创建失败" >&2; rollback
  fi
fi

if [[ "$IP_LIMIT" =~ ^[0-9]+$ ]] && (( IP_LIMIT > 0 )); then
  if ! /usr/local/sbin/iplimit_add.sh "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS"; then
    echo "❌ IP 限制创建失败" >&2; rollback
  fi
fi

E_STR=$(TZ=Asia/Shanghai date -d "@$EXP" '+%F %T')
PBK_Q="$(urlencode "$PBK")"
VLESS_URL="vless://${UUID}@${SERVER_ADDR}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"

echo "✅ 临时节点: $TAG"
echo "地址: ${SERVER_ADDR}:${PORT}"
echo "UUID: ${UUID}"
echo "有效期: ${D}s"
echo "到期(北京): ${E_STR}"
if (( PQ_GIB > 0 )); then echo "配额: ${PQ_GIB}GiB"; fi
if (( IP_LIMIT > 0 )); then echo "IP限制: ${IP_LIMIT} (超时${IP_STICKY_SECONDS}s)"; fi
echo "链接: ${VLESS_URL}"
MKEOF
  chmod +x /usr/local/sbin/vless_mktemp.sh

  cat >/usr/local/sbin/vless_gc.sh << 'GCEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

XRAY_DIR="/usr/local/etc/xray"
NOW=$(date +%s)

for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get TAG "$META" || true)"
  EXP="$(meta_get EXPIRE_EPOCH "$META" || true)"
  [[ -z "${TAG:-}" ]] && continue
  [[ -z "${EXP:-}" || ! "${EXP}" =~ ^[0-9]+$ ]] && continue
  if (( EXP <= NOW )); then
    VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
  fi
done
GCEOF
  chmod +x /usr/local/sbin/vless_gc.sh

  cat >/usr/local/sbin/vless_clear_all.sh << 'CLREOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9

XRAY_DIR="/usr/local/etc/xray"
META_FILES=("$XRAY_DIR"/vless-temp-*.meta)
if (( ${#META_FILES[@]} == 0 )); then
  echo "当前没有临时节点。"; exit 0
fi
for META in "${META_FILES[@]}"; do
  TAG="$(meta_get TAG "$META" || true)"
  [[ -z "${TAG:-}" ]] && continue
  echo "清理 ${TAG}"
  VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
done
systemctl daemon-reload >/dev/null 2>&1 || true
echo "✅ 所有临时节点已清理"
CLREOF
  chmod +x /usr/local/sbin/vless_clear_all.sh

  cat >/usr/local/sbin/vless_audit.sh << 'VAUDITEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

get_counter_bytes() {
  nft list counter inet portquota "$1" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++)if($i=="bytes"){print $(i+1);exit}}'
}

XRAY_DIR="/usr/local/etc/xray"
MAIN_CFG="${XRAY_DIR}/config.json"

get_main_port() {
  if [[ -f "$MAIN_CFG" ]]; then
    python3 - "$MAIN_CFG" <<'PY' 2>/dev/null || echo "443"
import json,sys
try:
    cfg=json.load(open(sys.argv[1]))
    ibs=cfg.get("inbounds",[])
    if ibs: print(ibs[0].get("port",443)); sys.exit(0)
except Exception: pass
print("443")
PY
  else echo "443"; fi
}

fmt="%-36s %-10s %-6s %-5s %-10s %-10s %-10s %-6s %-12s %-20s %-8s %-5s %-6s\n"
printf "$fmt" "NAME" "STATE" "PORT" "LISTEN" "LIMIT" "USED" "LEFT" "USE%" "TTL" "EXPIRE(Beijing)" "IP_LIM" "SLOTS" "STICKY"

MAIN_PORT="$(get_main_port)"
MAIN_STATE="$(systemctl is-active xray.service 2>/dev/null || echo unknown)"
MAIN_LISTEN="no"
ss -tlnH 2>/dev/null | grep -q ":${MAIN_PORT} " && MAIN_LISTEN="yes"
printf "$fmt" "xray.service" "$MAIN_STATE" "$MAIN_PORT" "$MAIN_LISTEN" "-" "-" "-" "-" "permanent" "-" "-" "-" "-"

NOW_TS=$(date +%s)
for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get TAG "$META" || true)"
  PORT="$(meta_get PORT "$META" || true)"
  EXP="$(meta_get EXPIRE_EPOCH "$META" || true)"
  T_PQ="$(meta_get PQ_GIB "$META" || true)"
  T_IPL="$(meta_get IP_LIMIT "$META" || true)"
  T_STICKY="$(meta_get IP_STICKY_SECONDS "$META" || true)"
  [[ -z "${TAG:-}" || -z "${PORT:-}" ]] && continue

  NAME="${TAG}.service"
  STATE="$(systemctl is-active "$NAME" 2>/dev/null || echo unknown)"
  LISTEN="no"
  ss -tlnH 2>/dev/null | grep -q ":${PORT} " && LISTEN="yes"

  LEFT_STR="N/A"; EXP_FMT="N/A"
  if [[ -n "${EXP:-}" && "$EXP" =~ ^[0-9]+$ ]]; then
    LEFT=$((EXP - NOW_TS))
    if (( LEFT <= 0 )); then LEFT_STR="expired"
    else
      Dd=$((LEFT/86400)); Hh=$(((LEFT%86400)/3600)); Mm=$(((LEFT%3600)/60))
      LEFT_STR=$(printf "%dd%02dh%02dm" "$Dd" "$Hh" "$Mm")
    fi
    EXP_FMT="$(TZ='Asia/Shanghai' date -d "@${EXP}" '+%Y-%m-%d %H:%M:%S')"
  fi

  Q_LIMIT="-"; Q_USED="-"; Q_LEFT="-"; Q_PCT="-"
  PQ_META="/etc/portquota/pq-${PORT}.meta"
  if [[ -f "$PQ_META" ]]; then
    ORIG="$(meta_get ORIGINAL_LIMIT_BYTES "$PQ_META" || true)"
    SAVED="$(meta_get SAVED_USED_BYTES "$PQ_META" || true)"
    : "${ORIG:=0}"; : "${SAVED:=0}"
    LIVE_OUT="$(get_counter_bytes "pq_cnt_out_${PORT}" || true)"; : "${LIVE_OUT:=0}"
    LIVE_IN="$(get_counter_bytes "pq_cnt_in_${PORT}" || true)"; : "${LIVE_IN:=0}"
    LIVE=$((LIVE_OUT + LIVE_IN))
    USED=$((SAVED + LIVE))
    if (( ORIG > 0 )); then
      QLEFT=$((ORIG - USED)); (( QLEFT < 0 )) && QLEFT=0
      Q_LIMIT="$(awk -v b="$ORIG" 'BEGIN{printf "%.2fG",b/1073741824}')"
      Q_USED="$(awk -v b="$USED" 'BEGIN{printf "%.2fG",b/1073741824}')"
      Q_LEFT="$(awk -v b="$QLEFT" 'BEGIN{printf "%.2fG",b/1073741824}')"
      Q_PCT="$(awk -v u="$USED" -v l="$ORIG" 'BEGIN{if(l>0)printf "%.1f%%",(u*100.0)/l; else print "N/A"}')"
    fi
  fi

  IPL_STR="-"; SLOTS_STR="-"; STICKY_STR="-"
  if [[ "${T_IPL:-0}" =~ ^[0-9]+$ ]] && (( T_IPL > 0 )); then
    IPL_STR="$T_IPL"
    STICKY_STR="${T_STICKY:-120}"
    SLOTS_STR="$(nft list set inet iplimit "iplimit_${PORT}" 2>/dev/null | grep -c 'expires' || echo 0)"
  fi

  printf "$fmt" "$NAME" "$STATE" "$PORT" "$LISTEN" "$Q_LIMIT" "$Q_USED" "$Q_LEFT" "$Q_PCT" "$LEFT_STR" "$EXP_FMT" "$IPL_STR" "$SLOTS_STR" "$STICKY_STR"
done
VAUDITEOF
  chmod +x /usr/local/sbin/vless_audit.sh

  cat >/etc/systemd/system/vless-gc.service << 'GCSVCEOF'
[Unit]
Description=VLESS Temp Nodes GC
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_gc.sh
GCSVCEOF

  cat >/etc/systemd/system/vless-gc.timer << 'GCTMREOF'
[Unit]
Description=Run VLESS GC every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
GCTMREOF

  systemctl daemon-reload
  systemctl enable --now vless-gc.timer || true
  echo "✅ 临时 VLESS 节点系统部署完成"
}

# ==================== 4. 端口配额系统（从零重建） ====================
install_port_quota() {
  mkdir -p /etc/portquota
  systemctl enable --now nftables >/dev/null 2>&1 || true

  cat >/usr/local/sbin/pq_add.sh << 'PQADDEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"; GIB="${2:-}"
CREATED_EPOCH="${3:-$(date +%s)}"
DURATION_SECONDS="${4:-0}"
if [[ -z "$PORT" || -z "$GIB" ]]; then
  echo "用法: pq_add.sh <端口> <GiB> [created_epoch] [duration_s]" >&2; exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
  echo "❌ 端口无效" >&2; exit 1
fi
if ! [[ "$GIB" =~ ^[0-9]+$ ]] || ((GIB<=0)); then
  echo "❌ GiB 需为正整数" >&2; exit 1
fi

BYTES=$((GIB * 1073741824))

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"; flock -w 10 9
fi

nft list table inet portquota >/dev/null 2>&1 || nft add table inet portquota
nft list chain inet portquota pq_out >/dev/null 2>&1 || \
  nft add chain inet portquota pq_out '{ type filter hook output priority filter; policy accept; }'
nft list chain inet portquota pq_in >/dev/null 2>&1 || \
  nft add chain inet portquota pq_in '{ type filter hook input priority filter; policy accept; }'

for chain in pq_out pq_in; do
  nft -a list chain inet portquota "$chain" 2>/dev/null | \
    awk -v p="$PORT" '$0 ~ "comment \"pq-[a-z]+-"p"\"" {print $NF}' | \
    while read -r h; do
      nft delete rule inet portquota "$chain" handle "$h" 2>/dev/null || true
    done
done
nft delete counter inet portquota "pq_cnt_out_$PORT" 2>/dev/null || true
nft delete counter inet portquota "pq_cnt_in_$PORT" 2>/dev/null || true
nft delete quota inet portquota "pq_quota_$PORT" 2>/dev/null || true

nft add counter inet portquota "pq_cnt_out_$PORT"
nft add counter inet portquota "pq_cnt_in_$PORT"
nft add quota inet portquota "pq_quota_$PORT" { over "$BYTES" bytes }

nft add rule inet portquota pq_out tcp sport "$PORT" \
  quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
nft add rule inet portquota pq_out tcp sport "$PORT" \
  counter name "pq_cnt_out_$PORT" comment "pq-cnt-out-$PORT"
nft add rule inet portquota pq_in tcp dport "$PORT" \
  quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
nft add rule inet portquota pq_in tcp dport "$PORT" \
  counter name "pq_cnt_in_$PORT" comment "pq-cnt-in-$PORT"

mkdir -p /etc/portquota
cat >/etc/portquota/pq-"$PORT".meta <<PQMETA
PORT=$PORT
ORIGINAL_LIMIT_BYTES=$BYTES
SAVED_USED_BYTES=0
LIMIT_BYTES=$BYTES
CREATED_EPOCH=$CREATED_EPOCH
DURATION_SECONDS=$DURATION_SECONDS
LAST_RESET_EPOCH=$CREATED_EPOCH
PQMETA

echo "✅ 端口 $PORT 配额 ${GIB}GiB"
PQADDEOF
  chmod +x /usr/local/sbin/pq_add.sh

  cat >/usr/local/sbin/pq_del.sh << 'PQDELEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
if [[ -z "$PORT" ]]; then echo "用法: pq_del.sh <端口>" >&2; exit 1; fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
  echo "❌ 端口无效" >&2; exit 1
fi

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"; flock -w 10 9
fi

for chain in pq_out pq_in; do
  if nft list chain inet portquota "$chain" >/dev/null 2>&1; then
    nft -a list chain inet portquota "$chain" 2>/dev/null | \
      awk -v p="$PORT" '$0 ~ "comment \"pq-[a-z]+-"p"\"" {print $NF}' | \
      while read -r h; do
        nft delete rule inet portquota "$chain" handle "$h" 2>/dev/null || true
      done
  fi
done
nft delete counter inet portquota "pq_cnt_out_$PORT" 2>/dev/null || true
nft delete counter inet portquota "pq_cnt_in_$PORT" 2>/dev/null || true
nft delete quota inet portquota "pq_quota_$PORT" 2>/dev/null || true

rm -f "/etc/portquota/pq-${PORT}.meta"
echo "✅ 端口 $PORT 配额已删除"
PQDELEOF
  chmod +x /usr/local/sbin/pq_del.sh

  cat >/usr/local/sbin/pq_save_state.sh << 'PQSAVEEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }
meta_set() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

get_counter_bytes() {
  nft list counter inet portquota "$1" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++)if($i=="bytes"){print $(i+1);exit}}'
}

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9

for PQ_META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get PORT "$PQ_META" || true)"
  [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ]] && continue

  ORIG="$(meta_get ORIGINAL_LIMIT_BYTES "$PQ_META" || true)"; : "${ORIG:=0}"
  SAVED="$(meta_get SAVED_USED_BYTES "$PQ_META" || true)"; : "${SAVED:=0}"

  LIVE_OUT="$(get_counter_bytes "pq_cnt_out_${PORT}" || true)"; : "${LIVE_OUT:=0}"
  LIVE_IN="$(get_counter_bytes "pq_cnt_in_${PORT}" || true)"; : "${LIVE_IN:=0}"
  LIVE=$((LIVE_OUT + LIVE_IN))

  NEW_SAVED=$((SAVED + LIVE))
  NEW_LIMIT=$((ORIG - NEW_SAVED))
  (( NEW_LIMIT < 0 )) && NEW_LIMIT=0

  meta_set "$PQ_META" SAVED_USED_BYTES "$NEW_SAVED"
  meta_set "$PQ_META" LIMIT_BYTES "$NEW_LIMIT"

  for chain in pq_out pq_in; do
    nft -a list chain inet portquota "$chain" 2>/dev/null | \
      awk -v p="$PORT" '$0 ~ "comment \"pq-[a-z]+-"p"\"" {print $NF}' | \
      while read -r h; do
        nft delete rule inet portquota "$chain" handle "$h" 2>/dev/null || true
      done
  done
  nft delete counter inet portquota "pq_cnt_out_$PORT" 2>/dev/null || true
  nft delete counter inet portquota "pq_cnt_in_$PORT" 2>/dev/null || true
  nft delete quota inet portquota "pq_quota_$PORT" 2>/dev/null || true

  nft add counter inet portquota "pq_cnt_out_$PORT"
  nft add counter inet portquota "pq_cnt_in_$PORT"
  nft add quota inet portquota "pq_quota_$PORT" { over "$NEW_LIMIT" bytes }

  nft add rule inet portquota pq_out tcp sport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
  nft add rule inet portquota pq_out tcp sport "$PORT" \
    counter name "pq_cnt_out_$PORT" comment "pq-cnt-out-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    counter name "pq_cnt_in_$PORT" comment "pq-cnt-in-$PORT"

done
echo "$(date '+%F %T %Z') [pq_save_state] saved" >> /var/log/pq-save.log 2>/dev/null || true
PQSAVEEOF
  chmod +x /usr/local/sbin/pq_save_state.sh

  cat >/usr/local/sbin/pq_restore.sh << 'PQRESTEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9

nft list table inet portquota >/dev/null 2>&1 || nft add table inet portquota
nft list chain inet portquota pq_out >/dev/null 2>&1 || \
  nft add chain inet portquota pq_out '{ type filter hook output priority filter; policy accept; }'
nft list chain inet portquota pq_in >/dev/null 2>&1 || \
  nft add chain inet portquota pq_in '{ type filter hook input priority filter; policy accept; }'

for PQ_META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get PORT "$PQ_META" || true)"
  [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ]] && continue

  LIMIT="$(meta_get LIMIT_BYTES "$PQ_META" || true)"; : "${LIMIT:=0}"

  nft delete counter inet portquota "pq_cnt_out_$PORT" 2>/dev/null || true
  nft delete counter inet portquota "pq_cnt_in_$PORT" 2>/dev/null || true
  nft delete quota inet portquota "pq_quota_$PORT" 2>/dev/null || true

  nft add counter inet portquota "pq_cnt_out_$PORT"
  nft add counter inet portquota "pq_cnt_in_$PORT"
  nft add quota inet portquota "pq_quota_$PORT" { over "$LIMIT" bytes }

  nft add rule inet portquota pq_out tcp sport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
  nft add rule inet portquota pq_out tcp sport "$PORT" \
    counter name "pq_cnt_out_$PORT" comment "pq-cnt-out-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    counter name "pq_cnt_in_$PORT" comment "pq-cnt-in-$PORT"

  echo "[pq_restore] port $PORT restored with ${LIMIT} bytes remaining"
done
PQRESTEOF
  chmod +x /usr/local/sbin/pq_restore.sh

  cat >/usr/local/sbin/pq_audit.sh << 'PQAUDITEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }
get_counter_bytes() {
  nft list counter inet portquota "$1" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++)if($i=="bytes"){print $(i+1);exit}}'
}

printf "%-8s %-8s %-12s %-12s %-12s %-12s %-8s\n" \
  "PORT" "STATE" "USED(GiB)" "LEFT(GiB)" "LIMIT(GiB)" "SAVED(GiB)" "USE%"

for PQ_META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get PORT "$PQ_META" || true)"
  [[ -z "$PORT" ]] && continue

  ORIG="$(meta_get ORIGINAL_LIMIT_BYTES "$PQ_META" || true)"; : "${ORIG:=0}"
  SAVED="$(meta_get SAVED_USED_BYTES "$PQ_META" || true)"; : "${SAVED:=0}"

  LIVE_OUT="$(get_counter_bytes "pq_cnt_out_${PORT}" || true)"; : "${LIVE_OUT:=0}"
  LIVE_IN="$(get_counter_bytes "pq_cnt_in_${PORT}" || true)"; : "${LIVE_IN:=0}"
  LIVE=$((LIVE_OUT + LIVE_IN))
  USED=$((SAVED + LIVE))
  LEFT=$((ORIG - USED)); (( LEFT < 0 )) && LEFT=0

  STATE="ok"
  (( ORIG > 0 && LEFT == 0 )) && STATE="blocked"

  G=1073741824
  U_G="$(awk -v b="$USED" -v g="$G" 'BEGIN{printf "%.2f",b/g}')"
  L_G="$(awk -v b="$LEFT" -v g="$G" 'BEGIN{printf "%.2f",b/g}')"
  O_G="$(awk -v b="$ORIG" -v g="$G" 'BEGIN{printf "%.2f",b/g}')"
  S_G="$(awk -v b="$SAVED" -v g="$G" 'BEGIN{printf "%.2f",b/g}')"
  PCT="N/A"
  if (( ORIG > 0 )); then
    PCT="$(awk -v u="$USED" -v l="$ORIG" 'BEGIN{printf "%.1f%%",(u*100.0)/l}')"
  fi

  printf "%-8s %-8s %-12s %-12s %-12s %-12s %-8s\n" \
    "$PORT" "$STATE" "$U_G" "$L_G" "$O_G" "$S_G" "$PCT"
done
PQAUDITEOF
  chmod +x /usr/local/sbin/pq_audit.sh

  cat >/usr/local/sbin/pq_reset.sh << 'PQRESETEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { awk -F= -v k="$1" '$1==k {sub($1"=",""); print; exit}' "$2"; }
meta_set() {
  local file="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

THIRTY_DAYS=2592000
NOW=$(date +%s)

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9

for PQ_META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get PORT "$PQ_META" || true)"
  [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ]] && continue

  DUR="$(meta_get DURATION_SECONDS "$PQ_META" || true)"; : "${DUR:=0}"
  if ! [[ "$DUR" =~ ^[0-9]+$ ]] || (( DUR <= THIRTY_DAYS )); then
    continue
  fi

  LAST="$(meta_get LAST_RESET_EPOCH "$PQ_META" || true)"; : "${LAST:=0}"
  if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then LAST=0; fi

  if (( (NOW - LAST) < THIRTY_DAYS )); then
    continue
  fi

  ORIG="$(meta_get ORIGINAL_LIMIT_BYTES "$PQ_META" || true)"; : "${ORIG:=0}"

  meta_set "$PQ_META" SAVED_USED_BYTES "0"
  meta_set "$PQ_META" LIMIT_BYTES "$ORIG"
  meta_set "$PQ_META" LAST_RESET_EPOCH "$NOW"

  for chain in pq_out pq_in; do
    nft -a list chain inet portquota "$chain" 2>/dev/null | \
      awk -v p="$PORT" '$0 ~ "comment \"pq-[a-z]+-"p"\"" {print $NF}' | \
      while read -r h; do
        nft delete rule inet portquota "$chain" handle "$h" 2>/dev/null || true
      done
  done
  nft delete counter inet portquota "pq_cnt_out_$PORT" 2>/dev/null || true
  nft delete counter inet portquota "pq_cnt_in_$PORT" 2>/dev/null || true
  nft delete quota inet portquota "pq_quota_$PORT" 2>/dev/null || true

  nft add counter inet portquota "pq_cnt_out_$PORT"
  nft add counter inet portquota "pq_cnt_in_$PORT"
  nft add quota inet portquota "pq_quota_$PORT" { over "$ORIG" bytes }

  nft add rule inet portquota pq_out tcp sport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
  nft add rule inet portquota pq_out tcp sport "$PORT" \
    counter name "pq_cnt_out_$PORT" comment "pq-cnt-out-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
  nft add rule inet portquota pq_in tcp dport "$PORT" \
    counter name "pq_cnt_in_$PORT" comment "pq-cnt-in-$PORT"

  echo "$(date '+%F %T %Z') [pq_reset] port $PORT reset" >> /var/log/pq-save.log 2>/dev/null || true
done
PQRESETEOF
  chmod +x /usr/local/sbin/pq_reset.sh

  cat >/etc/systemd/system/pq-save.service << 'PQSSVCEOF'
[Unit]
Description=Save portquota state (counters to metadata)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
PQSSVCEOF

  cat >/etc/systemd/system/pq-save.timer << 'PQSTMREOF'
[Unit]
Description=Save portquota state every 5 minutes

[Timer]
OnBootSec=60s
OnUnitActiveSec=300s
Persistent=true

[Install]
WantedBy=timers.target
PQSTMREOF

  cat >/etc/systemd/system/pq-shutdown-save.service << 'PQSDEOF'
[Unit]
Description=Save portquota state before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/sbin/pq_save_state.sh

[Install]
WantedBy=multi-user.target
PQSDEOF

  cat >/etc/systemd/system/pq-boot-restore.service << 'PQBREOF'
[Unit]
Description=Restore portquota state on boot
After=nftables.service network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_restore.sh

[Install]
WantedBy=multi-user.target
PQBREOF

  cat >/etc/systemd/system/pq-reset.service << 'PQRSVCEOF'
[Unit]
Description=Automatic 30-day quota reset

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset.sh
PQRSVCEOF

  cat >/etc/systemd/system/pq-reset.timer << 'PQRTMREOF'
[Unit]
Description=Check quota reset daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
PQRTMREOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
  systemctl enable pq-shutdown-save.service >/dev/null 2>&1 || true
  systemctl start pq-shutdown-save.service >/dev/null 2>&1 || true
  systemctl enable pq-boot-restore.service >/dev/null 2>&1 || true
  systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
  echo "✅ 端口配额系统部署完成"
}

# ==================== 5. 源 IP 槽位限制系统（从零重建） ====================
install_ip_limit() {

  cat >/usr/local/sbin/iplimit_add.sh << 'IPLADDEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:?用法: iplimit_add.sh <端口> <IP数> [超时秒]}"
LIMIT="${2:?需要 IP 数量}"
TIMEOUT="${3:-120}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT<1||PORT>65535)); then
  echo "❌ 端口无效" >&2; exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || ((LIMIT<1)); then
  echo "❌ IP 数量需为正整数" >&2; exit 1
fi
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || ((TIMEOUT<1)); then
  echo "❌ 超时需为正整数秒" >&2; exit 1
fi

nft list table inet iplimit >/dev/null 2>&1 || nft add table inet iplimit
nft list chain inet iplimit ipl_in >/dev/null 2>&1 || \
  nft add chain inet iplimit ipl_in '{ type filter hook input priority filter; policy accept; }'

nft -a list chain inet iplimit ipl_in 2>/dev/null | \
  awk -v p="$PORT" '$0 ~ "comment \"ipl-[a-z]+-"p"\"" {print $NF}' | \
  while read -r h; do
    nft delete rule inet iplimit ipl_in handle "$h" 2>/dev/null || true
  done
nft delete set inet iplimit "iplimit_${PORT}" 2>/dev/null || true

nft add set inet iplimit "iplimit_${PORT}" \
  "{ type ipv4_addr; size ${LIMIT}; timeout ${TIMEOUT}s; flags dynamic; }"

nft add rule inet iplimit ipl_in tcp dport "$PORT" \
  update @"iplimit_${PORT}" { ip saddr timeout "${TIMEOUT}s" } \
  accept comment "ipl-accept-$PORT"
nft add rule inet iplimit ipl_in tcp dport "$PORT" \
  drop comment "ipl-drop-$PORT"

echo "✅ 端口 $PORT IP限制: ${LIMIT}个, 超时${TIMEOUT}s"
IPLADDEOF
  chmod +x /usr/local/sbin/iplimit_add.sh

  cat >/usr/local/sbin/iplimit_del.sh << 'IPLDELEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:?用法: iplimit_del.sh <端口>}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then exit 0; fi

if nft list chain inet iplimit ipl_in >/dev/null 2>&1; then
  nft -a list chain inet iplimit ipl_in 2>/dev/null | \
    awk -v p="$PORT" '$0 ~ "comment \"ipl-[a-z]+-"p"\"" {print $NF}' | \
    while read -r h; do
      nft delete rule inet iplimit ipl_in handle "$h" 2>/dev/null || true
    done
fi
nft delete set inet iplimit "iplimit_${PORT}" 2>/dev/null || true
echo "✅ 端口 $PORT IP限制已删除"
IPLDELEOF
  chmod +x /usr/local/sbin/iplimit_del.sh
  echo "✅ IP 限制系统部署完成"
}

# ==================== 6. 日志轮转 ====================
install_logrotate_rules() {
  cat >/etc/logrotate.d/portquota-vless <<'LREOF'
/var/log/pq-save.log /var/log/vless-gc.log {
    daily
    rotate 2
    maxage 2
    missingok
    notifempty
    compress
    delaycompress
    dateext
    create 0640 root adm
}
LREOF
}

# ==================== 7. systemd journal 清理 ====================
install_journal_vacuum() {
  cat >/etc/systemd/system/journal-vacuum.service <<'JVSVCEOF'
[Unit]
Description=Vacuum systemd journal (keep 2 days)

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=2d
JVSVCEOF

  cat >/etc/systemd/system/journal-vacuum.timer <<'JVTMREOF'
[Unit]
Description=Daily vacuum systemd journal

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
JVTMREOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now journal-vacuum.timer >/dev/null 2>&1 || true
}

# ==================== 主流程 ====================
main() {
  check_debian12
  need_basic_tools
  download_upstreams

  install_update_all
  install_vless_script
  install_temp_vless_system
  install_port_quota
  install_ip_limit
  install_logrotate_rules
  install_journal_vacuum

  cat <<'DONEEOF'
==================================================
✅ 所有脚本已部署完毕（Debian 12）

可用命令：

1) 系统更新 + 新内核:
   update-all && reboot

2) VLESS Reality 主节点:
   bash /root/onekey_reality_ipv4.sh

3) 临时 VLESS 节点:
   D=600 vless_mktemp.sh
   id="tmp001" IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
   vless_audit.sh
   vless_clear_all.sh
   FORCE=1 vless_cleanup_one.sh <TAG>

4) 端口配额:
   pq_add.sh <端口> <GiB>
   pq_audit.sh
   pq_del.sh <端口>

5) IP 限制:
   iplimit_add.sh <端口> <IP数> [超时秒]
   iplimit_del.sh <端口>

🎯 建议顺序:
   1) update-all && reboot
   2) 编辑 /etc/default/vless-reality
   3) bash /root/onekey_reality_ipv4.sh
   4) D=xxx vless_mktemp.sh
==================================================
DONEEOF
}

main "$@"