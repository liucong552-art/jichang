#!/usr/bin/env bash
# Debian 12 一键部署脚本（整洁最终版）
# - 初始化系统 & 内核
# - VLESS Reality 主节点（客户端连接域名走 PUBLIC_DOMAIN；伪装站可自定义）
# - VLESS 临时节点 + 审计 + GC（绝对时间 TTL）
# - nftables TCP 双向配额系统（仅统计 VPS<->用户，自动持久化 + 5 分钟保存快照）
# - 长周期服务（>30 天）配额每 30 天自动重置满流量；<=30 天不重置
# - 删除临时节点时自动删除对应配额，避免残留
# - 修复临时节点“假成功”问题：启动后等待 active+监听，失败自动回滚并换端口重试
# - 修复 stop/cleanup 重入问题：拆分为 stop 包装脚本 + post-stop 清理脚本
# - 日志 logrotate：保留最近 2 天
# - systemd journal：自动 vacuum 保留 2 天

set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

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

CONF_FILE="/etc/default/vless-reality"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

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

install_xray_official() {
  echo "⚙ 安装 / 更新 Xray-core..."
  local installer="/tmp/xray-install-release.sh"
  rm -f "$installer"
  curl4 -L "$XRAY_INSTALL_URL" -o "$installer"
  chmod +x "$installer"
  bash "$installer" install --without-geodata
  rm -f "$installer"
  if [ ! -x /usr/local/bin/xray ]; then
    echo "❌ 未找到 /usr/local/bin/xray，请检查安装结果"; exit 1
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

xray_check_config() {
  local cfg="$1"
  /usr/local/bin/xray run -test -format=json -config "$cfg" >/dev/null 2>&1
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

resolve_ipv4s() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
local_global_ipv4s() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u; }
domain_hits_local_ipv4() {
  local host="$1" dip lip
  while read -r dip; do
    [[ -n "$dip" ]] || continue
    while read -r lip; do
      [[ -n "$lip" && "$dip" == "$lip" ]] && return 0
    done < <(local_global_ipv4s)
  done < <(resolve_ipv4s "$host")
  return 1
}
if ! getent ahostsv4 "$PUBLIC_DOMAIN" >/dev/null 2>&1; then
  echo "❌ 域名未解析到 IPv4: $PUBLIC_DOMAIN"
  echo "   请先把它的 DNS A 记录指向当前 VPS，再重试。"
  exit 1
fi
if ! domain_hits_local_ipv4 "$PUBLIC_DOMAIN"; then
  echo "⚠️  警告：PUBLIC_DOMAIN 已解析到 IPv4，但当前 A 记录未命中本机任一 global IPv4。"
  echo "   脚本继续执行，但客户端很可能无法连接到这台 VPS，请再次核对 DNS A 记录。"
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
install_xray_official

force_xray_run_as_root

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

BACKUP_CFG=""
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  BACKUP_CFG="$CONFIG_DIR/config.json.bak.$(date +%F-%H%M%S)"
  cp -a "$CONFIG_DIR/config.json" "$BACKUP_CFG"
fi

NEW_CFG="$CONFIG_DIR/config.test.$$.json"
cat >"$NEW_CFG" <<CONF
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
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_DEST",
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

chown root:root "$NEW_CFG" 2>/dev/null || true
chmod 600 "$NEW_CFG" 2>/dev/null || true

if ! xray_check_config "$NEW_CFG"; then
  echo "❌ 新生成的 xray 配置未通过校验，保留失败配置: $NEW_CFG" >&2
  exit 1
fi

mv -f "$NEW_CFG" "$CONFIG_DIR/config.json"

systemctl daemon-reload
systemctl reset-failed xray.service >/dev/null 2>&1 || true
systemctl enable xray.service >/dev/null 2>&1 || true
systemctl restart xray.service || {
  echo "❌ xray 重启失败，正在尝试回滚旧配置 ..." >&2
  if [[ -n "$BACKUP_CFG" && -f "$BACKUP_CFG" ]]; then
    cp -a "$BACKUP_CFG" "$CONFIG_DIR/config.json"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart xray.service >/dev/null 2>&1 || true
  fi
  exit 1
}

if ! wait_unit_and_port_stable xray.service "$PORT" 40 0.25 4; then
  echo "❌ xray 启动失败，状态与日志如下：" >&2
  systemctl --no-pager --full status xray.service >&2 || true
  journalctl -u xray.service --no-pager -n 120 >&2 || true
  if [[ -n "$BACKUP_CFG" && -f "$BACKUP_CFG" ]]; then
    echo "⚠️ 正在尝试回滚旧配置 ..." >&2
    cp -a "$BACKUP_CFG" "$CONFIG_DIR/config.json"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart xray.service >/dev/null 2>&1 || true
  fi
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

RUNTIME_META="/root/vless_reality_runtime.meta"
TMP_RUNTIME="${RUNTIME_META}.tmp.$$"
cat >"$TMP_RUNTIME" <<META
PUBLIC_KEY=$PUBLIC_KEY
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
REALITY_DEST=$REALITY_DEST
REALITY_SNI=$REALITY_SNI
PORT=$PORT
NODE_NAME=$NODE_NAME
META
chmod 600 "$TMP_RUNTIME" 2>/dev/null || true
mv -f "$TMP_RUNTIME" "$RUNTIME_META"

chmod 600 /root/v2ray_subscription_base64.txt /root/vless_reality_vision_url.txt "$RUNTIME_META" 2>/dev/null || true

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

# ------------------ 4. 日志轮转（保留 2 天） ------------------

install_logrotate_rules() {
  echo "🧩 写入 logrotate 规则（保留 2 天，压缩）..."
  cat >/etc/logrotate.d/portquota-vless <<'LR'
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
LR
}

# ------------------ 5. systemd-journald 清理（保留 2 天） ------------------

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


# ------------------ 3. VLESS 临时节点 + 审计 + 策略（增强版） ------------------

install_vless_enhancements() {
  echo "🧩 写入增强版 VLESS 临时节点系统与端口策略脚本 ..."
  cat >/root/vless_temp_audit_ipv4_all.sh <<'EOF_VLESS_ENH'
#!/usr/bin/env bash
# VLESS 临时节点 + 审计 + GC + 生命周期操作 + 开机自愈
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

XRAY_DIR="/usr/local/etc/xray"

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"
}

meta_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="${file}.tmp.$$"
  awk -F= -v k="$key" -v v="$value" '
    BEGIN{done=0}
    $1==k {print k "=" v; done=1; next}
    {print}
    END{if(!done) print k "=" v}
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

mkdir -p "$XRAY_DIR"

########################################
# 1) stop 后清理
########################################
cat >/usr/local/sbin/vless_poststop_cleanup.sh <<'POSTSTOP'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"
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
MANAGED_FLAG="/run/vless-managed-stop/${TAG}"

if [[ -f "$MANAGED_FLAG" ]]; then
  exit 0
fi

PORT=""
if [[ -f "$META" ]]; then
  PORT="$(meta_get "$META" PORT || true)"
fi
if [[ -z "${PORT:-}" && -f "$CFG" ]]; then
  PORT="$(read_port_from_cfg "$CFG" || true)"
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  PAUSED="$(meta_get "$META" PAUSED || true)"
  if [[ "${PAUSED:-0}" == "1" ]]; then
    echo "[vless_poststop_cleanup] ${TAG} 已暂停，跳过清理"
    exit 0
  fi
fi

LOCK="/run/vless-temp.lock"
if [[ "${VLESS_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "[vless_poststop_cleanup] lock busy, defer cleanup: ${TAG}"; exit 0; }
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ -n "${EXPIRE_EPOCH:-}" && "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    if (( EXPIRE_EPOCH > NOW )); then
      echo "[vless_poststop_cleanup] ${TAG} 未到期，跳过清理"
      exit 0
    fi
  fi
fi

systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
if [[ -n "${PORT:-}" && "$PORT" =~ ^[0-9]+$ ]] && [[ -x /usr/local/sbin/pq_del.sh ]]; then
  /usr/local/sbin/pq_del.sh "$PORT" >/dev/null 2>&1 || echo "[vless_poststop_cleanup] pq_del failed for ${TAG}:${PORT}" >&2
fi
rm -f "$CFG" "$META" "/etc/systemd/system/${UNIT_NAME}" 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true

echo "$(date '+%F %T %Z') cleanup ${TAG}" >> "$LOG" 2>/dev/null || true
POSTSTOP
chmod +x /usr/local/sbin/vless_poststop_cleanup.sh

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
LOCK="/run/vless-temp.lock"
MANAGED_DIR="/run/vless-managed-stop"
MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
mkdir -p "$MANAGED_DIR"
trap 'rm -f "$MANAGED_FLAG"' EXIT

if [[ "${VLESS_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9
fi


ACTIVE_STATE="$(systemctl show -p ActiveState --value "${UNIT_NAME}" 2>/dev/null || echo "")"
SUB_STATE="$(systemctl show -p SubState --value "${UNIT_NAME}" 2>/dev/null || echo "")"
if [[ "$ACTIVE_STATE" == "active" || "$ACTIVE_STATE" == "activating" || "$SUB_STATE" == "running" || "$SUB_STATE" == "start" ]]; then
  : >"$MANAGED_FLAG"
  if ! timeout 15 systemctl stop "$UNIT_NAME" >/dev/null 2>&1; then
    systemctl kill "$UNIT_NAME" >/dev/null 2>&1 || true
    timeout 10 systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$MANAGED_FLAG"
fi

if [[ -f "$CFG" || -f "$META" || -f "$UNIT_FILE" ]]; then
  VLESS_LOCK_HELD=1 FORCE="$FORCE" /usr/local/sbin/vless_poststop_cleanup.sh "$TAG"
fi
CLEAN
chmod +x /usr/local/sbin/vless_cleanup_one.sh

cat >/usr/local/sbin/vless_run_temp.sh <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
TAG="${1:?need TAG}"
CFG="${2:?need config path}"
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
XRAY_DIR="/usr/local/etc/xray"
META="${XRAY_DIR}/${TAG}.meta"
[[ -x "$XRAY_BIN" ]] || { echo "[vless_run_temp] xray binary not found" >&2; exit 1; }
[[ -f "$CFG" ]] || { echo "[vless_run_temp] config not found: $CFG" >&2; exit 1; }
[[ -f "$META" ]] || { echo "[vless_run_temp] meta not found: $META" >&2; exit 1; }
EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
PORT="$(meta_get "$META" PORT || true)"
POLICY="$(meta_get "$META" PQ_POLICY || true)"
PQ_GIB="$(meta_get "$META" PQ_GIB || true)"
MAX_IPS="$(meta_get "$META" PQ_MAX_IPS || true)"
IP_TIMEOUT_SECONDS="$(meta_get "$META" PQ_IP_TIMEOUT_SECONDS || true)"
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || { echo "[vless_run_temp] bad EXPIRE_EPOCH" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "[vless_run_temp] bad PORT" >&2; exit 1; }
[[ "$PQ_GIB" =~ ^[0-9]+$ ]] || PQ_GIB=0
[[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=90
NOW=$(date +%s)
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  FORCE=1 /usr/local/sbin/vless_poststop_cleanup.sh "$TAG" 2>/dev/null || true
  exit 0
fi
if [[ "${POLICY:-0}" == "1" ]]; then
  LIMIT_BYTES=$((PQ_GIB * 1024 * 1024 * 1024))
  if [[ ! -x /usr/local/sbin/pq_ensure_port.sh ]]; then
    echo "[vless_run_temp] pq_ensure_port.sh missing for policy-enabled tag: $TAG" >&2
    exit 1
  fi
  if ! PQ_LOCK_HELD=0 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_ensure_port.sh "$PORT" "$LIMIT_BYTES" >/dev/null 2>&1; then
    echo "[vless_run_temp] pq_ensure failed for ${TAG}:${PORT}" >&2
    exit 1
  fi
fi
exec timeout "$REMAIN" "$XRAY_BIN" run -c "$CFG"
RUN
chmod +x /usr/local/sbin/vless_run_temp.sh

########################################
# 2) 创建 / 生命周期操作
########################################
cat >/usr/local/sbin/vless_mktemp.sh <<'MK'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${D:?请用 D=秒 vless_mktemp.sh 方式调用，例如：D=600 vless_mktemp.sh}"

if ! [[ "$D" =~ ^[0-9]+$ ]] || (( D <= 0 )); then
  echo "❌ D 必须是正整数秒" >&2
  exit 1
fi
if [[ -n "${PQ_GIB:-}" ]]; then
  [[ "$PQ_GIB" =~ ^[0-9]+$ ]] || { echo "❌ PQ_GIB 必须是非负整数" >&2; exit 1; }
fi
if [[ -n "${MAX_IPS:-}" ]]; then
  [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || { echo "❌ MAX_IPS 必须是非负整数" >&2; exit 1; }
fi
IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}"
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "❌ IP_TIMEOUT_SECONDS 必须是正整数" >&2; exit 1; }
(( IP_TIMEOUT_SECONDS > 0 )) || { echo "❌ IP_TIMEOUT_SECONDS 必须大于 0" >&2; exit 1; }

CONF_FILE="/etc/default/vless-reality"
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9

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
urlencode() { python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}
urldecode() { python3 - "$1" <<'PY'
import urllib.parse,sys
print(urllib.parse.unquote(sys.argv[1]))
PY
}
sanitize_one_line() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }
port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v p="$port" '{ n=split($4,a,":"); if (a[n] == p) {found=1; exit} } END { exit(found ? 0 : 1) }'
}
wait_unit_and_port_stable() {
  local unit="$1" port="$2" tries="${3:-40}" delay="${4:-0.25}" stable_needed="${5:-4}"
  local i state sub stable=0
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]] && port_is_listening "$port"; then
      stable=$((stable+1))
      (( stable >= stable_needed )) && return 0
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
xray_check_config() {
  "$XRAY_BIN" run -test -format=json -config "$1" >/dev/null 2>&1
}
pick_free_port() {
  declare -A USED_PORTS=()
  while read -r p; do [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1; done < <(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/')
  shopt -s nullglob
  for f in "${XRAY_DIR}"/vless-temp-*.meta; do
    p="$(awk -F= '$1=="PORT"{sub($1"=","",$0);print;exit}' "$f" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
  done
  for f in /etc/portquota/pq-*.meta; do
    p="$(awk -F= '$1=="PORT"{sub($1"=","",$0);print;exit}' "$f" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
  done
  shopt -u nullglob
  local port="$PORT_START"
  while (( port <= PORT_END )); do
    if [[ -z "${USED_PORTS[$port]+x}" ]]; then echo "$port"; return 0; fi
    port=$((port+1))
  done
  return 1
}
write_unit() {
  cat >"$UNIT" <<U
[Unit]
Description=Temp VLESS $TAG
Wants=nftables.service pq-reconcile.service
After=network.target nftables.service pq-reconcile.service

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
}

XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
[[ -x "$XRAY_BIN" ]] || { echo "❌ 未找到 xray 可执行文件" >&2; exit 1; }
XRAY_DIR="/usr/local/etc/xray"
MAIN_CFG="${XRAY_DIR}/config.json"
[[ -f "$MAIN_CFG" ]] || { echo "❌ 未找到主 VLESS 配置 $MAIN_CFG" >&2; exit 1; }
mapfile -t arr < <(python3 - "$MAIN_CFG" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
ibs=cfg.get("inbounds",[])
if not ibs:
    print(""); print(""); print("")
else:
    ib=ibs[0]; rs=ib.get("streamSettings",{}).get("realitySettings",{})
    pkey=rs.get("privateKey",""); dest=rs.get("target","") or rs.get("dest",""); sns=rs.get("serverNames",[])
    sni=sns[0] if sns else ""
    print(pkey); print(dest); print(sni)
PY
)
REALITY_PRIVATE_KEY="${arr[0]:-}"
REALITY_DEST="${arr[1]:-}"
REALITY_SNI="${arr[2]:-}"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_DEST" ]] || { echo "❌ 无法从主配置解析 Reality 参数" >&2; exit 1; }
[[ -n "$REALITY_SNI" ]] || REALITY_SNI="${REALITY_DEST%%:*}"

PBK="${PBK:-}"
RUNTIME_META="/root/vless_reality_runtime.meta"
if [[ -z "$PBK" && -f "$RUNTIME_META" ]]; then
  PBK="$(awk -F= '$1=="PUBLIC_KEY"{sub($1"=","",$0); print; exit}' "$RUNTIME_META" 2>/dev/null || true)"
fi
if [[ -z "$PBK" && -f /root/vless_reality_vision_url.txt ]]; then
  LINE="$(sed -n '1p' /root/vless_reality_vision_url.txt 2>/dev/null || true)"
  [[ -n "$LINE" ]] && PBK="$(grep -o 'pbk=[^&]*' <<< "$LINE" | head -n1 | cut -d= -f2)"
fi
[[ -n "$PBK" ]] || { echo "❌ 未能获取 pbk" >&2; exit 1; }
PBK="$(urldecode "$PBK")"

PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
MAX_START_RETRIES="${MAX_START_RETRIES:-5}"
[[ "$PORT_START" =~ ^[0-9]+$ && "$PORT_END" =~ ^[0-9]+$ ]] || { echo "❌ 端口范围无效" >&2; exit 1; }
(( PORT_START >= 1 && PORT_END <= 65535 && PORT_START < PORT_END )) || { echo "❌ 端口范围无效" >&2; exit 1; }
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] || { echo "❌ MAX_START_RETRIES 无效" >&2; exit 1; }
SERVER_ADDR="${PUBLIC_DOMAIN:-}"
if [[ -z "$SERVER_ADDR" && -f "$CONF_FILE" ]]; then SERVER_ADDR="$(cfg_get "$CONF_FILE" PUBLIC_DOMAIN || true)"; fi
[[ -n "$SERVER_ADDR" && "$SERVER_ADDR" != "your.domain.com" ]] || { echo "❌ 未配置 PUBLIC_DOMAIN" >&2; exit 1; }
resolve_ipv4s() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
local_global_ipv4s() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u; }
domain_hits_local_ipv4() {
  local host="$1" dip lip
  while read -r dip; do
    [[ -n "$dip" ]] || continue
    while read -r lip; do
      [[ -n "$lip" && "$dip" == "$lip" ]] && return 0
    done < <(local_global_ipv4s)
  done < <(resolve_ipv4s "$host")
  return 1
}
getent ahostsv4 "$SERVER_ADDR" >/dev/null 2>&1 || { echo "❌ PUBLIC_DOMAIN 未解析到 IPv4: $SERVER_ADDR" >&2; exit 1; }
if ! domain_hits_local_ipv4 "$SERVER_ADDR"; then
  echo "⚠️  警告：PUBLIC_DOMAIN 当前解析未命中本机任一 global IPv4，生成链接可能出现假成功。" >&2
fi

PQ_GIB_SAFE="${PQ_GIB:-0}"
MAX_IPS_SAFE="${MAX_IPS:-0}"
POLICY_ENABLED=0
(( PQ_GIB_SAFE > 0 || MAX_IPS_SAFE > 0 )) && POLICY_ENABLED=1

mkdir -p "$XRAY_DIR"
UUID="$($XRAY_BIN uuid)"
SHORT_ID="$(openssl rand -hex 8)"
TAG="vless-temp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
CFG="${XRAY_DIR}/${TAG}.json"
META="${XRAY_DIR}/${TAG}.meta"
UNIT="/etc/systemd/system/${TAG}.service"

ATTEMPT=1
START_OK=0
LAST_PORT=""
LAST_EXP=""
while (( ATTEMPT <= MAX_START_RETRIES )); do
  PORT="$(pick_free_port || true)"
  [[ -n "$PORT" ]] || { echo "❌ 没有空闲端口" >&2; exit 1; }
  NOW="$(date +%s)"
  EXP="$((NOW + D))"
  LAST_PORT="$PORT"; LAST_EXP="$EXP"

  cat >"$CFG" <<CFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_DEST}",
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
    { "tag": "block", "protocol": "blackhole" }
  ]
}
CFG

  if ! xray_check_config "$CFG"; then
    rm -f "$CFG" >/dev/null 2>&1 || true
    echo "❌ 生成的临时节点配置未通过 xray 校验" >&2
    exit 1
  fi

  META_TMP="${META}.tmp.$$"
  cat >"$META_TMP" <<M
TAG=$TAG
UUID=$UUID
PORT=$PORT
SERVER_ADDR=$SERVER_ADDR
CREATE_EPOCH=$NOW
DURATION_SECONDS=$D
EXPIRE_EPOCH=$EXP
REALITY_DEST=$REALITY_DEST
REALITY_SNI=$REALITY_SNI
SHORT_ID=$SHORT_ID
PBK=$PBK
PAUSED=0
PAUSED_AT=0
PQ_POLICY=$POLICY_ENABLED
PQ_GIB=$PQ_GIB_SAFE
PQ_MAX_IPS=$MAX_IPS_SAFE
PQ_IP_TIMEOUT_SECONDS=$IP_TIMEOUT_SECONDS
M
  mv -f "$META_TMP" "$META"
  chmod 600 "$CFG" "$META" 2>/dev/null || true
  write_unit
  systemctl daemon-reload
  systemctl reset-failed "$TAG".service >/dev/null 2>&1 || true
  systemctl enable "$TAG".service >/dev/null 2>&1 || true

  if (( POLICY_ENABLED == 1 )); then
    if ! CREATE_EPOCH="$NOW" MAX_IPS="$MAX_IPS_SAFE" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_add.sh "$PORT" "$PQ_GIB_SAFE" "$D" "$EXP"; then
      VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
      echo "❌ 绑定端口策略失败" >&2
      exit 1
    fi
  fi

  systemctl start "$TAG".service >/dev/null 2>&1 || true
  if wait_unit_and_port_stable "$TAG".service "$PORT" 40 0.25 4; then
    START_OK=1
    break
  fi
  VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
 done

(( START_OK == 1 )) || { echo "❌ 启动临时 VLESS 服务失败" >&2; exit 1; }
E_STR="$(TZ=Asia/Shanghai date -d "@$LAST_EXP" '+%F %T')"
PBK_Q="$(urlencode "$PBK")"
VLESS_URL="vless://${UUID}@${SERVER_ADDR}:${LAST_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"

echo "✅ 新 VLESS 临时节点: $TAG
地址: ${SERVER_ADDR}:${LAST_PORT}
UUID: ${UUID}
有效期: ${D} 秒
到期(北京时间): ${E_STR}
VLESS 订阅链接: ${VLESS_URL}"
if (( POLICY_ENABLED == 1 )); then
  echo "已绑定端口策略: quota=${PQ_GIB_SAFE}GiB max_ips=${MAX_IPS_SAFE} ip_timeout=${IP_TIMEOUT_SECONDS}s"
fi
MK
chmod +x /usr/local/sbin/vless_mktemp.sh

cat >/usr/local/sbin/vless_extend.sh <<'EXT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
meta_set() { local file="$1" key="$2" value="$3" tmp="${file}.tmp.$$"; awk -F= -v k="$key" -v v="$value" 'BEGIN{d=0}$1==k{print k"="v;d=1;next}{print}END{if(!d)print k"="v}' "$file" > "$tmp" && mv "$tmp" "$file"; }
port_is_listening() { local port="$1"; ss -ltnH 2>/dev/null | awk -v p="$port" '{ n=split($4,a,":"); if (a[n] == p) {found=1; exit} } END { exit(found ? 0 : 1) }'; }
wait_unit_and_port_stable() {
  local unit="$1" port="$2" tries="${3:-40}" delay="${4:-0.25}" stable_needed="${5:-4}"
  local i state sub stable=0
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]] && port_is_listening "$port"; then
      stable=$((stable+1))
      (( stable >= stable_needed )) && return 0
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
managed_restart() {
  local unit="$1" flag="$2"
  : >"$flag"
  if ! systemctl restart "$unit" >/dev/null 2>&1; then
    rm -f "$flag"
    return 1
  fi
  rm -f "$flag"
}
managed_disable_now() {
  local unit="$1" flag="$2"
  : >"$flag"
  if ! systemctl disable --now "$unit" >/dev/null 2>&1; then
    rm -f "$flag"
    return 1
  fi
  rm -f "$flag"
}
TAG="${1:?need TAG}"
ADD_SECONDS="${2:?need seconds}"
[[ "$ADD_SECONDS" =~ ^[0-9]+$ ]] || { echo "❌ seconds 必须是非负整数" >&2; exit 1; }
LOCK="/run/vless-temp.lock"
META="/usr/local/etc/xray/${TAG}.meta"
exec 9>"$LOCK"
flock -w 10 9
[[ -f "$META" ]] || { echo "❌ 未找到 $META" >&2; exit 1; }
PORT="$(meta_get "$META" PORT || true)"
PAUSED="$(meta_get "$META" PAUSED || true)"; [[ "$PAUSED" =~ ^[0-9]+$ ]] || PAUSED=0
POLICY="$(meta_get "$META" PQ_POLICY || true)"
PQ_GIB="$(meta_get "$META" PQ_GIB || true)"; [[ "$PQ_GIB" =~ ^[0-9]+$ ]] || PQ_GIB=0
MAX_IPS="$(meta_get "$META" PQ_MAX_IPS || true)"; [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
IP_TIMEOUT_SECONDS="$(meta_get "$META" PQ_IP_TIMEOUT_SECONDS || true)"; [[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=90
CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"; [[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || CREATE_EPOCH=0
OLD_D="$(meta_get "$META" DURATION_SECONDS || true)"; [[ "$OLD_D" =~ ^[0-9]+$ ]] || OLD_D=0
OLD_EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"; [[ "$OLD_EXP" =~ ^[0-9]+$ ]] || { echo "❌ EXPIRE_EPOCH 非法" >&2; exit 1; }
NOW=$(date +%s)
(( OLD_EXP > NOW )) || { echo "❌ 节点已过期，无法续期" >&2; exit 1; }
NEW_D=$((OLD_D + ADD_SECONDS))
NEW_EXP=$((OLD_EXP + ADD_SECONDS))
PREV_ACTIVE=0
systemctl is-active --quiet "${TAG}.service" && PREV_ACTIVE=1 || true
MANAGED_DIR="/run/vless-managed-stop"
MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
mkdir -p "$MANAGED_DIR"
rollback_meta() {
  meta_set "$META" DURATION_SECONDS "$OLD_D"
  meta_set "$META" EXPIRE_EPOCH "$OLD_EXP"
}
refresh_quota_lifecycle() {
  local d="$1" exp="$2" limit_bytes=0
  if [[ "$POLICY" == "1" && "$PORT" =~ ^[0-9]+$ ]]; then
    limit_bytes=$(( PQ_GIB * 1024 * 1024 * 1024 ))
    if [[ ! -f "/etc/portquota/pq-${PORT}.meta" ]] && [[ -x /usr/local/sbin/pq_add.sh ]]; then
      CREATE_EPOCH="$CREATE_EPOCH" MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_add.sh "$PORT" "$PQ_GIB" "$d" "$exp" >/dev/null
    elif [[ -x /usr/local/sbin/pq_ensure_port.sh ]]; then
      PQ_LOCK_HELD=0 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_ensure_port.sh "$PORT" "$limit_bytes" >/dev/null
    fi
  fi
  if [[ "$PORT" =~ ^[0-9]+$ ]] && [[ -x /usr/local/sbin/pq_touch_lifecycle.sh ]] && [[ -f "/etc/portquota/pq-${PORT}.meta" ]]; then
    /usr/local/sbin/pq_touch_lifecycle.sh "$PORT" "$d" "$exp" >/dev/null
  fi
}
meta_set "$META" DURATION_SECONDS "$NEW_D"
meta_set "$META" EXPIRE_EPOCH "$NEW_EXP"
if ! refresh_quota_lifecycle "$NEW_D" "$NEW_EXP"; then
  rollback_meta
  refresh_quota_lifecycle "$OLD_D" "$OLD_EXP" || true
  echo "❌ 已回滚：配额生命周期更新失败" >&2
  exit 1
fi
if [[ "${PAUSED:-0}" != "1" ]]; then
  systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
  systemctl enable "${TAG}.service" >/dev/null 2>&1 || true
  if (( PREV_ACTIVE == 1 )); then
    if ! managed_restart "${TAG}.service" "$MANAGED_FLAG"; then
      rollback_meta
      refresh_quota_lifecycle "$OLD_D" "$OLD_EXP" || true
      managed_restart "${TAG}.service" "$MANAGED_FLAG" || true
      echo "❌ 已回滚：续期后重启服务失败" >&2
      exit 1
    fi
  else
    if ! systemctl start "${TAG}.service" >/dev/null 2>&1; then
      rollback_meta
      refresh_quota_lifecycle "$OLD_D" "$OLD_EXP" || true
      managed_disable_now "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
      echo "❌ 已回滚：续期后启动服务失败" >&2
      exit 1
    fi
  fi
  if [[ "$PORT" =~ ^[0-9]+$ ]] && ! wait_unit_and_port_stable "${TAG}.service" "$PORT" 40 0.25 4; then
    rollback_meta
    refresh_quota_lifecycle "$OLD_D" "$OLD_EXP" || true
    if (( PREV_ACTIVE == 1 )); then
      managed_restart "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
      wait_unit_and_port_stable "${TAG}.service" "$PORT" 20 0.25 2 >/dev/null 2>&1 || true
    else
      managed_disable_now "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
    fi
    echo "❌ 已回滚：续期后的服务未稳定运行" >&2
    exit 1
  fi
fi
echo "✅ 已续期 ${TAG}，新的到期时间: $(TZ=Asia/Shanghai date -d "@$NEW_EXP" '+%F %T')"
EXT
chmod +x /usr/local/sbin/vless_extend.sh

cat >/usr/local/sbin/vless_pause.sh <<'PAUSE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
meta_set() { local file="$1" key="$2" value="$3" tmp="${file}.tmp.$$"; awk -F= -v k="$key" -v v="$value" 'BEGIN{d=0}$1==k{print k"="v;d=1;next}{print}END{if(!d)print k"="v}' "$file" > "$tmp" && mv "$tmp" "$file"; }
port_is_listening() { local port="$1"; ss -ltnH 2>/dev/null | awk -v p="$port" '{ n=split($4,a,":"); if (a[n] == p) {found=1; exit} } END { exit(found ? 0 : 1) }'; }
TAG="${1:?need TAG}"
META="/usr/local/etc/xray/${TAG}.meta"
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9
[[ -f "$META" ]] || { echo "❌ 未找到 $META" >&2; exit 1; }
EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"
PORT="$(meta_get "$META" PORT || true)"
NOW=$(date +%s)
if [[ "$EXP" =~ ^[0-9]+$ ]] && (( EXP <= NOW )); then
  VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  echo "❌ 节点已过期，已清理" >&2
  exit 1
fi
MANAGED_DIR="/run/vless-managed-stop"
MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
mkdir -p "$MANAGED_DIR"
trap 'rm -f "$MANAGED_FLAG"' EXIT
: >"$MANAGED_FLAG"
if ! systemctl disable --now "${TAG}.service" >/dev/null 2>&1; then
  rm -f "$MANAGED_FLAG"
  echo "❌ 暂停失败：disable --now 执行失败" >&2
  exit 1
fi
if systemctl is-active --quiet "${TAG}.service"; then
  echo "❌ 暂停失败：服务仍处于 active" >&2
  exit 1
fi
if [[ "$PORT" =~ ^[0-9]+$ ]] && port_is_listening "$PORT"; then
  echo "❌ 暂停失败：端口 ${PORT} 仍在监听" >&2
  exit 1
fi
meta_set "$META" PAUSED 1
meta_set "$META" PAUSED_AT "$NOW"
echo "✅ 已暂停 ${TAG}（注意：到期时间仍继续计算）"
PAUSE
chmod +x /usr/local/sbin/vless_pause.sh

cat >/usr/local/sbin/vless_resume.sh <<'RESUME'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
meta_set() { local file="$1" key="$2" value="$3" tmp="${file}.tmp.$$"; awk -F= -v k="$key" -v v="$value" 'BEGIN{d=0}$1==k{print k"="v;d=1;next}{print}END{if(!d)print k"="v}' "$file" > "$tmp" && mv "$tmp" "$file"; }
port_is_listening() { local port="$1"; ss -ltnH 2>/dev/null | awk -v p="$port" '{ n=split($4,a,":"); if (a[n] == p) {found=1; exit} } END { exit(found ? 0 : 1) }'; }
xray_check_config() { /usr/local/bin/xray run -test -format=json -config "$1" >/dev/null 2>&1; }
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
wait_unit_and_port_stable() {
  local unit="$1" port="$2" tries="${3:-40}" delay="${4:-0.25}" stable_needed="${5:-4}"
  local i state sub stable=0
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]] && port_is_listening "$port"; then
      stable=$((stable+1))
      (( stable >= stable_needed )) && return 0
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
write_unit() {
  cat >"$UNIT" <<U
[Unit]
Description=Temp VLESS $TAG
Wants=nftables.service pq-reconcile.service
After=network.target nftables.service pq-reconcile.service

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
}
port_referenced_elsewhere() {
  local port="$1" self_meta="$2" f v
  shopt -s nullglob
  for f in /usr/local/etc/xray/vless-temp-*.meta; do
    [[ "$f" == "$self_meta" ]] && continue
    v="$(meta_get "$f" PORT || true)"
    if [[ "$v" == "$port" ]]; then
      return 0
    fi
  done
  return 1
}
cleanup_old_policy_port() {
  local old_port="$1" new_port="$2" self_meta="$3" policy="$4"
  [[ "$policy" == "1" ]] || return 0
  [[ "$old_port" =~ ^[0-9]+$ && "$new_port" =~ ^[0-9]+$ ]] || return 0
  [[ "$old_port" != "$new_port" ]] || return 0
  if port_referenced_elsewhere "$old_port" "$self_meta"; then
    echo "[vless_resume] old port still referenced by another temp meta, skip pq cleanup: ${old_port}" >&2
    return 0
  fi
  if [[ -x /usr/local/sbin/pq_del.sh ]] && { [[ -f "/etc/portquota/pq-${old_port}.meta" ]] || nft list table inet portquota >/dev/null 2>&1; }; then
    /usr/local/sbin/pq_del.sh "$old_port" >/dev/null 2>&1 || echo "[vless_resume] failed to cleanup old pq state for port ${old_port}" >&2
  fi
}
TAG="${1:?need TAG}"
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9
META="/usr/local/etc/xray/${TAG}.meta"
CFG="/usr/local/etc/xray/${TAG}.json"
UNIT="/etc/systemd/system/${TAG}.service"
[[ -f "$META" ]] || { echo "❌ 未找到 $META" >&2; exit 1; }
[[ -f "$CFG" ]] || { echo "❌ 未找到 $CFG" >&2; exit 1; }
if ! xray_check_config "$CFG"; then
  echo "❌ 恢复失败：节点配置未通过 xray 校验" >&2
  exit 1
fi
OLD_PORT="$(meta_get "$META" PORT || true)"
PORT="$OLD_PORT"
CFG_PORT="$(read_port_from_cfg "$CFG" || true)"
if [[ "$CFG_PORT" =~ ^[0-9]+$ ]] && [[ "$CFG_PORT" != "$PORT" ]]; then
  PORT="$CFG_PORT"
  meta_set "$META" PORT "$PORT"
fi
EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"
NOW=$(date +%s)
POLICY="$(meta_get "$META" PQ_POLICY || true)"
PQ_GIB="$(meta_get "$META" PQ_GIB || true)"
MAX_IPS="$(meta_get "$META" PQ_MAX_IPS || true)"
IP_TIMEOUT_SECONDS="$(meta_get "$META" PQ_IP_TIMEOUT_SECONDS || true)"
DURATION_SECONDS="$(meta_get "$META" DURATION_SECONDS || true)"
CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
[[ "$EXP" =~ ^[0-9]+$ ]] || { echo "❌ EXPIRE_EPOCH 非法" >&2; exit 1; }
(( EXP > NOW )) || { echo "❌ 节点已过期，无法恢复" >&2; exit 1; }
cleanup_old_policy_port "$OLD_PORT" "$PORT" "$META" "$POLICY"
if [[ ! -f "$UNIT" ]]; then
  write_unit
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
if [[ "$POLICY" == "1" && "$PORT" =~ ^[0-9]+$ ]]; then
  LIMIT_BYTES=$(( ${PQ_GIB:-0} * 1024 * 1024 * 1024 ))
  if [[ ! -f "/etc/portquota/pq-${PORT}.meta" ]] && [[ -x /usr/local/sbin/pq_add.sh ]]; then
    if ! CREATE_EPOCH="$CREATE_EPOCH" MAX_IPS="${MAX_IPS:-0}" IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}" /usr/local/sbin/pq_add.sh "$PORT" "${PQ_GIB:-0}" "${DURATION_SECONDS:-0}" "$EXP" >/dev/null 2>&1; then
      echo "❌ 恢复失败：端口策略重建失败" >&2
      exit 1
    fi
  elif [[ -x /usr/local/sbin/pq_ensure_port.sh ]]; then
    if ! PQ_LOCK_HELD=0 MAX_IPS="${MAX_IPS:-0}" IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}" /usr/local/sbin/pq_ensure_port.sh "$PORT" "$LIMIT_BYTES" >/dev/null 2>&1; then
      echo "❌ 恢复失败：端口策略校验失败" >&2
      exit 1
    fi
  fi
fi
systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
systemctl enable "${TAG}.service" >/dev/null 2>&1 || true
if ! systemctl start "${TAG}.service" >/dev/null 2>&1; then
  MANAGED_DIR="/run/vless-managed-stop"
  MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
  mkdir -p "$MANAGED_DIR"
  : >"$MANAGED_FLAG"
  systemctl disable --now "${TAG}.service" >/dev/null 2>&1 || true
  rm -f "$MANAGED_FLAG"
  systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
  echo "❌ 恢复失败：systemctl start 执行失败" >&2
  exit 1
fi
if [[ "$PORT" =~ ^[0-9]+$ ]] && ! wait_unit_and_port_stable "${TAG}.service" "$PORT" 40 0.25 4; then
  MANAGED_DIR="/run/vless-managed-stop"
  MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
  mkdir -p "$MANAGED_DIR"
  : >"$MANAGED_FLAG"
  systemctl disable --now "${TAG}.service" >/dev/null 2>&1 || true
  rm -f "$MANAGED_FLAG"
  systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
  echo "❌ 恢复失败：服务未稳定运行" >&2
  exit 1
fi
meta_set "$META" PAUSED 0
meta_set "$META" PAUSED_AT 0
echo "✅ 已恢复 ${TAG}"
RESUME
chmod +x /usr/local/sbin/vless_resume.sh

cat >/usr/local/sbin/vless_reconcile.sh <<'RECON'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
meta_set() { local file="$1" key="$2" value="$3" tmp="${file}.tmp.$$"; awk -F= -v k="$key" -v v="$value" 'BEGIN{d=0}$1==k{print k"="v;d=1;next}{print}END{if(!d)print k"="v}' "$file" > "$tmp" && mv "$tmp" "$file"; }
tcp_port_listening() { local port="$1"; ss -ltnH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p' | grep -qx "$port"; }
xray_check_config() { /usr/local/bin/xray run -test -format=json -config "$1" >/dev/null 2>&1; }
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
wait_unit_and_port_stable() {
  local unit="$1" port="$2" tries="${3:-40}" delay="${4:-0.25}" stable_needed="${5:-4}"
  local i state sub stable=0
  for ((i=1; i<=tries; i++)); do
    state="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" && ( "$sub" == "running" || "$sub" == "listening" || -z "$sub" ) ]] && tcp_port_listening "$port"; then
      stable=$((stable+1))
      (( stable >= stable_needed )) && return 0
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
write_unit() {
  local tag="$1" cfg="$2" unit="$3"
  cat >"$unit" <<U
[Unit]
Description=Temp VLESS ${tag}
Wants=nftables.service pq-reconcile.service
After=network.target nftables.service pq-reconcile.service

[Service]
Type=exec
ExecStart=/usr/local/sbin/vless_run_temp.sh ${tag} ${cfg}
ExecStopPost=/usr/local/sbin/vless_poststop_cleanup.sh ${tag}
Restart=no
SuccessExitStatus=124 143
TimeoutStopSec=20s

[Install]
WantedBy=multi-user.target
U
}
managed_restart() {
  local unit="$1" flag="$2"
  : >"$flag"
  if ! systemctl restart "$unit" >/dev/null 2>&1; then
    rm -f "$flag"
    return 1
  fi
  rm -f "$flag"
}
managed_disable_now() {
  local unit="$1" flag="$2"
  : >"$flag"
  if ! systemctl disable --now "$unit" >/dev/null 2>&1; then
    rm -f "$flag"
    return 1
  fi
  rm -f "$flag"
}
port_referenced_elsewhere() {
  local port="$1" self_meta="$2" f v
  shopt -s nullglob
  for f in /usr/local/etc/xray/vless-temp-*.meta; do
    [[ "$f" == "$self_meta" ]] && continue
    v="$(meta_get "$f" PORT || true)"
    if [[ "$v" == "$port" ]]; then
      return 0
    fi
  done
  return 1
}
cleanup_old_policy_port() {
  local old_port="$1" new_port="$2" self_meta="$3" policy="$4"
  [[ "$policy" == "1" ]] || return 0
  [[ "$old_port" =~ ^[0-9]+$ && "$new_port" =~ ^[0-9]+$ ]] || return 0
  [[ "$old_port" != "$new_port" ]] || return 0
  if port_referenced_elsewhere "$old_port" "$self_meta"; then
    echo "[vless_reconcile] old port still referenced by another temp meta, skip pq cleanup: ${old_port}" >&2
    return 0
  fi
  if [[ -x /usr/local/sbin/pq_del.sh ]] && { [[ -f "/etc/portquota/pq-${old_port}.meta" ]] || nft list table inet portquota >/dev/null 2>&1; }; then
    /usr/local/sbin/pq_del.sh "$old_port" >/dev/null 2>&1 || echo "[vless_reconcile] failed to cleanup old pq state for port ${old_port}" >&2
  fi
}
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0
XRAY_DIR="/usr/local/etc/xray"
NOW=$(date +%s)
MANAGED_DIR="/run/vless-managed-stop"
mkdir -p "$MANAGED_DIR"
for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  PORT="$(meta_get "$META" PORT || true)"
  OLD_PORT="$PORT"
  EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"
  PAUSED="$(meta_get "$META" PAUSED || true)"
  POLICY="$(meta_get "$META" PQ_POLICY || true)"
  PQ_GIB="$(meta_get "$META" PQ_GIB || true)"
  MAX_IPS="$(meta_get "$META" PQ_MAX_IPS || true)"
  IP_TIMEOUT_SECONDS="$(meta_get "$META" PQ_IP_TIMEOUT_SECONDS || true)"
  DURATION_SECONDS="$(meta_get "$META" DURATION_SECONDS || true)"
  CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
  CFG="${XRAY_DIR}/${TAG}.json"
  UNIT="/etc/systemd/system/${TAG}.service"
  MANAGED_FLAG="${MANAGED_DIR}/${TAG}"
  [[ -n "$TAG" && "$PORT" =~ ^[0-9]+$ && "$EXP" =~ ^[0-9]+$ ]] || continue
  if (( EXP <= NOW )); then
    VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
    continue
  fi
  if [[ ! -f "$CFG" ]]; then
    VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
    continue
  fi
  if ! xray_check_config "$CFG"; then
    echo "[vless_reconcile] invalid config, disable unit: ${TAG}" >&2
    if [[ -f "$UNIT" ]]; then
      managed_disable_now "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
      systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
    fi
    continue
  fi
  CFG_PORT="$(read_port_from_cfg "$CFG" || true)"
  if [[ "$CFG_PORT" =~ ^[0-9]+$ ]] && [[ "$CFG_PORT" != "$PORT" ]]; then
    PORT="$CFG_PORT"
    meta_set "$META" PORT "$PORT"
  fi
  cleanup_old_policy_port "$OLD_PORT" "$PORT" "$META" "$POLICY"
  if [[ ! -f "$UNIT" ]]; then
    write_unit "$TAG" "$CFG" "$UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
  fi
  if [[ "$POLICY" == "1" && "$PORT" =~ ^[0-9]+$ ]]; then
    LIMIT_BYTES=$(( ${PQ_GIB:-0} * 1024 * 1024 * 1024 ))
    if [[ ! -f "/etc/portquota/pq-${PORT}.meta" && -x /usr/local/sbin/pq_add.sh ]]; then
      if ! CREATE_EPOCH="$CREATE_EPOCH" MAX_IPS="${MAX_IPS:-0}" IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}" /usr/local/sbin/pq_add.sh "$PORT" "${PQ_GIB:-0}" "${DURATION_SECONDS:-0}" "$EXP" >/dev/null 2>&1; then
        echo "[vless_reconcile] pq_add failed for ${TAG}:${PORT}, disable service" >&2
        managed_disable_now "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
        systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
        continue
      fi
    elif [[ -x /usr/local/sbin/pq_ensure_port.sh ]]; then
      if ! PQ_LOCK_HELD=0 MAX_IPS="${MAX_IPS:-0}" IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}" /usr/local/sbin/pq_ensure_port.sh "$PORT" "$LIMIT_BYTES" >/dev/null 2>&1; then
        echo "[vless_reconcile] pq_ensure failed for ${TAG}:${PORT}, disable service" >&2
        managed_disable_now "${TAG}.service" "$MANAGED_FLAG" >/dev/null 2>&1 || true
        systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
        continue
      fi
    fi
  fi
  if [[ "${PAUSED:-0}" == "1" ]]; then
    if ! managed_disable_now "${TAG}.service" "$MANAGED_FLAG"; then
      echo "[vless_reconcile] failed to pause ${TAG}.service" >&2
      continue
    fi
    if systemctl is-active --quiet "${TAG}.service" || tcp_port_listening "$PORT"; then
      echo "[vless_reconcile] ${TAG}.service still active/listening while paused" >&2
    fi
    continue
  fi
  systemctl reset-failed "${TAG}.service" >/dev/null 2>&1 || true
  systemctl enable "${TAG}.service" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "${TAG}.service"; then
    if systemctl start "${TAG}.service" >/dev/null 2>&1; then
      wait_unit_and_port_stable "${TAG}.service" "$PORT" 40 0.25 4 >/dev/null 2>&1 || echo "[vless_reconcile] service not stable after start: ${TAG}:${PORT}" >&2
    else
      echo "[vless_reconcile] failed to start ${TAG}.service" >&2
    fi
  elif ! tcp_port_listening "$PORT"; then
    if managed_restart "${TAG}.service" "$MANAGED_FLAG"; then
      wait_unit_and_port_stable "${TAG}.service" "$PORT" 40 0.25 4 >/dev/null 2>&1 || echo "[vless_reconcile] service not stable after restart: ${TAG}:${PORT}" >&2
    else
      echo "[vless_reconcile] failed to restart ${TAG}.service" >&2
    fi
  fi
done
RECON
chmod +x /usr/local/sbin/vless_reconcile.sh

########################################
# 3) 审计 / GC / 清空
########################################
cat >/usr/local/sbin/vless_gc.sh <<'GC'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0
XRAY_DIR="/usr/local/etc/xray"
NOW=$(date +%s)
for META in "$XRAY_DIR"/vless-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  [[ -n "$TAG" && "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || continue
  if (( EXPIRE_EPOCH <= NOW )); then
    VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
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

cat >/etc/systemd/system/vless-reconcile.service <<'RSVC'
[Unit]
Description=Reconcile VLESS temp nodes after boot and periodically
Wants=pq-reconcile.service nftables.service
After=network.target pq-reconcile.service nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_reconcile.sh
RSVC

cat >/etc/systemd/system/vless-reconcile.timer <<'RTMR'
[Unit]
Description=Run VLESS reconcile after boot and periodically

[Timer]
OnBootSec=45s
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
RTMR

systemctl daemon-reload
systemctl enable --now vless-gc.timer >/dev/null 2>&1 || true
systemctl enable --now vless-reconcile.timer >/dev/null 2>&1 || true

cat >/usr/local/sbin/vless_audit.sh <<'AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
tcp_port_listening() { local port="${1:-}"; [[ -n "$port" ]] || return 1; ss -ltnH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p' | grep -qx "$port"; }
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
fmt_gib() { local b="${1:-0}"; [[ "$b" =~ ^[0-9]+$ ]] || b=0; awk -v v="$b" 'BEGIN{printf "%.2f", v/1024/1024/1024}'; }
fmt_left() { local exp="${1:-}" now=$(date +%s); if [[ "$exp" =~ ^[0-9]+$ ]]; then local left=$((exp-now)); if (( left <= 0 )); then echo expired; else printf "%02dd%02dh%02dm" $((left/86400)) $(((left%86400)/3600)) $(((left%3600)/60)); fi; else echo -; fi; }
fmt_expire_cn() { local exp="${1:-}"; if [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > 0 )); then TZ='Asia/Shanghai' date -d "@$exp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo -; else echo -; fi; }
quota_cells() {
  local port="${1:-}" meta="/etc/portquota/pq-${port}.meta" qstate="none" limit="-" used="-" left="-" pct="-"
  if [[ -f "$meta" ]]; then
    local limit_bytes saved_used mode out_b in_b total_b live_used total_used left_b pct_val
    limit_bytes="$(meta_total_limit_bytes "$meta")"; saved_used="$(meta_get "$meta" SAVED_USED_BYTES || true)"; mode="$(meta_get "$meta" MODE || true)"
    [[ "$saved_used" =~ ^[0-9]+$ ]] || saved_used=0; mode="${mode:-quota}"
    if [[ "$mode" != "quota" || "$limit_bytes" == "0" ]]; then
      qstate="track"
      out_b="$(get_counter_bytes "pq_out_${port}" || true)"; [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
      in_b="$(get_counter_bytes "pq_in_${port}" || true)"; [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
      total_b=$((out_b+in_b))
      total_used=$((saved_used + total_b))
      used="$(fmt_gib "$total_used")"
    else
      out_b="$(get_counter_bytes "pq_out_${port}" || true)"; [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
      in_b="$(get_counter_bytes "pq_in_${port}" || true)"; [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
      total_b=$((out_b+in_b))
      live_used="$(get_quota_used_bytes "pq_quota_${port}" || true)"; [[ "$live_used" =~ ^[0-9]+$ ]] || live_used="$total_b"
      total_used=$((saved_used + live_used)); (( total_used > limit_bytes )) && total_used="$limit_bytes"
      left_b=$((limit_bytes-total_used)); (( left_b < 0 )) && left_b=0
      pct_val="$(awk -v u="$total_used" -v l="$limit_bytes" 'BEGIN{printf "%.1f%%", (l>0 ? (u*100.0/l) : 0)}')"
      limit="$(fmt_gib "$limit_bytes")"; used="$(fmt_gib "$total_used")"; left="$(fmt_gib "$left_b")"; pct="$pct_val"
      if (( left_b == 0 )); then qstate="full"; else qstate="ok"; fi
    fi
  fi
  printf '%s|%s|%s|%s|%s\n' "$qstate" "$limit" "$used" "$left" "$pct"
}
NAME_W=32; STATE_W=8; PORT_W=5; RDY_W=3; Q_W=5; LIMIT_W=7; USED_W=7; LEFT_W=7; USE_W=5; TTL_W=10; EXP_W=19
print_sep() { printf '%*s\n' 118 '' | tr ' ' '-'; }
get_main_port() {
  local main_cfg="/usr/local/etc/xray/config.json"
  if [[ -f "$main_cfg" ]]; then
    python3 - "$main_cfg" <<'PY'
import json,sys
try:
    cfg=json.load(open(sys.argv[1])); ibs=cfg.get("inbounds",[])
    if ibs and isinstance(ibs[0], dict):
        p=ibs[0].get("port","")
        if isinstance(p,int): print(p); sys.exit(0)
        if isinstance(p,str) and p.isdigit(): print(p); sys.exit(0)
except Exception:
    pass
print("443")
PY
  else
    echo 443
  fi
}
render_row() {
  local name="$1" state="$2" port="$3" ready="$4" qstate="$5" limit="$6" used="$7" leftq="$8" pct="$9" ttl_left="${10}" expire_cn="${11}"
  printf "%-${NAME_W}s %-${STATE_W}s %-${PORT_W}s %-${RDY_W}s %-${Q_W}s %-${LIMIT_W}s %-${USED_W}s %-${LEFT_W}s %-${USE_W}s %-${TTL_W}s %-${EXP_W}s\n" "$name" "$state" "$port" "$ready" "$qstate" "$limit" "$used" "$leftq" "$pct" "$ttl_left" "$expire_cn"
}
echo
printf '%s\n' '=== VLESS AUDIT ==='
print_sep
render_row "NAME" "STATE" "PORT" "RDY" "Q" "LIMIT" "USED" "LEFT" "USE%" "TTL" "EXPIRE(CN)"
print_sep
MAIN_PORT="$(get_main_port)"; MAIN_STATE="$(systemctl is-active xray.service 2>/dev/null || echo unknown)"; MAIN_READY=no
[[ "$MAIN_STATE" == active ]] && tcp_port_listening "$MAIN_PORT" && MAIN_READY=yes
render_row "vless-main" "$MAIN_STATE" "$MAIN_PORT" "$MAIN_READY" "none" "-" "-" "-" "-" "-" "-"
for META in /usr/local/etc/xray/vless-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"; PORT="$(meta_get "$META" PORT || true)"; EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"; PAUSED="$(meta_get "$META" PAUSED || true)"
  [[ -n "$TAG" && -n "$PORT" ]] || continue
  STATE="$(systemctl is-active "${TAG}.service" 2>/dev/null || echo unknown)"; READY=no
  if [[ "${PAUSED:-0}" == "1" ]]; then STATE=paused; else [[ "$STATE" == active ]] && tcp_port_listening "$PORT" && READY=yes; fi
  IFS='|' read -r QSTATE LIMIT USED LEFT_Q PCT <<< "$(quota_cells "$PORT")"
  render_row "$TAG" "$STATE" "$PORT" "$READY" "$QSTATE" "$LIMIT" "$USED" "$LEFT_Q" "$PCT" "$(fmt_left "$EXP")" "$(fmt_expire_cn "$EXP")"
done
print_sep
AUDIT
chmod +x /usr/local/sbin/vless_audit.sh

cat >/usr/local/sbin/vless_clear_all.sh <<'CLR'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file"; }
LOCK="/run/vless-temp.lock"
exec 9>"$LOCK"
flock -w 10 9
META_FILES=(/usr/local/etc/xray/vless-temp-*.meta)
if (( ${#META_FILES[@]} == 0 )); then echo "当前没有任何临时 VLESS 节点。"; exit 0; fi
for META in "${META_FILES[@]}"; do
  TAG="$(meta_get "$META" TAG || true)"
  [[ -n "$TAG" ]] || continue
  VLESS_LOCK_HELD=1 FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
done
echo "✅ 所有临时 VLESS 节点清理流程已执行完毕。"
CLR
chmod +x /usr/local/sbin/vless_clear_all.sh

cat <<'HELP'
✅ VLESS 临时节点增强版脚本部署完成。
============ 使用方法（VLESS 临时节点 / 审计 / 策略） ============

1) 新建临时节点（示例 600 秒）：
   D=600 vless_mktemp.sh

2) 创建节点时直接绑定配额（推荐）：
   PQ_GIB=50 D=600 vless_mktemp.sh
   PQ_GIB=50 D=$((60*86400)) vless_mktemp.sh
   PQ_GIB=50 D=$((20*86400)) vless_mktemp.sh

3) 创建节点时附带 IP 数限制：
   MAX_IPS=3 D=600 vless_mktemp.sh
   MAX_IPS=3 PQ_GIB=50 D=600 vless_mktemp.sh

4) 可选参数：
   PORT_START=40000 PORT_END=60000 D=600 vless_mktemp.sh
   MAX_START_RETRIES=8 D=600 vless_mktemp.sh
   PBK=<publicKey> D=600 vless_mktemp.sh

5) 管理命令：
   vless_extend.sh <TAG> <SECONDS>
   vless_pause.sh <TAG>
   vless_resume.sh <TAG>
   vless_audit.sh
   vless_clear_all.sh
   FORCE=1 vless_cleanup_one.sh vless-temp-YYYYMMDDHHMMSS-ABCD

6) 端口策略 / 配额：
   pq_add.sh 443 500
   pq_add.sh 40000 50 $((60*86400))
   pq_set.sh 40000 80
   MAX_IPS=3 IP_TIMEOUT_SECONDS=90 pq_set.sh 40000 80
   pq_audit.sh
   pq_del.sh 40000
===============================================================
HELP
EOF_VLESS_ENH
  chmod +x /root/vless_temp_audit_ipv4_all.sh
  cat >/tmp/pq-enhanced-vless.sh <<'EOF_PQ_ENH'
#!/usr/bin/env bash
set -Eeuo pipefail
PROTO="tcp"
mkdir -p /etc/portquota /etc/nftables.d
systemctl enable --now nftables >/dev/null 2>&1 || true
if ! nft list table inet portquota >/dev/null 2>&1; then nft add table inet portquota; fi
if ! nft list chain inet portquota down_out >/dev/null 2>&1; then nft add chain inet portquota down_out '{ type filter hook output priority filter; policy accept; }'; fi
if ! nft list chain inet portquota up_in >/dev/null 2>&1; then nft add chain inet portquota up_in '{ type filter hook input priority filter; policy accept; }'; fi

cat >/usr/local/sbin/pq_save.sh <<'SAVE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != 1 ]]; then exec 9>"$LOCK"; flock -w 10 9; fi
OUT="/etc/nftables.d/portquota.nft"
mkdir -p /etc/nftables.d
nft list table inet portquota > "${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"
if [[ -f /etc/nftables.conf ]] && ! grep -qE 'include "/etc/nftables\.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf; fi
SAVE
chmod +x /usr/local/sbin/pq_save.sh

cat >/usr/local/sbin/pq_apply_port.sh <<'APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
PROTO="tcp"
obj_exists() { local kind="$1" name="$2"; nft list "$kind" inet portquota "$name" >/dev/null 2>&1; }
PORT="${1:-}"
BYTES="${2:-}"
MAX_IPS="${3:-${MAX_IPS:-0}}"
IP_TIMEOUT_SECONDS="${4:-${IP_TIMEOUT_SECONDS:-30}}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "❌ 端口非法" >&2; exit 1; }
[[ "$BYTES" =~ ^[0-9]+$ ]] || { echo "❌ bytes 必须是非负整数" >&2; exit 1; }
[[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=30
LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != 1 ]]; then exec 9>"$LOCK"; flock -w 10 9; fi
if ! nft list table inet portquota >/dev/null 2>&1; then nft add table inet portquota; fi
if ! nft list chain inet portquota down_out >/dev/null 2>&1; then nft add chain inet portquota down_out '{ type filter hook output priority filter; policy accept; }'; fi
if ! nft list chain inet portquota up_in >/dev/null 2>&1; then nft add chain inet portquota up_in '{ type filter hook input priority filter; policy accept; }'; fi
TMP_RULES="$(mktemp)"
cleanup() { rm -f "$TMP_RULES"; }
trap cleanup EXIT
{
  for chain in down_out up_in; do
    nft -a list chain inet portquota "$chain" 2>/dev/null | awk -v p="$PORT" '
      $0 ~ "comment \"pq-count-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-drop-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-harddrop-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-ip-refresh-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-ip-enforce-(out|in)-"p"\"" {print $NF}
    ' | while read -r h; do
      [[ "$h" =~ ^[0-9]+$ ]] && printf 'delete rule inet portquota %s handle %s\n' "$chain" "$h"
    done
  done
  obj_exists counter "pq_out_$PORT" && echo "delete counter inet portquota pq_out_$PORT"
  obj_exists counter "pq_in_$PORT" && echo "delete counter inet portquota pq_in_$PORT"
  obj_exists quota "pq_quota_$PORT" && echo "delete quota inet portquota pq_quota_$PORT"
  obj_exists set "pq_ip_$PORT" && echo "delete set inet portquota pq_ip_$PORT"
  echo "add counter inet portquota pq_out_$PORT"
  echo "add counter inet portquota pq_in_$PORT"
  if (( MAX_IPS > 0 )); then
    echo "add set inet portquota pq_ip_$PORT { type ipv4_addr; flags timeout,dynamic; timeout ${IP_TIMEOUT_SECONDS}s; size ${MAX_IPS}; }"
    echo "add rule inet portquota up_in ${PROTO} dport $PORT update @pq_ip_$PORT { ip saddr timeout ${IP_TIMEOUT_SECONDS}s } comment \"pq-ip-refresh-in-$PORT\""
    echo "add rule inet portquota up_in ${PROTO} dport $PORT ip saddr != @pq_ip_$PORT drop comment \"pq-ip-enforce-in-$PORT\""
  fi
  if (( BYTES > 0 )); then
    echo "add quota inet portquota pq_quota_$PORT { over $BYTES bytes }"
    echo "add rule inet portquota down_out ${PROTO} sport $PORT quota name \"pq_quota_$PORT\" drop comment \"pq-drop-out-$PORT\""
    echo "add rule inet portquota up_in ${PROTO} dport $PORT quota name \"pq_quota_$PORT\" drop comment \"pq-drop-in-$PORT\""
  else
    echo "add rule inet portquota down_out ${PROTO} sport $PORT drop comment \"pq-harddrop-out-$PORT\""
    echo "add rule inet portquota up_in ${PROTO} dport $PORT drop comment \"pq-harddrop-in-$PORT\""
  fi
  echo "add rule inet portquota down_out ${PROTO} sport $PORT counter name \"pq_out_$PORT\" comment \"pq-count-out-$PORT\""
  echo "add rule inet portquota up_in ${PROTO} dport $PORT counter name \"pq_in_$PORT\" comment \"pq-count-in-$PORT\""
} >"$TMP_RULES"
nft -f "$TMP_RULES"
PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
APPLY
chmod +x /usr/local/sbin/pq_apply_port.sh

cat >/usr/local/sbin/pq_ensure_port.sh <<'ENSURE'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
PROTO="tcp"
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
meta_set() { local file="$1" key="$2" val="$3"; touch "$file"; if grep -q "^${key}=" "$file" 2>/dev/null; then sed -i -E "s#^${key}=.*#${key}=${val}#" "$file"; else printf '%s=%s\n' "$key" "$val" >>"$file"; fi; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
obj_exists() { local kind="$1" name="$2"; nft list "$kind" inet portquota "$name" >/dev/null 2>&1; }
rule_line() { local chain="$1" comment="$2"; nft -a list chain inet portquota "$chain" 2>/dev/null | grep -F "comment \"$comment\"" | head -n1 || true; }
rule_has() { local chain="$1" comment="$2" expect="$3"; local line; line="$(rule_line "$chain" "$comment")"; [[ -n "$line" && "$line" == *"$expect"* ]]; }
quota_matches() { local name="$1" bytes="$2" line; line="$(nft list quota inet portquota "$name" 2>/dev/null | tr '\n' ' ' || true)"; [[ -n "$line" ]] && [[ "$line" == *"over ${bytes} bytes"* || "$line" == *"over \"${bytes}\" bytes"* ]]; }
set_matches() { local name="$1" size="$2" timeout="$3" line; line="$(nft list set inet portquota "$name" 2>/dev/null | tr '\n' ' ' || true)"; [[ -n "$line" ]] && [[ "$line" == *"size ${size}"* ]] && [[ "$line" == *"timeout ${timeout}s"* ]]; }
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
PORT="${1:-}"
BYTES_ARG="${2:-0}"
META="/etc/portquota/pq-${PORT}.meta"
MAX_IPS="${3:-${MAX_IPS:-}}"
IP_TIMEOUT_SECONDS="${4:-${IP_TIMEOUT_SECONDS:-}}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "❌ 端口非法" >&2; exit 1; }
[[ "$BYTES_ARG" =~ ^[0-9]+$ ]] || BYTES_ARG=0
if [[ -z "$MAX_IPS" && -f "$META" ]]; then MAX_IPS="$(meta_get "$META" MAX_IPS || true)"; fi
if [[ -z "$IP_TIMEOUT_SECONDS" && -f "$META" ]]; then IP_TIMEOUT_SECONDS="$(meta_get "$META" IP_TIMEOUT_SECONDS || true)"; fi
[[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=30
LIMIT_BYTES="$(meta_total_limit_bytes "$META")"
(( LIMIT_BYTES > 0 )) || LIMIT_BYTES="$BYTES_ARG"
REMAIN_BYTES="$(meta_get "$META" REMAIN_BYTES || true)"
SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
[[ "$REMAIN_BYTES" =~ ^[0-9]+$ ]] || REMAIN_BYTES="$LIMIT_BYTES"
[[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
(( REMAIN_BYTES > LIMIT_BYTES )) && REMAIN_BYTES="$LIMIT_BYTES"
[[ -f "$META" ]] && meta_set "$META" LIMIT_BYTES "$LIMIT_BYTES"
OUT_B="$(get_counter_bytes "pq_out_${PORT}" || true)"; [[ "$OUT_B" =~ ^[0-9]+$ ]] || OUT_B=0
IN_B="$(get_counter_bytes "pq_in_${PORT}" || true)"; [[ "$IN_B" =~ ^[0-9]+$ ]] || IN_B=0
TOTAL_B=$((OUT_B + IN_B))
LIVE_USED="$(get_quota_used_bytes "pq_quota_${PORT}" || true)"; [[ "$LIVE_USED" =~ ^[0-9]+$ ]] || LIVE_USED="$TOTAL_B"
TOTAL_USED=$((SAVED_USED_BYTES + LIVE_USED))
if (( LIMIT_BYTES > 0 && TOTAL_USED > LIMIT_BYTES )); then TOTAL_USED="$LIMIT_BYTES"; fi
if (( LIMIT_BYTES > 0 )); then
  REMAIN_BYTES=$((LIMIT_BYTES - TOTAL_USED))
  (( REMAIN_BYTES < 0 )) && REMAIN_BYTES=0
  [[ -f "$META" ]] && { meta_set "$META" SAVED_USED_BYTES "$TOTAL_USED"; meta_set "$META" REMAIN_BYTES "$REMAIN_BYTES"; }
fi
LOCK="/run/portquota.lock"
if [[ "${PQ_LOCK_HELD:-0}" != 1 ]]; then exec 9>"$LOCK"; flock -w 10 9; fi
NEED=0
nft list table inet portquota >/dev/null 2>&1 || NEED=1
nft list chain inet portquota down_out >/dev/null 2>&1 || NEED=1
nft list chain inet portquota up_in >/dev/null 2>&1 || NEED=1
obj_exists counter "pq_out_$PORT" || NEED=1
obj_exists counter "pq_in_$PORT" || NEED=1
rule_has down_out "pq-count-out-$PORT" "counter name \"pq_out_$PORT\"" || NEED=1
rule_has up_in "pq-count-in-$PORT" "counter name \"pq_in_$PORT\"" || NEED=1
if (( REMAIN_BYTES > 0 )); then
  obj_exists quota "pq_quota_$PORT" || NEED=1
  quota_matches "pq_quota_$PORT" "$REMAIN_BYTES" || NEED=1
  rule_has down_out "pq-drop-out-$PORT" "quota name \"pq_quota_$PORT\" drop" || NEED=1
  rule_has up_in "pq-drop-in-$PORT" "quota name \"pq_quota_$PORT\" drop" || NEED=1
  [[ -z "$(rule_line down_out "pq-harddrop-out-$PORT")" ]] || NEED=1
  [[ -z "$(rule_line up_in "pq-harddrop-in-$PORT")" ]] || NEED=1
else
  rule_has down_out "pq-harddrop-out-$PORT" " drop " || NEED=1
  rule_has up_in "pq-harddrop-in-$PORT" " drop " || NEED=1
fi
if (( MAX_IPS > 0 )); then
  obj_exists set "pq_ip_$PORT" || NEED=1
  set_matches "pq_ip_$PORT" "$MAX_IPS" "$IP_TIMEOUT_SECONDS" || NEED=1
  rule_has up_in "pq-ip-refresh-in-$PORT" "update @pq_ip_$PORT" || NEED=1
  rule_has up_in "pq-ip-enforce-in-$PORT" "ip saddr != @pq_ip_$PORT drop" || NEED=1
  [[ -z "$(rule_line down_out "pq-ip-refresh-out-$PORT")" ]] || NEED=1
  [[ -z "$(rule_line down_out "pq-ip-enforce-out-$PORT")" ]] || NEED=1
fi
if (( NEED == 1 )); then
  PQ_LOCK_HELD=1 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_apply_port.sh "$PORT" "$REMAIN_BYTES" "$MAX_IPS" "$IP_TIMEOUT_SECONDS"
fi
ENSURE
chmod +x /usr/local/sbin/pq_ensure_port.sh

cat >/usr/local/sbin/pq_add.sh <<'ADD'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
write_meta() { local dst="$1" tmp="${1}.tmp.$$"; cat >"$tmp"; chmod 600 "$tmp" 2>/dev/null || true; mv -f "$tmp" "$dst"; }
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1); exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
PORT="${1:-}"
GIB="${2:-}"
SERVICE_SECONDS_ARG="${3:-${SERVICE_SECONDS:-0}}"
EXPIRE_EPOCH_ARG="${4:-${EXPIRE_EPOCH:-0}}"
CREATE_EPOCH="${CREATE_EPOCH:-$(date +%s)}"
RESET_INTERVAL_SECONDS="${RESET_INTERVAL_SECONDS:-2592000}"
MAX_IPS="${MAX_IPS:-0}"
IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-30}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "❌ 端口非法" >&2; exit 1; }
[[ "$GIB" =~ ^[0-9]+$ ]] || { echo "❌ GiB 必须是非负整数" >&2; exit 1; }
[[ "$SERVICE_SECONDS_ARG" =~ ^[0-9]+$ ]] || { echo "❌ SERVICE_SECONDS 非法" >&2; exit 1; }
[[ "$EXPIRE_EPOCH_ARG" =~ ^[0-9]+$ ]] || { echo "❌ EXPIRE_EPOCH 非法" >&2; exit 1; }
[[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || { echo "❌ CREATE_EPOCH 非法" >&2; exit 1; }
[[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || { echo "❌ RESET_INTERVAL_SECONDS 非法" >&2; exit 1; }
[[ "$MAX_IPS" =~ ^[0-9]+$ ]] || { echo "❌ MAX_IPS 非法" >&2; exit 1; }
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "❌ IP_TIMEOUT_SECONDS 非法" >&2; exit 1; }
BYTES=$((GIB * 1024 * 1024 * 1024))
MODE=track
(( BYTES > 0 )) && MODE=quota
SERVICE_SECONDS="$SERVICE_SECONDS_ARG"
EXPIRE_EPOCH="$EXPIRE_EPOCH_ARG"
if (( SERVICE_SECONDS > 0 && EXPIRE_EPOCH == 0 )); then EXPIRE_EPOCH=$((CREATE_EPOCH + SERVICE_SECONDS)); fi
AUTO_RESET=0; LAST_RESET_EPOCH=0; NEXT_RESET_EPOCH=0; RESET_COUNT=0
if [[ "$MODE" == quota ]] && (( SERVICE_SECONDS > RESET_INTERVAL_SECONDS && EXPIRE_EPOCH > CREATE_EPOCH )); then AUTO_RESET=1; NEXT_RESET_EPOCH=$((CREATE_EPOCH + RESET_INTERVAL_SECONDS)); fi
LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9
mkdir -p /etc/portquota
META="/etc/portquota/pq-${PORT}.meta"
OLD_SAVED="$(meta_get "$META" SAVED_USED_BYTES || true)"; [[ "$OLD_SAVED" =~ ^[0-9]+$ ]] || OLD_SAVED=0
OUT_B="$(get_counter_bytes "pq_out_${PORT}" || true)"; [[ "$OUT_B" =~ ^[0-9]+$ ]] || OUT_B=0
IN_B="$(get_counter_bytes "pq_in_${PORT}" || true)"; [[ "$IN_B" =~ ^[0-9]+$ ]] || IN_B=0
TOTAL_B=$((OUT_B + IN_B))
LIVE_USED="$(get_quota_used_bytes "pq_quota_${PORT}" || true)"; [[ "$LIVE_USED" =~ ^[0-9]+$ ]] || LIVE_USED="$TOTAL_B"
USED=$((OLD_SAVED + LIVE_USED))
(( USED > BYTES )) && USED="$BYTES"
REMAIN=$((BYTES - USED))
(( REMAIN < 0 )) && REMAIN=0
PQ_LOCK_HELD=1 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_apply_port.sh "$PORT" "$REMAIN" "$MAX_IPS" "$IP_TIMEOUT_SECONDS"
write_meta /etc/portquota/pq-"$PORT".meta <<M
PORT=$PORT
LIMIT_BYTES=$BYTES
LIMIT_GIB=$GIB
REMAIN_BYTES=$REMAIN
SAVED_USED_BYTES=$USED
MODE=$MODE
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS
AUTO_RESET=$AUTO_RESET
LAST_RESET_EPOCH=$LAST_RESET_EPOCH
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH
RESET_COUNT=$RESET_COUNT
MAX_IPS=$MAX_IPS
IP_TIMEOUT_SECONDS=$IP_TIMEOUT_SECONDS
PROTO=tcp
M
PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
systemctl enable --now nftables >/dev/null 2>&1 || true
if [[ "$MODE" == quota ]]; then echo "✅ 已为端口 $PORT 设置 ${GIB}GiB 配额，MAX_IPS=${MAX_IPS}，IP_TIMEOUT=${IP_TIMEOUT_SECONDS}s"; else echo "✅ 已为端口 $PORT 设置跟踪/IP 限制策略，MAX_IPS=${MAX_IPS}，IP_TIMEOUT=${IP_TIMEOUT_SECONDS}s"; fi
ADD
chmod +x /usr/local/sbin/pq_add.sh

cat >/usr/local/sbin/pq_set.sh <<'SET'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
PORT="${1:-}"
GIB="${2:-}"
META="/etc/portquota/pq-${PORT}.meta"
[[ -f "$META" ]] || { echo "❌ 未找到 $META" >&2; exit 1; }
CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
SERVICE_SECONDS="$(meta_get "$META" SERVICE_SECONDS || true)"
EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
RESET_INTERVAL_SECONDS="$(meta_get "$META" RESET_INTERVAL_SECONDS || true)"
MAX_IPS="${MAX_IPS:-$(meta_get "$META" MAX_IPS || true)}"
IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-$(meta_get "$META" IP_TIMEOUT_SECONDS || true)}"
CREATE_EPOCH="$CREATE_EPOCH" SERVICE_SECONDS="$SERVICE_SECONDS" EXPIRE_EPOCH="$EXPIRE_EPOCH" RESET_INTERVAL_SECONDS="$RESET_INTERVAL_SECONDS" MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_add.sh "$PORT" "$GIB" "$SERVICE_SECONDS" "$EXPIRE_EPOCH"
SET
chmod +x /usr/local/sbin/pq_set.sh

cat >/usr/local/sbin/pq_touch_lifecycle.sh <<'TOUCH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
write_meta() { local dst="$1" tmp="${1}.tmp.$$"; cat >"$tmp"; chmod 600 "$tmp" 2>/dev/null || true; mv -f "$tmp" "$dst"; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
PORT="${1:?need port}"
SERVICE_SECONDS="${2:?need service seconds}"
EXPIRE_EPOCH="${3:?need expire epoch}"
META="/etc/portquota/pq-${PORT}.meta"
[[ -f "$META" ]] || exit 0
LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9
LIMIT_BYTES="$(meta_total_limit_bytes "$META")"
LIMIT_GIB="$(meta_get "$META" LIMIT_GIB || true)"
REMAIN_BYTES="$(meta_get "$META" REMAIN_BYTES || true)"
SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
MODE="$(meta_get "$META" MODE || true)"
CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
RESET_INTERVAL_SECONDS="$(meta_get "$META" RESET_INTERVAL_SECONDS || true)"
AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"
LAST_RESET_EPOCH="$(meta_get "$META" LAST_RESET_EPOCH || true)"
NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"
RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"
MAX_IPS="$(meta_get "$META" MAX_IPS || true)"
IP_TIMEOUT_SECONDS="$(meta_get "$META" IP_TIMEOUT_SECONDS || true)"
PROTO="$(meta_get "$META" PROTO || true)"
[[ "$LIMIT_GIB" =~ ^[0-9]+$ ]] || LIMIT_GIB=0
[[ "$REMAIN_BYTES" =~ ^[0-9]+$ ]] || REMAIN_BYTES="$LIMIT_BYTES"
[[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
[[ "$CREATE_EPOCH" =~ ^[0-9]+$ ]] || CREATE_EPOCH=0
[[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || RESET_INTERVAL_SECONDS=2592000
[[ "$AUTO_RESET" =~ ^[0-9]+$ ]] || AUTO_RESET=0
[[ "$LAST_RESET_EPOCH" =~ ^[0-9]+$ ]] || LAST_RESET_EPOCH=0
[[ "$NEXT_RESET_EPOCH" =~ ^[0-9]+$ ]] || NEXT_RESET_EPOCH=0
[[ "$RESET_COUNT" =~ ^[0-9]+$ ]] || RESET_COUNT=0
[[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
[[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=30
[[ "$SERVICE_SECONDS" =~ ^[0-9]+$ ]] || { echo "❌ SERVICE_SECONDS 非法" >&2; exit 1; }
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || { echo "❌ EXPIRE_EPOCH 非法" >&2; exit 1; }
PROTO="${PROTO:-tcp}"
if [[ "$MODE" == "quota" ]] && (( LIMIT_BYTES > 0 )) && (( SERVICE_SECONDS > RESET_INTERVAL_SECONDS )) && (( EXPIRE_EPOCH > CREATE_EPOCH )); then
  AUTO_RESET=1
  if (( NEXT_RESET_EPOCH <= 0 )); then
    if (( LAST_RESET_EPOCH > 0 )); then NEXT_RESET_EPOCH=$((LAST_RESET_EPOCH + RESET_INTERVAL_SECONDS)); else NEXT_RESET_EPOCH=$((CREATE_EPOCH + RESET_INTERVAL_SECONDS)); fi
  fi
  if (( NEXT_RESET_EPOCH >= EXPIRE_EPOCH )); then NEXT_RESET_EPOCH=0; fi
else
  AUTO_RESET=0
  NEXT_RESET_EPOCH=0
fi
write_meta "$META" <<M
PORT=$PORT
LIMIT_BYTES=$LIMIT_BYTES
LIMIT_GIB=$LIMIT_GIB
REMAIN_BYTES=$REMAIN_BYTES
SAVED_USED_BYTES=$SAVED_USED_BYTES
MODE=$MODE
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS
AUTO_RESET=$AUTO_RESET
LAST_RESET_EPOCH=$LAST_RESET_EPOCH
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH
RESET_COUNT=$RESET_COUNT
MAX_IPS=$MAX_IPS
IP_TIMEOUT_SECONDS=$IP_TIMEOUT_SECONDS
PROTO=$PROTO
M
TOUCH
chmod +x /usr/local/sbin/pq_touch_lifecycle.sh

cat >/usr/local/sbin/pq_reset.sh <<'RESET'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
write_meta() { local dst="$1" tmp="${1}.tmp.$$"; cat >"$tmp"; chmod 600 "$tmp" 2>/dev/null || true; mv -f "$tmp" "$dst"; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0
NOW="$(date +%s)"
CHANGED=0
for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_total_limit_bytes "$META")"
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
  MAX_IPS="$(meta_get "$META" MAX_IPS || true)"
  IP_TIMEOUT_SECONDS="$(meta_get "$META" IP_TIMEOUT_SECONDS || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$MODE" == quota ]] || continue
  [[ "$AUTO_RESET" =~ ^[0-9]+$ ]] || AUTO_RESET=0
  [[ "$SERVICE_SECONDS" =~ ^[0-9]+$ ]] || SERVICE_SECONDS=0
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || EXPIRE_EPOCH=0
  [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || RESET_INTERVAL_SECONDS=2592000
  [[ "$NEXT_RESET_EPOCH" =~ ^[0-9]+$ ]] || NEXT_RESET_EPOCH=0
  [[ "$RESET_COUNT" =~ ^[0-9]+$ ]] || RESET_COUNT=0
  [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
  [[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=30
  (( AUTO_RESET == 1 )) || continue
  (( SERVICE_SECONDS > RESET_INTERVAL_SECONDS )) || continue
  (( EXPIRE_EPOCH > NOW )) || continue
  (( NEXT_RESET_EPOCH > 0 )) || continue
  DID_RESET=0
  while (( NEXT_RESET_EPOCH > 0 && NEXT_RESET_EPOCH <= NOW && NEXT_RESET_EPOCH < EXPIRE_EPOCH )); do
    if ! PQ_LOCK_HELD=1 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_apply_port.sh "$PORT" "$LIMIT_BYTES" "$MAX_IPS" "$IP_TIMEOUT_SECONDS"; then break; fi
    LAST_RESET_EPOCH="$NEXT_RESET_EPOCH"
    NEXT_RESET_EPOCH=$((NEXT_RESET_EPOCH + RESET_INTERVAL_SECONDS))
    RESET_COUNT=$((RESET_COUNT + 1))
    DID_RESET=1
  done
  (( NEXT_RESET_EPOCH >= EXPIRE_EPOCH )) && NEXT_RESET_EPOCH=0
  if (( DID_RESET == 1 )); then
    write_meta "$META" <<M
PORT=$PORT
LIMIT_BYTES=$LIMIT_BYTES
LIMIT_GIB=$LIMIT_GIB
REMAIN_BYTES=$LIMIT_BYTES
SAVED_USED_BYTES=0
MODE=$MODE
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS
AUTO_RESET=$AUTO_RESET
LAST_RESET_EPOCH=$LAST_RESET_EPOCH
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH
RESET_COUNT=$RESET_COUNT
MAX_IPS=$MAX_IPS
IP_TIMEOUT_SECONDS=$IP_TIMEOUT_SECONDS
PROTO=tcp
M
    CHANGED=1
  fi
done
(( CHANGED == 1 )) && PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
RESET
chmod +x /usr/local/sbin/pq_reset.sh

cat >/usr/local/sbin/pq_reconcile.sh <<'RECON'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0
[[ -x /usr/local/sbin/pq_ensure_port.sh ]] || { echo "[pq_reconcile] missing /usr/local/sbin/pq_ensure_port.sh" >&2; exit 1; }
[[ -x /usr/local/sbin/pq_meta_repair.sh ]] && /usr/local/sbin/pq_meta_repair.sh --quiet >/dev/null 2>&1 || true
for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"; MAX_IPS="$(meta_get "$META" MAX_IPS || true)"; IP_TIMEOUT_SECONDS="$(meta_get "$META" IP_TIMEOUT_SECONDS || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$MAX_IPS" =~ ^[0-9]+$ ]] || MAX_IPS=0
  [[ "$IP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || IP_TIMEOUT_SECONDS=30
  if ! PQ_LOCK_HELD=1 MAX_IPS="$MAX_IPS" IP_TIMEOUT_SECONDS="$IP_TIMEOUT_SECONDS" /usr/local/sbin/pq_ensure_port.sh "$PORT" 0 >/dev/null 2>&1; then
    echo "[pq_reconcile] pq_ensure failed for ${PORT}" >&2
  fi
done
RECON
chmod +x /usr/local/sbin/pq_reconcile.sh

cat >/usr/local/sbin/pq_del.sh <<'DEL'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
obj_exists() { local kind="$1" name="$2"; nft list "$kind" inet portquota "$name" >/dev/null 2>&1; }
PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "❌ 用法: pq_del.sh <端口>" >&2; exit 1; }
LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -w 10 9
if ! nft list table inet portquota >/dev/null 2>&1; then
  rm -f /etc/portquota/pq-"$PORT".meta
  exit 0
fi
TMP_RULES="$(mktemp)"
cleanup() { rm -f "$TMP_RULES"; }
trap cleanup EXIT
{
  for chain in down_out up_in; do
    nft -a list chain inet portquota "$chain" 2>/dev/null | awk -v p="$PORT" '
      $0 ~ "comment \"pq-count-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-drop-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-harddrop-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-ip-refresh-(out|in)-"p"\"" ||
      $0 ~ "comment \"pq-ip-enforce-(out|in)-"p"\"" {print $NF}
    ' | while read -r h; do
      [[ "$h" =~ ^[0-9]+$ ]] && printf 'delete rule inet portquota %s handle %s\n' "$chain" "$h"
    done
  done
  obj_exists counter "pq_out_$PORT" && echo "delete counter inet portquota pq_out_$PORT"
  obj_exists counter "pq_in_$PORT" && echo "delete counter inet portquota pq_in_$PORT"
  obj_exists quota "pq_quota_$PORT" && echo "delete quota inet portquota pq_quota_$PORT"
  obj_exists set "pq_ip_$PORT" && echo "delete set inet portquota pq_ip_$PORT"
} >"$TMP_RULES"
if [[ -s "$TMP_RULES" ]]; then nft -f "$TMP_RULES"; fi
rm -f /etc/portquota/pq-"$PORT".meta
PQ_LOCK_HELD=1 /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true
DEL
chmod +x /usr/local/sbin/pq_del.sh

cat >/usr/local/sbin/pq_audit.sh <<'AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
get_ipset_count() { local name="${1:-}"; nft list set inet portquota "$name" 2>/dev/null | awk 'BEGIN{c=0} /elements = \{/ {line=$0; sub(/^.*elements = \{ */, "", line); sub(/ *\}.*$/, "", line); n=split(line,a,/,/); for(i=1;i<=n;i++) if(a[i] ~ /([0-9]{1,3}\.){3}[0-9]{1,3}/) c++;} END{print c+0}'; }
fmt_epoch() { local ts="${1:-}"; if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )); then date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts"; else echo -; fi; }
printf "%-8s %-8s %-11s %-11s %-8s %-6s %-6s %-7s %-8s %-8s %-19s %-19s\n" PORT STATE TOTALGiB LIMITGiB USE% IPCUR IPMAX IPTO RESET COUNT NEXT_RESET EXPIRE
for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"; LIMIT_BYTES="$(meta_total_limit_bytes "$META")"; SAVED_USED="$(meta_get "$META" SAVED_USED_BYTES || true)"; MODE="$(meta_get "$META" MODE || true)"; AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"; NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"; RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"; EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"; MAX_IPS="$(meta_get "$META" MAX_IPS || true)"; IP_TIMEOUT_SECONDS="$(meta_get "$META" IP_TIMEOUT_SECONDS || true)"
  [[ -n "$PORT" ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$SAVED_USED" =~ ^[0-9]+$ ]] || SAVED_USED=0
  OUT_B="$(get_counter_bytes "pq_out_${PORT}" || true)"; [[ "$OUT_B" =~ ^[0-9]+$ ]] || OUT_B=0
  IN_B="$(get_counter_bytes "pq_in_${PORT}" || true)"; [[ "$IN_B" =~ ^[0-9]+$ ]] || IN_B=0
  TOTAL_B=$((OUT_B + IN_B))
  if [[ "$MODE" == quota && "$LIMIT_BYTES" -gt 0 ]]; then
    LIVE_USED="$(get_quota_used_bytes "pq_quota_${PORT}" || true)"; [[ "$LIVE_USED" =~ ^[0-9]+$ ]] || LIVE_USED="$TOTAL_B"
    TOTAL_USED=$((SAVED_USED + LIVE_USED)); (( TOTAL_USED > LIMIT_BYTES )) && TOTAL_USED="$LIMIT_BYTES"
    LIMIT_GIB="$(awk -v b="$LIMIT_BYTES" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"
    TOTAL_GIB="$(awk -v b="$TOTAL_USED" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"
    PCT="$(awk -v u="$TOTAL_USED" -v l="$LIMIT_BYTES" 'BEGIN{printf "%.1f%%",(l>0?(u*100.0/l):0)}')"
    if (( TOTAL_USED >= LIMIT_BYTES )); then STATE=dropped; else STATE=ok; fi
  else
    TOTAL_USED=$((SAVED_USED + TOTAL_B))
    TOTAL_GIB="$(awk -v b="$TOTAL_USED" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"
    LIMIT_GIB="-"
    PCT="-"
    STATE=track
  fi
  IP_CUR=0
  [[ "${MAX_IPS:-0}" =~ ^[0-9]+$ ]] || MAX_IPS=0
  (( MAX_IPS > 0 )) && IP_CUR="$(get_ipset_count "pq_ip_${PORT}")"
  RESET_FLAG=no
  [[ "${AUTO_RESET:-0}" == 1 ]] && RESET_FLAG=yes
  printf "%-8s %-8s %-11s %-11s %-8s %-6s %-6s %-7s %-8s %-8s %-19s %-19s\n" "$PORT" "$STATE" "$TOTAL_GIB" "$LIMIT_GIB" "$PCT" "$IP_CUR" "$MAX_IPS" "${IP_TIMEOUT_SECONDS:-0}" "$RESET_FLAG" "${RESET_COUNT:-0}" "$(fmt_epoch "$NEXT_RESET_EPOCH")" "$(fmt_epoch "$EXPIRE_EPOCH")"
done
AUDIT
chmod +x /usr/local/sbin/pq_audit.sh

cat >/usr/local/sbin/pq_save_state.sh <<'SAVESTATE'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
meta_set() { local file="$1" key="$2" val="$3"; touch "$file"; if grep -q "^${key}=" "$file" 2>/dev/null; then sed -i -E "s#^${key}=.*#${key}=${val}#" "$file"; else printf '%s=%s\n' "$key" "$val" >>"$file"; fi; }
meta_total_limit_bytes() {
  local meta="$1" limit_bytes limit_gib total
  limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"; limit_gib="$(meta_get "$meta" LIMIT_GIB || true)"
  [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
  [[ "$limit_gib" =~ ^[0-9]+$ ]] || limit_gib=0
  total="$limit_bytes"
  if (( limit_gib > 0 )); then
    local from_gib=$((limit_gib * 1024 * 1024 * 1024))
    (( from_gib > total )) && total="$from_gib"
  fi
  echo "$total"
}
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_total_limit_bytes "$META")"
  SAVED_USED_BYTES="$(meta_get "$META" SAVED_USED_BYTES || true)"
  MODE="$(meta_get "$META" MODE || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$SAVED_USED_BYTES" =~ ^[0-9]+$ ]] || SAVED_USED_BYTES=0
  OUT_B="$(get_counter_bytes "pq_out_${PORT}" || true)"; [[ "$OUT_B" =~ ^[0-9]+$ ]] || OUT_B=0
  IN_B="$(get_counter_bytes "pq_in_${PORT}" || true)"; [[ "$IN_B" =~ ^[0-9]+$ ]] || IN_B=0
  TOTAL_B=$((OUT_B + IN_B))
  if [[ "$MODE" == quota && "$LIMIT_BYTES" -gt 0 ]]; then LIVE_USED="$(get_quota_used_bytes "pq_quota_${PORT}" || true)"; [[ "$LIVE_USED" =~ ^[0-9]+$ ]] || LIVE_USED="$TOTAL_B"; else LIVE_USED="$TOTAL_B"; fi
  NEW_SAVED=$((SAVED_USED_BYTES + LIVE_USED)); (( NEW_SAVED > LIMIT_BYTES )) && NEW_SAVED="$LIMIT_BYTES"
  REMAIN=$((LIMIT_BYTES - NEW_SAVED)); (( REMAIN < 0 )) && REMAIN=0
  meta_set "$META" LIMIT_BYTES "$LIMIT_BYTES"
  meta_set "$META" SAVED_USED_BYTES "$NEW_SAVED"
  meta_set "$META" REMAIN_BYTES "$REMAIN"
done
SAVESTATE
chmod +x /usr/local/sbin/pq_save_state.sh
cat >/usr/local/sbin/pq_meta_repair.sh <<'REPAIR'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=","",$0); print; exit}' "$file" 2>/dev/null || true; }
meta_set() { local file="$1" key="$2" val="$3"; touch "$file"; if grep -q "^${key}=" "$file" 2>/dev/null; then sed -i -E "s#^${key}=.*#${key}=${val}#" "$file"; else printf '%s=%s\n' "$key" "$val" >>"$file"; fi; }
get_counter_bytes() { local obj="${1:-}"; nft list counter inet portquota "$obj" 2>/dev/null | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'; }
get_quota_used_bytes() { local obj="${1:-}"; nft list quota inet portquota "$obj" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'; }
changed=0
for META in /etc/portquota/pq-*.meta; do
  [[ -f "$META" ]] || continue
  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  LIMIT_GIB="$(meta_get "$META" LIMIT_GIB || true)"
  SAVED="$(meta_get "$META" SAVED_USED_BYTES || true)"
  REMAIN="$(meta_get "$META" REMAIN_BYTES || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || LIMIT_BYTES=0
  [[ "$LIMIT_GIB" =~ ^[0-9]+$ ]] || LIMIT_GIB=0
  [[ "$SAVED" =~ ^[0-9]+$ ]] || SAVED=0
  [[ "$REMAIN" =~ ^[0-9]+$ ]] || REMAIN=0
  EXPECTED="$LIMIT_BYTES"
  if (( LIMIT_GIB > 0 )); then from_gib=$((LIMIT_GIB * 1024 * 1024 * 1024)); (( from_gib > EXPECTED )) && EXPECTED="$from_gib"; fi
  OUT_B="$(get_counter_bytes "pq_out_${PORT}" || true)"; [[ "$OUT_B" =~ ^[0-9]+$ ]] || OUT_B=0
  IN_B="$(get_counter_bytes "pq_in_${PORT}" || true)"; [[ "$IN_B" =~ ^[0-9]+$ ]] || IN_B=0
  TOTAL_B=$((OUT_B + IN_B))
  LIVE_USED="$(get_quota_used_bytes "pq_quota_${PORT}" || true)"; [[ "$LIVE_USED" =~ ^[0-9]+$ ]] || LIVE_USED="$TOTAL_B"
  TOTAL_USED=$((SAVED + LIVE_USED)); (( TOTAL_USED > EXPECTED )) && TOTAL_USED="$EXPECTED"
  NEW_REMAIN=$((EXPECTED - TOTAL_USED)); (( NEW_REMAIN < 0 )) && NEW_REMAIN=0
  if (( LIMIT_BYTES != EXPECTED )); then meta_set "$META" LIMIT_BYTES "$EXPECTED"; changed=1; fi
  if (( REMAIN != NEW_REMAIN )); then meta_set "$META" REMAIN_BYTES "$NEW_REMAIN"; changed=1; fi
done
if (( QUIET == 0 )); then
  if (( changed == 1 )); then echo "✅ 已修正 PQ meta 中的总额度/剩余额度字段"; else echo "ℹ PQ meta 无需修正"; fi
fi
REPAIR
chmod +x /usr/local/sbin/pq_meta_repair.sh

cat >/etc/systemd/system/pq-save-state.service <<'PQSSTATE'
[Unit]
Description=Save portquota used bytes before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target kexec.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
TimeoutStartSec=30

[Install]
WantedBy=reboot.target
WantedBy=halt.target
WantedBy=poweroff.target
WantedBy=kexec.target
PQSSTATE

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

cat >/etc/systemd/system/pq-reconcile.service <<'RQSVC'
[Unit]
Description=Reconcile nftables portquota rules after boot and periodically

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reconcile.sh
RQSVC

cat >/etc/systemd/system/pq-reconcile.timer <<'RQTMR'
[Unit]
Description=Reconcile nftables portquota policy after boot and periodically

[Timer]
OnBootSec=40s
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
RQTMR

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
systemctl enable --now pq-reconcile.timer >/dev/null 2>&1 || true
systemctl enable pq-save-state.service >/dev/null 2>&1 || true
[[ -x /usr/local/sbin/pq_meta_repair.sh ]] && /usr/local/sbin/pq_meta_repair.sh --quiet >/dev/null 2>&1 || true
EOF_PQ_ENH
  chmod +x /tmp/pq-enhanced-vless.sh
  bash /tmp/pq-enhanced-vless.sh
  rm -f /tmp/pq-enhanced-vless.sh
}

# ------------------ 主流程 ------------------

main() {
  check_debian12
  need_basic_tools
  install_vless_defaults
  install_update_all
  install_vless_script
  install_vless_enhancements
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
   MAX_IPS=3 PQ_GIB=50 D=600 vless_mktemp.sh
   MAX_IPS=3 D=600 vless_mktemp.sh
   PQ_GIB=50 D=$((60*86400)) vless_mktemp.sh
   PQ_GIB=50 D=$((20*86400)) vless_mktemp.sh

   vless_extend.sh <TAG> <SECONDS>
   vless_pause.sh <TAG>
   vless_resume.sh <TAG>
   vless_audit.sh
   vless_clear_all.sh
   FORCE=1 vless_cleanup_one.sh vless-temp-YYYYMMDDHHMMSS-ABCD

4) TCP 配额（nftables + 5 分钟保存快照，双向合计）：
   # 主节点配额
   pq_add.sh 443 500

   # 已创建节点后补配额 / 改配额
   pq_add.sh 40000 50 $((60*86400))
   pq_add.sh 40001 50 $((20*86400))

   pq_set.sh 40000 80
   MAX_IPS=3 IP_TIMEOUT_SECONDS=90 pq_set.sh 40000 80
   pq_audit.sh
   pq_del.sh 40000

5) 日志轮转（保留最近 2 天）：
   - /var/log/pq-save.log
   - /var/log/vless-gc.log
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
   5) 主节点限额或后补限额时，再用：pq_add.sh / pq_audit.sh / pq_del.sh
==================================================
DONE
}

main "$@"
