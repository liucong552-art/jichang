#!/usr/bin/env bash
# Debian 12 一键部署脚本（升级修正版）
# - 初始化系统 & 内核
# - VLESS Reality 主节点（客户端连接域名走 PUBLIC_DOMAIN；伪装站可自定义）
# - VLESS 临时节点 + 审计 + GC（绝对时间 TTL）
# - nftables TCP 双向配额系统（仅统计 VPS<->用户，关机前持久化已用流量 + 5 分钟保存快照）
# - 长周期服务（>30 天）配额每 30 天自动重置满流量；<=30 天不重置
# - 重启/关机前自动保存 live used，开机后按剩余配额重建，不再从 0 开始显示
# - 删除临时节点时自动删除对应配额，避免残留
# - 修复临时节点“假成功”问题：启动后等待 active+监听，失败自动回滚并换端口重试
# - 修复 stop/cleanup 重入问题：拆分为 stop 包装脚本 + post-stop 清理脚本
# - 日志 logrotate：保留最近 2 天
# - systemd journal：自动 vacuum 保留 2 天

set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"
VLESS_DEFAULTS="/etc/default/vless-reality"

# ------------------ 公共函数 ------------------

curl_fs() {
  curl -fsSL --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本"
    exit 1
  fi
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [[ "$codename" != "bookworm" ]]; then
    echo "❌ 本脚本仅适用于 Debian 12 (bookworm)，当前: ${codename:-未知}"
    exit 1
  fi
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux logrotate procps

  local c
  for c in curl openssl python3 nft timeout ss flock getent awk sed grep base64 systemctl journalctl sysctl; do
    command -v "$c" >/dev/null 2>&1 || { echo "❌ 缺少命令: $c"; exit 1; }
  done
}

download_upstreams() {
  echo "⬇ 下载/更新 上游文件到 ${UP_BASE} ..."
  mkdir -p "$UP_BASE"

  curl_fs "${REPO_BASE}/xray-install-release.sh" -o "${UP_BASE}/xray-install-release.sh"
  chmod +x "${UP_BASE}/xray-install-release.sh"

  echo "✅ 上游已更新："
  ls -l "$UP_BASE"
}

# ------------------ 0. VLESS 默认配置模板 ------------------

install_vless_defaults() {
  echo "🧩 初始化 ${VLESS_DEFAULTS} 配置模板 ..."
  mkdir -p /etc/default

  if [[ ! -f "${VLESS_DEFAULTS}" ]]; then
    cat >"${VLESS_DEFAULTS}" <<'CFG'
# 客户端连接 VPS 用的域名
# 例如：proxy.example.com
# VPS 换 IP 后，只需要把这个域名的 A 记录改到新 IP
PUBLIC_DOMAIN=your.domain.com

# Reality 伪装站（可自行改，不一定要 apple）
# 例如：www.cloudflare.com / www.microsoft.com / www.amazon.com
CAMOUFLAGE_DOMAIN=www.apple.com

# 可选：Reality 实际 dest；留空则自动用 CAMOUFLAGE_DOMAIN:443
REALITY_DEST=

# 可选：Reality 的 serverNames/sni；留空则自动用 CAMOUFLAGE_DOMAIN
REALITY_SNI=

# 监听端口
PORT=443

# 节点名称（显示在链接 # 后面）
NODE_NAME=VLESS-REALITY
CFG
    chmod 600 "${VLESS_DEFAULTS}"
    echo "✅ 已生成配置模板：${VLESS_DEFAULTS}"
    echo "   请先编辑 PUBLIC_DOMAIN，再运行主节点脚本。"
  else
    echo "ℹ 已存在：${VLESS_DEFAULTS}（保留原内容，不覆盖）"
  fi
}

# ------------------ 1. 系统更新 + 新内核 ------------------

install_update_all() {
  echo "🧩 写入 /usr/local/bin/update-all ..."
  cat >/usr/local/bin/update-all <<'EOF_UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

check_debian12() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请以 root 身份运行本脚本"; exit 1
  fi
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [ "$codename" != "bookworm" ]; then
    echo "❌ 本脚本仅适用于 Debian 12 (bookworm)，当前为: ${codename:-未知}"
    exit 1
  fi
}

check_debian12
echo "🚀 开始系统更新 (Debian 12 / bookworm)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get full-upgrade -y
apt-get --purge autoremove -y
apt-get autoclean -y
apt-get clean -y

echo "✅ 软件包更新完成"

echo "🧱 配置 bookworm-backports 仓库..."
BACKPORTS_FILE=/etc/apt/sources.list.d/backports.list
if [ -f "$BACKPORTS_FILE" ]; then
  cp "$BACKPORTS_FILE" "${BACKPORTS_FILE}.bak.$(date +%F-%H%M%S)"
fi

cat >"$BACKPORTS_FILE" <<BEOF
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
BEOF

apt-get update -o Acquire::Retries=3

echo "🔧 从 backports 安装最新内核..."
arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) img=linux-image-amd64; hdr=linux-headers-amd64 ;;
  arm64) img=linux-image-arm64; hdr=linux-headers-arm64 ;;
  *)
    echo "❌ 未支持架构: $arch（如需支持请扩展 case）"
    exit 1
    ;;
esac
apt-get -t bookworm-backports install -y "$img" "$hdr"

echo
echo "📦 当前已安装的内核包 (linux-image)："
dpkg -l | grep "^ii  linux-image" | tail -n 10 || true

echo
echo "🖥 当前正在运行的内核：$(uname -r)"
echo "⚠️ 重启后系统才会真正切换到新内核，请执行：reboot"
EOF_UPDATE

  chmod +x /usr/local/bin/update-all
}

# ------------------ 2. VLESS Reality 一键 ------------------

install_vless_script() {
  echo "🧩 写入 /root/onekey_reality_ipv4.sh ..."
  cat >/root/onekey_reality_ipv4.sh <<'EOF_REALITY'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"
CONF_FILE="/etc/default/vless-reality"

curl4() {
  curl -4fsS --connect-timeout 3 --max-time 8 --retry 3 --retry-delay 1 "$@"
}

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

urlencode() {
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
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

wait_unit_running() {
  local unit="$1" tries="${2:-20}" delay="${3:-0.25}"
  local i state sub
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]]; then
      return 0
    fi
    if [[ "$state" == "failed" || "$state" == "inactive" || "$state" == "deactivating" ]]; then
      return 1
    fi
    sleep "$delay"
  done
  systemctl is-active --quiet "$unit"
}

wait_port_listening() {
  local port="$1" tries="${2:-20}" delay="${3:-0.25}"
  local i
  for ((i=1; i<=tries; i++)); do
    if port_is_listening "$port"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
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

check_debian12() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请以 root 身份运行"; exit 1
  fi
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  if [ "$codename" != "bookworm" ]; then
    echo "❌ 仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"
    exit 1
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
    echo "❌ 未找到 /usr/local/bin/xray，请检查安装脚本"; exit 1
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

check_debian12

if [[ ! -f "$CONF_FILE" ]]; then
  echo "❌ 缺少配置文件: $CONF_FILE"
  echo "   请先创建该文件，或者重新运行一键部署脚本生成模板。"
  exit 1
fi

PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-$(cfg_get "$CONF_FILE" PUBLIC_DOMAIN || true)}"
CAMOUFLAGE_DOMAIN="${CAMOUFLAGE_DOMAIN:-$(cfg_get "$CONF_FILE" CAMOUFLAGE_DOMAIN || true)}"
REALITY_DEST="${REALITY_DEST:-$(cfg_get "$CONF_FILE" REALITY_DEST || true)}"
REALITY_SNI="${REALITY_SNI:-$(cfg_get "$CONF_FILE" REALITY_SNI || true)}"
PORT="${PORT:-$(cfg_get "$CONF_FILE" PORT || true)}"
NODE_NAME="${NODE_NAME:-$(cfg_get "$CONF_FILE" NODE_NAME || true)}"

CAMOUFLAGE_DOMAIN="${CAMOUFLAGE_DOMAIN:-www.apple.com}"
REALITY_SNI="${REALITY_SNI:-$CAMOUFLAGE_DOMAIN}"
REALITY_DEST="${REALITY_DEST:-${CAMOUFLAGE_DOMAIN}:443}"
PORT="${PORT:-443}"
NODE_NAME="${NODE_NAME:-VLESS-REALITY}"

if [[ -z "$PUBLIC_DOMAIN" || "$PUBLIC_DOMAIN" == "your.domain.com" ]]; then
  echo "❌ 请先编辑 $CONF_FILE"
  echo "   至少要把 PUBLIC_DOMAIN 改成你自己的域名，例如：proxy.example.com"
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ PORT 无效：$PORT"
  exit 1
fi

if ! getent ahostsv4 "$PUBLIC_DOMAIN" >/dev/null 2>&1; then
  echo "❌ 域名未解析到 IPv4: $PUBLIC_DOMAIN"
  echo "   请先把它的 DNS A 记录指向当前 VPS，再重试。"
  exit 1
fi

echo "客户端连接域名: $PUBLIC_DOMAIN"
echo "伪装域名(SNI):   $REALITY_SNI"
echo "Reality dest:    $REALITY_DEST"
echo "端口:            $PORT"
sleep 2

echo "=== 1. 启用 BBR ==="
cat >/etc/sysctl.d/99-bbr.conf <<SYS
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-bbr.conf || true
echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

echo
echo "=== 2. 安装 / 更新 Xray-core ==="
install_xray_from_local_or_repo

force_xray_run_as_root
systemctl stop xray.service 2>/dev/null || true

echo
echo "=== 3. 生成 UUID 与 Reality 密钥 ==="
UUID=$(/usr/local/bin/xray uuid)

KEY_OUT=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(
  printf '%s\n' "$KEY_OUT" | awk '
    /^PrivateKey:/   {print $2; exit}
    /^Private key:/  {print $3; exit}
  '
)
PUBLIC_KEY=$(
  printf '%s\n' "$KEY_OUT" | awk '
    /^PublicKey:/    {print $2; exit}
    /^Public key:/   {print $3; exit}
    /^Password:/     {print $2; exit}
  '
)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "❌ 无法解析 Reality 密钥："
  echo "$KEY_OUT"
  exit 1
fi

SHORT_ID="$(openssl rand -hex 8)"

CONFIG_DIR="/usr/local/etc/xray"
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
systemctl reset-failed xray.service >/dev/null 2>&1 || true
systemctl enable xray.service >/dev/null 2>&1 || true
systemctl restart xray.service

if ! wait_unit_and_port_stable xray.service "$PORT" 40 0.25 4; then
  echo "❌ xray 启动失败，状态与日志如下：" >&2
  systemctl --no-pager --full status xray.service >&2 || true
  journalctl -u xray.service --no-pager -n 120 >&2 || true
  exit 1
fi

systemctl --no-pager --full status xray.service || true

PBK_Q="$(urlencode "$PUBLIC_KEY")"
NODE_NAME_Q="$(urlencode "$NODE_NAME")"
VLESS_URL="vless://${UUID}@${PUBLIC_DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${NODE_NAME_Q}"

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
echo "✅ VLESS+Reality+Vision 安装完成（连接域名=${PUBLIC_DOMAIN}，SNI=${REALITY_SNI}）"
EOF_REALITY

  chmod +x /root/onekey_reality_ipv4.sh
}

# ------------------ 3. VLESS 临时节点 + 审计 + GC（绝对时间 TTL） ------------------

install_vless_temp_audit() {
  echo "🧩 写入 /root/vless_temp_audit_ipv4_all.sh 和相关脚本 ..."
  cat >/root/vless_temp_audit_ipv4_all.sh <<'EOF_TEMP'
#!/usr/bin/env bash
# VLESS 临时节点 + 审计 + GC (Reality) 一键部署 / 覆盖（绝对时间 TTL）
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

XRAY_DIR="/usr/local/etc/xray"

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

########################################
# 1) 停止后清理脚本（只做清理，不再 stop 自己）
########################################
cat >/usr/local/sbin/vless_poststop_cleanup.sh <<'POSTSTOP'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

read_port_from_cfg() {
  local cfg="$1"
  python3 - "$cfg" <<'PY' 2>/dev/null || true
import json,sys
try:
    cfg=json.load(open(sys.argv[1]))
    ibs=cfg.get("inbounds",[])
    if ibs and isinstance(ibs[0], dict):
        p=ibs[0].get("port","")
        if isinstance(p,int):
            print(p); sys.exit(0)
        if isinstance(p,str) and p.isdigit():
            print(p); sys.exit(0)
except Exception:
    pass
PY
}

TAG="${1:?need TAG}"
UNIT_NAME="${TAG}.service"
XRAY_DIR="/usr/local/etc/xray"
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
LOG="/var/log/vless-gc.log"
FORCE="${FORCE:-0}"

PORT=""
if [[ -f "$META" ]]; then
  PORT="$(meta_get "$META" PORT || true)"
fi
if [[ -z "${PORT:-}" && -f "$CFG" ]]; then
  PORT="$(read_port_from_cfg "$CFG" || true)"
fi

LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9 || { echo "[vless_poststop_cleanup] lock busy, skip cleanup: ${TAG}"; exit 0; }

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ -n "${EXPIRE_EPOCH:-}" && "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    if (( EXPIRE_EPOCH > NOW )); then
      echo "[vless_poststop_cleanup] ${TAG} 未到期 (EXPIRE_EPOCH=${EXPIRE_EPOCH}, NOW=${NOW})，跳过清理"
      exit 0
    fi
  fi
fi

echo "[vless_poststop_cleanup] 开始清理: ${TAG}"

systemctl disable "${UNIT_NAME}" >/dev/null 2>&1 || true

if [[ -n "${PORT:-}" && "$PORT" =~ ^[0-9]+$ ]]; then
  if [[ -x /usr/local/sbin/iplimit_del.sh ]]; then
    /usr/local/sbin/iplimit_del.sh "$PORT" >/dev/null 2>&1 || true
  fi
  if [[ -x /usr/local/sbin/pq_del.sh ]]; then
    /usr/local/sbin/pq_del.sh "$PORT" >/dev/null 2>&1 || true
  fi
fi

rm -f "$CFG" "$META" "/etc/systemd/system/${UNIT_NAME}" 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "${UNIT_NAME}" >/dev/null 2>&1 || true

echo "[vless_poststop_cleanup] 完成清理: ${TAG}"
echo "$(date '+%F %T %Z') cleanup ${TAG}" >> "$LOG" 2>/dev/null || true
POSTSTOP
chmod +x /usr/local/sbin/vless_poststop_cleanup.sh

########################################
# 2) 用户入口：清理一个节点（必要时先 stop，再调用 post-stop 清理）
########################################
cat >/usr/local/sbin/vless_cleanup_one.sh <<'CLEAN'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

TAG="${1:?need TAG}"
UNIT_NAME="${TAG}.service"
XRAY_DIR="/usr/local/etc/xray"
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
FORCE="${FORCE:-0}"

ACTIVE_STATE="$(systemctl show -p ActiveState --value "${UNIT_NAME}" 2>/dev/null || echo "")"
SUB_STATE="$(systemctl show -p SubState --value "${UNIT_NAME}" 2>/dev/null || echo "")"

if [[ "${ACTIVE_STATE}" == "active" || "${ACTIVE_STATE}" == "activating" || "${SUB_STATE}" == "running" || "${SUB_STATE}" == "start" ]]; then
  if ! timeout 15 systemctl stop "${UNIT_NAME}" >/dev/null 2>&1; then
    systemctl kill "${UNIT_NAME}" >/dev/null 2>&1 || true
    timeout 10 systemctl stop "${UNIT_NAME}" >/dev/null 2>&1 || true
  fi
fi

if [[ -f "$CFG" || -f "$META" || -f "$UNIT_FILE" ]]; then
  FORCE="$FORCE" /usr/local/sbin/vless_poststop_cleanup.sh "$TAG"
fi
CLEAN
chmod +x /usr/local/sbin/vless_cleanup_one.sh

########################################
# 3) 绝对时间 TTL 运行包装脚本
########################################
cat >/usr/local/sbin/vless_run_temp.sh <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

TAG="${1:?need TAG}"
CFG="${2:?need config path}"

XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "[vless_run_temp] xray binary not found" >&2
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "[vless_run_temp] 请安装 coreutils (缺少 timeout)" >&2
  exit 1
fi

XRAY_DIR="/usr/local/etc/xray"
META="${XRAY_DIR}/${TAG}.meta"
if [[ ! -f "$META" ]]; then
  echo "[vless_run_temp] meta not found: $META" >&2
  exit 1
fi

EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
if [[ -z "${EXPIRE_EPOCH:-}" || ! "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "[vless_run_temp] bad EXPIRE_EPOCH in $META" >&2
  exit 1
fi

NOW=$(date +%s)
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  echo "[vless_run_temp] $TAG already expired (EXPIRE_EPOCH=$EXPIRE_EPOCH, NOW=$NOW)"
  FORCE=1 /usr/local/sbin/vless_poststop_cleanup.sh "$TAG" 2>/dev/null || true
  exit 0
fi

echo "[vless_run_temp] run $TAG for up to ${REMAIN}s (expire at $EXPIRE_EPOCH)"
exec timeout "$REMAIN" "$XRAY_BIN" run -c "$CFG"
RUN
chmod +x /usr/local/sbin/vless_run_temp.sh

########################################
# 4) 创建临时 VLESS 节点：D=秒 vless_mktemp.sh
########################################
cat >/usr/local/sbin/vless_mktemp.sh <<'MK'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${D:?请用 D=秒 vless_mktemp.sh 方式调用，例如：D=600 vless_mktemp.sh}"

if ! [[ "$D" =~ ^[0-9]+$ ]] || (( D <= 0 )); then
  echo "❌ D 必须是正整数秒，例如：D=600 vless_mktemp.sh" >&2
  exit 1
fi

CONF_FILE="/etc/default/vless-reality"
LOCK="/run/vless-temp.lock"
LOCK_FD=9
exec 9>"$LOCK"

lock_acquire() { flock -w 10 "$LOCK_FD"; }
lock_release() { flock -u "$LOCK_FD" || true; }

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

urlencode() {
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}
urldecode() {
  python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.unquote(sys.argv[1]))
PY
}

sanitize_one_line() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

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

wait_unit_running() {
  local unit="$1" tries="${2:-20}" delay="${3:-0.25}"
  local i state sub
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]]; then
      return 0
    fi
    if [[ "$state" == "failed" || "$state" == "inactive" || "$state" == "deactivating" ]]; then
      return 1
    fi
    sleep "$delay"
  done
  systemctl is-active --quiet "$unit"
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
  declare -A USED_PORTS=()
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
  done < <(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')

  shopt -s nullglob
  for f in "${XRAY_DIR}"/vless-temp-*.meta; do
    p="$(awk -F= '$1=="PORT"{sub($1"=","");print;exit}' "$f" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
  done
  shopt -u nullglob

  local port="$PORT_START"
  while (( port <= PORT_END )); do
    if [[ -z "${USED_PORTS[$port]+x}" ]]; then
      echo "$port"
      return 0
    fi
    port=$((port+1))
  done
  return 1
}

write_temp_files() {
  local port="$1" now="$2" exp="$3"

  cat >"$CFG" <<CFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
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
CFG

  cat >"$META" <<M
TAG=$TAG
UUID=$UUID
PORT=$port
SERVER_ADDR=$SERVER_ADDR
CREATE_EPOCH=$now
DURATION_SECONDS=$D
EXPIRE_EPOCH=$exp
REALITY_DEST=$REALITY_DEST
REALITY_SNI=$REALITY_SNI
SHORT_ID=$SHORT_ID
PBK=$PBK
IP_LIMIT=$IP_LIMIT
IP_STICKY_SECONDS=$IP_STICKY_SECONDS
M

  cat >"$UNIT" <<U
[Unit]
Description=Temp VLESS $TAG
After=network.target

[Service]
Type=exec
ExecStart=/usr/local/sbin/vless_run_temp.sh $TAG $CFG
ExecStopPost=/usr/local/sbin/vless_poststop_cleanup.sh $TAG
Restart=no
SuccessExitStatus=124 143
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
U

  chmod 600 "$CFG" "$META" 2>/dev/null || true
}

XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
[[ -x "$XRAY_BIN" ]] || { echo "❌ 未找到 xray 可执行文件"; exit 1; }

XRAY_DIR="/usr/local/etc/xray"
MAIN_CFG="${XRAY_DIR}/config.json"
if [[ ! -f "$MAIN_CFG" ]]; then
  echo "❌ 未找到主 VLESS 配置 ${MAIN_CFG}，请先执行 onekey_reality_ipv4.sh" >&2
  exit 1
fi

mapfile -t arr < <(python3 - "$MAIN_CFG" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
ibs=cfg.get("inbounds",[])
if not ibs:
    print("")
    print("")
    print("")
else:
    ib=ibs[0]
    rs=ib.get("streamSettings",{}).get("realitySettings",{})
    pkey=rs.get("privateKey","")
    dest=rs.get("dest","")
    sns=rs.get("serverNames",[])
    sni=sns[0] if sns else ""
    print(pkey)
    print(dest)
    print(sni)
PY
)

REALITY_PRIVATE_KEY="${arr[0]:-}"
REALITY_DEST="${arr[1]:-}"
REALITY_SNI="${arr[2]:-}"

if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_DEST" ]]; then
  echo "❌ 无法从 ${MAIN_CFG} 解析 Reality 配置" >&2
  exit 1
fi
if [[ -z "$REALITY_SNI" ]]; then
  REALITY_SNI="${REALITY_DEST%%:*}"
fi

PBK_INPUT="${PBK:-}"
PBK="$PBK_INPUT"

if [[ -z "$PBK" && -f /root/vless_reality_vision_url.txt ]]; then
  LINE="$(sed -n '1p' /root/vless_reality_vision_url.txt 2>/dev/null || true)"
  if [[ -n "$LINE" ]]; then
    PBK="$(grep -o 'pbk=[^&]*' <<< "$LINE" | head -n1 | cut -d= -f2)"
  fi
fi

if [[ -z "$PBK" ]]; then
  echo "❌ 未能获取 Reality PublicKey (pbk)。" >&2
  echo "   解决方法：" >&2
  echo "   1) 先执行：bash /root/onekey_reality_ipv4.sh（会生成 /root/vless_reality_vision_url.txt）" >&2
  echo "   2) 或手动传入：PBK=<你的publicKey> D=600 vless_mktemp.sh" >&2
  exit 1
fi

PBK_RAW="$(urldecode "$PBK")"
PBK="$PBK_RAW"

PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
MAX_START_RETRIES="${MAX_START_RETRIES:-5}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-1800}"

if ! [[ "$PORT_START" =~ ^[0-9]+$ ]] || ! [[ "$PORT_END" =~ ^[0-9]+$ ]] || \
   (( PORT_START < 1 || PORT_END > 65535 || PORT_START >= PORT_END )); then
  echo "❌ PORT_START/PORT_END 无效（需要 1<=start<end<=65535），当前: ${PORT_START}-${PORT_END}" >&2
  exit 1
fi

if ! [[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] || (( MAX_START_RETRIES < 1 || MAX_START_RETRIES > 20 )); then
  echo "❌ MAX_START_RETRIES 无效（需要 1-20 的整数），当前: ${MAX_START_RETRIES}" >&2
  exit 1
fi
if ! [[ "$IP_LIMIT" =~ ^[0-9]+$ ]] || (( IP_LIMIT < 0 || IP_LIMIT > 65535 )); then
  echo "❌ IP_LIMIT 无效（需要 0-65535 的整数，0=不限），当前: ${IP_LIMIT}" >&2
  exit 1
fi
if ! [[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ ]] || (( IP_STICKY_SECONDS <= 0 )); then
  echo "❌ IP_STICKY_SECONDS 无效（需要正整数秒），当前: ${IP_STICKY_SECONDS}" >&2
  exit 1
fi

SERVER_ADDR="${PUBLIC_DOMAIN:-}"
if [[ -z "$SERVER_ADDR" && -f "$CONF_FILE" ]]; then
  SERVER_ADDR="$(cfg_get "$CONF_FILE" PUBLIC_DOMAIN || true)"
fi

if [[ -z "$SERVER_ADDR" || "$SERVER_ADDR" == "your.domain.com" ]]; then
  echo "❌ 未配置 PUBLIC_DOMAIN。请先编辑 /etc/default/vless-reality" >&2
  exit 1
fi

if ! getent ahostsv4 "$SERVER_ADDR" >/dev/null 2>&1; then
  echo "❌ PUBLIC_DOMAIN 当前未解析到 IPv4：$SERVER_ADDR" >&2
  exit 1
fi

sanitize_one_line "$SERVER_ADDR" || { echo "❌ bad SERVER_ADDR"; exit 1; }
sanitize_one_line "$REALITY_DEST" || { echo "❌ bad REALITY_DEST"; exit 1; }
sanitize_one_line "$REALITY_SNI" || { echo "❌ bad REALITY_SNI"; exit 1; }
sanitize_one_line "$PBK" || { echo "❌ bad PBK"; exit 1; }

mkdir -p "$XRAY_DIR"

UUID="$("$XRAY_BIN" uuid)"
SHORT_ID="$(openssl rand -hex 8)"
TAG="vless-temp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
UNIT="/etc/systemd/system/${TAG}.service"

sanitize_one_line "$TAG" || { echo "❌ bad TAG"; exit 1; }
sanitize_one_line "$UUID" || { echo "❌ bad UUID"; exit 1; }
sanitize_one_line "$SHORT_ID" || { echo "❌ bad SHORT_ID"; exit 1; }

lock_acquire

START_OK=0
ATTEMPT=1
LAST_PORT=""
LAST_EXP=""

while (( ATTEMPT <= MAX_START_RETRIES )); do
  PORT="$(pick_free_port || true)"
  if [[ -z "${PORT:-}" ]]; then
    lock_release
    echo "❌ 在 ${PORT_START}-${PORT_END} 范围内没有空闲 TCP 端口了。" >&2
    exit 1
  fi

  NOW="$(date +%s)"
  EXP="$((NOW + D))"
  LAST_PORT="$PORT"
  LAST_EXP="$EXP"

  write_temp_files "$PORT" "$NOW" "$EXP"

  systemctl daemon-reload
  systemctl reset-failed "$TAG".service >/dev/null 2>&1 || true

  if ! systemctl enable "$TAG".service >/dev/null 2>&1; then
    echo "⚠️ 无法 enable $TAG.service（可以稍后手动 systemctl enable $TAG.service）" >&2
  fi

  if [[ -n "${PQ_GIB:-}" ]]; then
    if ! CREATE_EPOCH="$NOW" /usr/local/sbin/pq_add.sh "$PORT" "$PQ_GIB" "$D" "$EXP"; then
      echo "❌ 绑定配额失败，正在回滚..." >&2
      lock_release
      FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
      exit 1
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    if ! CREATE_EPOCH="$NOW" /usr/local/sbin/iplimit_add.sh "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" "$D" "$EXP"; then
      echo "❌ 绑定源 IP 槽位限制失败，正在回滚..." >&2
      lock_release
      FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
      exit 1
    fi
  fi

  systemctl start "$TAG".service >/dev/null 2>&1 || true

  if wait_unit_and_port_stable "$TAG".service "$PORT" 40 0.25 4; then
    START_OK=1
    break
  fi

  echo "⚠️ 临时节点启动未稳定（尝试 ${ATTEMPT}/${MAX_START_RETRIES}，端口 ${PORT} 可能被占用或进程异常退出），准备自动重试..." >&2
  systemctl --no-pager --full status "$TAG".service >&2 || true
  journalctl -u "$TAG".service --no-pager -n 20 >&2 || true

  lock_release
  FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
  sleep 1
  lock_acquire

  ATTEMPT=$((ATTEMPT + 1))
done

lock_release

if (( START_OK != 1 )); then
  echo "❌ 启动临时 VLESS 服务失败，已自动尝试 ${MAX_START_RETRIES} 次。" >&2
  exit 1
fi

E_STR="$(TZ=Asia/Shanghai date -d "@$LAST_EXP" '+%F %T')"
PBK_Q="$(urlencode "$PBK")"
VLESS_URL="vless://${UUID}@${SERVER_ADDR}:${LAST_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"

echo "✅ 新 VLESS 临时节点: $TAG
地址: ${SERVER_ADDR}:${LAST_PORT}
UUID: ${UUID}
有效期: ${D} 秒
到期(北京时间): ${E_STR}
VLESS 订阅链接: ${VLESS_URL}"
if [[ -n "${PQ_GIB:-}" ]]; then
  echo "已绑定配额: ${PQ_GIB}GiB"
fi
if (( IP_LIMIT > 0 )); then
  echo "已启用源 IP 槽位限制: 最多 ${IP_LIMIT} 个活动源 IP"
  echo "IP 槽位续期: 仅按入站源 IP 刷新，保活 ${IP_STICKY_SECONDS} 秒"
fi
MK
chmod +x /usr/local/sbin/vless_mktemp.sh

########################################
# 5) GC：按 meta 过期时间清理
########################################
cat >/usr/local/sbin/vless_gc.sh <<'GC'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

LOCK="/run/vless-gc.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

XRAY_DIR="/usr/local/etc/xray"
NOW=$(date +%s)

for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"

  [[ -z "${TAG:-}" ]] && continue
  [[ -z "${EXPIRE_EPOCH:-}" || ! "${EXPIRE_EPOCH}" =~ ^[0-9]+$ ]] && continue

  if (( EXPIRE_EPOCH <= NOW )); then
    /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
  fi
done
GC
chmod +x /usr/local/sbin/vless_gc.sh

cat >/etc/systemd/system/vless-gc.service <<'GCSVC'
[Unit]
Description=VLESS Temp Nodes Garbage Collector
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_gc.sh
GCSVC

cat >/etc/systemd/system/vless-gc.timer <<'GCTMR'
[Unit]
Description=Run VLESS GC every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
GCTMR

systemctl daemon-reload
systemctl enable --now vless-gc.timer || true

########################################
# 6) 审计脚本（主 VLESS + 临时 VLESS）
########################################
cat >/usr/local/sbin/vless_audit.sh <<'AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

if [[ -r /usr/local/sbin/pq_lib.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/sbin/pq_lib.sh
fi

tcp_port_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p' | grep -qx "$port"
}

fmt_left() {
  local exp="${1:-}"
  local now
  now=$(date +%s)
  if [[ "$exp" =~ ^[0-9]+$ ]]; then
    local left=$((exp - now))
    if (( left <= 0 )); then
      echo "expired"
    else
      local d=$((left/86400))
      local h=$(((left%86400)/3600))
      local m=$(((left%3600)/60))
      printf "%02dd%02dh%02dm" "$d" "$h" "$m"
    fi
  else
    echo "-"
  fi
}

fmt_expire_cn() {
  local exp="${1:-}"
  if [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > 0 )); then
    TZ='Asia/Shanghai' date -d "@$exp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"
  else
    echo "-"
  fi
}

quota_cells() {
  local port="$1"
  local meta="/etc/portquota/pq-${port}.meta"
  local qstate="none" limit="-" used="-" left="-" pct="-"

  if [[ -f "$meta" && -r /usr/local/sbin/pq_lib.sh ]]; then
    pq_normalize_meta "$meta" >/dev/null 2>&1 || true

    local limit_bytes original_bytes saved_bytes live_b used_b left_b pct_val mode
    limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"
    original_bytes="$(meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
    saved_bytes="$(meta_get "$meta" SAVED_USED_BYTES || true)"
    mode="$(meta_get "$meta" MODE || true)"

    [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
    [[ "$original_bytes" =~ ^[0-9]+$ ]] || original_bytes="$limit_bytes"
    [[ "$saved_bytes" =~ ^[0-9]+$ ]] || saved_bytes=0
    mode="${mode:-quota}"

    if [[ "$mode" != "quota" || "$original_bytes" == "0" ]]; then
      qstate="track"
    else
      live_b="$(pq_get_live_used_bytes "$port" "$limit_bytes" || true)"
      [[ "$live_b" =~ ^[0-9]+$ ]] || live_b=0
      used_b=$((saved_bytes + live_b))
      if (( used_b > original_bytes )); then
        used_b="$original_bytes"
      fi
      left_b=$((original_bytes - used_b))
      (( left_b < 0 )) && left_b=0
      pct_val="$(awk -v u="$used_b" -v l="$original_bytes" 'BEGIN{printf "%.1f%%", (l>0 ? (u*100.0/l) : 0)}')"
      limit="$(pq_fmt_gib "$original_bytes")"
      used="$(pq_fmt_gib "$used_b")"
      left="$(pq_fmt_gib "$left_b")"
      pct="$pct_val"
      if (( left_b == 0 )); then
        qstate="full"
      else
        qstate="ok"
      fi
    fi
  fi

  printf '%s|%s|%s|%s|%s\n' "$qstate" "$limit" "$used" "$left" "$pct"
}

NAME_W=32
STATE_W=8
PORT_W=5
RDY_W=3
Q_W=5
LIMIT_W=7
USED_W=7
LEFT_W=7
USE_W=5
TTL_W=10
EXP_W=19

print_sep() {
  printf '%*s\n' 118 '' | tr ' ' '-'
}

MAIN_VLESS="${MAIN_VLESS:-xray.service}"
XRAY_DIR="/usr/local/etc/xray"
MAIN_CFG="${XRAY_DIR}/config.json"

get_main_port() {
  if [[ -f "$MAIN_CFG" ]]; then
    python3 - "$MAIN_CFG" <<'PYPORT'
import json,sys
try:
    cfg=json.load(open(sys.argv[1]))
    ibs=cfg.get("inbounds",[])
    if ibs and isinstance(ibs[0], dict):
        p=ibs[0].get("port","")
        if isinstance(p,int):
            print(p); sys.exit(0)
        if isinstance(p,str) and p.isdigit():
            print(p); sys.exit(0)
except Exception:
    pass
print("443")
PYPORT
  else
    echo "443"
  fi
}

render_row() {
  local name="$1" state="$2" port="$3" ready="$4" qstate="$5" limit="$6" used="$7" leftq="$8" pct="$9" ttl_left="${10}" expire_cn="${11}"
  local first=1 chunk rest
  rest="$name"
  while :; do
    if (( ${#rest} > NAME_W )); then
      chunk="${rest:0:NAME_W}"
      rest="${rest:NAME_W}"
    else
      chunk="$rest"
      rest=""
    fi

    if (( first )); then
      printf "%-${NAME_W}s %-${STATE_W}s %-${PORT_W}s %-${RDY_W}s %-${Q_W}s %-${LIMIT_W}s %-${USED_W}s %-${LEFT_W}s %-${USE_W}s %-${TTL_W}s %-${EXP_W}s\n" \
        "$chunk" "$state" "$port" "$ready" "$qstate" "$limit" "$used" "$leftq" "$pct" "$ttl_left" "$expire_cn"
      first=0
    else
      printf "%-${NAME_W}s\n" "$chunk"
    fi

    [[ -z "$rest" ]] && break
  done
}

echo
printf '%s\n' '=== VLESS AUDIT ==='
print_sep
render_row "NAME" "STATE" "PORT" "RDY" "Q" "LIMIT" "USED" "LEFT" "USE%" "TTL" "EXPIRE(CN)"
print_sep

MAIN_PORT="$(get_main_port)"
if systemctl list-unit-files "$MAIN_VLESS" >/dev/null 2>&1; then
  MAIN_STATE="$(systemctl is-active "$MAIN_VLESS" 2>/dev/null || echo unknown)"
  MAIN_READY="no"
  [[ "$MAIN_STATE" == "active" ]] && tcp_port_listening "$MAIN_PORT" && MAIN_READY="yes"
  render_row "vless-main" "$MAIN_STATE" "$MAIN_PORT" "$MAIN_READY" "none" "-" "-" "-" "-" "-" "-"
fi

for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  PORT="$(meta_get "$META" PORT || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  [[ -z "${TAG:-}" || -z "${PORT:-}" ]] && continue

  NAME="$TAG"
  STATE="$(systemctl is-active "$NAME" 2>/dev/null || echo unknown)"
  READY="no"
  [[ "$STATE" == "active" ]] && tcp_port_listening "$PORT" && READY="yes"
  IFS='|' read -r QSTATE LIMIT USED LEFT_Q PCT <<< "$(quota_cells "$PORT")"
  render_row "$NAME" "$STATE" "$PORT" "$READY" "$QSTATE" "$LIMIT" "$USED" "$LEFT_Q" "$PCT" "$(fmt_left "$EXPIRE_EPOCH")" "$(fmt_expire_cn "$EXPIRE_EPOCH")"
done
print_sep
AUDIT
chmod +x /usr/local/sbin/vless_audit.sh

########################################
# 7) 清空全部临时 VLESS 节点（强制）
########################################
cat >/usr/local/sbin/vless_clear_all.sh <<'CLR'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

LOCK="/run/vless-clear-all.lock"
exec 9>"$LOCK"
flock -w 10 9

XRAY_DIR="/usr/local/etc/xray"

echo "== VLESS 临时节点批量清理开始 =="

META_FILES=("$XRAY_DIR"/vless-temp-*.meta)
if (( ${#META_FILES[@]} == 0 )); then
  echo "当前没有任何临时 VLESS 节点。"
  exit 0
fi

for META in "${META_FILES[@]}"; do
  echo "--- 发现 meta: ${META}"
  TAG="$(meta_get "$META" TAG || true)"

  if [[ -z "${TAG:-}" ]]; then
    echo "  ⚠️  跳过：${META} 中没有 TAG"
    continue
  fi

  echo "  -> 清理 ${TAG}"
  FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
done

systemctl daemon-reload >/dev/null 2>&1 || true
echo "✅ 所有临时 VLESS 节点清理流程已执行完毕。"
CLR
chmod +x /usr/local/sbin/vless_clear_all.sh

echo "✅ VLESS 临时节点 + 审计 + GC 脚本部署/覆盖完成（绝对时间 TTL）。"

cat <<USE
============ 使用方法（VLESS 临时节点 / 审计） ============

1) 新建一个临时 VLESS 节点（例如 600 秒）：
   D=600 vless_mktemp.sh

   # 可自定义临时端口范围（默认 40000-50050）：
   PORT_START=40000 PORT_END=60000 D=600 vless_mktemp.sh

   # 启动阶段自动重试次数（默认 5 次）：
   MAX_START_RETRIES=8 D=600 vless_mktemp.sh

   # 如 pbk 获取失败，可手动传入（可传原始或已编码，脚本会归一化）：
   PBK=<publicKey> D=600 vless_mktemp.sh

   # 创建节点时直接绑定配额：
   PQ_GIB=50 D=600 vless_mktemp.sh

   # 创建节点时启用源 IP 槽位限制（例：只允许 1 个 / 3 个活动源 IP）
   IP_LIMIT=1 D=600 vless_mktemp.sh
   IP_LIMIT=3 D=600 vless_mktemp.sh

   # 调整“IP 占位”保活时长（默认 1800 秒）；只按入站源 IP 续期，出站回包不会续命
   IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh

   # 配额和 IP 限制可同时开启
   PQ_GIB=50 IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh

   # 60 天节点：超过 30 天，进入第 31 天自动重置满流量（同时重置计数器）
   PQ_GIB=50 D=$((60*86400)) vless_mktemp.sh

   # 20 天节点：到期前不自动重置
   PQ_GIB=50 D=$((20*86400)) vless_mktemp.sh

   - 创建时记录 EXPIRE_EPOCH = 创建瞬间 + D 秒
   - 配额 CREATE_EPOCH 与节点创建时间保持一致
   - 之后每次重启都会按 EXPIRE_EPOCH 计算剩余 TTL
   - 生成的订阅地址统一使用 /etc/default/vless-reality 中的 PUBLIC_DOMAIN
   - 如果启动后发现端口被抢占/进程异常退出，会自动回滚并换端口重试，不再“假成功”

2) 查看主 VLESS + 所有临时节点状态（按绝对时间计算剩余）：
   vless_audit.sh

3) 正常情况下：
   - vless_run_temp.sh 使用 timeout(剩余秒数) 控制节点寿命
   - 进程退出后 ExecStopPost -> vless_poststop_cleanup.sh 只做清理
   - vless-gc.timer 作为兜底，定时扫描 EXPIRE_EPOCH 过期节点
   - 手工清理统一走 vless_cleanup_one.sh，避免 stop/cleanup 重入

4) 查看当前各端口的源 IP 槽位占用情况：
   iplimit_audit.sh

5) 手动强制清空所有临时节点（无视是否过期）：
   vless_clear_all.sh

6) 强制干掉某一个未过期节点示例：
   FORCE=1 vless_cleanup_one.sh vless-temp-YYYYMMDDHHMMSS-ABCD
==========================================================
USE
EOF_TEMP

  chmod +x /root/vless_temp_audit_ipv4_all.sh
}

# ------------------ 4. nftables 配额系统（TCP 双向，仅统计 VPS<->用户） ------------------

install_port_quota() {
  echo "🧩 部署 TCP 双向配额系统（nftables，仅统计 VPS<->用户，重启前持久化已用流量）..."
  mkdir -p /etc/portquota

  systemctl enable --now nftables >/dev/null 2>&1 || true

  if ! nft list table inet portquota >/dev/null 2>&1; then
    nft add table inet portquota
  fi
  if ! nft list chain inet portquota down_out >/dev/null 2>&1; then
    nft add chain inet portquota down_out '{ type filter hook output priority filter; policy accept; }'
  fi
  if ! nft list chain inet portquota up_in >/dev/null 2>&1; then
    nft add chain inet portquota up_in '{ type filter hook input priority filter; policy accept; }'
  fi

  cat >/usr/local/sbin/pq_lib.sh <<'PQLIB'
#!/usr/bin/env bash

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

pq_fmt_gib() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v v="$b" 'BEGIN{printf "%.2f", v/1024/1024/1024}'
}

pq_fmt_epoch() {
  local ts="${1:-}"
  if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
    date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts"
  else
    echo "-"
  fi
}

pq_counter_bytes() {
  local obj="$1"
  nft list counter inet portquota "$obj" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'
}

pq_quota_used_bytes() {
  local obj="$1"
  nft list quota inet portquota "$obj" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'
}

pq_get_live_used_bytes() {
  local port="$1"
  local remain="${2:-}"
  local out_b in_b total_b quota_b live_b

  out_b="$(pq_counter_bytes "pq_out_${port}" || true)"; [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
  in_b="$(pq_counter_bytes "pq_in_${port}" || true)";   [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
  total_b=$((out_b + in_b))

  quota_b="$(pq_quota_used_bytes "pq_quota_${port}" || true)"
  if [[ "$quota_b" =~ ^[0-9]+$ ]]; then
    live_b="$quota_b"
  else
    live_b="$total_b"
  fi

  [[ "$live_b" =~ ^[0-9]+$ ]] || live_b=0
  if [[ "$remain" =~ ^[0-9]+$ ]] && (( live_b > remain )); then
    live_b="$remain"
  fi
  echo "$live_b"
}

pq_write_meta() {
  local file="$1"
  shift

  declare -A kv=()
  declare -A seen=()
  local line k v

  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *=* ]] || continue
      k="${line%%=*}"
      v="${line#*=}"
      [[ -n "$k" ]] && kv["$k"]="$v"
    done < "$file"
  fi

  for line in "$@"; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    [[ -n "$k" ]] && kv["$k"]="$v"
  done

  local order=(PORT LIMIT_BYTES ORIGINAL_LIMIT_BYTES SAVED_USED_BYTES LIMIT_GIB MODE CREATE_EPOCH SERVICE_SECONDS EXPIRE_EPOCH RESET_INTERVAL_SECONDS AUTO_RESET LAST_RESET_EPOCH NEXT_RESET_EPOCH RESET_COUNT)
  : > "${file}.tmp"

  for k in "${order[@]}"; do
    if [[ -n "${kv[$k]+x}" ]]; then
      printf '%s=%s\n' "$k" "${kv[$k]}" >> "${file}.tmp"
      seen["$k"]=1
    fi
  done

  for k in "${!kv[@]}"; do
    [[ -n "${seen[$k]+x}" ]] && continue
    printf '%s=%s\n' "$k" "${kv[$k]}" >> "${file}.tmp"
  done

  mv "${file}.tmp" "$file"
}

pq_normalize_meta() {
  local meta="$1"
  local limit orig saved limit_gib changed=0 rebuilt

  limit="$(meta_get "$meta" LIMIT_BYTES || true)"
  orig="$(meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(meta_get "$meta" SAVED_USED_BYTES || true)"
  limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"

  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  if [[ ! "$orig" =~ ^[0-9]+$ ]]; then
    orig="$limit"
    changed=1
  fi
  if [[ ! "$saved" =~ ^[0-9]+$ ]]; then
    saved=0
    changed=1
  fi

  if (( saved > orig )); then
    saved="$orig"
    changed=1
  fi
  if (( limit > orig )); then
    limit="$orig"
    changed=1
  fi

  rebuilt=$((orig - saved))
  (( rebuilt < 0 )) && rebuilt=0
  if (( limit != rebuilt )); then
    limit="$rebuilt"
    changed=1
  fi

  if [[ ! "$limit_gib" =~ ^[0-9]+$ ]]; then
    limit_gib=$((orig / 1024 / 1024 / 1024))
    changed=1
  fi

  if (( changed == 1 )); then
    pq_write_meta "$meta" \
      "LIMIT_BYTES=$limit" \
      "ORIGINAL_LIMIT_BYTES=$orig" \
      "SAVED_USED_BYTES=$saved" \
      "LIMIT_GIB=$limit_gib"
  fi
}
PQLIB
  chmod +x /usr/local/sbin/pq_lib.sh

  cat >/usr/local/sbin/pq_save.sh <<'SAVE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

OUT="/etc/nftables.d/portquota.nft"
LOG="/var/log/pq-save.log"

mkdir -p /etc/nftables.d

if ! nft list table inet portquota > "${OUT}.tmp" 2>/dev/null; then
  echo "$(date '+%F %T %Z') [pq-save] export portquota failed" >> "$LOG"
  rm -f "${OUT}.tmp" 2>/dev/null || true
  exit 1
fi

mv "${OUT}.tmp" "$OUT"
echo "$(date '+%F %T %Z') [pq-save] saved $OUT" >> "$LOG"

if [[ -f /etc/nftables.conf ]]; then
  if ! grep -qE 'include "/etc/nftables\.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
  fi
fi
SAVE
  chmod +x /usr/local/sbin/pq_save.sh

  cat >/usr/local/sbin/pq_live_used_bytes.sh <<'PQLIVE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
REMAIN="${2:-}"
if [[ -z "$PORT" ]]; then
  echo "用法: pq_live_used_bytes.sh <端口> [当前剩余额度bytes]" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh
pq_get_live_used_bytes "$PORT" "$REMAIN"
PQLIVE
  chmod +x /usr/local/sbin/pq_live_used_bytes.sh

  /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true

  cat >/usr/local/sbin/pq_apply_port.sh <<'APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
BYTES="${2:-}"

if [[ -z "$PORT" || -z "$BYTES" ]]; then
  echo "用法: pq_apply_port.sh <端口> <remaining-bytes>" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi
if ! [[ "$BYTES" =~ ^[0-9]+$ ]] || (( BYTES < 0 )); then
  echo "❌ remaining-bytes 必须是非负整数" >&2
  exit 1
fi

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

if ! nft list table inet portquota >/dev/null 2>&1; then
  nft add table inet portquota
fi
if ! nft list chain inet portquota down_out >/dev/null 2>&1; then
  nft add chain inet portquota down_out '{ type filter hook output priority filter; policy accept; }'
fi
if ! nft list chain inet portquota up_in >/dev/null 2>&1; then
  nft add chain inet portquota up_in '{ type filter hook input priority filter; policy accept; }'
fi

nft -a list chain inet portquota down_out 2>/dev/null | \
 awk -v p="$PORT" '
   $0 ~ "comment \"pq-count-out-"p"\"" ||
   $0 ~ "comment \"pq-drop-out-"p"\""  {print $NF}
 ' | while read -r h; do
   nft delete rule inet portquota down_out handle "$h" 2>/dev/null || true
 done

nft -a list chain inet portquota up_in 2>/dev/null | \
 awk -v p="$PORT" '
   $0 ~ "comment \"pq-count-in-"p"\"" ||
   $0 ~ "comment \"pq-drop-in-"p"\""  {print $NF}
 ' | while read -r h; do
   nft delete rule inet portquota up_in handle "$h" 2>/dev/null || true
 done

nft delete counter inet portquota "pq_out_$PORT" 2>/dev/null || true
nft delete counter inet portquota "pq_in_$PORT" 2>/dev/null || true
nft delete quota   inet portquota "pq_quota_$PORT" 2>/dev/null || true

if (( BYTES > 0 )); then
  nft add counter inet portquota "pq_out_$PORT"
  nft add counter inet portquota "pq_in_$PORT"
  nft add quota inet portquota "pq_quota_$PORT" { over "$BYTES" bytes }

  nft add rule inet portquota down_out tcp sport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
  nft add rule inet portquota down_out tcp sport "$PORT" \
    counter name "pq_out_$PORT" comment "pq-count-out-$PORT"

  nft add rule inet portquota up_in tcp dport "$PORT" \
    quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
  nft add rule inet portquota up_in tcp dport "$PORT" \
    counter name "pq_in_$PORT" comment "pq-count-in-$PORT"
else
  nft add rule inet portquota down_out tcp sport "$PORT" \
    drop comment "pq-drop-out-$PORT"
  nft add rule inet portquota up_in tcp dport "$PORT" \
    drop comment "pq-drop-in-$PORT"
fi
APPLY
  chmod +x /usr/local/sbin/pq_apply_port.sh

  cat >/usr/local/sbin/pq_save_state.sh <<'STATE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

LOG="/var/log/pq-save.log"
CHANGED=0

for META in /etc/portquota/pq-*.meta; do
  pq_normalize_meta "$META" >/dev/null 2>&1 || true

  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  ORIGINAL_LIMIT_BYTES="$(meta_get "$META" ORIGINAL_LIMIT_BYTES || true)"
  SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
  LIMIT_GIB="$(meta_get "$META" LIMIT_GIB || true)"
  MODE="$(meta_get "$META" MODE || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$ORIGINAL_LIMIT_BYTES" =~ ^[0-9]+$ ]] || ORIGINAL_LIMIT_BYTES="$LIMIT_BYTES"
  [[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
  [[ "$LIMIT_GIB" =~ ^[0-9]+$ ]] || LIMIT_GIB=$((ORIGINAL_LIMIT_BYTES / 1024 / 1024 / 1024))
  [[ "$MODE" == "quota" ]] || continue

  LIVE_USED_BYTES="$(pq_get_live_used_bytes "$PORT" "$LIMIT_BYTES" || true)"
  [[ "$LIVE_USED_BYTES" =~ ^[0-9]+$ ]] || LIVE_USED_BYTES=0

  if (( LIVE_USED_BYTES > 0 )); then
    NEW_SAVED_USED_BYTES=$((SAVED_USED_BYTES + LIVE_USED_BYTES))
    if (( NEW_SAVED_USED_BYTES > ORIGINAL_LIMIT_BYTES )); then
      NEW_SAVED_USED_BYTES="$ORIGINAL_LIMIT_BYTES"
    fi
    NEW_LIMIT_BYTES=$((LIMIT_BYTES - LIVE_USED_BYTES))
    (( NEW_LIMIT_BYTES < 0 )) && NEW_LIMIT_BYTES=0

    pq_write_meta "$META" \
      "PORT=$PORT" \
      "LIMIT_BYTES=$NEW_LIMIT_BYTES" \
      "ORIGINAL_LIMIT_BYTES=$ORIGINAL_LIMIT_BYTES" \
      "SAVED_USED_BYTES=$NEW_SAVED_USED_BYTES" \
      "LIMIT_GIB=$LIMIT_GIB"

    CHANGED=1
    echo "$(date '+%F %T %Z') [pq-state] port=$PORT live_used=$LIVE_USED_BYTES saved_used=$NEW_SAVED_USED_BYTES remaining=$NEW_LIMIT_BYTES" >> "$LOG"
  fi
done

PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
exit 0
STATE
  chmod +x /usr/local/sbin/pq_save_state.sh

  cat >/usr/local/sbin/pq_restore.sh <<'RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh

LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

LOG="/var/log/pq-save.log"
CHANGED=0

for META in /etc/portquota/pq-*.meta; do
  pq_normalize_meta "$META" >/dev/null 2>&1 || true

  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  MODE="$(meta_get "$META" MODE || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$MODE" == "quota" ]] || continue

  if PQ_LOCK_HELD=1 /usr/local/sbin/pq_apply_port.sh "$PORT" "$LIMIT_BYTES"; then
    CHANGED=1
  else
    echo "$(date '+%F %T %Z') [pq-restore] port=$PORT restore failed" >> "$LOG"
  fi
done

if (( CHANGED == 1 )); then
  PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
fi
RESTORE
  chmod +x /usr/local/sbin/pq_restore.sh

  cat >/usr/local/sbin/pq_add.sh <<'ADD'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh

PORT="${1:-}"
GIB="${2:-}"
SERVICE_SECONDS_ARG="${3:-${SERVICE_SECONDS:-0}}"
EXPIRE_EPOCH_ARG="${4:-${EXPIRE_EPOCH:-0}}"
CREATE_EPOCH="${CREATE_EPOCH:-$(date +%s)}"
RESET_INTERVAL_SECONDS="${RESET_INTERVAL_SECONDS:-2592000}"

if [[ -z "$PORT" || -z "$GIB" ]]; then
  echo "用法: pq_add.sh <端口> <GiB(整数)> [SERVICE_SECONDS] [EXPIRE_EPOCH]" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi
if ! [[ "$GIB" =~ ^[0-9]+$ ]] || (( GIB <= 0 )); then
  echo "❌ GiB 需为正整数" >&2
  exit 1
fi
if ! [[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || (( CREATE_EPOCH <= 0 )); then
  echo "❌ CREATE_EPOCH 非法" >&2
  exit 1
fi
if ! [[ "$SERVICE_SECONDS_ARG" =~ ^[0-9]+$ ]] || (( SERVICE_SECONDS_ARG < 0 )); then
  echo "❌ SERVICE_SECONDS 必须是非负整数秒" >&2
  exit 1
fi
if ! [[ "$EXPIRE_EPOCH_ARG" =~ ^[0-9]+$ ]] || (( EXPIRE_EPOCH_ARG < 0 )); then
  echo "❌ EXPIRE_EPOCH 必须是非负整数" >&2
  exit 1
fi
if ! [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || (( RESET_INTERVAL_SECONDS <= 0 )); then
  echo "❌ RESET_INTERVAL_SECONDS 必须是正整数" >&2
  exit 1
fi

BYTES=$((GIB * 1024 * 1024 * 1024))
SERVICE_SECONDS="$SERVICE_SECONDS_ARG"
EXPIRE_EPOCH="$EXPIRE_EPOCH_ARG"
if (( SERVICE_SECONDS > 0 && EXPIRE_EPOCH == 0 )); then
  EXPIRE_EPOCH=$((CREATE_EPOCH + SERVICE_SECONDS))
fi

AUTO_RESET=0
LAST_RESET_EPOCH=0
NEXT_RESET_EPOCH=0
RESET_COUNT=0
if (( SERVICE_SECONDS > RESET_INTERVAL_SECONDS && EXPIRE_EPOCH > CREATE_EPOCH )); then
  AUTO_RESET=1
  NEXT_RESET_EPOCH=$((CREATE_EPOCH + RESET_INTERVAL_SECONDS))
fi

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9

PQ_LOCK_HELD=1 /usr/local/sbin/pq_apply_port.sh "$PORT" "$BYTES"

pq_write_meta /etc/portquota/pq-"$PORT".meta \
PORT=$PORT \
LIMIT_BYTES=$BYTES \
ORIGINAL_LIMIT_BYTES=$BYTES \
SAVED_USED_BYTES=0 \
LIMIT_GIB=$GIB \
MODE=quota \
CREATE_EPOCH=$CREATE_EPOCH \
SERVICE_SECONDS=$SERVICE_SECONDS \
EXPIRE_EPOCH=$EXPIRE_EPOCH \
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS \
AUTO_RESET=$AUTO_RESET \
LAST_RESET_EPOCH=$LAST_RESET_EPOCH \
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH \
RESET_COUNT=$RESET_COUNT

PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh
systemctl enable --now nftables >/dev/null 2>&1 || true

if (( AUTO_RESET == 1 )); then
  NEXT_RESET_FMT="$(date -d "@$NEXT_RESET_EPOCH" '+%F %T' 2>/dev/null || echo "$NEXT_RESET_EPOCH")"
  echo "✅ 已为端口 $PORT 设置限额 ${GIB}GiB，服务期超过 30 天，进入第 31 天时会自动重置满流量（同时重置计数器）"
  echo "   服务时长: ${SERVICE_SECONDS}s"
  echo "   到期时间: ${EXPIRE_EPOCH}"
  echo "   下次重置: ${NEXT_RESET_FMT}"
else
  echo "✅ 已为端口 $PORT 设置限额 ${GIB}GiB，服务期不超过 30 天，到期前不自动重置"
fi
ADD
  chmod +x /usr/local/sbin/pq_add.sh

  cat >/usr/local/sbin/pq_reset.sh <<'RESET'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

NOW="$(date +%s)"
CHANGED=0
LOG="/var/log/pq-save.log"

for META in /etc/portquota/pq-*.meta; do
  pq_normalize_meta "$META" >/dev/null 2>&1 || true

  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  ORIGINAL_LIMIT_BYTES="$(meta_get "$META" ORIGINAL_LIMIT_BYTES || true)"
  SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
  LIMIT_GIB="$(meta_get "$META" LIMIT_GIB || true)"
  MODE="$(meta_get "$META" MODE || true)"
  CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
  SERVICE_SECONDS="$(meta_get "$META" SERVICE_SECONDS || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(meta_get "$META" RESET_INTERVAL_SECONDS || true)"
  AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"
  LAST_RESET_EPOCH="$(meta_get "$META" LAST_RESET_EPOCH || true)"
  NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"
  RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$ORIGINAL_LIMIT_BYTES" =~ ^[0-9]+$ ]] || ORIGINAL_LIMIT_BYTES="$LIMIT_BYTES"
  [[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
  [[ "$LIMIT_GIB" =~ ^[0-9]+$ ]] || LIMIT_GIB=$((ORIGINAL_LIMIT_BYTES / 1024 / 1024 / 1024))
  [[ "$MODE" == "quota" ]] || continue
  [[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || CREATE_EPOCH=0
  [[ "$SERVICE_SECONDS" =~ ^[0-9]+$ ]] || SERVICE_SECONDS=0
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || EXPIRE_EPOCH=0
  [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || RESET_INTERVAL_SECONDS=2592000
  [[ "$AUTO_RESET" =~ ^[0-9]+$ ]] || AUTO_RESET=0
  [[ "$LAST_RESET_EPOCH" =~ ^[0-9]+$ ]] || LAST_RESET_EPOCH=0
  [[ "$NEXT_RESET_EPOCH" =~ ^[0-9]+$ ]] || NEXT_RESET_EPOCH=0
  [[ "$RESET_COUNT" =~ ^[0-9]+$ ]] || RESET_COUNT=0

  (( AUTO_RESET == 1 )) || continue
  (( SERVICE_SECONDS > RESET_INTERVAL_SECONDS )) || continue
  (( EXPIRE_EPOCH > NOW )) || continue
  (( NEXT_RESET_EPOCH > 0 )) || continue

  DID_RESET=0
  while (( NEXT_RESET_EPOCH > 0 && NEXT_RESET_EPOCH <= NOW && NEXT_RESET_EPOCH < EXPIRE_EPOCH )); do
    if ! PQ_LOCK_HELD=1 /usr/local/sbin/pq_apply_port.sh "$PORT" "$ORIGINAL_LIMIT_BYTES"; then
      echo "$(date '+%F %T %Z') [pq-reset] port=$PORT reset failed" >> "$LOG"
      break
    fi
    LIMIT_BYTES="$ORIGINAL_LIMIT_BYTES"
    SAVED_USED_BYTES=0
    LAST_RESET_EPOCH="$NEXT_RESET_EPOCH"
    NEXT_RESET_EPOCH=$((NEXT_RESET_EPOCH + RESET_INTERVAL_SECONDS))
    RESET_COUNT=$((RESET_COUNT + 1))
    DID_RESET=1
  done

  if (( NEXT_RESET_EPOCH >= EXPIRE_EPOCH )); then
    NEXT_RESET_EPOCH=0
  fi

  if (( DID_RESET == 1 )); then
    pq_write_meta "$META" \
      "PORT=$PORT" \
      "LIMIT_BYTES=$LIMIT_BYTES" \
      "ORIGINAL_LIMIT_BYTES=$ORIGINAL_LIMIT_BYTES" \
      "SAVED_USED_BYTES=$SAVED_USED_BYTES" \
      "LIMIT_GIB=$LIMIT_GIB" \
      "MODE=$MODE" \
      "CREATE_EPOCH=$CREATE_EPOCH" \
      "SERVICE_SECONDS=$SERVICE_SECONDS" \
      "EXPIRE_EPOCH=$EXPIRE_EPOCH" \
      "RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS" \
      "AUTO_RESET=$AUTO_RESET" \
      "LAST_RESET_EPOCH=$LAST_RESET_EPOCH" \
      "NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH" \
      "RESET_COUNT=$RESET_COUNT"
    CHANGED=1
    echo "$(date '+%F %T %Z') [pq-reset] port=$PORT reset_count=$RESET_COUNT last_reset=$LAST_RESET_EPOCH" >> "$LOG"
  fi
done

if (( CHANGED == 1 )); then
  PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh
fi
RESET
  chmod +x /usr/local/sbin/pq_reset.sh

  cat >/usr/local/sbin/pq_del.sh <<'DEL'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
if [[ -z "$PORT" ]]; then echo "用法: pq_del.sh <端口>" >&2; exit 1; fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2; exit 1
fi

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9

if nft list chain inet portquota down_out >/dev/null 2>&1; then
  nft -a list chain inet portquota down_out 2>/dev/null | \
   awk -v p="$PORT" '
     $0 ~ "comment \"pq-count-out-"p"\"" ||
     $0 ~ "comment \"pq-drop-out-"p"\""  {print $NF}
   ' | while read -r h; do
     nft delete rule inet portquota down_out handle "$h" 2>/dev/null || true
   done
fi

if nft list chain inet portquota up_in >/dev/null 2>&1; then
  nft -a list chain inet portquota up_in 2>/dev/null | \
   awk -v p="$PORT" '
     $0 ~ "comment \"pq-count-in-"p"\"" ||
     $0 ~ "comment \"pq-drop-in-"p"\""  {print $NF}
   ' | while read -r h; do
     nft delete rule inet portquota up_in handle "$h" 2>/dev/null || true
   done
fi

nft delete counter inet portquota "pq_out_$PORT" 2>/dev/null || true
nft delete counter inet portquota "pq_in_$PORT" 2>/dev/null || true
nft delete quota   inet portquota "pq_quota_$PORT" 2>/dev/null || true

rm -f /etc/portquota/pq-"$PORT".meta
PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh
systemctl enable --now nftables >/dev/null 2>&1 || true

echo "✅ 已删除端口 $PORT 的配额（双向统计/限额）"
DEL
  chmod +x /usr/local/sbin/pq_del.sh

  cat >/usr/local/sbin/pq_audit.sh <<'AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

# shellcheck disable=SC1091
source /usr/local/sbin/pq_lib.sh

printf "%-8s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-8s %-8s %-19s %-19s\n" \
  "PORT" "STATE" "LIVE(G)" "SAVED(G)" "USED(G)" "LEFT(G)" "LIMIT(G)" "PERCENT" "RESET" "COUNT" "NEXT_RESET" "EXPIRE"

for META in /etc/portquota/pq-*.meta; do
  pq_normalize_meta "$META" >/dev/null 2>&1 || true

  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  ORIGINAL_LIMIT_BYTES="$(meta_get "$META" ORIGINAL_LIMIT_BYTES || true)"
  SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
  MODE="$(meta_get "$META" MODE || true)"
  AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"
  NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"
  RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$ORIGINAL_LIMIT_BYTES" =~ ^[0-9]+$ ]] || ORIGINAL_LIMIT_BYTES="$LIMIT_BYTES"
  [[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
  MODE="${MODE:-quota}"
  [[ "$AUTO_RESET" =~ ^[0-9]+$ ]] || AUTO_RESET=0
  [[ "$NEXT_RESET_EPOCH" =~ ^[0-9]+$ ]] || NEXT_RESET_EPOCH=0
  [[ "$RESET_COUNT" =~ ^[0-9]+$ ]] || RESET_COUNT=0
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || EXPIRE_EPOCH=0

  LIVE_USED_BYTES=0
  USED_BYTES=0
  LEFT_BYTES=0
  STATE="track"
  PCT="N/A"

  if [[ "$MODE" == "quota" ]] && (( ORIGINAL_LIMIT_BYTES > 0 )); then
    LIVE_USED_BYTES="$(pq_get_live_used_bytes "$PORT" "$LIMIT_BYTES" || true)"
    [[ "$LIVE_USED_BYTES" =~ ^[0-9]+$ ]] || LIVE_USED_BYTES=0
    USED_BYTES=$((SAVED_USED_BYTES + LIVE_USED_BYTES))
    if (( USED_BYTES > ORIGINAL_LIMIT_BYTES )); then
      USED_BYTES="$ORIGINAL_LIMIT_BYTES"
    fi
    LEFT_BYTES=$((ORIGINAL_LIMIT_BYTES - USED_BYTES))
    (( LEFT_BYTES < 0 )) && LEFT_BYTES=0
    if (( LEFT_BYTES == 0 )); then
      STATE="full"
    else
      STATE="ok"
    fi
    PCT="$(awk -v u="$USED_BYTES" -v l="$ORIGINAL_LIMIT_BYTES" 'BEGIN{printf "%.1f%%", (l>0 ? (u*100.0/l) : 0)}')"
  fi

  RESET_FLAG="no"
  (( AUTO_RESET == 1 )) && RESET_FLAG="yes"

  printf "%-8s %-8s %-10s %-10s %-10s %-10s %-10s %-8s %-8s %-8s %-19s %-19s\n" \
    "$PORT" "$STATE" "$(pq_fmt_gib "$LIVE_USED_BYTES")" "$(pq_fmt_gib "$SAVED_USED_BYTES")" "$(pq_fmt_gib "$USED_BYTES")" "$(pq_fmt_gib "$LEFT_BYTES")" "$(pq_fmt_gib "$ORIGINAL_LIMIT_BYTES")" "$PCT" "$RESET_FLAG" "$RESET_COUNT" "$(pq_fmt_epoch "$NEXT_RESET_EPOCH")" "$(pq_fmt_epoch "$EXPIRE_EPOCH")"
done
AUDIT
  chmod +x /usr/local/sbin/pq_audit.sh

  cat >/etc/systemd/system/pq-save.service <<'PQSVC'
[Unit]
Description=Save nftables portquota table (with counters/quotas)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save.sh
PQSVC

  cat >/etc/systemd/system/pq-save.timer <<'PQTMR'
[Unit]
Description=Periodically save nftables portquota snapshot

[Timer]
OnBootSec=30s
OnUnitActiveSec=300s
Persistent=true

[Install]
WantedBy=timers.target
PQTMR

  cat >/etc/systemd/system/pq-reset.service <<'PRSVC'
[Unit]
Description=Auto reset portquota every 30 days for long-lived services

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset.sh
PRSVC

  cat >/etc/systemd/system/pq-reset.timer <<'PRTMR'
[Unit]
Description=Check long-lived portquota reset window

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
PRTMR

  cat >/etc/systemd/system/pq-restore.service <<'PRSVR'
[Unit]
Description=Restore portquota remaining quota from persistent metadata
After=nftables.service
Wants=nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_restore.sh

[Install]
WantedBy=multi-user.target
PRSVR

  cat >/etc/systemd/system/pq-save-state-shutdown.service <<'PQSHUT'
[Unit]
Description=Persist portquota live usage before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target kexec.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh

[Install]
WantedBy=reboot.target halt.target poweroff.target kexec.target
PQSHUT

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-restore.service >/dev/null 2>&1 || true
  systemctl enable pq-save-state-shutdown.service >/dev/null 2>&1 || true

  cat <<USE
============ 使用方法（TCP 双向配额 / 审计，仅统计 VPS<->用户） ============

1) 普通配额（不关心服务期，默认不自动重置）：
   pq_add.sh 443 500

2) 给有明确服务期的端口加配额：
   # 60 天节点：超过 30 天，进入第 31 天自动重置一次（同时重置计数器）
   pq_add.sh 40000 50 $((60*86400))

   # 20 天节点：不自动重置
   pq_add.sh 40001 50 $((20*86400))

   # 也可显式传入到期时间
   CREATE_EPOCH=$(date +%s) pq_add.sh 40002 50 $((60*86400)) $(( $(date +%s) + 60*86400 ))

3) 查看所有端口使用情况（USED = SAVED_USED_BYTES + 当前 live used）：
   pq_audit.sh

4) 删除某个端口的配额：
   pq_del.sh 40000

5) 手动持久化当前开机期间的 live used（正常重启/关机前会自动执行）：
   pq_save_state.sh

统计口径说明：
- 仅统计“用户 <-> VPS”这条 VLESS TCP 连接的流量：
  - VPS -> 用户：hook output，匹配 tcp sport = 监听端口
  - 用户 -> VPS：hook input， 匹配 tcp dport = 监听端口
- 不统计“VPS <-> 网站”的转发流量：
  因为 VPS 访问网站的连接使用临时源端口，不会命中上述 sport/dport = 监听端口的匹配

重启持久化说明：
- ORIGINAL_LIMIT_BYTES：原始总配额
- SAVED_USED_BYTES：历史累计已用
- LIMIT_BYTES：当前剩余配额（用于下次开机重建 nft 规则）
- 审计值 USED = SAVED_USED_BYTES + 当前 live used，所以 reboot 后不会再显示成 0

自动重置规则：
- 服务时长 > 30 天：每满 30 天自动重置一次流量到满额，并重置当前周期计数器
- 服务时长 <= 30 天：到期前不自动重置
- 到达服务到期时间后，不再重置
==========================================================
USE
}

# ------------------ 5. 临时订阅源 IP 槽位限制（仅入站续期） ------------------

install_temp_ip_limit() {
  echo "🧩 部署临时订阅源 IP 槽位限制（仅入站续期，出站只校验不续命）..."
  mkdir -p /etc/portiphold

  systemctl enable --now nftables >/dev/null 2>&1 || true

  if ! nft list table inet portiphold >/dev/null 2>&1; then
    nft add table inet portiphold
  fi
  if ! nft list chain inet portiphold ip_out >/dev/null 2>&1; then
    nft add chain inet portiphold ip_out '{ type filter hook output priority -5; policy accept; }'
  fi
  if ! nft list chain inet portiphold ip_in >/dev/null 2>&1; then
    nft add chain inet portiphold ip_in '{ type filter hook input priority -5; policy accept; }'
  fi

  cat >/usr/local/sbin/iplimit_save.sh <<'IPSAVE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

LOCK="/run/iplimit.lock"
if [[ "${IPLIMIT_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

OUT="/etc/nftables.d/portiphold.nft"
LOG="/var/log/iplimit-save.log"

mkdir -p /etc/nftables.d

if ! nft list table inet portiphold > "${OUT}.tmp" 2>/dev/null; then
  echo "$(date '+%F %T %Z') [iplimit-save] export portiphold failed" >> "$LOG"
  rm -f "${OUT}.tmp" 2>/dev/null || true
  exit 1
fi

mv "${OUT}.tmp" "$OUT"
echo "$(date '+%F %T %Z') [iplimit-save] saved $OUT" >> "$LOG"

if [[ -f /etc/nftables.conf ]]; then
  if ! grep -qE 'include "/etc/nftables\.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
  fi
fi
IPSAVE
  chmod +x /usr/local/sbin/iplimit_save.sh

  /usr/local/sbin/iplimit_save.sh >/dev/null 2>&1 || true

  cat >/usr/local/sbin/iplimit_apply.sh <<'IPAPPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
MAX_IPS="${2:-}"
HOLD_SECONDS="${3:-}"

if [[ -z "$PORT" || -z "$MAX_IPS" || -z "$HOLD_SECONDS" ]]; then
  echo "用法: iplimit_apply.sh <端口> <最大活动源IP数> <保活秒数>" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi
if ! [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || (( MAX_IPS <= 0 )); then
  echo "❌ 最大活动源 IP 数必须是正整数" >&2
  exit 1
fi
if ! [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]] || (( HOLD_SECONDS <= 0 )); then
  echo "❌ 保活秒数必须是正整数" >&2
  exit 1
fi

LOCK="/run/iplimit.lock"
if [[ "${IPLIMIT_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi

if ! nft list table inet portiphold >/dev/null 2>&1; then
  nft add table inet portiphold
fi
if ! nft list chain inet portiphold ip_out >/dev/null 2>&1; then
  nft add chain inet portiphold ip_out '{ type filter hook output priority -5; policy accept; }'
fi
if ! nft list chain inet portiphold ip_in >/dev/null 2>&1; then
  nft add chain inet portiphold ip_in '{ type filter hook input priority -5; policy accept; }'
fi

SET_NAME="iplive4_${PORT}"

nft -a list chain inet portiphold ip_in 2>/dev/null | \
 awk -v p="$PORT" '
   $0 ~ "comment \"ipl-keep-in-"p"\"" ||
   $0 ~ "comment \"ipl-add-in-"p"\""  ||
   $0 ~ "comment \"ipl-drop-in-"p"\"" {print $NF}
 ' | while read -r h; do
   nft delete rule inet portiphold ip_in handle "$h" 2>/dev/null || true
 done

nft -a list chain inet portiphold ip_out 2>/dev/null | \
 awk -v p="$PORT" '
   $0 ~ "comment \"ipl-pass-out-"p"\"" ||
   $0 ~ "comment \"ipl-drop-out-"p"\"" {print $NF}
 ' | while read -r h; do
   nft delete rule inet portiphold ip_out handle "$h" 2>/dev/null || true
 done

nft delete set inet portiphold "$SET_NAME" 2>/dev/null || true

nft add set inet portiphold "$SET_NAME" "{ type ipv4_addr; flags dynamic,timeout; timeout ${HOLD_SECONDS}s; size ${MAX_IPS}; }"

nft add rule inet portiphold ip_in tcp dport "$PORT" ip saddr @${SET_NAME} \
  update @${SET_NAME} { ip saddr timeout ${HOLD_SECONDS}s } accept comment "ipl-keep-in-$PORT"
nft add rule inet portiphold ip_in tcp dport "$PORT" \
  add @${SET_NAME} { ip saddr timeout ${HOLD_SECONDS}s } accept comment "ipl-add-in-$PORT"
nft add rule inet portiphold ip_in tcp dport "$PORT" \
  drop comment "ipl-drop-in-$PORT"

nft add rule inet portiphold ip_out tcp sport "$PORT" ip daddr @${SET_NAME} \
  accept comment "ipl-pass-out-$PORT"
nft add rule inet portiphold ip_out tcp sport "$PORT" \
  drop comment "ipl-drop-out-$PORT"
IPAPPLY
  chmod +x /usr/local/sbin/iplimit_apply.sh

  cat >/usr/local/sbin/iplimit_add.sh <<'IPADD'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
MAX_IPS="${2:-}"
HOLD_SECONDS="${3:-}"
SERVICE_SECONDS_ARG="${4:-${SERVICE_SECONDS:-0}}"
EXPIRE_EPOCH_ARG="${5:-${EXPIRE_EPOCH:-0}}"
CREATE_EPOCH="${CREATE_EPOCH:-$(date +%s)}"

if [[ -z "$PORT" || -z "$MAX_IPS" || -z "$HOLD_SECONDS" ]]; then
  echo "用法: iplimit_add.sh <端口> <最大活动源IP数> <保活秒数> [SERVICE_SECONDS] [EXPIRE_EPOCH]" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi
if ! [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || (( MAX_IPS <= 0 )); then
  echo "❌ 最大活动源 IP 数必须是正整数" >&2
  exit 1
fi
if ! [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]] || (( HOLD_SECONDS <= 0 )); then
  echo "❌ 保活秒数必须是正整数" >&2
  exit 1
fi
if ! [[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || (( CREATE_EPOCH <= 0 )); then
  echo "❌ CREATE_EPOCH 非法" >&2
  exit 1
fi
if ! [[ "$SERVICE_SECONDS_ARG" =~ ^[0-9]+$ ]] || (( SERVICE_SECONDS_ARG < 0 )); then
  echo "❌ SERVICE_SECONDS 必须是非负整数秒" >&2
  exit 1
fi
if ! [[ "$EXPIRE_EPOCH_ARG" =~ ^[0-9]+$ ]] || (( EXPIRE_EPOCH_ARG < 0 )); then
  echo "❌ EXPIRE_EPOCH 必须是非负整数" >&2
  exit 1
fi

SERVICE_SECONDS="$SERVICE_SECONDS_ARG"
EXPIRE_EPOCH="$EXPIRE_EPOCH_ARG"
if (( SERVICE_SECONDS > 0 && EXPIRE_EPOCH == 0 )); then
  EXPIRE_EPOCH=$((CREATE_EPOCH + SERVICE_SECONDS))
fi

LOCK="/run/iplimit.lock"
exec 9>"$LOCK"
flock -w 10 9

IPLIMIT_LOCK_HELD=1 /usr/local/sbin/iplimit_apply.sh "$PORT" "$MAX_IPS" "$HOLD_SECONDS"

cat >/etc/portiphold/ipl-"$PORT".meta <<M
PORT=$PORT
MODE=limit
MAX_IPS=$MAX_IPS
HOLD_SECONDS=$HOLD_SECONDS
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
M

IPLIMIT_LOCK_HELD=1 /usr/local/sbin/iplimit_save.sh
systemctl enable --now nftables >/dev/null 2>&1 || true

echo "✅ 已为端口 $PORT 启用源 IP 槽位限制：最多 ${MAX_IPS} 个活动源 IP，槽位保活 ${HOLD_SECONDS} 秒（仅入站源 IP 续期）"
IPADD
  chmod +x /usr/local/sbin/iplimit_add.sh

  cat >/usr/local/sbin/iplimit_del.sh <<'IPDEL'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
if [[ -z "$PORT" ]]; then
  echo "用法: iplimit_del.sh <端口>" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi

LOCK="/run/iplimit.lock"
exec 9>"$LOCK"
flock -w 10 9

SET_NAME="iplive4_${PORT}"

if nft list chain inet portiphold ip_in >/dev/null 2>&1; then
  nft -a list chain inet portiphold ip_in 2>/dev/null | \
   awk -v p="$PORT" '
     $0 ~ "comment \"ipl-keep-in-"p"\"" ||
     $0 ~ "comment \"ipl-add-in-"p"\""  ||
     $0 ~ "comment \"ipl-drop-in-"p"\"" {print $NF}
   ' | while read -r h; do
     nft delete rule inet portiphold ip_in handle "$h" 2>/dev/null || true
   done
fi

if nft list chain inet portiphold ip_out >/dev/null 2>&1; then
  nft -a list chain inet portiphold ip_out 2>/dev/null | \
   awk -v p="$PORT" '
     $0 ~ "comment \"ipl-pass-out-"p"\"" ||
     $0 ~ "comment \"ipl-drop-out-"p"\"" {print $NF}
   ' | while read -r h; do
     nft delete rule inet portiphold ip_out handle "$h" 2>/dev/null || true
   done
fi

nft delete set inet portiphold "$SET_NAME" 2>/dev/null || true
rm -f /etc/portiphold/ipl-"$PORT".meta
IPLIMIT_LOCK_HELD=1 /usr/local/sbin/iplimit_save.sh
systemctl enable --now nftables >/dev/null 2>&1 || true

echo "✅ 已删除端口 $PORT 的源 IP 槽位限制"
IPDEL
  chmod +x /usr/local/sbin/iplimit_del.sh

  cat >/usr/local/sbin/iplimit_audit.sh <<'IPAUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

get_ips() {
  local port="$1" set_name="iplive4_${1}" raw
  raw="$(nft list set inet portiphold "$set_name" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -z "$raw" ]]; then
    echo ""
    return 0
  fi
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' <<< "$raw" | paste -sd, -
}

printf "%-8s %-8s %-8s %-12s %-19s %-s\n" "PORT" "MAX_IPS" "USED" "HOLD(s)" "EXPIRE" "IPS"

for META in /etc/portiphold/ipl-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"
  MAX_IPS="$(meta_get "$META" MAX_IPS || true)"
  HOLD_SECONDS="$(meta_get "$META" HOLD_SECONDS || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
  [[ "$HOLD_SECONDS" =~ ^[0-9]+$ ]] || HOLD_SECONDS=0
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || EXPIRE_EPOCH=0

  IPS="$(get_ips "$PORT")"
  if [[ -n "$IPS" ]]; then
    USED="$(awk -F',' '{print NF}' <<< "$IPS")"
  else
    USED=0
    IPS="-"
  fi

  if (( EXPIRE_EPOCH > 0 )); then
    EXPIRE_FMT="$(date -d "@$EXPIRE_EPOCH" '+%F %T' 2>/dev/null || echo "$EXPIRE_EPOCH")"
  else
    EXPIRE_FMT="-"
  fi

  printf "%-8s %-8s %-8s %-12s %-19s %-s\n" "$PORT" "$MAX_IPS" "$USED" "$HOLD_SECONDS" "$EXPIRE_FMT" "$IPS"
done
IPAUDIT
  chmod +x /usr/local/sbin/iplimit_audit.sh

  cat >/etc/systemd/system/iplimit-save.service <<'IPSVC'
[Unit]
Description=Save nftables source IP slot table

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/iplimit_save.sh
IPSVC

  cat >/etc/systemd/system/iplimit-save.timer <<'IPTMR'
[Unit]
Description=Periodically save nftables source IP slot snapshot

[Timer]
OnBootSec=45s
OnUnitActiveSec=300s
Persistent=true

[Install]
WantedBy=timers.target
IPTMR

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now iplimit-save.timer >/dev/null 2>&1 || true

  cat <<USE
============ 使用方法（临时订阅源 IP 槽位限制，仅入站续期） ============

1) 创建临时节点时启用源 IP 槽位限制：
   IP_LIMIT=1 D=600 vless_mktemp.sh
   IP_LIMIT=3 D=600 vless_mktemp.sh

2) 调整“IP 占位”保活时长（默认 1800 秒）：
   IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh

3) 配额和 IP 限制可同时使用：
   PQ_GIB=50 IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh

4) 行为说明：
   - 每个临时端口最多允许 IP_LIMIT 个活动源 IP
   - 新的入站源 IP 到来时，占用一个槽位
   - 已占位的源 IP 只有在“入站”访问该端口时，才会刷新自己的过期时间
   - 服务端发往客户端的出站回包只校验目标 IP 是否已占位，不会刷新占位，避免被回包反复续命
   - 槽位超时后自动释放，新的源 IP 才能补位

5) 查看当前占位情况：
   iplimit_audit.sh
=============================================================
USE
}

# ------------------ 5. 日志轮转（保留 2 天） ------------------

install_logrotate_rules() {
  echo "🧩 写入 logrotate 规则（保留 2 天，压缩）..."
  cat >/etc/logrotate.d/portquota-vless <<'LR'
/var/log/pq-save.log /var/log/vless-gc.log /var/log/iplimit-save.log {
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
LR
}

# ------------------ 6. systemd-journald 清理（保留 2 天） ------------------

install_journal_vacuum() {
  echo "🧩 设置 systemd journal 自动清理（保留 2 天）..."
  cat >/etc/systemd/system/journal-vacuum.service <<'SVC'
[Unit]
Description=Vacuum systemd journal (keep 2 days)

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=2d
SVC

  cat >/etc/systemd/system/journal-vacuum.timer <<'TMR'
[Unit]
Description=Daily vacuum systemd journal

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TMR

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now journal-vacuum.timer >/dev/null 2>&1 || true
}

# ------------------ 主流程 ------------------

main() {
  check_debian12
  need_basic_tools
  download_upstreams

  install_vless_defaults
  install_update_all
  install_vless_script
  install_vless_temp_audit
  install_port_quota
  install_temp_ip_limit
  install_logrotate_rules
  install_journal_vacuum

  cat <<'DONE'
==================================================
✅ 所有脚本已生成完毕（适用于 Debian 12）

默认身份：root
不需要 sudo

先做这一件事：
   nano /etc/default/vless-reality

至少把这一项改掉：
   PUBLIC_DOMAIN=your.domain.com

例如改成：
   PUBLIC_DOMAIN=proxy.example.com
   CAMOUFLAGE_DOMAIN=www.cloudflare.com
   REALITY_DEST=www.cloudflare.com:443
   REALITY_SNI=www.cloudflare.com
   PORT=443
   NODE_NAME=MY-VLESS

可用命令一览：

1) 系统更新 + 新内核：
   update-all
   reboot

2) VLESS Reality 主节点（客户端连接域名 + 可自定义伪装站）：
   bash /root/onekey_reality_ipv4.sh

3) VLESS 临时节点 + 审计 + GC（绝对时间 TTL）：
   bash /root/vless_temp_audit_ipv4_all.sh

   # 部署后：
   D=600 vless_mktemp.sh
   PORT_START=40000 PORT_END=60000 D=600 vless_mktemp.sh
   MAX_START_RETRIES=8 D=600 vless_mktemp.sh
   PBK=<publicKey> D=600 vless_mktemp.sh

   # 推荐：创建临时节点时直接绑定配额
   PQ_GIB=50 D=600 vless_mktemp.sh
   PQ_GIB=50 D=$((60*86400)) vless_mktemp.sh
   PQ_GIB=50 D=$((20*86400)) vless_mktemp.sh

   # 临时节点支持源 IP 槽位限制（例：只允许 1 个 / 3 个活动源 IP）
   IP_LIMIT=1 D=600 vless_mktemp.sh
   IP_LIMIT=3 D=600 vless_mktemp.sh
   IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh
   PQ_GIB=50 IP_LIMIT=3 IP_STICKY_SECONDS=900 D=600 vless_mktemp.sh

   vless_audit.sh
   vless_clear_all.sh
   FORCE=1 vless_cleanup_one.sh vless-temp-YYYYMMDDHHMMSS-ABCD

4) TCP 配额（nftables + 5 分钟保存快照，双向合计）：
   # 主节点配额
   pq_add.sh 443 500

   # 已创建节点后补配额 / 改配额
   pq_add.sh 40000 50 $((60*86400))
   pq_add.sh 40001 50 $((20*86400))

   pq_audit.sh
   pq_del.sh 40000

5) 日志轮转（保留最近 2 天）：
   - /var/log/pq-save.log
   - /var/log/vless-gc.log
   - /var/log/iplimit-save.log
   配置文件：/etc/logrotate.d/portquota-vless

6) systemd journal 自动清理（保留 2 天）：
   systemctl status journal-vacuum.timer

域名逻辑说明：
- 客户端连接 VPS：走 PUBLIC_DOMAIN
- Reality 伪装站/SNI：走 CAMOUFLAGE_DOMAIN / REALITY_SNI / REALITY_DEST
- VPS 换 IP 后，只需把 PUBLIC_DOMAIN 的解析改到新 IP，客户端链接不用变

配额自动重置逻辑：
- 服务时长 > 30 天：第 31 天开始每满 30 天自动重置满流量（同时重置计数器）
- 服务时长 <= 30 天：到期前不自动重置
- 临时节点删除时，会自动删除对应端口配额，避免残留

🎯 建议顺序：
   1) update-all && reboot
   2) 编辑 /etc/default/vless-reality
   3) bash /root/onekey_reality_ipv4.sh
   4) bash /root/vless_temp_audit_ipv4_all.sh
      然后优先用：PQ_GIB=xx D=xxx vless_mktemp.sh
      如需限制临时订阅活动源 IP 数：IP_LIMIT=1 或 IP_LIMIT=3（可配 IP_STICKY_SECONDS）
   5) 主节点限额或后补限额时，再用：pq_add.sh / pq_audit.sh / pq_del.sh
==================================================
DONE
}

main "$@"
