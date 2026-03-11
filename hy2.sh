#!/usr/bin/env bash
# Debian 12 一键部署脚本（HY2 折中优化版 / 正式证书复用版）
#
# 目标：
# - 主节点：hy2.liucna.com:443 + 正式证书 + masquerade
# - 临时节点：独立高端口 + 复用同一张正式证书 + 独立配额
# - 长周期服务（>30 天）配额每 30 天自动重置满流量；<=30 天不重置
# - 不再使用“临时高端口 + 自签证书 + pinSHA256”路线
# - /etc/default/hy2-main 直接生成带注释模板
#
# 使用：
#   bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/debian12-/main/hy2.sh)

set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

UP_BASE="/usr/local/src/debian12-upstream"
ENV_FILE="/etc/default/hy2-main"

curl_fs() {
  curl -fsSL --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本"
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  if [[ "$codename" != "bookworm" ]]; then
    echo "❌ 本脚本仅适用于 Debian 12 (bookworm)，当前: ${codename:-未知}"
    exit 1
  fi
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux logrotate certbot

  local c
  for c in curl openssl python3 nft timeout ss flock awk sed grep base64 systemctl certbot; do
    command -v "$c" >/dev/null 2>&1 || { echo "❌ 缺少命令: $c"; exit 1; }
  done
}

download_upstreams() {
  echo "⬇ 下载/更新上游文件到 ${UP_BASE} ..."
  mkdir -p "$UP_BASE"
  curl_fs "https://get.hy2.sh/" -o "${UP_BASE}/get_hy2.sh"
  chmod +x "${UP_BASE}/get_hy2.sh"
  echo "✅ 上游已更新："
  ls -l "$UP_BASE"
}

install_update_all() {
  echo "🧩 写入 /usr/local/bin/update-all ..."
  cat >/usr/local/bin/update-all << 'EOF'
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
EOF
  chmod +x /usr/local/bin/update-all
}

install_env_template() {
  echo "🧩 写入 /etc/default/hy2-main（带注释模板）..."
  if [[ ! -f "$ENV_FILE" ]]; then
    cat >"$ENV_FILE" <<'EOF'
# ==================================================
# HY2 主配置文件
# ==================================================
#
# 这个文件控制：
# 1) 主节点：HY_DOMAIN:443
# 2) 临时高端口节点：HY_DOMAIN:临时端口
#
# 以后 VPS 换 IP，只需要改 HY_DOMAIN 的 DNS 解析，
# 主节点和临时节点的原有链接都不用重新发。
#
# 注意：
# - 如果你使用 Cloudflare，请保持 DNS only（灰云）
# - 使用 certbot standalone 申请证书时，需要 TCP 80 可达
# - 主节点和临时节点都会复用同一张正式证书
#

# 客户端真正连接你 VPS 的域名
HY_DOMAIN=hy2.liucna.com

# 主节点监听地址（通常不要改）
HY_LISTEN=:443

# 用于申请正式证书的邮箱
ACME_EMAIL=

# 伪装目标网站
# 请改成你自己选的站点，不建议直接照抄公开教程示例
MASQ_URL=https://www.apple.com/

# 是否启用 Salamander 混淆
# 默认 0，不开启
# 只有在明确确认“当前网络专门封锁 QUIC / HTTP/3，但 UDP 还活着”时才建议改成 1
ENABLE_SALAMANDER=0

# 只有在 ENABLE_SALAMANDER=1 时才需要填写
SALAMANDER_PASSWORD=

# 主节点名称（显示在链接 # 后面）
NODE_NAME=HY2-MAIN

# 临时端口默认范围
TEMP_PORT_START=40000
TEMP_PORT_END=50050
EOF
    chmod 600 "$ENV_FILE"
  fi
}

install_hy2_main_script() {
  echo "🧩 写入 /root/onekey_hy2_main_tls.sh ..."
  cat >/root/onekey_hy2_main_tls.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

UP_BASE="/usr/local/src/debian12-upstream"
ENV_FILE="/etc/default/hy2-main"
HY_BASE="/etc/hysteria"
CFG_FILE="${HY_BASE}/config-main.yaml"
SERVICE_FILE="/etc/systemd/system/hy2.service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-hy2.sh"
TOKEN_FILE="${HY_BASE}/main.token"

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

install_hysteria_from_local_or_repo() {
  mkdir -p "$UP_BASE"
  local installer="$UP_BASE/get_hy2.sh"
  if [ ! -x "$installer" ]; then
    echo "⬇ 获取 Hysteria 2 安装脚本..."
    curl -fsSL "https://get.hy2.sh/" -o "$installer"
    chmod +x "$installer"
  fi
  echo "⚙ 安装 / 更新 Hysteria 2 ..."
  bash "$installer"
  command -v hysteria >/dev/null 2>&1 || { echo "❌ 未找到 hysteria 可执行文件"; exit 1; }
}

yaml_quote() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
print("'" + s.replace("'", "''") + "'")
PY
}

check_debian12
[[ -f "$ENV_FILE" ]] || { echo "❌ 缺少 $ENV_FILE"; exit 1; }

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${HY_DOMAIN:?缺少 HY_DOMAIN}"
: "${HY_LISTEN:?缺少 HY_LISTEN}"
: "${ACME_EMAIL:?缺少 ACME_EMAIL}"
: "${MASQ_URL:?缺少 MASQ_URL}"
: "${ENABLE_SALAMANDER:=0}"
: "${SALAMANDER_PASSWORD:=}"
: "${NODE_NAME:=HY2-MAIN}"

if [[ "$ENABLE_SALAMANDER" == "1" && -z "$SALAMANDER_PASSWORD" ]]; then
  echo "❌ ENABLE_SALAMANDER=1 时必须设置 SALAMANDER_PASSWORD"
  exit 1
fi

echo "=== 1. 启用 BBR ==="
cat >/etc/sysctl.d/99-bbr.conf <<SYS
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-bbr.conf || true
echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

echo
echo "=== 2. 安装 / 更新 Hysteria 2 ==="
install_hysteria_from_local_or_repo
systemctl stop hysteria-server.service 2>/dev/null || true
systemctl disable hysteria-server.service 2>/dev/null || true

echo
echo "=== 3. 申请 / 续期正式证书（certbot standalone） ==="
mkdir -p "$HY_BASE"
chmod 700 "$HY_BASE" 2>/dev/null || true

certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  -m "$ACME_EMAIL" \
  -d "$HY_DOMAIN" \
  --keep-until-expiring

CRT="/etc/letsencrypt/live/${HY_DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${HY_DOMAIN}/privkey.pem"

[[ -s "$CRT" && -s "$KEY" ]] || { echo "❌ 证书文件不存在：$CRT / $KEY"; exit 1; }

echo
echo "=== 4. 准备主账号 / 续期钩子 ==="
if [[ ! -f "$TOKEN_FILE" ]]; then
  openssl rand -hex 16 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
MAIN_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"

mkdir -p "$(dirname "$RENEW_HOOK")"
cat >"$RENEW_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl restart hy2.service || true
for svc in $(systemctl list-units --type=service --state=active --no-legend 'hy2-temp-*.service' | awk '{print $1}'); do
  systemctl restart "$svc" || true
done
HOOK
chmod +x "$RENEW_HOOK"

systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true

echo
echo "=== 5. 写入主配置 ==="
DOMAIN_Q="$(yaml_quote "$HY_DOMAIN")"
CRT_Q="$(yaml_quote "$CRT")"
KEY_Q="$(yaml_quote "$KEY")"
TOKEN_Q="$(yaml_quote "$MAIN_TOKEN")"
MASQ_Q="$(yaml_quote "$MASQ_URL")"
SALAM_Q="$(yaml_quote "$SALAMANDER_PASSWORD")"

if [[ -f "$CFG_FILE" ]]; then
  cp -a "$CFG_FILE" "${CFG_FILE}.bak.$(date +%F-%H%M%S)"
fi

{
  echo "listen: ${HY_LISTEN}"
  echo
  echo "tls:"
  echo "  cert: ${CRT_Q}"
  echo "  key: ${KEY_Q}"
  echo
  echo "auth:"
  echo "  type: password"
  echo "  password: ${TOKEN_Q}"
  echo
  if [[ "$ENABLE_SALAMANDER" == "1" ]]; then
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${SALAM_Q}"
    echo
  fi
  echo "masquerade:"
  echo "  type: proxy"
  echo "  proxy:"
  echo "    url: ${MASQ_Q}"
  echo "    rewriteHost: true"
  echo
  echo "speedTest: false"
  echo "disableUDP: false"
  echo "udpIdleTimeout: 60s"
} >"$CFG_FILE"

chmod 600 "$CFG_FILE"

echo
echo "=== 6. 写入 systemd 服务 ==="
HY_BIN="$(command -v hysteria)"
cat >"$SERVICE_FILE" <<SVC
[Unit]
Description=Hysteria 2 Main Service
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${HY_BIN} server -c ${CFG_FILE}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable hy2.service >/dev/null 2>&1 || true
systemctl restart hy2.service

sleep 3
if ! systemctl is-active --quiet hy2.service; then
  echo "❌ hy2 启动失败，状态与日志如下：" >&2
  systemctl --no-pager --full status hy2.service >&2 || true
  journalctl -u hy2.service --no-pager -n 120 >&2 || true
  exit 1
fi

URL="hy2://${MAIN_TOKEN}@${HY_DOMAIN}:443/?sni=${HY_DOMAIN}#${NODE_NAME}"
if [[ "$ENABLE_SALAMANDER" == "1" ]]; then
  URL="hy2://${MAIN_TOKEN}@${HY_DOMAIN}:443/?sni=${HY_DOMAIN}&obfs=salamander&obfs-password=${SALAMANDER_PASSWORD}#${NODE_NAME}"
fi

if base64 --help 2>/dev/null | grep -q -- "-w"; then
  echo "$URL" | base64 -w0 >/root/hy2_main_subscription_base64.txt
else
  echo "$URL" | base64 | tr -d '\n' >/root/hy2_main_subscription_base64.txt
fi
echo "$URL" >/root/hy2_main_url.txt
chmod 600 /root/hy2_main_url.txt /root/hy2_main_subscription_base64.txt 2>/dev/null || true

echo
echo "================== 主节点信息 =================="
echo "$URL"
echo
echo "Base64 订阅："
cat /root/hy2_main_subscription_base64.txt
echo
echo "保存位置："
echo "  /root/hy2_main_url.txt"
echo "  /root/hy2_main_subscription_base64.txt"
echo "✅ HY2 主节点安装完成"
EOF
  chmod +x /root/onekey_hy2_main_tls.sh
}

install_hy2_temp_system() {
  echo "🧩 写入 /root/hy2_temp_port_all.sh 和相关脚本 ..."
  cat >/root/hy2_temp_port_all.sh << 'EOF'
#!/usr/bin/env bash
# HY2 临时节点：独立高端口 + 复用正式证书 + GC
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

ENV_FILE="/etc/default/hy2-main"
TEMP_DIR="/etc/hysteria/temp"

[[ -f "$ENV_FILE" ]] || {
  echo "❌ 缺少 $ENV_FILE，请先执行主节点部署"
  exit 1
}

mkdir -p "$TEMP_DIR"

########################################
# 1) 单节点清理
########################################
cat >/usr/local/sbin/hy2_cleanup_one.sh << 'CLEAN'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"; }

TAG="${1:?need TAG}"
UNIT_NAME="${TAG}.service"
TEMP_DIR="/etc/hysteria/temp"
CFG="${TEMP_DIR}/${TAG}.yaml"
META="${TEMP_DIR}/${TAG}.meta"
LOG="/var/log/hy2-gc.log"
FORCE="${FORCE:-0}"

PORT=""
if [[ -f "$META" ]]; then
  PORT="$(meta_get "$META" PORT || true)"
fi

LOCK="/run/hy2-temp.lock"
if [[ "${HY2_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"$LOCK"
  flock -w 10 9 || { echo "[hy2_cleanup_one] lock busy, skip cleanup: ${TAG}"; exit 0; }
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ -n "${EXPIRE_EPOCH:-}" && "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    if (( EXPIRE_EPOCH > NOW )); then
      echo "[hy2_cleanup_one] ${TAG} 未到期，跳过清理"
      exit 0
    fi
  fi
fi

ACTIVE_STATE="$(systemctl show -p ActiveState --value "${UNIT_NAME}" 2>/dev/null || echo "")"
if [[ "${ACTIVE_STATE}" == "active" || "${ACTIVE_STATE}" == "activating" ]]; then
  if ! timeout 8 systemctl stop "${UNIT_NAME}" >/dev/null 2>&1; then
    systemctl kill "${UNIT_NAME}" >/dev/null 2>&1 || true
  fi
fi

systemctl disable "${UNIT_NAME}" >/dev/null 2>&1 || true

if [[ -n "${PORT:-}" && "$PORT" =~ ^[0-9]+$ ]] && [[ -x /usr/local/sbin/pq_del.sh ]]; then
  /usr/local/sbin/pq_del.sh "$PORT" >/dev/null 2>&1 || true
fi

rm -f "$CFG" "$META" "/etc/systemd/system/${UNIT_NAME}" 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "${UNIT_NAME}" >/dev/null 2>&1 || true

echo "$(date '+%F %T %Z') cleanup ${TAG}" >> "$LOG" 2>/dev/null || true
echo "✅ 已清理临时节点: ${TAG}"
CLEAN
chmod +x /usr/local/sbin/hy2_cleanup_one.sh

########################################
# 2) 创建临时节点：D=秒 hy2_mktemp.sh
########################################
cat >/usr/local/sbin/hy2_mktemp.sh << 'MK'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

: "${D:?请用 D=秒 hy2_mktemp.sh 方式调用，例如：D=600 hy2_mktemp.sh}"

if ! [[ "$D" =~ ^[0-9]+$ ]] || (( D <= 0 )); then
  echo "❌ D 必须是正整数秒，例如：D=600 hy2_mktemp.sh" >&2
  exit 1
fi
if [[ -n "${PQ_GIB:-}" ]]; then
  if ! [[ "$PQ_GIB" =~ ^[0-9]+$ ]] || (( PQ_GIB <= 0 )); then
    echo "❌ PQ_GIB 必须是正整数，例如：PQ_GIB=50 D=60 hy2_mktemp.sh" >&2
    exit 1
  fi
fi

LOCK="/run/hy2-temp.lock"
exec 9>"$LOCK"
flock -w 10 9

ENV_FILE="/etc/default/hy2-main"
TEMP_DIR="/etc/hysteria/temp"

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${HY_DOMAIN:?缺少 HY_DOMAIN}"
: "${TEMP_PORT_START:=40000}"
: "${TEMP_PORT_END:=50050}"
: "${ENABLE_SALAMANDER:=0}"
: "${SALAMANDER_PASSWORD:=}"

CRT="/etc/letsencrypt/live/${HY_DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${HY_DOMAIN}/privkey.pem"
[[ -s "$CRT" && -s "$KEY" ]] || {
  echo "❌ 缺少正式证书，请先执行：bash /root/onekey_hy2_main_tls.sh"
  exit 1
}

mkdir -p "$TEMP_DIR"

[[ "$TEMP_PORT_START" =~ ^[0-9]+$ && "$TEMP_PORT_END" =~ ^[0-9]+$ ]] || { echo "❌ 端口范围非法"; exit 1; }
(( TEMP_PORT_START >= 1 && TEMP_PORT_END <= 65535 && TEMP_PORT_START < TEMP_PORT_END )) || { echo "❌ 端口范围非法"; exit 1; }

declare -A USED_PORTS=()
while read -r p; do
  [[ -n "$p" ]] && USED_PORTS["$p"]=1
done < <(ss -lunH 2>/dev/null | awk '{print $5}' | sed -E 's/.*:([0-9]+)$/\1/')

shopt -s nullglob
for f in "${TEMP_DIR}"/hy2-temp-*.meta; do
  p="$(awk -F= '$1=="PORT"{sub($1"=","");print;exit}' "$f" 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] && USED_PORTS["$p"]=1
done
shopt -u nullglob

PORT="$TEMP_PORT_START"
while (( PORT <= TEMP_PORT_END )); do
  if [[ -z "${USED_PORTS[$PORT]+x}" ]]; then
    break
  fi
  PORT=$((PORT+1))
done
(( PORT <= TEMP_PORT_END )) || { echo "❌ 没有空闲端口"; exit 1; }

TOKEN="$(openssl rand -hex 16)"
TAG="hy2-temp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
CFG="${TEMP_DIR}/${TAG}.yaml"
META="${TEMP_DIR}/${TAG}.meta"
UNIT="/etc/systemd/system/${TAG}.service"

NOW=$(date +%s)
EXP=$((NOW + D))

yaml_quote() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
print("'" + s.replace("'", "''") + "'")
PY
}

TOKEN_Q="$(yaml_quote "$TOKEN")"
CRT_Q="$(yaml_quote "$CRT")"
KEY_Q="$(yaml_quote "$KEY")"
SALAM_Q="$(yaml_quote "$SALAMANDER_PASSWORD")"

{
  echo "listen: :${PORT}"
  echo
  echo "tls:"
  echo "  cert: ${CRT_Q}"
  echo "  key: ${KEY_Q}"
  echo
  echo "auth:"
  echo "  type: password"
  echo "  password: ${TOKEN_Q}"
  echo
  if [[ "$ENABLE_SALAMANDER" == "1" ]]; then
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${SALAM_Q}"
    echo
  fi
  echo "speedTest: false"
  echo "disableUDP: false"
  echo "udpIdleTimeout: 60s"
} >"$CFG"

cat >"$META" <<M
TAG=$TAG
PORT=$PORT
TOKEN=$TOKEN
CREATE_EPOCH=$NOW
DURATION_SECONDS=$D
EXPIRE_EPOCH=$EXP
M

chmod 600 "$CFG" "$META" 2>/dev/null || true

HY_BIN="$(command -v hysteria)"
cat >"$UNIT" <<U
[Unit]
Description=Temp HY2 ${TAG}
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${HY_BIN} server -c ${CFG}
ExecStopPost=/usr/local/sbin/hy2_cleanup_one.sh ${TAG}
Restart=no
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
U

systemctl daemon-reload
systemctl enable "${TAG}.service" >/dev/null 2>&1 || true

if [[ -n "${PQ_GIB:-}" ]]; then
  if ! CREATE_EPOCH="$NOW" /usr/local/sbin/pq_add.sh "$PORT" "$PQ_GIB" "$D" "$EXP"; then
    echo "❌ 绑定配额失败，正在回滚..." >&2
    HY2_LOCK_HELD=1 FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
    exit 1
  fi
fi

if ! systemctl start "${TAG}.service"; then
  echo "❌ 启动临时 HY2 服务失败，正在回滚..."
  HY2_LOCK_HELD=1 FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
  exit 1
fi

sleep 2
if ! systemctl is-active --quiet "${TAG}.service"; then
  echo "❌ 临时 HY2 服务未能成功启动"
  HY2_LOCK_HELD=1 FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
  exit 1
fi

E_STR="$(TZ=Asia/Shanghai date -d "@$EXP" '+%F %T')"

URL="hy2://${TOKEN}@${HY_DOMAIN}:${PORT}/?sni=${HY_DOMAIN}#${TAG}"
if [[ "$ENABLE_SALAMANDER" == "1" ]]; then
  URL="hy2://${TOKEN}@${HY_DOMAIN}:${PORT}/?sni=${HY_DOMAIN}&obfs=salamander&obfs-password=${SALAMANDER_PASSWORD}#${TAG}"
fi

echo "✅ 新 HY2 临时节点: ${TAG}
地址: ${HY_DOMAIN}:${PORT}/udp
Token: ${TOKEN}
有效期: ${D} 秒
到期(北京时间): ${E_STR}
HY2 链接: ${URL}"
if [[ -n "${PQ_GIB:-}" ]]; then
  echo "已绑定配额: ${PQ_GIB}GiB"
fi
MK
chmod +x /usr/local/sbin/hy2_mktemp.sh

########################################
# 3) 审计脚本
########################################
cat >/usr/local/sbin/hy2_audit.sh << 'AUDIT'
#!/usr/bin/env bash
# HY2_AUDIT_RDY_FIX_V6
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

parse_port_from_listen() {
  local listen="${1:-}"
  if [[ "$listen" =~ ([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

udp_port_listening() {
  local port="$1"
  ss -lunH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p' | grep -qx "$port"
}

get_counter_bytes() {
  local obj="$1"
  nft list counter inet portquota "$obj" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'
}

get_quota_used_bytes() {
  local obj="$1"
  nft list quota inet portquota "$obj" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'
}

fmt_gib() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v v="$b" 'BEGIN{printf "%.2f", v/1024/1024/1024}'
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

  if [[ -f "$meta" ]]; then
    local limit_bytes mode out_b in_b total_b quota_used_b used_b left_b pct_val
    limit_bytes="$(meta_get "$meta" LIMIT_BYTES || true)"
    mode="$(meta_get "$meta" MODE || true)"
    [[ "$limit_bytes" =~ ^[0-9]+$ ]] || limit_bytes=0
    mode="${mode:-quota}"

    if [[ "$mode" != "quota" || "$limit_bytes" == "0" ]]; then
      qstate="track"
    else
      out_b="$(get_counter_bytes "pq_out_${port}" || true)"; [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
      in_b="$(get_counter_bytes "pq_in_${port}" || true)";   [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
      total_b=$((out_b + in_b))
      quota_used_b="$(get_quota_used_bytes "pq_quota_${port}" || true)"
      if [[ "$quota_used_b" =~ ^[0-9]+$ ]]; then
        used_b="$quota_used_b"
      else
        used_b="$total_b"
      fi
      (( used_b < 0 )) && used_b=0
      if (( used_b > limit_bytes )); then
        used_b="$limit_bytes"
      fi
      left_b=$((limit_bytes - used_b))
      (( left_b < 0 )) && left_b=0
      pct_val="$(awk -v u="$used_b" -v l="$limit_bytes" 'BEGIN{printf "%.1f%%", (l>0 ? (u*100.0/l) : 0)}')"
      limit="$(fmt_gib "$limit_bytes")"
      used="$(fmt_gib "$used_b")"
      left="$(fmt_gib "$left_b")"
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

TEMP_DIR="/etc/hysteria/temp"
ENV_FILE="/etc/default/hy2-main"
MAIN_PORT="443"

if [[ -r "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  P="$(parse_port_from_listen "${HY_LISTEN:-:443}" || true)"
  [[ "$P" =~ ^[0-9]+$ ]] && MAIN_PORT="$P"
fi

echo
printf '%s\n' '=== HY2 AUDIT ==='
print_sep
render_row "NAME" "STATE" "PORT" "RDY" "Q" "LIMIT" "USED" "LEFT" "USE%" "TTL" "EXPIRE(CN)"
print_sep

if systemctl list-unit-files hy2.service >/dev/null 2>&1; then
  STATE="$(systemctl is-active hy2.service 2>/dev/null || echo unknown)"
  READY="no"
  if [[ "$STATE" == "active" ]] && udp_port_listening "$MAIN_PORT"; then
    READY="yes"
  fi
  render_row "hy2.service" "$STATE" "$MAIN_PORT" "$READY" "none" "-" "-" "-" "-" "-" "-"
fi

for META in "$TEMP_DIR"/hy2-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  PORT="$(meta_get "$META" PORT || true)"
  EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"
  [[ -n "$TAG" && -n "$PORT" ]] || continue

  NAME="${TAG}.service"
  STATE="$(systemctl is-active "${TAG}.service" 2>/dev/null || echo unknown)"
  READY="no"
  if [[ "$STATE" == "active" ]] && udp_port_listening "$PORT"; then
    READY="yes"
  fi
  IFS='|' read -r QSTATE LIMIT USED LEFT_Q PCT <<< "$(quota_cells "$PORT")"
  render_row "$NAME" "$STATE" "$PORT" "$READY" "$QSTATE" "$LIMIT" "$USED" "$LEFT_Q" "$PCT" "$(fmt_left "$EXP")" "$(fmt_expire_cn "$EXP")"
done

print_sep
AUDIT
chmod +x /usr/local/sbin/hy2_audit.sh

########################################
# 4) GC
########################################
cat >/usr/local/sbin/hy2_gc.sh << 'GC'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"; }

LOCK="/run/hy2-temp.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

TEMP_DIR="/etc/hysteria/temp"
NOW=$(date +%s)

for META in "$TEMP_DIR"/hy2-temp-*.meta; do
  TAG="$(meta_get "$META" TAG || true)"
  EXP="$(meta_get "$META" EXPIRE_EPOCH || true)"
  [[ -n "$TAG" ]] || continue
  [[ "$EXP" =~ ^[0-9]+$ ]] || continue

  if (( EXP <= NOW )); then
    HY2_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
  fi
done
GC
chmod +x /usr/local/sbin/hy2_gc.sh

cat >/etc/systemd/system/hy2-gc.service << 'GCSVC'
[Unit]
Description=HY2 Temp Nodes Garbage Collector
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2_gc.sh
GCSVC

cat >/etc/systemd/system/hy2-gc.timer << 'GCTMR'
[Unit]
Description=Run HY2 temp node GC every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
GCTMR

systemctl daemon-reload
systemctl enable --now hy2-gc.timer >/dev/null 2>&1 || true

########################################
# 5) 清空全部临时节点
########################################
cat >/usr/local/sbin/hy2_clear_all.sh << 'CLR'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() { local file="$1" key="$2"; awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"; }

LOCK="/run/hy2-temp.lock"
exec 9>"$LOCK"
flock -w 10 9

TEMP_DIR="/etc/hysteria/temp"
META_FILES=("$TEMP_DIR"/hy2-temp-*.meta)
if (( ${#META_FILES[@]} == 0 )); then
  echo "当前没有任何临时 HY2 节点。"
  exit 0
fi

for META in "${META_FILES[@]}"; do
  TAG="$(meta_get "$META" TAG || true)"
  [[ -n "$TAG" ]] || continue
  HY2_LOCK_HELD=1 FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
done

echo "✅ 所有临时 HY2 节点已清理。"
CLR
chmod +x /usr/local/sbin/hy2_clear_all.sh

echo "✅ HY2 临时高端口系统已部署完成。"
EOF

  chmod +x /root/hy2_temp_port_all.sh
}

install_port_quota() {
  echo "🧩 部署 UDP 双向配额系统（nftables，仅统计 VPS<->用户，不包含网站流量）..."
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

  /usr/local/sbin/pq_save.sh >/dev/null 2>&1 || true

  cat >/usr/local/sbin/pq_apply_port.sh <<'APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

PORT="${1:-}"
BYTES="${2:-}"

if [[ -z "$PORT" || -z "$BYTES" ]]; then
  echo "用法: pq_apply_port.sh <端口> <bytes>" >&2
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "❌ 端口必须是 1-65535 的整数" >&2
  exit 1
fi
if ! [[ "$BYTES" =~ ^[0-9]+$ ]] || (( BYTES <= 0 )); then
  echo "❌ bytes 必须是正整数" >&2
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

nft add counter inet portquota "pq_out_$PORT"
nft add counter inet portquota "pq_in_$PORT"
nft add quota inet portquota "pq_quota_$PORT" { over "$BYTES" bytes }

nft add rule inet portquota down_out udp sport "$PORT" \
  quota name "pq_quota_$PORT" drop comment "pq-drop-out-$PORT"
nft add rule inet portquota down_out udp sport "$PORT" \
  counter name "pq_out_$PORT" comment "pq-count-out-$PORT"

nft add rule inet portquota up_in udp dport "$PORT" \
  quota name "pq_quota_$PORT" drop comment "pq-drop-in-$PORT"
nft add rule inet portquota up_in udp dport "$PORT" \
  counter name "pq_in_$PORT" comment "pq-count-in-$PORT"
APPLY
  chmod +x /usr/local/sbin/pq_apply_port.sh

  cat >/usr/local/sbin/pq_add.sh <<'ADD'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

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

cat >/etc/portquota/pq-"$PORT".meta <<M
PORT=$PORT
LIMIT_BYTES=$BYTES
LIMIT_GIB=$GIB
MODE=quota
PROTO=udp
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS
AUTO_RESET=$AUTO_RESET
LAST_RESET_EPOCH=$LAST_RESET_EPOCH
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH
RESET_COUNT=$RESET_COUNT
M

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

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

LOCK="/run/portquota.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

NOW="$(date +%s)"
CHANGED=0

for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  LIMIT_GIB="$(meta_get "$META" LIMIT_GIB || true)"
  MODE="$(meta_get "$META" MODE || true)"
  PROTO="$(meta_get "$META" PROTO || true)"
  CREATE_EPOCH="$(meta_get "$META" CREATE_EPOCH || true)"
  SERVICE_SECONDS="$(meta_get "$META" SERVICE_SECONDS || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(meta_get "$META" RESET_INTERVAL_SECONDS || true)"
  AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"
  LAST_RESET_EPOCH="$(meta_get "$META" LAST_RESET_EPOCH || true)"
  NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"
  RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] || continue
  [[ "$LIMIT_GIB" =~ ^[0-9]+$ ]] || LIMIT_GIB=0
  [[ "$MODE" == "quota" ]] || continue
  [[ "$PROTO" == "udp" || -z "$PROTO" ]] || continue
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
    if ! PQ_LOCK_HELD=1 /usr/local/sbin/pq_apply_port.sh "$PORT" "$LIMIT_BYTES"; then
      echo "$(date '+%F %T %Z') [pq-reset] port=$PORT reset failed" >> /var/log/pq-save.log
      break
    fi
    LAST_RESET_EPOCH="$NEXT_RESET_EPOCH"
    NEXT_RESET_EPOCH=$((NEXT_RESET_EPOCH + RESET_INTERVAL_SECONDS))
    RESET_COUNT=$((RESET_COUNT + 1))
    DID_RESET=1
  done

  if (( NEXT_RESET_EPOCH >= EXPIRE_EPOCH )); then
    NEXT_RESET_EPOCH=0
  fi

  if (( DID_RESET == 1 )); then
    cat >"$META" <<M
PORT=$PORT
LIMIT_BYTES=$LIMIT_BYTES
LIMIT_GIB=$LIMIT_GIB
MODE=$MODE
PROTO=udp
CREATE_EPOCH=$CREATE_EPOCH
SERVICE_SECONDS=$SERVICE_SECONDS
EXPIRE_EPOCH=$EXPIRE_EPOCH
RESET_INTERVAL_SECONDS=$RESET_INTERVAL_SECONDS
AUTO_RESET=$AUTO_RESET
LAST_RESET_EPOCH=$LAST_RESET_EPOCH
NEXT_RESET_EPOCH=$NEXT_RESET_EPOCH
RESET_COUNT=$RESET_COUNT
M
    CHANGED=1
    echo "$(date '+%F %T %Z') [pq-reset] port=$PORT reset_count=$RESET_COUNT last_reset=$LAST_RESET_EPOCH" >> /var/log/pq-save.log
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

echo "✅ 已删除端口 $PORT 的配额（UDP 双向统计/限额）"
DEL
  chmod +x /usr/local/sbin/pq_del.sh

  cat >/usr/local/sbin/pq_audit.sh <<'AUDIT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub($1"=",""); print; exit}' "$file"
}

printf "%-8s %-8s %-12s %-12s %-12s %-12s %-8s %-8s %-8s %-19s %-19s\n" \
  "PORT" "STATE" "DOWN(GiB)" "UP(GiB)" "TOTAL(GiB)" "LIMIT(GiB)" "PERCENT" "RESET" "COUNT" "NEXT_RESET" "EXPIRE"

get_counter_bytes() {
  local obj="$1"
  nft list counter inet portquota "$obj" 2>/dev/null \
    | awk '/bytes/{for(i=1;i<=NF;i++) if($i=="bytes"){print $(i+1);exit}}'
}

get_quota_used_bytes() {
  local obj="$1"
  nft list quota inet portquota "$obj" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="used"){print $(i+1); exit}}'
}

fmt_epoch() {
  local ts="$1"
  if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
    date -d "@$ts" '+%F %T' 2>/dev/null || echo "$ts"
  else
    echo "-"
  fi
}

for META in /etc/portquota/pq-*.meta; do
  PORT="$(meta_get "$META" PORT || true)"
  LIMIT_BYTES="$(meta_get "$META" LIMIT_BYTES || true)"
  MODE="$(meta_get "$META" MODE || true)"
  AUTO_RESET="$(meta_get "$META" AUTO_RESET || true)"
  NEXT_RESET_EPOCH="$(meta_get "$META" NEXT_RESET_EPOCH || true)"
  RESET_COUNT="$(meta_get "$META" RESET_COUNT || true)"
  EXPIRE_EPOCH="$(meta_get "$META" EXPIRE_EPOCH || true)"

  PORT="${PORT:-}"; [[ -z "$PORT" ]] && continue
  LIMIT_BYTES="${LIMIT_BYTES:-0}"
  MODE="${MODE:-quota}"
  AUTO_RESET="${AUTO_RESET:-0}"
  NEXT_RESET_EPOCH="${NEXT_RESET_EPOCH:-0}"
  RESET_COUNT="${RESET_COUNT:-0}"
  EXPIRE_EPOCH="${EXPIRE_EPOCH:-0}"

  OUT_OBJ="pq_out_${PORT}"
  IN_OBJ="pq_in_${PORT}"
  QUOTA_OBJ="pq_quota_${PORT}"

  OUT_B="$(get_counter_bytes "$OUT_OBJ" || true)"; [[ -z "$OUT_B" ]] && OUT_B=0
  IN_B="$(get_counter_bytes "$IN_OBJ"  || true)"; [[ -z "$IN_B"  ]] && IN_B=0
  TOTAL_B=$((OUT_B + IN_B))

  DOWN_GIB="$(awk -v b="$OUT_B" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"
  UP_GIB="$(awk -v b="$IN_B"  'BEGIN{printf "%.2f",b/1024/1024/1024}')"
  TOTAL_GIB="$(awk -v b="$TOTAL_B" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"

  if [[ "$LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( LIMIT_BYTES > 0 )); then
    LIMIT_GIB="$(awk -v b="$LIMIT_BYTES" 'BEGIN{printf "%.2f",b/1024/1024/1024}')"
  else
    LIMIT_BYTES=0
    LIMIT_GIB="0.00"
  fi

  STATE="ok"
  if [[ "$MODE" == "quota" ]] && (( LIMIT_BYTES > 0 )); then
    QUOTA_USED_B="$(get_quota_used_bytes "$QUOTA_OBJ" 2>/dev/null || true)"
    if [[ "$QUOTA_USED_B" =~ ^[0-9]+$ ]] && (( QUOTA_USED_B >= LIMIT_BYTES )); then
      STATE="dropped"
    elif (( TOTAL_B >= LIMIT_BYTES )); then
      STATE="dropped"
    fi
  elif [[ "$MODE" != "quota" || "$LIMIT_BYTES" == "0" ]]; then
    STATE="track"
  fi

  if (( LIMIT_BYTES > 0 )); then
    USED_FOR_PCT="$TOTAL_B"
    if [[ "$STATE" == "dropped" ]]; then
      USED_FOR_PCT="$LIMIT_BYTES"
    elif (( USED_FOR_PCT > LIMIT_BYTES )); then
      USED_FOR_PCT="$LIMIT_BYTES"
    fi
    PCT="$(awk -v u="$USED_FOR_PCT" -v l="$LIMIT_BYTES" 'BEGIN{printf "%.1f%%",(u*100.0)/l}')"
  else
    PCT="N/A"
  fi

  RESET_FLAG="no"
  (( AUTO_RESET == 1 )) && RESET_FLAG="yes"

  printf "%-8s %-8s %-12s %-12s %-12s %-12s %-8s %-8s %-8s %-19s %-19s\n" \
    "$PORT" "$STATE" "$DOWN_GIB" "$UP_GIB" "$TOTAL_GIB" "$LIMIT_GIB" "$PCT" "$RESET_FLAG" "$RESET_COUNT" "$(fmt_epoch "$NEXT_RESET_EPOCH")" "$(fmt_epoch "$EXPIRE_EPOCH")"
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

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
}

install_logrotate_rules() {
  echo "🧩 写入 logrotate 规则（保留 2 天，压缩）..."
  cat >/etc/logrotate.d/hy2-tools <<'LR'
/var/log/pq-save.log /var/log/hy2-gc.log {
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

main() {
  check_debian12
  need_basic_tools
  download_upstreams

  install_update_all
  install_env_template
  install_hy2_main_script
  install_hy2_temp_system
  install_port_quota
  install_logrotate_rules
  install_journal_vacuum

  cat <<'DONE'
==================================================
✅ 所有脚本已生成完毕（适用于 Debian 12）

可用命令一览：

1) 系统更新 + 新内核：
   update-all
   reboot

2) 编辑主配置文件（带注释模板已生成）：
   nano /etc/default/hy2-main

3) 主 HY2 节点（443 + 正式证书 + masquerade）：
   bash /root/onekey_hy2_main_tls.sh

4) 临时高端口系统（只需部署一次）：
   bash /root/hy2_temp_port_all.sh

   部署后：
   D=600 hy2_mktemp.sh

   # 推荐：创建临时节点时直接绑定配额
   PQ_GIB=50 D=600 hy2_mktemp.sh
   PQ_GIB=50 D=$((60*86400)) hy2_mktemp.sh
   PQ_GIB=50 D=$((20*86400)) hy2_mktemp.sh

   # 临时覆盖端口范围
   TEMP_PORT_START=40000 TEMP_PORT_END=60000 D=600 hy2_mktemp.sh

   hy2_audit.sh
   hy2_clear_all.sh
   FORCE=1 hy2_cleanup_one.sh hy2-temp-YYYYMMDDHHMMSS-ABCD

5) UDP 配额系统：
   # 主节点配额
   pq_add.sh 443 500

   # 已创建节点后补配额 / 改配额
   pq_add.sh 40000 50
   pq_add.sh 40001 50 $((60*86400))
   pq_add.sh 40002 50 $((20*86400))

   pq_audit.sh
   pq_del.sh 40000

6) systemd journal 自动清理（保留 2 天）：
   systemctl status journal-vacuum.timer
==================================================
DONE
}

main "$@"
