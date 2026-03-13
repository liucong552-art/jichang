#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"
DEFAULTS_FILE="/etc/default/vless-reality"

curl_fs() {
  curl -4fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本" >&2
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || { echo "❌ 本脚本仅适用于 Debian 12 (bookworm)，当前: ${codename:-未知}" >&2; exit 1; }
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends     ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux
}

prefetch_xray_installer() {
  mkdir -p "$UP_BASE"
  if [[ ! -x "${UP_BASE}/xray-install-release.sh" ]]; then
    echo "⬇ 预下载 Xray 安装脚本到 ${UP_BASE}/xray-install-release.sh ..."
    curl_fs -L "${REPO_BASE}/xray-install-release.sh" -o "${UP_BASE}/xray-install-release.sh"
    chmod +x "${UP_BASE}/xray-install-release.sh"
  fi
}

check_debian12
need_basic_tools
prefetch_xray_installer

if [[ ! -f "$DEFAULTS_FILE" ]]; then
  install -d -m 700 /etc/default
  cat >"$DEFAULTS_FILE" <<'__VR_DEFAULTS__'
# The domain clients use to connect to this VPS.
PUBLIC_DOMAIN=

# Reality camouflage target (camouflage domain / dest / sni semantics must not change).
CAMOUFLAGE_DOMAIN=www.apple.com
REALITY_DEST=www.apple.com:443
REALITY_SNI=www.apple.com

# Main node listen port and display name.
PORT=443
NODE_NAME=VLESS-REALITY-IPv4
__VR_DEFAULTS__
  chmod 600 "$DEFAULTS_FILE"
fi

cat >'/root/onekey_reality_ipv4.sh' <<'__VR_MAIN__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

REPO_BASE="https://raw.githubusercontent.com/liucong552-art/debian12-/main"
UP_BASE="/usr/local/src/debian12-upstream"
DEFAULTS_FILE="/etc/default/vless-reality"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
MAIN_STATE_DIR="/var/lib/vless-reality/main"
MAIN_STATE_FILE="${MAIN_STATE_DIR}/main.env"

curl4() {
  curl -4fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

die() {
  echo "❌ $*" >&2
  exit 1
}

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "请以 root 身份运行"
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || die "仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 iproute2 coreutils util-linux
}

is_public_ipv4() {
  local ip="${1:-}"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = (sys.argv[1] or '').strip()
try:
    addr = ipaddress.ip_address(ip)
    if addr.version == 4 and addr.is_global:
        raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
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
      printf '%s\n' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r' || true)"
  if [[ -n "$ip" ]] && is_public_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

resolve_domain_ipv4s() {
  local domain="${1:-}"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
}

require_domain_points_here() {
  local domain="$1" current_ip="$2"
  local ok=1
  mapfile -t resolved < <(resolve_domain_ipv4s "$domain")
  (( ${#resolved[@]} > 0 )) || die "无法解析 PUBLIC_DOMAIN=${domain} 的 IPv4 A 记录"
  for ip in "${resolved[@]}"; do
    if [[ "$ip" == "$current_ip" ]]; then
      ok=0
      break
    fi
  done
  (( ok == 0 )) || {
    printf '❌ PUBLIC_DOMAIN=%s 的 DNS A 记录未指向当前 VPS IPv4=%s\n' "$domain" "$current_ip" >&2
    printf '   当前解析结果: %s\n' "${resolved[*]}" >&2
    exit 1
  }
}

load_defaults() {
  [[ -f "$DEFAULTS_FILE" ]] || die "未找到 ${DEFAULTS_FILE}"
  # shellcheck disable=SC1090
  set -a
  . "$DEFAULTS_FILE"
  set +a

  [[ -n "${PUBLIC_DOMAIN:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 PUBLIC_DOMAIN"
  PORT="${PORT:-443}"
  NODE_NAME="${NODE_NAME:-VLESS-REALITY-IPv4}"

  if [[ -n "${CAMOUFLAGE_DOMAIN:-}" ]]; then
    REALITY_DEST="${REALITY_DEST:-${CAMOUFLAGE_DOMAIN}:443}"
    REALITY_SNI="${REALITY_SNI:-${CAMOUFLAGE_DOMAIN}}"
  fi

  [[ -n "${REALITY_DEST:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 REALITY_DEST（或设置 CAMOUFLAGE_DOMAIN）"
  [[ -n "${REALITY_SNI:-}" ]] || die "${DEFAULTS_FILE} 中必须设置 REALITY_SNI（或设置 CAMOUFLAGE_DOMAIN）"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "PORT 必须是 1-65535 的整数"
}

install_xray_from_local_or_repo() {
  mkdir -p "$UP_BASE"
  local xray_installer="${UP_BASE}/xray-install-release.sh"
  if [[ ! -x "$xray_installer" ]]; then
    echo "⬇ 从仓库获取 Xray 安装脚本..."
    curl4 -L "${REPO_BASE}/xray-install-release.sh" -o "$xray_installer"
    chmod +x "$xray_installer"
  fi

  echo "⚙ 安装 / 更新 Xray-core..."
  "$xray_installer" install --without-geodata
  [[ -x /usr/local/bin/xray ]] || die "未找到 /usr/local/bin/xray，请检查安装脚本"
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

enable_bbr() {
  echo "=== 1. 启用 BBR ==="
  cat >/etc/sysctl.d/99-bbr.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
  echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
}

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

extract_reality_keys() {
  local key_out="$1"
  local private_key public_key
  private_key="$(printf '%s\n' "$key_out" | awk '
    /^PrivateKey:/   {print $2; exit}
    /^Private key:/  {print $3; exit}
  ')"
  public_key="$(printf '%s\n' "$key_out" | awk '
    /^PublicKey:/    {print $2; exit}
    /^Public key:/   {print $3; exit}
    /^Password:/     {print $2; exit}
  ')"
  [[ -n "$private_key" && -n "$public_key" ]] || return 1
  printf '%s\n%s\n' "$private_key" "$public_key"
}

write_main_config() {
  local uuid="$1" private_key="$2" short_id="$3"
  mkdir -p "$XRAY_CONFIG_DIR" "$MAIN_STATE_DIR"
  if [[ -f "$XRAY_CONFIG_FILE" ]]; then
    cp -a "$XRAY_CONFIG_FILE" "${XRAY_CONFIG_FILE}.bak.$(date +%F-%H%M%S)"
  fi

  cat >"$XRAY_CONFIG_FILE" <<CONF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "xtls-rprx-vision" }
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
          "privateKey": "${private_key}",
          "shortIds": [ "${short_id}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "routeOnly": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
CONF
  chown root:root "$XRAY_CONFIG_FILE" 2>/dev/null || true
  chmod 600 "$XRAY_CONFIG_FILE" 2>/dev/null || true
}

wait_main_stable() {
  local port="$1"
  local consecutive=0
  local attempt
  for attempt in $(seq 1 12); do
    if systemctl is-active --quiet xray.service \
      && ss -ltnH 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {found=1} END{exit !found}'
    then
      consecutive=$((consecutive + 1))
      if (( consecutive >= 3 )); then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

save_main_state() {
  local uuid="$1" private_key="$2" public_key="$3" short_id="$4"
  cat >"$MAIN_STATE_FILE" <<STATE
PUBLIC_DOMAIN=${PUBLIC_DOMAIN}
CAMOUFLAGE_DOMAIN=${CAMOUFLAGE_DOMAIN:-}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
PORT=${PORT}
NODE_NAME=${NODE_NAME}
UUID=${uuid}
PRIVATE_KEY=${private_key}
PBK=${public_key}
SHORT_ID=${short_id}
INSTALL_EPOCH=$(date +%s)
STATE
  chmod 600 "$MAIN_STATE_FILE"
}

write_subscription_outputs() {
  local uuid="$1" public_key="$2" short_id="$3"
  local pbk_q vless_url
  pbk_q="$(urlencode "$public_key")"
  vless_url="vless://${uuid}@${PUBLIC_DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${pbk_q}&sid=${short_id}#${NODE_NAME}"

  printf '%s\n' "$vless_url" >/root/vless_reality_vision_url.txt
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    printf '%s' "$vless_url" | base64 -w0 >/root/v2ray_subscription_base64.txt
  else
    printf '%s' "$vless_url" | base64 | tr -d '\n' >/root/v2ray_subscription_base64.txt
  fi
  chmod 600 /root/vless_reality_vision_url.txt /root/v2ray_subscription_base64.txt 2>/dev/null || true

  echo
  echo "================== 节点信息 =================="
  cat /root/vless_reality_vision_url.txt
  echo
  echo "Base64 订阅："
  cat /root/v2ray_subscription_base64.txt
  echo
  echo "保存位置："
  echo "  /root/vless_reality_vision_url.txt"
  echo "  /root/v2ray_subscription_base64.txt"
}

main() {
  check_debian12
  need_basic_tools
  load_defaults

  local server_ip
  server_ip="$(get_public_ipv4 || true)"
  [[ -n "$server_ip" ]] || die "无法检测到可用的公网 IPv4（可能被阻断或处于 NAT 后）"

  require_domain_points_here "$PUBLIC_DOMAIN" "$server_ip"

  echo "服务器 IPv4: ${server_ip}"
  echo "PUBLIC_DOMAIN: ${PUBLIC_DOMAIN}"
  echo "CAMOUFLAGE_DOMAIN: ${CAMOUFLAGE_DOMAIN:-}"
  echo "REALITY_DEST: ${REALITY_DEST}"
  echo "REALITY_SNI: ${REALITY_SNI}"
  echo "端口: ${PORT}"
  sleep 2

  enable_bbr

  echo
  echo "=== 2. 安装 / 更新 Xray-core ==="
  install_xray_from_local_or_repo
  force_xray_run_as_root

  systemctl stop xray.service 2>/dev/null || true

  echo
  echo "=== 3. 生成 UUID 与 Reality 密钥 ==="
  local uuid key_out private_key public_key short_id
  uuid="$(/usr/local/bin/xray uuid)"
  key_out="$(/usr/local/bin/xray x25519)"
  mapfile -t kp < <(extract_reality_keys "$key_out") || {
    echo "$key_out" >&2
    die "无法解析 xray x25519 输出"
  }
  private_key="${kp[0]}"
  public_key="${kp[1]}"
  short_id="$(openssl rand -hex 8)"

  echo
  echo "=== 4. 写入主节点配置 ==="
  write_main_config "$uuid" "$private_key" "$short_id"
  save_main_state "$uuid" "$private_key" "$public_key" "$short_id"

  echo
  echo "=== 5. 启动并验证 xray.service ==="
  systemctl daemon-reload
  systemctl enable xray.service >/dev/null 2>&1 || true
  systemctl restart xray.service

  if ! wait_main_stable "$PORT"; then
    echo "❌ xray 主节点稳定性校验失败，状态与日志如下：" >&2
    systemctl --no-pager --full status xray.service >&2 || true
    journalctl -u xray.service --no-pager -n 120 >&2 || true
    exit 1
  fi

  write_subscription_outputs "$uuid" "$public_key" "$short_id"

  echo
  echo "✅ 主节点安装完成"
  echo "   订阅地址保持使用 PUBLIC_DOMAIN=${PUBLIC_DOMAIN}"
  echo "   如果 VPS 公网 IPv4 变化，只需要更新 ${PUBLIC_DOMAIN} 的 DNS A 记录即可。"
}

main "$@"
__VR_MAIN__
chmod 755 '/root/onekey_reality_ipv4.sh'

cat >'/root/vless_temp_audit_ipv4_all.sh' <<'__VR_LATER__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行" >&2
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || { echo "❌ 仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}" >&2; exit 1; }
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux
}

check_debian12
need_basic_tools

install -d -m 755 /usr/local/lib/vless-reality /usr/local/sbin /var/lib/vless-reality /run/vless-reality /etc/tmpfiles.d

cat >'/etc/tmpfiles.d/vless-reality.conf' <<'__VR_FILE_1__'
d /run/vless-reality 0755 root root -
__VR_FILE_1__
chmod 644 '/etc/tmpfiles.d/vless-reality.conf'
systemd-tmpfiles --create /etc/tmpfiles.d/vless-reality.conf >/dev/null 2>&1 || true

cat >'/etc/systemd/system/pq-reset.service' <<'__VR_FILE_2__'
[Unit]
Description=Reset eligible managed quotas every 30 days
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset_due.sh
__VR_FILE_2__
chmod 644 '/etc/systemd/system/pq-reset.service'

cat >'/etc/systemd/system/pq-reset.timer' <<'__VR_FILE_3__'
[Unit]
Description=Check for due quota resets

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_3__
chmod 644 '/etc/systemd/system/pq-reset.timer'

cat >'/etc/systemd/system/pq-save.service' <<'__VR_FILE_4__'
[Unit]
Description=Persist managed port quota usage and rebuild counters
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
__VR_FILE_4__
chmod 644 '/etc/systemd/system/pq-save.service'

cat >'/etc/systemd/system/pq-save.timer' <<'__VR_FILE_5__'
[Unit]
Description=Run quota save every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_5__
chmod 644 '/etc/systemd/system/pq-save.timer'

cat >'/etc/systemd/system/vless-gc.service' <<'__VR_FILE_6__'
[Unit]
Description=GC expired temporary VLESS nodes
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vless_gc.sh
__VR_FILE_6__
chmod 644 '/etc/systemd/system/vless-gc.service'

cat >'/etc/systemd/system/vless-gc.timer' <<'__VR_FILE_7__'
[Unit]
Description=Run VLESS temp GC regularly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
__VR_FILE_7__
chmod 644 '/etc/systemd/system/vless-gc.timer'

cat >'/etc/systemd/system/vless-managed-restore.service' <<'__VR_FILE_8__'
[Unit]
Description=Restore managed VLESS quota and IP-limit rules
After=local-fs.target nftables.service systemd-tmpfiles-setup.service
Wants=nftables.service
Before=multi-user.target
ConditionPathIsDirectory=/var/lib/vless-reality

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/vless-reality
ExecStartPre=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/vless-reality.conf
ExecStart=/usr/local/sbin/vless_restore_all.sh

[Install]
WantedBy=multi-user.target
__VR_FILE_8__
chmod 644 '/etc/systemd/system/vless-managed-restore.service'

cat >'/etc/systemd/system/vless-managed-shutdown-save.service' <<'__VR_FILE_9__'
[Unit]
Description=Save managed VLESS quota usage before shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target kexec.target
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/vless-reality
ExecStart=/usr/local/sbin/pq_save_state.sh
TimeoutStartSec=120

[Install]
WantedBy=shutdown.target
WantedBy=halt.target
WantedBy=reboot.target
WantedBy=poweroff.target
WantedBy=kexec.target
__VR_FILE_9__
chmod 644 '/etc/systemd/system/vless-managed-shutdown-save.service'

cat >'/usr/local/lib/vless-reality/common.sh' <<'__VR_FILE_10__'
#!/usr/bin/env bash
set -Eeuo pipefail

VR_BASE_DIR="/usr/local/lib/vless-reality"
VR_STATE_DIR="/var/lib/vless-reality"
VR_MAIN_STATE_DIR="${VR_STATE_DIR}/main"
VR_TEMP_STATE_DIR="${VR_STATE_DIR}/temp"
VR_QUOTA_STATE_DIR="${VR_STATE_DIR}/quota"
VR_IPLIMIT_STATE_DIR="${VR_STATE_DIR}/iplimit"
VR_XRAY_DIR="/usr/local/etc/xray"
VR_DEFAULTS_FILE="/etc/default/vless-reality"
VR_LOCK_DIR="/run/vless-reality"
VR_MAIN_STATE_FILE="${VR_MAIN_STATE_DIR}/main.env"

vr_die() {
  echo "❌ $*" >&2
  exit 1
}

vr_require_root_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    vr_die "请以 root 身份运行"
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || vr_die "仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"
}

vr_ensure_runtime_dirs() {
  install -d -m 755 \
    "$VR_BASE_DIR" \
    "$VR_STATE_DIR" \
    "$VR_MAIN_STATE_DIR" \
    "$VR_TEMP_STATE_DIR" \
    "$VR_QUOTA_STATE_DIR" \
    "$VR_IPLIMIT_STATE_DIR" \
    "$VR_XRAY_DIR" \
    "$VR_LOCK_DIR"
}

vr_ensure_lock_dir() {
  install -d -m 755 "$VR_LOCK_DIR"
}

vr_acquire_lock_fd() {
  local fd="$1" file="$2" wait_seconds="${3:-20}" fail_msg="${4:-锁繁忙}"
  vr_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -w "$wait_seconds" "$fd" || vr_die "$fail_msg"
}

vr_try_lock_fd() {
  local fd="$1" file="$2"
  vr_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -n "$fd"
}

vr_curl4() {
  curl -4fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

vr_is_public_ipv4() {
  local ip="${1:-}"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = (sys.argv[1] or '').strip()
try:
    addr = ipaddress.ip_address(ip)
    if addr.version == 4 and addr.is_global:
        raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY
}

vr_get_public_ipv4() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(vr_curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
    if [[ -n "$ip" ]] && vr_is_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r' || true)"
  if [[ -n "$ip" ]] && vr_is_public_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

vr_load_defaults() {
  [[ -f "$VR_DEFAULTS_FILE" ]] || vr_die "未找到 ${VR_DEFAULTS_FILE}"
  # shellcheck disable=SC1090
  set -a
  . "$VR_DEFAULTS_FILE"
  set +a

  [[ -n "${PUBLIC_DOMAIN:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 PUBLIC_DOMAIN"
  PORT="${PORT:-443}"
  NODE_NAME="${NODE_NAME:-VLESS-REALITY-IPv4}"
  if [[ -n "${CAMOUFLAGE_DOMAIN:-}" ]]; then
    REALITY_DEST="${REALITY_DEST:-${CAMOUFLAGE_DOMAIN}:443}"
    REALITY_SNI="${REALITY_SNI:-${CAMOUFLAGE_DOMAIN}}"
  fi
  [[ -n "${REALITY_DEST:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 REALITY_DEST（或 CAMOUFLAGE_DOMAIN）"
  [[ -n "${REALITY_SNI:-}" ]] || vr_die "${VR_DEFAULTS_FILE} 中必须设置 REALITY_SNI（或 CAMOUFLAGE_DOMAIN）"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "PORT 必须是 1-65535 的整数"
}

vr_urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

vr_urldecode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.unquote(sys.argv[1]))
PY
}

vr_parse_gib_to_bytes() {
  python3 - "$1" <<'PY'
from decimal import Decimal, ROUND_DOWN
import sys
raw = (sys.argv[1] or '').strip()
try:
    d = Decimal(raw)
    if d <= 0:
        raise ValueError
except Exception:
    raise SystemExit(1)
bytes_val = (d * (1024 ** 3)).to_integral_value(rounding=ROUND_DOWN)
print(int(bytes_val))
PY
}

vr_base64_one_line() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

vr_meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$0 !~ /^[[:space:]]*#/ && $1==k {sub($1"=", ""); print; exit}' "$file"
}

vr_meta_upsert() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file" 2>/dev/null; then
    awk -F= -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $1 == k { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
  else
    if [[ -f "$file" ]]; then
      cat "$file" >"$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

vr_write_meta() {
  local file="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  : >"$tmp"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp"
  done
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

vr_port_is_listening() {
  local port="$1"
  ss -ltnH 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {found=1} END{exit !found}'
}

vr_wait_unit_and_port() {
  local unit="$1" port="$2"
  local need_consecutive="${3:-3}"
  local max_checks="${4:-12}"
  local consecutive=0
  local i
  for i in $(seq 1 "$max_checks"); do
    if systemctl is-active --quiet "$unit" && vr_port_is_listening "$port"; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= need_consecutive )); then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

vr_unit_state() {
  local unit="$1" state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active|reloading|inactive|failed|activating|deactivating) ;;
    "") if [[ -f "/etc/systemd/system/${unit}" || -f "/lib/systemd/system/${unit}" ]]; then state="inactive"; else state="missing"; fi ;;
    *) ;;
  esac
  printf '%s\n' "$state"
}

vr_human_bytes() {
  python3 - "$1" <<'PY'
import sys
n = int(sys.argv[1])
units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
v = float(n)
for u in units:
    if v < 1024 or u == units[-1]:
        print(f"{v:.2f}{u}")
        break
    v /= 1024.0
PY
}

vr_pct_text() {
  local used="$1" total="$2"
  python3 - "$used" "$total" <<'PY'
import sys
u = int(sys.argv[1])
t = int(sys.argv[2])
if t <= 0:
    print('N/A')
else:
    print(f"{(u * 100.0) / t:.1f}%")
PY
}

vr_ttl_human() {
  local expire_epoch="${1:-0}"
  if [[ -z "$expire_epoch" || ! "$expire_epoch" =~ ^[0-9]+$ ]]; then
    printf 'N/A\n'
    return 0
  fi
  local now left d h m s
  now="$(date +%s)"
  left=$((expire_epoch - now))
  if (( left <= 0 )); then
    printf 'expired\n'
    return 0
  fi
  d=$((left / 86400))
  h=$(((left % 86400) / 3600))
  m=$(((left % 3600) / 60))
  s=$((left % 60))
  printf '%02dd%02dh%02dm%02ds\n' "$d" "$h" "$m" "$s"
}

vr_beijing_time() {
  local epoch="${1:-0}"
  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf 'N/A\n'
    return 0
  fi
  TZ='Asia/Shanghai' date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
}

vr_safe_tag() {
  local raw="$1"
  [[ "$raw" =~ ^[A-Za-z0-9._-]+$ ]] || vr_die "非法 id/tag: ${raw}；仅允许字母、数字、点、下划线、连字符"
  printf '%s\n' "$raw"
}

vr_temp_tag_from_id() {
  local raw_id="$1"
  printf 'vless-temp-%s\n' "$raw_id"
}

vr_temp_meta_file() {
  printf '%s/%s.env\n' "$VR_TEMP_STATE_DIR" "$1"
}

vr_temp_cfg_file() {
  printf '%s/%s.json\n' "$VR_XRAY_DIR" "$1"
}

vr_temp_unit_file() {
  printf '/etc/systemd/system/%s.service\n' "$1"
}

vr_temp_url_file() {
  printf '%s/%s.url\n' "$VR_TEMP_STATE_DIR" "$1"
}

vr_quota_meta_file() {
  printf '%s/%s.env\n' "$VR_QUOTA_STATE_DIR" "$1"
}

vr_iplimit_meta_file() {
  printf '%s/%s.env\n' "$VR_IPLIMIT_STATE_DIR" "$1"
}

vr_collect_temp_tags() {
  {
    for meta in "$VR_TEMP_STATE_DIR"/*.env; do
      [[ -f "$meta" ]] || continue
      vr_meta_get "$meta" TAG || true
    done
    for unit in /etc/systemd/system/vless-temp-*.service; do
      [[ -f "$unit" ]] || continue
      basename "$unit" .service
    done
  } | awk 'NF {print}' | sort -u
}

vr_temp_owner_port_from_aux() {
  local tag="$1"
  local file port
  for file in "$VR_QUOTA_STATE_DIR"/*.env "$VR_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    if [[ "$(vr_meta_get "$file" OWNER_TAG || true)" == "$tag" ]]; then
      port="$(vr_meta_get "$file" PORT || true)"
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
  done
  return 1
}

vr_temp_port_from_any() {
  local tag="$1"
  local meta cfg port
  meta="$(vr_temp_meta_file "$tag")"
  if [[ -f "$meta" ]]; then
    port="$(vr_meta_get "$meta" PORT || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if port="$(vr_temp_owner_port_from_aux "$tag" 2>/dev/null || true)"; then
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  cfg="$(vr_temp_cfg_file "$tag")"
  if [[ -f "$cfg" ]]; then
    port="$(python3 - "$cfg" <<'PY'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        cfg = json.load(fh)
    print(cfg['inbounds'][0]['port'])
except Exception:
    pass
PY
)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  return 1
}

vr_read_main_reality() {
  local main_cfg="${VR_XRAY_DIR}/config.json"
  [[ -f "$main_cfg" ]] || vr_die "未找到主节点配置 ${main_cfg}，请先执行 /root/onekey_reality_ipv4.sh"
  python3 - "$main_cfg" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    cfg = json.load(fh)
ib = cfg.get('inbounds', [{}])[0]
rs = ib.get('streamSettings', {}).get('realitySettings', {})
sni_list = rs.get('serverNames', []) or []
print(rs.get('privateKey', ''))
print(rs.get('dest', ''))
print(sni_list[0] if sni_list else '')
print(ib.get('port', ''))
PY
}

vr_read_main_published() {
  local pbk public_domain port node_name short_id uuid
  pbk="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
  public_domain="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
  port="$(vr_meta_get "$VR_MAIN_STATE_FILE" PORT 2>/dev/null || true)"
  node_name="$(vr_meta_get "$VR_MAIN_STATE_FILE" NODE_NAME 2>/dev/null || true)"
  short_id="$(vr_meta_get "$VR_MAIN_STATE_FILE" SHORT_ID 2>/dev/null || true)"
  uuid="$(vr_meta_get "$VR_MAIN_STATE_FILE" UUID 2>/dev/null || true)"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$pbk" "$public_domain" "$port" "$node_name" "$short_id" "$uuid"
}

vr_main_url_published_pbk() {
  if [[ -f /root/vless_reality_vision_url.txt ]]; then
    sed -n '1p' /root/vless_reality_vision_url.txt 2>/dev/null | grep -o 'pbk=[^&]*' | head -n1 | cut -d= -f2
  fi
}

vr_current_public_domain() {
  local value
  value="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    vr_load_defaults >/dev/null 2>&1 || true
    value="${PUBLIC_DOMAIN:-}"
  fi
  printf '%s\n' "$value"
}
__VR_FILE_10__
chmod 644 '/usr/local/lib/vless-reality/common.sh'

cat >'/usr/local/lib/vless-reality/render_table.py' <<'__VR_FILE_11__'
#!/usr/bin/env python3
import os
import shutil
import sys
import unicodedata

SCHEMAS = {
    "vless": [
        {"name": "NAME",  "min":  8, "ideal": 15, "max": 32, "align": "left",  "weight": 10},
        {"name": "STATE", "min":  6, "ideal":  6, "max":  8, "align": "left",  "weight":  1},
        {"name": "PORT",  "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "LISN",  "min":  4, "ideal":  4, "max":  4, "align": "left",  "weight":  1},
        {"name": "QUOTA", "min":  6, "ideal":  6, "max":  6, "align": "left",  "weight":  1},
        {"name": "LIMIT", "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USED",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "LEFT",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USE%",  "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "TTL",   "min":  6, "ideal":  8, "max": 12, "align": "left",  "weight":  2},
        {"name": "EXPBJ", "min":  8, "ideal": 12, "max": 19, "align": "left",  "weight":  3},
        {"name": "IPLM",  "min":  4, "ideal":  4, "max":  4, "align": "right", "weight":  1},
        {"name": "IPACT", "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "STKY",  "min":  4, "ideal":  4, "max":  4, "align": "right", "weight":  1},
    ],
    "pq": [
        {"name": "PORT",   "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "OWNER",  "min": 10, "ideal": 20, "max": 40, "align": "left",  "weight": 10},
        {"name": "STATE",  "min":  6, "ideal":  6, "max":  8, "align": "left",  "weight":  1},
        {"name": "LIMIT",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USED",   "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "LEFT",   "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USE%",   "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "RESET",  "min":  5, "ideal":  5, "max":  8, "align": "left",  "weight":  1},
        {"name": "NEXTBJ", "min":  8, "ideal": 12, "max": 19, "align": "left",  "weight":  3},
    ],
}


def char_width(ch: str) -> int:
    if not ch or ch in "\n\r" or unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text: str) -> int:
    return sum(char_width(ch) for ch in text)


def take_prefix(text: str, width: int):
    out = []
    used = 0
    idx = 0
    while idx < len(text):
        ch = text[idx]
        if ch == "\n":
            idx += 1
            break
        w = char_width(ch)
        if used + w > width:
            break
        out.append(ch)
        used += w
        idx += 1
    return "".join(out), text[idx:]


def split_point(text: str, width: int) -> int:
    prefix, _ = take_prefix(text, width)
    if len(prefix) == len(text):
        return len(text)

    for i in range(len(prefix) - 1, -1, -1):
        ch = prefix[i]
        prev = prefix[i - 1] if i > 0 else ""

        if ch.isspace():
            return i + 1
        if ch in "/_-:@":
            return i + 1
        if i > 0 and prev.isdigit() and ch.isalpha():
            return i

    return len(prefix)


def wrap_cell(text: str, width: int):
    text = "-" if text in (None, "") else str(text)
    text = text.replace("\r", "")
    lines = []

    for part in text.split("\n"):
        part = part.strip()
        if not part:
            lines.append("")
            continue

        while part:
            if text_width(part) <= width:
                lines.append(part)
                break

            cut = split_point(part, width)
            left = part[:cut].rstrip()
            part = part[cut:].lstrip()

            if not left:
                left, part = take_prefix(part, width)

            lines.append(left)

    return lines or ["-"]


def pad(text: str, width: int, align: str):
    text = "" if text is None else str(text)
    if text_width(text) > width:
        text = take_prefix(text, width)[0]
    spaces = " " * max(0, width - text_width(text))
    return spaces + text if align == "right" else text + spaces


def border(left: str, mid: str, right: str, widths):
    return left + mid.join("━" * w for w in widths) + right


def terminal_columns() -> int:
    env_cols = os.environ.get("COLUMNS", "").strip()
    if env_cols.isdigit() and int(env_cols) > 0:
        return int(env_cols)
    return shutil.get_terminal_size(fallback=(120, 24)).columns


def allocate_widths(schema):
    mins = [c["min"] for c in schema]
    ideals = [c["ideal"] for c in schema]
    maxs = [c["max"] for c in schema]
    weights = [max(1, int(c.get("weight", 1))) for c in schema]

    widths = ideals[:]
    available = max(sum(mins), terminal_columns() - (len(schema) + 1))
    current = sum(widths)

    if current > available:
        deficit = current - available
        order = sorted(range(len(schema)), key=lambda i: (weights[i], ideals[i] - mins[i]), reverse=True)
        changed = True
        while deficit > 0 and changed:
            changed = False
            for i in order:
                if deficit <= 0:
                    break
                if widths[i] > mins[i]:
                    widths[i] -= 1
                    deficit -= 1
                    changed = True
    elif current < available:
        extra = available - current
        order = sorted(range(len(schema)), key=lambda i: (weights[i], maxs[i] - ideals[i]), reverse=True)
        changed = True
        while extra > 0 and changed:
            changed = False
            for i in order:
                if extra <= 0:
                    break
                if widths[i] < maxs[i]:
                    widths[i] += 1
                    extra -= 1
                    changed = True

    return widths


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in SCHEMAS:
        print("usage: render_table.py <vless|pq>", file=sys.stderr)
        sys.exit(2)

    schema = SCHEMAS[sys.argv[1]]
    headers = [c["name"] for c in schema]
    aligns = [c["align"] for c in schema]
    widths = allocate_widths(schema)

    rows = []
    for raw in sys.stdin:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        cols = raw.split("\t")
        if len(cols) < len(schema):
            cols += [""] * (len(schema) - len(cols))
        rows.append(cols[:len(schema)])

    if not rows:
        rows = [["-"] * len(schema)]

    print(border("┏", "┳", "┓", widths))
    print("┃" + "│".join(pad(h, w, "left") for h, w in zip(headers, widths)) + "┃")
    print(border("┣", "╋", "┫", widths))

    for idx, row in enumerate(rows):
        wrapped = [wrap_cell(col, width) for col, width in zip(row, widths)]
        height = max(len(parts) for parts in wrapped)

        for line_no in range(height):
            out = []
            for col_idx, parts in enumerate(wrapped):
                text = parts[line_no] if line_no < len(parts) else ""
                out.append(pad(text, widths[col_idx], aligns[col_idx]))
            print("┃" + "│".join(out) + "┃")

        if idx != len(rows) - 1:
            print(border("┣", "╋", "┫", widths))

    print(border("┗", "┻", "┛", widths))


if __name__ == "__main__":
    main()
__VR_FILE_11__
chmod 755 '/usr/local/lib/vless-reality/render_table.py'

cat >'/usr/local/lib/vless-reality/iplimit-lib.sh' <<'__VR_FILE_12__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

VR_IL_TABLE="vr_iplimit"
VR_IL_INPUT_CHAIN="il_input"
VR_IL_LOCK_FILE="${VR_LOCK_DIR}/iplimit.lock"

vr_il_lock() {
  if [[ "${VR_IL_LOCK_HELD:-0}" != "1" ]]; then
    vr_acquire_lock_fd 8 "$VR_IL_LOCK_FILE" 20 "iplimit 锁繁忙"
    export VR_IL_LOCK_HELD=1
  fi
}

vr_il_set_name() { printf 'vr_il_%s\n' "$1"; }
vr_il_comment_refresh() { printf 'vr-il-refresh-%s\n' "$1"; }
vr_il_comment_claim() { printf 'vr-il-claim-%s\n' "$1"; }
vr_il_comment_drop() { printf 'vr-il-drop-%s\n' "$1"; }

vr_il_meta_owner_exists() {
  local meta="$1" owner_tag owner_kind
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(vr_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  return 0
}

vr_il_ensure_base() {
  vr_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$VR_IL_TABLE" >/dev/null 2>&1 || nft add table inet "$VR_IL_TABLE"
  nft list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" '{ type filter hook input priority -10; policy accept; }'
}

vr_il_delete_rules_with_comment() {
  local comment="$1"
  nft -a list chain inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" handle "$handle" >/dev/null 2>&1 || true
      done
}

vr_il_delete_port_rules() {
  local port="$1"
  vr_il_delete_rules_with_comment "$(vr_il_comment_refresh "$port")"
  vr_il_delete_rules_with_comment "$(vr_il_comment_claim "$port")"
  vr_il_delete_rules_with_comment "$(vr_il_comment_drop "$port")"
}

vr_il_delete_port_set() {
  local port="$1"
  nft delete set inet "$VR_IL_TABLE" "$(vr_il_set_name "$port")" >/dev/null 2>&1 || true
}

vr_il_failsafe_block_port() {
  local port="$1"
  vr_il_ensure_base
  vr_il_delete_port_rules "$port"
  nft add rule inet "$VR_IL_TABLE" "$VR_IL_INPUT_CHAIN" tcp dport "$port" drop comment "$(vr_il_comment_drop "$port")" >/dev/null 2>&1 || true
}

vr_il_rebuild_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "vr_il_rebuild_port: bad port ${port}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || vr_die "vr_il_rebuild_port: bad limit ${ip_limit}"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || vr_die "vr_il_rebuild_port: bad sticky ${sticky_seconds}"

  vr_il_lock
  vr_il_ensure_base
  vr_il_delete_port_rules "$port"
  vr_il_delete_port_set "$port"

  if ! nft -f - <<EOF_RULES
add set inet ${VR_IL_TABLE} $(vr_il_set_name "$port") { type ipv4_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} tcp dport ${port} ip saddr @$(vr_il_set_name "$port") update @$(vr_il_set_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_refresh "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} tcp dport ${port} add @$(vr_il_set_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(vr_il_comment_claim "$port")"
add rule inet ${VR_IL_TABLE} ${VR_IL_INPUT_CHAIN} tcp dport ${port} drop comment "$(vr_il_comment_drop "$port")"
EOF_RULES
  then
    vr_il_failsafe_block_port "$port"
    return 1
  fi
}

vr_il_write_meta() {
  local port="$1" owner_kind="$2" owner_tag="$3" ip_limit="$4" sticky_seconds="$5"
  vr_write_meta "$(vr_iplimit_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "IP_LIMIT=${ip_limit}" \
    "IP_STICKY_SECONDS=${sticky_seconds}" \
    "SET_NAME=$(vr_il_set_name "$port")" \
    "CREATED_EPOCH=$(date +%s)"
}

vr_il_add_managed_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3" owner_kind="${4:-temp}" owner_tag="${5:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "端口必须为整数"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || vr_die "IP_LIMIT 必须为正整数"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || vr_die "IP_STICKY_SECONDS 必须为正整数"
  vr_il_lock
  vr_il_ensure_base
  vr_il_write_meta "$port" "$owner_kind" "$owner_tag" "$ip_limit" "$sticky_seconds"
  vr_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

vr_il_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  vr_il_lock
  if nft list table inet "$VR_IL_TABLE" >/dev/null 2>&1; then
    vr_il_delete_port_rules "$port"
    vr_il_delete_port_set "$port"
  fi
  rm -f "$(vr_iplimit_meta_file "$port")"
}

vr_il_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_il_meta_owner_exists "$meta" || return 0
  local port ip_limit sticky_seconds
  port="$(vr_meta_get "$meta" PORT || true)"
  ip_limit="$(vr_meta_get "$meta" IP_LIMIT || true)"
  sticky_seconds="$(vr_meta_get "$meta" IP_STICKY_SECONDS || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || return 0
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || return 0
  vr_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

vr_il_active_ips() {
  local port="$1" set_name
  set_name="$(vr_il_set_name "$port")"
  nft list set inet "$VR_IL_TABLE" "$set_name" 2>/dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | awk '!seen[$0]++' \
    | xargs echo -n
  printf '\n'
}

vr_il_active_count() {
  local port="$1" ips
  ips="$(vr_il_active_ips "$port" || true)"
  if [[ -z "$ips" ]]; then
    printf '0\n'
  else
    wc -w <<<"$ips" | tr -d ' '
  fi
}

vr_il_state() {
  local port="$1" meta
  meta="$(vr_iplimit_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  if nft list set inet "$VR_IL_TABLE" "$(vr_il_set_name "$port")" >/dev/null 2>&1; then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}
__VR_FILE_12__
chmod 644 '/usr/local/lib/vless-reality/iplimit-lib.sh'

cat >'/usr/local/lib/vless-reality/quota-lib.sh' <<'__VR_FILE_13__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

VR_PQ_TABLE="vr_pq"
VR_PQ_INPUT_CHAIN="pq_input"
VR_PQ_OUTPUT_CHAIN="pq_output"
VR_PQ_LOCK_FILE="${VR_LOCK_DIR}/portquota.lock"

vr_pq_lock() {
  if [[ "${VR_PQ_LOCK_HELD:-0}" != "1" ]]; then
    vr_acquire_lock_fd 9 "$VR_PQ_LOCK_FILE" 20 "portquota 锁繁忙"
    export VR_PQ_LOCK_HELD=1
  fi
}

vr_pq_counter_in() { printf 'vr_pq_in_%s\n' "$1"; }
vr_pq_counter_out() { printf 'vr_pq_out_%s\n' "$1"; }
vr_pq_quota_obj() { printf 'vr_pq_q_%s\n' "$1"; }
vr_pq_comment_count_in() { printf 'vr-pq-count-in-%s\n' "$1"; }
vr_pq_comment_count_out() { printf 'vr-pq-count-out-%s\n' "$1"; }
vr_pq_comment_drop_in() { printf 'vr-pq-drop-in-%s\n' "$1"; }
vr_pq_comment_drop_out() { printf 'vr-pq-drop-out-%s\n' "$1"; }

vr_pq_meta_owner_exists() {
  local meta="$1"
  local owner_tag owner_kind
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(vr_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  return 0
}

vr_pq_ensure_base() {
  vr_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$VR_PQ_TABLE" >/dev/null 2>&1 || nft add table inet "$VR_PQ_TABLE"
  nft list chain inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" '{ type filter hook input priority 0; policy accept; }'
  nft list chain inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" '{ type filter hook output priority 0; policy accept; }'
}

vr_pq_delete_rules_with_comment() {
  local chain="$1" comment="$2"
  nft -a list chain inet "$VR_PQ_TABLE" "$chain" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$VR_PQ_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || true
      done
}

vr_pq_delete_port_rules() {
  local port="$1"
  vr_pq_delete_rules_with_comment "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_drop_in "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_INPUT_CHAIN" "$(vr_pq_comment_count_in "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_drop_out "$port")"
  vr_pq_delete_rules_with_comment "$VR_PQ_OUTPUT_CHAIN" "$(vr_pq_comment_count_out "$port")"
}

vr_pq_delete_port_objects() {
  local port="$1"
  nft delete counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_in "$port")" >/dev/null 2>&1 || true
  nft delete counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_out "$port")" >/dev/null 2>&1 || true
  nft delete quota inet "$VR_PQ_TABLE" "$(vr_pq_quota_obj "$port")" >/dev/null 2>&1 || true
}

vr_pq_failsafe_block_port() {
  local port="$1"
  vr_pq_ensure_base
  vr_pq_delete_port_rules "$port"
  vr_pq_delete_port_objects "$port"
  nft add rule inet "$VR_PQ_TABLE" "$VR_PQ_INPUT_CHAIN" tcp dport "$port" drop comment "$(vr_pq_comment_drop_in "$port")" >/dev/null 2>&1 || true
  nft add rule inet "$VR_PQ_TABLE" "$VR_PQ_OUTPUT_CHAIN" tcp sport "$port" drop comment "$(vr_pq_comment_drop_out "$port")" >/dev/null 2>&1 || true
}

vr_pq_rebuild_port() {
  local port="$1" remaining_bytes="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "vr_pq_rebuild_port: bad port ${port}"
  [[ "$remaining_bytes" =~ ^[0-9]+$ ]] || vr_die "vr_pq_rebuild_port: bad remaining ${remaining_bytes}"

  vr_pq_lock
  vr_pq_ensure_base
  vr_pq_delete_port_rules "$port"
  vr_pq_delete_port_objects "$port"

  if (( remaining_bytes > 0 )); then
    if ! nft -f - <<EOF_RULES
add counter inet ${VR_PQ_TABLE} $(vr_pq_counter_in "$port")
add counter inet ${VR_PQ_TABLE} $(vr_pq_counter_out "$port")
add quota inet ${VR_PQ_TABLE} $(vr_pq_quota_obj "$port") { over ${remaining_bytes} bytes used 0 bytes }
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} quota name "$(vr_pq_quota_obj "$port")" drop comment "$(vr_pq_comment_drop_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} counter name "$(vr_pq_counter_in "$port")" comment "$(vr_pq_comment_count_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} quota name "$(vr_pq_quota_obj "$port")" drop comment "$(vr_pq_comment_drop_out "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} counter name "$(vr_pq_counter_out "$port")" comment "$(vr_pq_comment_count_out "$port")"
EOF_RULES
    then
      vr_pq_failsafe_block_port "$port"
      return 1
    fi
  else
    if ! nft -f - <<EOF_RULES
add rule inet ${VR_PQ_TABLE} ${VR_PQ_INPUT_CHAIN} tcp dport ${port} drop comment "$(vr_pq_comment_drop_in "$port")"
add rule inet ${VR_PQ_TABLE} ${VR_PQ_OUTPUT_CHAIN} tcp sport ${port} drop comment "$(vr_pq_comment_drop_out "$port")"
EOF_RULES
    then
      vr_pq_failsafe_block_port "$port"
      return 1
    fi
  fi
}

vr_pq_counter_bytes() {
  local obj="$1"
  nft list counter inet "$VR_PQ_TABLE" "$obj" 2>/dev/null \
    | awk '/bytes/ { for (i = 1; i <= NF; i++) if ($i == "bytes") { gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit } }'
}

vr_pq_live_used_bytes() {
  local port="$1"
  local in_b out_b
  in_b="$(vr_pq_counter_bytes "$(vr_pq_counter_in "$port")" || true)"
  out_b="$(vr_pq_counter_bytes "$(vr_pq_counter_out "$port")" || true)"
  in_b="${in_b:-0}"
  out_b="${out_b:-0}"
  [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
  [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
  printf '%s\n' $((in_b + out_b))
}

vr_pq_state() {
  local port="$1"
  local meta="$(vr_quota_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  local original saved live used left
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left <= 0 )); then
    printf 'exhausted\n'
    return 0
  fi
  if nft list counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_in "$port")" >/dev/null 2>&1 \
    && nft list counter inet "$VR_PQ_TABLE" "$(vr_pq_counter_out "$port")" >/dev/null 2>&1 \
    && nft list quota inet "$VR_PQ_TABLE" "$(vr_pq_quota_obj "$port")" >/dev/null 2>&1
  then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}

vr_pq_write_meta() {
  local port="$1" original="$2" saved="$3" remaining="$4" owner_kind="$5" owner_tag="$6" duration_seconds="$7" expire_epoch="$8" next_reset_epoch="$9" interval_seconds="${10}" created_epoch="${11}" last_reset_epoch="${12}" last_save_epoch="${13}"
  vr_write_meta "$(vr_quota_meta_file "$port")" \
    "PORT=${port}" \
    "ORIGINAL_LIMIT_BYTES=${original}" \
    "SAVED_USED_BYTES=${saved}" \
    "LIMIT_BYTES=${remaining}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "DURATION_SECONDS=${duration_seconds}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "RESET_INTERVAL_SECONDS=${interval_seconds}" \
    "NEXT_RESET_EPOCH=${next_reset_epoch}" \
    "CREATED_EPOCH=${created_epoch}" \
    "LAST_RESET_EPOCH=${last_reset_epoch}" \
    "LAST_SAVE_EPOCH=${last_save_epoch}"
}

vr_pq_add_managed_port() {
  local port="$1" original_bytes="$2" owner_kind="${3:-manual}" owner_tag="${4:-}" duration_seconds="${5:-0}" expire_epoch="${6:-0}"
  [[ "$port" =~ ^[0-9]+$ ]] || vr_die "端口必须为整数"
  [[ "$original_bytes" =~ ^[0-9]+$ ]] || vr_die "original_bytes 必须为整数"
  (( original_bytes > 0 )) || vr_die "配额必须大于 0"

  vr_pq_lock
  vr_pq_ensure_base

  local created_epoch interval_seconds next_reset_epoch
  created_epoch="$(date +%s)"
  interval_seconds=0
  next_reset_epoch=0
  if [[ "$duration_seconds" =~ ^[0-9]+$ ]] && (( duration_seconds > 2592000 )); then
    interval_seconds=2592000
    next_reset_epoch=$((created_epoch + interval_seconds))
  fi

  vr_pq_write_meta "$port" "$original_bytes" 0 "$original_bytes" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "$created_epoch" 0 "$created_epoch"
  vr_pq_rebuild_port "$port" "$original_bytes"
}

vr_pq_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  vr_pq_lock
  if nft list table inet "$VR_PQ_TABLE" >/dev/null 2>&1; then
    vr_pq_delete_port_rules "$port"
    vr_pq_delete_port_objects "$port"
  fi
  rm -f "$(vr_quota_meta_file "$port")"
}

vr_pq_save_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0

  local port original saved live new_saved left next_reset_epoch interval_seconds created_epoch last_reset_epoch owner_kind owner_tag duration_seconds expire_epoch
  port="$(vr_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(vr_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  next_reset_epoch="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  interval_seconds="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  created_epoch="$(vr_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(vr_meta_get "$meta" LAST_RESET_EPOCH || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  new_saved=$((saved + live))
  if (( new_saved > original )); then
    new_saved="$original"
  fi
  left=$((original - new_saved))
  if (( left < 0 )); then
    left=0
  fi
  vr_pq_write_meta "$port" "$original" "$new_saved" "$left" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "${next_reset_epoch:-0}" "${interval_seconds:-0}" "${created_epoch:-$(date +%s)}" "${last_reset_epoch:-0}" "$(date +%s)"
  vr_pq_rebuild_port "$port" "$left"
}

vr_pq_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0
  local port remaining
  port="$(vr_meta_get "$meta" PORT || true)"
  remaining="$(vr_meta_get "$meta" LIMIT_BYTES || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  vr_pq_rebuild_port "$port" "$remaining"
}

vr_pq_reset_due_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  vr_pq_meta_owner_exists "$meta" || return 0

  local port original owner_kind owner_tag duration_seconds expire_epoch interval_seconds next_reset_epoch created_epoch now last_reset_epoch
  port="$(vr_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  owner_kind="$(vr_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(vr_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(vr_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  interval_seconds="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  next_reset_epoch="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  created_epoch="$(vr_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(vr_meta_get "$meta" LAST_RESET_EPOCH || true)"

  [[ "$interval_seconds" =~ ^[0-9]+$ ]] || interval_seconds=0
  (( interval_seconds > 0 )) || return 0
  now="$(date +%s)"
  [[ "$next_reset_epoch" =~ ^[0-9]+$ ]] || next_reset_epoch=0
  (( next_reset_epoch > 0 )) || return 0
  if [[ "$expire_epoch" =~ ^[0-9]+$ ]] && (( expire_epoch > 0 && expire_epoch <= now )); then
    return 0
  fi
  (( now >= next_reset_epoch )) || return 0

  while (( next_reset_epoch <= now )); do
    next_reset_epoch=$((next_reset_epoch + interval_seconds))
  done

  vr_pq_write_meta "$port" "$original" 0 "$original" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "${created_epoch:-$now}" "$now" "$now"
  vr_pq_rebuild_port "$port" "$original"
}
__VR_FILE_13__
chmod 644 '/usr/local/lib/vless-reality/quota-lib.sh'

cat >'/usr/local/sbin/iplimit_restore_all.sh' <<'__VR_FILE_14__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

vr_ensure_runtime_dirs
vr_il_lock
rc=0
for meta in "$VR_IPLIMIT_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_il_restore_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_14__
chmod 755 '/usr/local/sbin/iplimit_restore_all.sh'

cat >'/usr/local/sbin/pq_add.sh' <<'__VR_FILE_15__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

PORT="${1:-}"
GIB="${2:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: pq_add.sh <端口> <GiB>"
[[ -n "$GIB" ]] || vr_die "用法: pq_add.sh <端口> <GiB>"
BYTES="$(vr_parse_gib_to_bytes "$GIB")" || vr_die "GiB 必须为正数"
vr_pq_add_managed_port "$PORT" "$BYTES" manual ""
echo "✅ 已为端口 ${PORT} 设置总配额 $(vr_human_bytes "$BYTES")"
__VR_FILE_15__
chmod 755 '/usr/local/sbin/pq_add.sh'

cat >'/usr/local/sbin/pq_audit.sh' <<'__VR_FILE_16__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  PORT="$(vr_meta_get "$meta" PORT || true)"
  OWNER_KIND="$(vr_meta_get "$meta" OWNER_KIND || true)"
  OWNER_TAG="$(vr_meta_get "$meta" OWNER_TAG || true)"
  ORIGINAL="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  SAVED="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  NEXT_RESET_EPOCH="$(vr_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(vr_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"

  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  ORIGINAL="${ORIGINAL:-0}"
  SAVED="${SAVED:-0}"
  LIVE="$(vr_pq_live_used_bytes "$PORT" || true)"
  LIVE="${LIVE:-0}"
  USED=$((SAVED + LIVE))
  LEFT=$((ORIGINAL - USED))
  if (( LEFT < 0 )); then
    LEFT=0
  fi
  OWNER="${OWNER_KIND:-manual}"
  if [[ -n "$OWNER_TAG" ]]; then
    OWNER="${OWNER_KIND:-manual}:${OWNER_TAG}"
  fi
  STATE="$(vr_pq_state "$PORT")"
  if [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && (( RESET_INTERVAL_SECONDS > 0 )); then
    RESET='30d'
    NEXT_RESET_BJ="$(vr_beijing_time "$NEXT_RESET_EPOCH")"
  else
    RESET='-'
    NEXT_RESET_BJ='-'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PORT" \
    "$OWNER" \
    "$STATE" \
    "$(vr_human_bytes "$ORIGINAL")" \
    "$(vr_human_bytes "$USED")" \
    "$(vr_human_bytes "$LEFT")" \
    "$(vr_pct_text "$USED" "$ORIGINAL")" \
    "$RESET" \
    "$NEXT_RESET_BJ" >>"$TMP_ROWS"
done

sort -t $'\t' -k1,1n "$TMP_ROWS" | /usr/local/lib/vless-reality/render_table.py pq
__VR_FILE_16__
chmod 755 '/usr/local/sbin/pq_audit.sh'

cat >'/usr/local/sbin/pq_del.sh' <<'__VR_FILE_17__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: pq_del.sh <端口>"
vr_pq_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的配额管理"
__VR_FILE_17__
chmod 755 '/usr/local/sbin/pq_del.sh'

cat >'/usr/local/sbin/ip_set.sh' <<'__VR_FILE_IP_SET__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

PORT="${1:-}"
IP_LIMIT="${2:-}"
STICKY_SECONDS="${3:-}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: ip_set.sh <端口> <limit> [sticky_seconds]"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] && (( IP_LIMIT > 0 )) || vr_die "limit 必须是正整数"

META="$(vr_iplimit_meta_file "$PORT")"
OWNER_KIND="manual"
OWNER_TAG=""

if [[ -f "$META" ]]; then
  OWNER_KIND="$(vr_meta_get "$META" OWNER_KIND || true)"
  OWNER_TAG="$(vr_meta_get "$META" OWNER_TAG || true)"
  if [[ -z "$STICKY_SECONDS" ]]; then
    STICKY_SECONDS="$(vr_meta_get "$META" IP_STICKY_SECONDS || true)"
  fi
fi

if [[ -z "$OWNER_TAG" ]]; then
  for TEMP_META in "$VR_TEMP_STATE_DIR"/*.env; do
    [[ -f "$TEMP_META" ]] || continue
    TEMP_PORT="$(vr_meta_get "$TEMP_META" PORT || true)"
    if [[ "$TEMP_PORT" == "$PORT" ]]; then
      OWNER_KIND="temp"
      OWNER_TAG="$(vr_meta_get "$TEMP_META" TAG || true)"
      break
    fi
  done
fi

STICKY_SECONDS="${STICKY_SECONDS:-120}"
[[ "$STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( STICKY_SECONDS > 0 )) || vr_die "sticky_seconds 必须是正整数"
[[ -n "$OWNER_KIND" ]] || OWNER_KIND="manual"

vr_il_add_managed_port "$PORT" "$IP_LIMIT" "$STICKY_SECONDS" "$OWNER_KIND" "$OWNER_TAG"
echo "✅ 已将端口 ${PORT} 的 IP_LIMIT 设为 ${IP_LIMIT}（STICKY=${STICKY_SECONDS}s）"
__VR_FILE_IP_SET__
chmod 755 '/usr/local/sbin/ip_set.sh'

cat >'/usr/local/sbin/ip_del.sh' <<'__VR_FILE_IP_DEL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || vr_die "用法: ip_del.sh <端口>"
vr_il_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的 IP 限制管理"
__VR_FILE_IP_DEL__
chmod 755 '/usr/local/sbin/ip_del.sh'


cat >'/usr/local/sbin/pq_reset_due.sh' <<'__VR_FILE_18__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_reset_due_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_18__
chmod 755 '/usr/local/sbin/pq_reset_due.sh'

cat >'/usr/local/sbin/pq_restore_all.sh' <<'__VR_FILE_19__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_restore_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_19__
chmod 755 '/usr/local/sbin/pq_restore_all.sh'

cat >'/usr/local/sbin/pq_save_state.sh' <<'__VR_FILE_20__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh

vr_ensure_runtime_dirs
vr_pq_lock
rc=0
for meta in "$VR_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  vr_pq_save_one "$meta" || rc=1
done
exit "$rc"
__VR_FILE_20__
chmod 755 '/usr/local/sbin/pq_save_state.sh'

cat >'/usr/local/sbin/vless_audit.sh' <<'__VR_FILE_21__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

FILTER_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      FILTER_TAG="${2:-}"
      shift 2
      ;;
    *)
      vr_die "未知参数: $1"
      ;;
  esac
done

quota_summary() {
  local port="$1"
  local meta state original saved live used left
  meta="$(vr_quota_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf 'none|-|-|-|-\n'
    return 0
  fi
  original="$(vr_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(vr_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(vr_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left < 0 )); then
    left=0
  fi
  state="$(vr_pq_state "$port")"
  printf '%s|%s|%s|%s|%s\n' \
    "$state" \
    "$(vr_human_bytes "$original")" \
    "$(vr_human_bytes "$used")" \
    "$(vr_human_bytes "$left")" \
    "$(vr_pct_text "$used" "$original")"
}

ip_summary() {
  local port="$1"
  local meta ip_limit sticky active_count
  meta="$(vr_iplimit_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf '%s\n' '-|-|-'
    return 0
  fi
  ip_limit="$(vr_meta_get "$meta" IP_LIMIT || true)"
  sticky="$(vr_meta_get "$meta" IP_STICKY_SECONDS || true)"
  active_count="$(vr_il_active_count "$port" || true)"
  printf '%s|%s|%s\n' "${ip_limit:-0}" "${active_count:-0}" "${sticky:-0}"
}

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

if [[ -z "$FILTER_TAG" ]]; then
  MAIN_PORT="$(vr_meta_get "$VR_MAIN_STATE_FILE" PORT 2>/dev/null || true)"
  if [[ ! "$MAIN_PORT" =~ ^[0-9]+$ ]]; then
    vr_load_defaults >/dev/null 2>&1 || true
    MAIN_PORT="${PORT:-443}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "main/xray.service" \
    "$(vr_unit_state xray.service)" \
    "$MAIN_PORT" \
    "$(if vr_port_is_listening "$MAIN_PORT"; then echo yes; else echo no; fi)" \
    "none" "-" "-" "-" "-" "permanent" "-" "-" "-" "-" >>"$TMP_ROWS"
fi

FOUND=0
for TAG in $(vr_collect_temp_tags); do
  [[ -n "$TAG" ]] || continue
  if [[ -n "$FILTER_TAG" && "$TAG" != "$FILTER_TAG" ]]; then
    continue
  fi
  FOUND=1
  META="$(vr_temp_meta_file "$TAG")"
  PORT="$(vr_temp_port_from_any "$TAG" 2>/dev/null || true)"
  UNIT_STATE="$(vr_unit_state "${TAG}.service")"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && vr_port_is_listening "$PORT"; then
    LISTEN="yes"
  else
    LISTEN="no"
  fi

  if [[ -f "$META" ]]; then
    EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
    TTL_TEXT="$(vr_ttl_human "$EXPIRE_EPOCH")"
    EXPIRE_BJ="$(vr_beijing_time "$EXPIRE_EPOCH")"
  else
    TTL_TEXT="missing"
    EXPIRE_BJ="missing"
  fi

  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    IFS='|' read -r QUOTA_STATE LIMIT USED LEFT USEP < <(quota_summary "$PORT")
    IFS='|' read -r IPLIM IPACT STICKY < <(ip_summary "$PORT")
  else
    QUOTA_STATE="none"
    LIMIT="-"
    USED="-"
    LEFT="-"
    USEP="-"
    IPLIM="-"
    IPACT="-"
    STICKY="-"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TAG" \
    "$UNIT_STATE" \
    "${PORT:--}" \
    "$LISTEN" \
    "$QUOTA_STATE" \
    "$LIMIT" \
    "$USED" \
    "$LEFT" \
    "$USEP" \
    "$TTL_TEXT" \
    "$EXPIRE_BJ" \
    "$IPLIM" \
    "$IPACT" \
    "$STICKY" >>"$TMP_ROWS"
done

if [[ -n "$FILTER_TAG" && "$FOUND" -eq 0 ]]; then
  exit 1
fi

sort -t $'\t' -k1,1 "$TMP_ROWS" | /usr/local/lib/vless-reality/render_table.py vless
__VR_FILE_21__
chmod 755 '/usr/local/sbin/vless_audit.sh'

cat >'/usr/local/sbin/vless_cleanup_one.sh' <<'__VR_FILE_22__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

TAG="${1:?need TAG}"
MODE="${2:-}"
FORCE="${FORCE:-0}"
META="$(vr_temp_meta_file "$TAG")"
CFG="$(vr_temp_cfg_file "$TAG")"
UNIT_FILE="$(vr_temp_unit_file "$TAG")"
URL_FILE="$(vr_temp_url_file "$TAG")"
UNIT_NAME="${TAG}.service"
FROM_STOP_POST=0
[[ "$MODE" == "--from-stop-post" ]] && FROM_STOP_POST=1

if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  if (( FROM_STOP_POST == 1 )); then
    if ! vr_try_lock_fd 7 "${VR_LOCK_DIR}/temp.lock"; then
      exit 0
    fi
  else
    vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
  fi
  export VR_TEMP_LOCK_HELD=1
fi

PORT="$(vr_temp_port_from_any "$TAG" 2>/dev/null || true)"

if (( FROM_STOP_POST == 1 )) && [[ "$FORCE" != "1" ]] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
  vr_pq_save_one "$(vr_quota_meta_file "$PORT")" >/dev/null 2>&1 || true
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW="$(date +%s)"
    if (( EXPIRE_EPOCH > NOW )); then
      exit 0
    fi
  fi
fi

if systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1 || [[ -f "$UNIT_FILE" ]]; then
  if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    timeout 15 systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || systemctl kill "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
fi

if [[ "$PORT" =~ ^[0-9]+$ ]]; then
  VR_PQ_LOCK_HELD=0 vr_pq_delete_managed_port "$PORT" || true
  VR_IL_LOCK_HELD=0 vr_il_delete_managed_port "$PORT" || true
fi

rm -f "$CFG" "$META" "$UNIT_FILE" "$URL_FILE"
systemctl daemon-reload >/dev/null 2>&1 || true
__VR_FILE_22__
chmod 755 '/usr/local/sbin/vless_cleanup_one.sh'

cat >'/usr/local/sbin/vless_clear_all.sh' <<'__VR_FILE_23__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

vr_ensure_runtime_dirs
vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
export VR_TEMP_LOCK_HELD=1

mapfile -t TAGS < <(vr_collect_temp_tags)

for tag in "${TAGS[@]:-}"; do
  [[ -n "$tag" ]] || continue
  FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$tag" || true
done

systemctl daemon-reload >/dev/null 2>&1 || true
__VR_FILE_23__
chmod 755 '/usr/local/sbin/vless_clear_all.sh'

cat >'/usr/local/sbin/vless_gc.sh' <<'__VR_FILE_24__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

vr_ensure_runtime_dirs
if ! vr_try_lock_fd 7 "${VR_LOCK_DIR}/temp.lock"; then
  exit 0
fi
export VR_TEMP_LOCK_HELD=1

NOW="$(date +%s)"
for meta in "$VR_TEMP_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  TAG="$(vr_meta_get "$meta" TAG || true)"
  EXPIRE_EPOCH="$(vr_meta_get "$meta" EXPIRE_EPOCH || true)"
  [[ -n "$TAG" ]] || continue
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || continue
  if (( EXPIRE_EPOCH <= NOW )); then
    FORCE=1 VR_TEMP_LOCK_HELD=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" || true
  fi
done
__VR_FILE_24__
chmod 755 '/usr/local/sbin/vless_gc.sh'

cat >'/usr/local/sbin/vless_mktemp.sh' <<'__VR_FILE_25__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/iplimit-lib.sh

: "${D:?请用 D=秒 vless_mktemp.sh 调用，例如：id=tmp001 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh}"
[[ "$D" =~ ^[0-9]+$ ]] && (( D > 0 )) || vr_die "D 必须是正整数秒"

RAW_ID="${id:-tmp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)}"
SAFE_ID="$(vr_safe_tag "$RAW_ID")"
TAG="$(vr_temp_tag_from_id "$SAFE_ID")"
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-50050}"
MAX_START_RETRIES="${MAX_START_RETRIES:-12}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
PQ_GIB="${PQ_GIB:-}"

[[ "$PORT_START" =~ ^[0-9]+$ ]] && [[ "$PORT_END" =~ ^[0-9]+$ ]] && (( PORT_START >= 1 && PORT_END <= 65535 && PORT_START <= PORT_END )) || \
  vr_die "PORT_START/PORT_END 无效"
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] && (( MAX_START_RETRIES > 0 )) || vr_die "MAX_START_RETRIES 必须是正整数"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] || vr_die "IP_LIMIT 必须是非负整数"
[[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( IP_STICKY_SECONDS > 0 )) || vr_die "IP_STICKY_SECONDS 必须是正整数"

vr_ensure_runtime_dirs
if [[ "${VR_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  vr_acquire_lock_fd 7 "${VR_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
  export VR_TEMP_LOCK_HELD=1
fi

EXIST_META="$(vr_temp_meta_file "$TAG")"
if [[ -f "$EXIST_META" ]]; then
  EXIST_EXPIRE="$(vr_meta_get "$EXIST_META" EXPIRE_EPOCH || true)"
  if [[ "$EXIST_EXPIRE" =~ ^[0-9]+$ ]] && (( EXIST_EXPIRE <= $(date +%s) )); then
    FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  else
    vr_die "临时节点 ${TAG} 已存在"
  fi
fi

mapfile -t MAIN_INFO < <(vr_read_main_reality)
REALITY_PRIVATE_KEY="${MAIN_INFO[0]:-}"
REALITY_DEST="${MAIN_INFO[1]:-}"
REALITY_SNI="${MAIN_INFO[2]:-}"
MAIN_PORT="${MAIN_INFO[3]:-}"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_DEST" ]] || vr_die "无法从主节点读取 Reality 参数"
[[ -n "$REALITY_SNI" ]] || REALITY_SNI="${REALITY_DEST%%:*}"

PUBLISHED_DOMAIN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PUBLIC_DOMAIN 2>/dev/null || true)"
if [[ -z "$PUBLISHED_DOMAIN" ]]; then
  vr_load_defaults
  PUBLISHED_DOMAIN="$PUBLIC_DOMAIN"
fi
[[ -n "$PUBLISHED_DOMAIN" ]] || vr_die "无法获取主节点 PUBLIC_DOMAIN"

PBK_IN="${PBK:-}"
if [[ -z "$PBK_IN" ]]; then
  PBK_IN="$(vr_meta_get "$VR_MAIN_STATE_FILE" PBK 2>/dev/null || true)"
fi
if [[ -z "$PBK_IN" ]]; then
  PBK_IN="$(vr_main_url_published_pbk 2>/dev/null || true)"
fi
[[ -n "$PBK_IN" ]] || vr_die "无法获取主节点 PBK，请先运行 /root/onekey_reality_ipv4.sh 或手动传入 PBK=<...>"
PBK_RAW="$(vr_urldecode "$PBK_IN")"

PQ_LIMIT_BYTES=""
if [[ -n "$PQ_GIB" ]]; then
  PQ_LIMIT_BYTES="$(vr_parse_gib_to_bytes "$PQ_GIB")" || vr_die "PQ_GIB 必须是正数"
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( PQ_LIMIT_BYTES > 0 )) || vr_die "PQ_GIB 转换失败"
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
  [[ -n "$(vr_meta_get "$meta" EXPIRE_EPOCH || true)" ]]
  [[ -n "$(vr_meta_get "$meta" PORT || true)" ]]
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta="$(vr_quota_meta_file "$port")"
    [[ -f "$qmeta" ]]
    [[ -n "$(vr_meta_get "$qmeta" ORIGINAL_LIMIT_BYTES || true)" ]]
    [[ -n "$(vr_meta_get "$qmeta" SAVED_USED_BYTES || true)" ]]
    [[ -n "$(vr_meta_get "$qmeta" LIMIT_BYTES || true)" ]]
  fi
  if (( IP_LIMIT > 0 )); then
    local imeta="$(vr_iplimit_meta_file "$port")"
    [[ -f "$imeta" ]]
    [[ -n "$(vr_meta_get "$imeta" IP_LIMIT || true)" ]]
    [[ -n "$(vr_meta_get "$imeta" IP_STICKY_SECONDS || true)" ]]
  fi
  /usr/local/sbin/vless_audit.sh --tag "$TAG" >/dev/null 2>&1
}

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
  [[ -n "$PORT" ]] || vr_die "在 ${PORT_START}-${PORT_END} 范围内没有空闲端口"

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
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ]
}
CONF
  chmod 600 "$CFG" 2>/dev/null || true

  vr_write_meta "$META" \
    "TAG=${TAG}" \
    "ID=${SAFE_ID}" \
    "PORT=${PORT}" \
    "PUBLIC_DOMAIN=${PUBLISHED_DOMAIN}" \
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
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}"

  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Temporary VLESS ${TAG}
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

  if ! validate_full_state "$META" "$PORT"; then
    if systemctl is-active --quiet "${TAG}.service" 2>/dev/null && vr_port_is_listening "$PORT"; then
      echo "⚠ validate_full_state 失败，但节点已成功启动；为避免重复创建，跳过重试" >&2
    else
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  PBK_Q="$(vr_urlencode "$PBK_RAW")"
  VLESS_URL="vless://${UUID}@${PUBLISHED_DOMAIN}:${PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&pbk=${PBK_Q}&sid=${SHORT_ID}#${TAG}"
  printf '%s\n' "$VLESS_URL" >"$URL_FILE"
  chmod 600 "$URL_FILE" 2>/dev/null || true

  echo "✅ 临时节点创建成功"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "TTL: $(vr_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(vr_beijing_time "$EXPIRE_EPOCH")"
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

vr_die "临时节点创建失败，已回滚（尝试次数: ${MAX_START_RETRIES}）"
__VR_FILE_25__
chmod 755 '/usr/local/sbin/vless_mktemp.sh'

cat >'/usr/local/sbin/vless_restore_all.sh' <<'__VR_FILE_26__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

rc=0
/usr/local/sbin/vless_gc.sh || rc=1
/usr/local/sbin/pq_restore_all.sh || rc=1
/usr/local/sbin/iplimit_restore_all.sh || rc=1
exit "$rc"
__VR_FILE_26__
chmod 755 '/usr/local/sbin/vless_restore_all.sh'

cat >'/usr/local/sbin/vless_run_temp.sh' <<'__VR_FILE_27__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/vless-reality/common.sh

TAG="${1:?need TAG}"
CFG="${2:?need CONFIG}"
META="$(vr_temp_meta_file "$TAG")"
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"

[[ -x "$XRAY_BIN" ]] || vr_die "未找到 xray 可执行文件"
[[ -f "$CFG" ]] || vr_die "配置不存在: ${CFG}"
[[ -f "$META" ]] || vr_die "meta 不存在: ${META}"

EXPIRE_EPOCH="$(vr_meta_get "$META" EXPIRE_EPOCH || true)"
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || vr_die "bad EXPIRE_EPOCH in ${META}"

NOW="$(date +%s)"
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  FORCE=1 /usr/local/sbin/vless_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  exit 0
fi

exec timeout --foreground "$REMAIN" "$XRAY_BIN" run -c "$CFG"
__VR_FILE_27__
chmod 755 '/usr/local/sbin/vless_run_temp.sh'

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now nftables >/dev/null 2>&1 || true
systemctl enable --now vless-gc.timer >/dev/null 2>&1 || true
systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
systemctl enable vless-managed-restore.service >/dev/null 2>&1 || true
systemctl start vless-managed-restore.service >/dev/null 2>&1 || true
systemctl enable vless-managed-shutdown-save.service >/dev/null 2>&1 || true

cat <<'USE'
✅ Later modules installed/refreshed:
  - temporary VLESS node system
  - nftables port quota save/restore/reset
  - source-IP slot limiting
  - read-only audit scripts
  - GC/save/reset/restore/shutdown-save systemd automation

Commands:
  id=tmp001 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
  vless_audit.sh
  pq_audit.sh
  vless_clear_all.sh
  pq_add.sh <port> <GiB>
  pq_del.sh <port>
USE
__VR_LATER__
chmod 755 '/root/vless_temp_audit_ipv4_all.sh'

bash /root/vless_temp_audit_ipv4_all.sh

cat <<'DONE'
==================================================
✅ Fresh implementation written.

Files:
  /etc/default/vless-reality
  /root/onekey_reality_ipv4.sh
  /root/vless_temp_audit_ipv4_all.sh

Main node flow was kept separate:
  1) Edit /etc/default/vless-reality
  2) bash /root/onekey_reality_ipv4.sh

Later modules are installed and can also be refreshed independently with:
  bash /root/vless_temp_audit_ipv4_all.sh

Most-used commands:
  id=tmp001 IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
  vless_audit.sh
  pq_audit.sh
  vless_clear_all.sh
==================================================
DONE
