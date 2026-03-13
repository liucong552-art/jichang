#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

SELF_COPY="/root/onekey_hy2_managed.sh"
ENV_FILE="/etc/default/hy2-main"
UP_BASE="/usr/local/src/hy2-managed"
MODE="${1:-install-all}"

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本" >&2
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || { echo "❌ 本脚本仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}" >&2; exit 1; }
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables iproute2 coreutils util-linux \
    certbot logrotate systemd-sysv grep sed gawk procps
}

cache_self_copy() {
  install -d -m 700 /root
  if [[ -r "${BASH_SOURCE[0]}" ]]; then
    cat "${BASH_SOURCE[0]}" > "$SELF_COPY"
    chmod 700 "$SELF_COPY"
  fi
}

install_base_dirs() {
  install -d -m 755 /usr/local/lib/hy2 /usr/local/sbin /etc/systemd/system /etc/tmpfiles.d /etc/logrotate.d
  install -d -m 700 /var/lib/hy2 /var/lib/hy2/main /var/lib/hy2/temp /var/lib/hy2/quota /var/lib/hy2/iplimit
  install -d -m 700 /etc/hysteria /etc/hysteria/temp
  install -d -m 755 /run/hy2
}

env_upsert_key() {
  local file="$1" key="$2" value="$3" q tmp
  printf -v q '%q' "$value"
  tmp="$(mktemp)"
  if [[ -f "$file" ]] && grep -q "^${key}=" "$file" 2>/dev/null; then
    awk -v k="$key" -v q="$q" -F= '
      BEGIN { done = 0 }
      $1 == k { print k "=" q; done = 1; next }
      { print }
      END { if (!done) print k "=" q }
    ' "$file" >"$tmp"
  else
    [[ -f "$file" ]] && cat "$file" >"$tmp"
    printf '%s=%s\n' "$key" "$q" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
}

apply_env_overrides() {
  [[ -f "$ENV_FILE" ]] || return 0
  local keys=(
    HY_DOMAIN HY_LISTEN ACME_EMAIL MASQ_URL ENABLE_SALAMANDER SALAMANDER_PASSWORD NODE_NAME
    TEMP_PORT_START TEMP_PORT_END
  )
  local k v
  for k in "${keys[@]}"; do
    if [[ "${!k+x}" == "x" && -n "${!k}" ]]; then
      v="${!k}"
      env_upsert_key "$ENV_FILE" "$k" "$v"
    fi
  done
  if [[ "${ENABLE_SALAMANDER+x}" == "x" && "${ENABLE_SALAMANDER}" == "0" ]]; then
    env_upsert_key "$ENV_FILE" ENABLE_SALAMANDER "0"
  fi
}

main_env_ready() {
  [[ -f "$ENV_FILE" ]] || return 1
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
  [[ -n "${HY_DOMAIN:-}" && "${HY_DOMAIN:-}" != "hy2.example.com" ]] || return 1
  [[ -n "${ACME_EMAIL:-}" ]] || return 1
  [[ -n "${MASQ_URL:-}" ]] || return 1
  [[ "${ENABLE_SALAMANDER:-0}" =~ ^[01]$ ]] || return 1
  if [[ "${ENABLE_SALAMANDER:-0}" == "1" && -z "${SALAMANDER_PASSWORD:-}" ]]; then
    return 1
  fi
  return 0
}

enable_bbr() {
  cat >/etc/sysctl.d/99-bbr.conf <<'__HY_BBR__'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
__HY_BBR__
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
}

fetch_hysteria_installer() {
  install -d -m 755 "$UP_BASE"
  curl -fsSL "https://get.hy2.sh/" -o "${UP_BASE}/get_hy2.sh"
  chmod 700 "${UP_BASE}/get_hy2.sh"
}

install_hysteria_binary() {
  fetch_hysteria_installer
  bash "${UP_BASE}/get_hy2.sh"
  command -v hysteria >/dev/null 2>&1 || { echo "❌ 未找到 hysteria 可执行文件" >&2; exit 1; }
  systemctl stop hysteria.service >/dev/null 2>&1 || true
  systemctl disable hysteria.service >/dev/null 2>&1 || true
  systemctl stop hysteria-server.service >/dev/null 2>&1 || true
  systemctl disable hysteria-server.service >/dev/null 2>&1 || true
}

install_update_all() {
  cat >/usr/local/bin/update-all <<'__HY_UPDATE_ALL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本" >&2
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || { echo "❌ 本脚本仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}" >&2; exit 1; }
}

check_debian12
export DEBIAN_FRONTEND=noninteractive

echo "🚀 开始系统更新..."
apt-get update -o Acquire::Retries=3
apt-get full-upgrade -y
apt-get --purge autoremove -y
apt-get autoclean -y
apt-get clean -y

BACKPORTS_FILE=/etc/apt/sources.list.d/backports.list
if [[ -f "$BACKPORTS_FILE" ]]; then
  cp "$BACKPORTS_FILE" "${BACKPORTS_FILE}.bak.$(date +%F-%H%M%S)"
fi
cat >"$BACKPORTS_FILE" <<'__HY_BACKPORTS__'
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
__HY_BACKPORTS__

apt-get update -o Acquire::Retries=3

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) img=linux-image-amd64; hdr=linux-headers-amd64 ;;
  arm64) img=linux-image-arm64; hdr=linux-headers-arm64 ;;
  *)
    echo "❌ 未支持架构: $arch" >&2
    exit 1
    ;;
esac

apt-get -t bookworm-backports install -y "$img" "$hdr"

echo "✅ 更新完成"
echo "🖥 当前内核: $(uname -r)"
echo "⚠️ 如需切换到新内核，请执行：reboot"
__HY_UPDATE_ALL__
  chmod 755 /usr/local/bin/update-all
}

install_env_template() {
  local tpl_domain="${HY_DOMAIN:-hy2.example.com}"
  local tpl_listen="${HY_LISTEN:-:443}"
  local tpl_email="${ACME_EMAIL:-}"
  local tpl_masq="${MASQ_URL:-https://www.apple.com/}"
  local tpl_obfs="${ENABLE_SALAMANDER:-0}"
  local tpl_obfs_pwd="${SALAMANDER_PASSWORD:-}"
  local tpl_name="${NODE_NAME:-HY2-MAIN}"
  local tpl_ps="${TEMP_PORT_START:-40000}"
  local tpl_pe="${TEMP_PORT_END:-50050}"

  if [[ ! -f "$ENV_FILE" ]]; then
    cat >"$ENV_FILE" <<__HY_ENV__
# ==================================================
# HY2 受管系统主配置
# ==================================================
# - 主节点固定使用正式证书 + 密码鉴权 + masquerade
# - 临时节点复用同一张正式证书，独立高端口，受管到期退出
# - 如使用 Cloudflare，请保持 DNS only（灰云）
# - certbot standalone 申请证书时需要 TCP 80 可达

HY_DOMAIN=${tpl_domain}
HY_LISTEN=${tpl_listen}
ACME_EMAIL=${tpl_email}
MASQ_URL=${tpl_masq}
ENABLE_SALAMANDER=${tpl_obfs}
SALAMANDER_PASSWORD=${tpl_obfs_pwd}
NODE_NAME=${tpl_name}
TEMP_PORT_START=${tpl_ps}
TEMP_PORT_END=${tpl_pe}
__HY_ENV__
  fi
  chmod 600 "$ENV_FILE"
  apply_env_overrides
}

install_tmpfiles() {
  cat >/etc/tmpfiles.d/hy2.conf <<'__HY_TMPFILES__'
d /run/hy2 0755 root root -
__HY_TMPFILES__
  chmod 644 /etc/tmpfiles.d/hy2.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/hy2.conf >/dev/null 2>&1 || true
}

write_common_lib() {
  cat >/usr/local/lib/hy2/common.sh <<'__HY_COMMON__'
#!/usr/bin/env bash
set -Eeuo pipefail

HY_LIB_DIR="/usr/local/lib/hy2"
HY_STATE_DIR="/var/lib/hy2"
HY_MAIN_DIR="${HY_STATE_DIR}/main"
HY_TEMP_DIR="${HY_STATE_DIR}/temp"
HY_QUOTA_DIR="${HY_STATE_DIR}/quota"
HY_IPLIMIT_DIR="${HY_STATE_DIR}/iplimit"
HY_RUN_DIR="/run/hy2"
HY_CFG_DIR="/etc/hysteria"
HY_TEMP_CFG_DIR="${HY_CFG_DIR}/temp"
HY_DEFAULTS_FILE="/etc/default/hy2-main"
HY_MAIN_CFG_FILE="${HY_CFG_DIR}/config-main.yaml"
HY_MAIN_SERVICE_FILE="/etc/systemd/system/hy2.service"
HY_MAIN_STATE_FILE="${HY_MAIN_DIR}/main.env"
HY_MAIN_PASSWORD_FILE="${HY_MAIN_DIR}/main.password"

hy_die() {
  echo "❌ $*" >&2
  exit 1
}

hy_log() {
  echo "[$(date '+%F %T')] $*" >&2
}

hy_require_root_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    hy_die "请以 root 身份运行"
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || hy_die "仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"
}

hy_ensure_runtime_dirs() {
  install -d -m 755 "$HY_LIB_DIR" "$HY_RUN_DIR"
  install -d -m 700 "$HY_STATE_DIR" "$HY_MAIN_DIR" "$HY_TEMP_DIR" "$HY_QUOTA_DIR" "$HY_IPLIMIT_DIR" "$HY_CFG_DIR" "$HY_TEMP_CFG_DIR"
}

hy_ensure_lock_dir() {
  install -d -m 755 "$HY_RUN_DIR"
}

hy_acquire_lock_fd() {
  local fd="$1" file="$2" wait_seconds="${3:-20}" fail_msg="${4:-锁繁忙}"
  hy_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -w "$wait_seconds" "$fd" || hy_die "$fail_msg"
}

hy_try_lock_fd() {
  local fd="$1" file="$2"
  hy_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -n "$fd"
}

hy_curl4() {
  curl -4fsS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 "$@"
}

hy_is_public_ipv4() {
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

hy_get_public_ipv4() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(hy_curl4 "$url" 2>/dev/null | tr -d ' \n\r' || true)"
    if [[ -n "$ip" ]] && hy_is_public_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r' || true)"
  if [[ -n "$ip" ]] && hy_is_public_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

hy_resolve_domain_ipv4s() {
  local domain="${1:-}"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
}

hy_require_domain_points_here() {
  local domain="$1" current_ip="$2"
  local ok=1
  mapfile -t resolved < <(hy_resolve_domain_ipv4s "$domain")
  (( ${#resolved[@]} > 0 )) || hy_die "无法解析 ${domain} 的 IPv4 A 记录"
  local ip
  for ip in "${resolved[@]}"; do
    if [[ "$ip" == "$current_ip" ]]; then
      ok=0
      break
    fi
  done
  (( ok == 0 )) || hy_die "${domain} 的 DNS A 记录未指向当前 VPS IPv4=${current_ip}；当前解析：${resolved[*]}"
}

hy_load_env() {
  [[ -f "$HY_DEFAULTS_FILE" ]] || hy_die "未找到 ${HY_DEFAULTS_FILE}"
  # shellcheck disable=SC1090
  set -a
  . "$HY_DEFAULTS_FILE"
  set +a
  HY_DOMAIN="${HY_DOMAIN:-}"
  HY_LISTEN="${HY_LISTEN:-:443}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  MASQ_URL="${MASQ_URL:-}"
  ENABLE_SALAMANDER="${ENABLE_SALAMANDER:-0}"
  SALAMANDER_PASSWORD="${SALAMANDER_PASSWORD:-}"
  NODE_NAME="${NODE_NAME:-HY2-MAIN}"
  TEMP_PORT_START="${TEMP_PORT_START:-40000}"
  TEMP_PORT_END="${TEMP_PORT_END:-50050}"
}

hy_require_main_env_ready() {
  hy_load_env
  [[ -n "$HY_DOMAIN" && "$HY_DOMAIN" != "hy2.example.com" ]] || hy_die "请先在 ${HY_DEFAULTS_FILE} 中设置 HY_DOMAIN"
  [[ -n "$ACME_EMAIL" ]] || hy_die "请先在 ${HY_DEFAULTS_FILE} 中设置 ACME_EMAIL"
  [[ -n "$MASQ_URL" ]] || hy_die "请先在 ${HY_DEFAULTS_FILE} 中设置 MASQ_URL"
  [[ "$ENABLE_SALAMANDER" =~ ^[01]$ ]] || hy_die "ENABLE_SALAMANDER 只能是 0 或 1"
  if [[ "$ENABLE_SALAMANDER" == "1" && -z "$SALAMANDER_PASSWORD" ]]; then
    hy_die "ENABLE_SALAMANDER=1 时必须设置 SALAMANDER_PASSWORD"
  fi
}

hy_yaml_quote() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
print("'" + s.replace("'", "''") + "'")
PY
}

hy_urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

hy_parse_gib_to_bytes() {
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
print(int((d * (1024 ** 3)).to_integral_value(rounding=ROUND_DOWN)))
PY
}

hy_base64_one_line() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

hy_meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$0 !~ /^[[:space:]]*#/ && $1==k {sub($1"=", ""); print; exit}' "$file"
}

hy_meta_upsert() {
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
    [[ -f "$file" ]] && cat "$file" >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

hy_write_meta() {
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

hy_human_bytes() {
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

hy_pct_text() {
  local used="$1" total="$2"
  python3 - "$used" "$total" <<'PY'
import sys
u = int(sys.argv[1])
t = int(sys.argv[2])
if t <= 0:
    print('-')
else:
    print(f"{(u * 100.0) / t:.1f}%")
PY
}

hy_ttl_human() {
  local expire_epoch="${1:-0}"
  if [[ -z "$expire_epoch" || ! "$expire_epoch" =~ ^[0-9]+$ ]]; then
    printf '-\n'
    return 0
  fi
  local now left d h m s
  now="$(date +%s)"
  left=$((expire_epoch - now))
  if (( left <= 0 )); then
    printf '已过期\n'
    return 0
  fi
  d=$((left / 86400))
  h=$(((left % 86400) / 3600))
  m=$(((left % 3600) / 60))
  s=$((left % 60))
  printf '%02dd%02dh%02dm%02ds\n' "$d" "$h" "$m" "$s"
}

hy_beijing_time() {
  local epoch="${1:-0}"
  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf '-\n'
    return 0
  fi
  TZ='Asia/Shanghai' date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
}

hy_safe_id() {
  local raw="$1"
  [[ "$raw" =~ ^[A-Za-z0-9._-]+$ ]] || hy_die "非法 id/tag: ${raw}；仅允许字母、数字、点、下划线、连字符"
  printf '%s\n' "$raw"
}

hy_temp_tag_from_id() { printf 'hy2-temp-%s\n' "$1"; }
hy_temp_meta_file() { printf '%s/%s.env\n' "$HY_TEMP_DIR" "$1"; }
hy_temp_cfg_file() { printf '%s/%s.yaml\n' "$HY_TEMP_CFG_DIR" "$1"; }
hy_temp_unit_file() { printf '/etc/systemd/system/%s.service\n' "$1"; }
hy_temp_url_file() { printf '%s/%s.url\n' "$HY_TEMP_DIR" "$1"; }
hy_temp_aux_file() { printf '%s/%s.aux\n' "$HY_TEMP_DIR" "$1"; }
hy_quota_meta_file() { printf '%s/%s.env\n' "$HY_QUOTA_DIR" "$1"; }
hy_iplimit_meta_file() { printf '%s/%s.env\n' "$HY_IPLIMIT_DIR" "$1"; }

hy_unit_state() {
  local unit="$1" state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active|reloading|inactive|failed|activating|deactivating) ;;
    "")
      if [[ -f "/etc/systemd/system/${unit}" || -f "/lib/systemd/system/${unit}" ]]; then
        state="inactive"
      else
        state="missing"
      fi
      ;;
    *) ;;
  esac
  printf '%s\n' "$state"
}

hy_udp_port_is_listening() {
  local port="$1"
  ss -lunH 2>/dev/null | awk '{print $5}' | sed -nE 's/.*:([0-9]+)$/\1/p' | grep -qx "$port"
}

hy_wait_unit_and_udp_port() {
  local unit="$1" port="$2" need_consecutive="${3:-3}" max_checks="${4:-12}"
  local consecutive=0 i
  for i in $(seq 1 "$max_checks"); do
    if systemctl is-active --quiet "$unit" && hy_udp_port_is_listening "$port"; then
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

hy_cfg_listen_port() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 1
  awk -F: '/^listen:[[:space:]]*/ {print $NF; exit}' "$cfg" | tr -d '[:space:][]'
}

hy_main_listen_port() {
  local port=""
  if [[ -f "$HY_MAIN_STATE_FILE" ]]; then
    port="$(hy_meta_get "$HY_MAIN_STATE_FILE" PORT || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if [[ -f "$HY_DEFAULTS_FILE" ]]; then
    hy_load_env >/dev/null 2>&1 || true
    if [[ "${HY_LISTEN:-}" =~ ([0-9]+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  if [[ -f "$HY_MAIN_CFG_FILE" ]]; then
    port="$(hy_cfg_listen_port "$HY_MAIN_CFG_FILE" || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  printf '443\n'
}

hy_collect_temp_tags() {
  {
    local meta unit
    for meta in "$HY_TEMP_DIR"/*.env; do
      [[ -f "$meta" ]] || continue
      hy_meta_get "$meta" TAG || true
    done
    for unit in /etc/systemd/system/hy2-temp-*.service; do
      [[ -f "$unit" ]] || continue
      basename "$unit" .service
    done
  } | awk 'NF {print}' | sort -u
}

hy_temp_owner_port_from_aux() {
  local tag="$1" file port
  for file in "$HY_QUOTA_DIR"/*.env "$HY_IPLIMIT_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    if [[ "$(hy_meta_get "$file" OWNER_TAG || true)" == "$tag" ]]; then
      port="$(hy_meta_get "$file" PORT || true)"
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
  done
  return 1
}

hy_temp_port_from_any() {
  local tag="$1" meta cfg port
  meta="$(hy_temp_meta_file "$tag")"
  if [[ -f "$meta" ]]; then
    port="$(hy_meta_get "$meta" PORT || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if port="$(hy_temp_owner_port_from_aux "$tag" 2>/dev/null || true)"; then
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  cfg="$(hy_temp_cfg_file "$tag")"
  if [[ -f "$cfg" ]]; then
    port="$(hy_cfg_listen_port "$cfg" || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  return 1
}

hy_main_exists() {
  local port
  port="$(hy_main_listen_port || true)"
  [[ -n "$port" && -f "$HY_MAIN_STATE_FILE" ]] || [[ -f "$HY_MAIN_CFG_FILE" ]]
}

hy_owner_from_port() {
  local port="$1" main_port tag meta p
  main_port="$(hy_main_listen_port || true)"
  if [[ "$port" == "$main_port" ]] && hy_main_exists; then
    printf 'main\thy2-main\n'
    return 0
  fi
  for meta in "$HY_TEMP_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    p="$(hy_meta_get "$meta" PORT || true)"
    if [[ "$p" == "$port" ]]; then
      tag="$(hy_meta_get "$meta" TAG || true)"
      printf 'temp\t%s\n' "$tag"
      return 0
    fi
  done
  printf 'manual\t\n'
}

hy_temp_url_from_meta() {
  local meta="$1"
  [[ -f "$meta" ]] || return 1
  local auth domain port sni tag obfs_enabled obfs_password auth_q name_q
  auth="$(hy_meta_get "$meta" AUTH_PASSWORD || true)"
  domain="$(hy_meta_get "$meta" PUBLISHED_DOMAIN || true)"
  port="$(hy_meta_get "$meta" PORT || true)"
  sni="$(hy_meta_get "$meta" SNI || true)"
  tag="$(hy_meta_get "$meta" TAG || true)"
  obfs_enabled="$(hy_meta_get "$meta" OBFS_ENABLED || true)"
  obfs_password="$(hy_meta_get "$meta" OBFS_PASSWORD || true)"
  [[ -n "$auth" && -n "$domain" && "$port" =~ ^[0-9]+$ ]] || return 1
  auth_q="$(hy_urlencode "$auth")"
  name_q="$(hy_urlencode "$tag")"
  if [[ "$obfs_enabled" == "1" ]]; then
    printf 'hy2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s#%s\n' \
      "$auth_q" "$domain" "$port" "$sni" "$(hy_urlencode "$obfs_password")" "$name_q"
  else
    printf 'hy2://%s@%s:%s/?sni=%s#%s\n' "$auth_q" "$domain" "$port" "$sni" "$name_q"
  fi
}

hy_write_temp_url_aux_from_meta() {
  local meta="$1"
  [[ -f "$meta" ]] || return 1
  local tag port url url_file aux_file expire_epoch expire_bj pq_limit ip_limit sticky
  tag="$(hy_meta_get "$meta" TAG || true)"
  port="$(hy_meta_get "$meta" PORT || true)"
  expire_epoch="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
  pq_limit="$(hy_meta_get "$meta" PQ_LIMIT_BYTES || true)"
  ip_limit="$(hy_meta_get "$meta" IP_LIMIT || true)"
  sticky="$(hy_meta_get "$meta" IP_STICKY_SECONDS || true)"
  [[ -n "$tag" && "$port" =~ ^[0-9]+$ ]] || return 1
  url="$(hy_temp_url_from_meta "$meta")" || return 1
  url_file="$(hy_temp_url_file "$tag")"
  aux_file="$(hy_temp_aux_file "$tag")"
  expire_bj="$(hy_beijing_time "$expire_epoch")"
  printf '%s\n' "$url" >"$url_file"
  chmod 600 "$url_file" 2>/dev/null || true
  hy_write_meta "$aux_file" \
    "TAG=${tag}" \
    "PORT=${port}" \
    "URL=${url}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "EXPIRE_BJ=${expire_bj}" \
    "PQ_LIMIT_BYTES=${pq_limit:-0}" \
    "IP_LIMIT=${ip_limit:-0}" \
    "IP_STICKY_SECONDS=${sticky:-0}"
}

hy_main_url_from_state() {
  [[ -f "$HY_MAIN_STATE_FILE" ]] || return 1
  local auth domain port sni node obfs_enabled obfs_password auth_q node_q
  auth="$(cat "$HY_MAIN_PASSWORD_FILE" 2>/dev/null | tr -d '\r\n' || true)"
  domain="$(hy_meta_get "$HY_MAIN_STATE_FILE" HY_DOMAIN || true)"
  port="$(hy_meta_get "$HY_MAIN_STATE_FILE" PORT || true)"
  sni="$(hy_meta_get "$HY_MAIN_STATE_FILE" SNI || true)"
  node="$(hy_meta_get "$HY_MAIN_STATE_FILE" NODE_NAME || true)"
  obfs_enabled="$(hy_meta_get "$HY_MAIN_STATE_FILE" OBFS_ENABLED || true)"
  obfs_password="$(hy_meta_get "$HY_MAIN_STATE_FILE" OBFS_PASSWORD || true)"
  [[ -n "$auth" && -n "$domain" && "$port" =~ ^[0-9]+$ ]] || return 1
  auth_q="$(hy_urlencode "$auth")"
  node_q="$(hy_urlencode "$node")"
  if [[ "$obfs_enabled" == "1" ]]; then
    printf 'hy2://%s@%s:%s/?sni=%s&obfs=salamander&obfs-password=%s#%s\n' \
      "$auth_q" "$domain" "$port" "$sni" "$(hy_urlencode "$obfs_password")" "$node_q"
  else
    printf 'hy2://%s@%s:%s/?sni=%s#%s\n' "$auth_q" "$domain" "$port" "$sni" "$node_q"
  fi
}
__HY_COMMON__
  chmod 644 /usr/local/lib/hy2/common.sh
}

write_quota_lib() {
  cat >/usr/local/lib/hy2/quota-lib.sh <<'__HY_QUOTA_LIB__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

HY_PQ_TABLE="hy2_pq"
HY_PQ_INPUT_CHAIN="input"
HY_PQ_OUTPUT_CHAIN="output"
HY_PQ_LOCK_FILE="${HY_RUN_DIR}/portquota.lock"

hy_pq_lock() {
  if [[ "${HY_PQ_LOCK_HELD:-0}" != "1" ]]; then
    hy_acquire_lock_fd 9 "$HY_PQ_LOCK_FILE" 20 "quota 锁繁忙"
    export HY_PQ_LOCK_HELD=1
  fi
}

hy_pq_counter_in() { printf 'hy2_pq_in_%s\n' "$1"; }
hy_pq_counter_out() { printf 'hy2_pq_out_%s\n' "$1"; }
hy_pq_quota_obj() { printf 'hy2_pq_q_%s\n' "$1"; }
hy_pq_comment_count_in() { printf 'hy2-pq-count-in-%s\n' "$1"; }
hy_pq_comment_count_out() { printf 'hy2-pq-count-out-%s\n' "$1"; }
hy_pq_comment_drop_in() { printf 'hy2-pq-drop-in-%s\n' "$1"; }
hy_pq_comment_drop_out() { printf 'hy2-pq-drop-out-%s\n' "$1"; }

hy_pq_meta_owner_exists() {
  local meta="$1" owner_tag owner_kind port main_port
  owner_tag="$(hy_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(hy_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  port="$(hy_meta_get "$meta" PORT 2>/dev/null || true)"
  case "$owner_kind" in
    temp)
      [[ -n "$owner_tag" ]] || return 1
      [[ -f "$(hy_temp_meta_file "$owner_tag")" ]] || return 1
      ;;
    main)
      main_port="$(hy_main_listen_port || true)"
      [[ "$port" == "$main_port" ]] || return 1
      hy_main_exists || return 1
      ;;
    manual|"")
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

hy_pq_ensure_base() {
  hy_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$HY_PQ_TABLE" >/dev/null 2>&1 || nft add table inet "$HY_PQ_TABLE"
  nft list chain inet "$HY_PQ_TABLE" "$HY_PQ_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY_PQ_TABLE" "$HY_PQ_INPUT_CHAIN" '{ type filter hook input priority 0; policy accept; }'
  nft list chain inet "$HY_PQ_TABLE" "$HY_PQ_OUTPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY_PQ_TABLE" "$HY_PQ_OUTPUT_CHAIN" '{ type filter hook output priority 0; policy accept; }'
}

hy_pq_reset_runtime() {
  hy_pq_lock
  nft delete table inet "$HY_PQ_TABLE" >/dev/null 2>&1 || true
  hy_pq_ensure_base
}

hy_pq_delete_rules_with_comment() {
  local chain="$1" comment="$2"
  nft -a list chain inet "$HY_PQ_TABLE" "$chain" 2>/dev/null \
    | awk -v c="comment \\\""comment"\\\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$HY_PQ_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || true
      done
}

hy_pq_delete_port_rules() {
  local port="$1"
  hy_pq_delete_rules_with_comment "$HY_PQ_INPUT_CHAIN" "$(hy_pq_comment_drop_in "$port")"
  hy_pq_delete_rules_with_comment "$HY_PQ_INPUT_CHAIN" "$(hy_pq_comment_count_in "$port")"
  hy_pq_delete_rules_with_comment "$HY_PQ_OUTPUT_CHAIN" "$(hy_pq_comment_drop_out "$port")"
  hy_pq_delete_rules_with_comment "$HY_PQ_OUTPUT_CHAIN" "$(hy_pq_comment_count_out "$port")"
}

hy_pq_delete_port_objects() {
  local port="$1"
  nft delete counter inet "$HY_PQ_TABLE" "$(hy_pq_counter_in "$port")" >/dev/null 2>&1 || true
  nft delete counter inet "$HY_PQ_TABLE" "$(hy_pq_counter_out "$port")" >/dev/null 2>&1 || true
  nft delete quota inet "$HY_PQ_TABLE" "$(hy_pq_quota_obj "$port")" >/dev/null 2>&1 || true
}

hy_pq_failsafe_block_port() {
  local port="$1"
  hy_pq_ensure_base
  hy_pq_delete_port_rules "$port"
  hy_pq_delete_port_objects "$port"
  nft add rule inet "$HY_PQ_TABLE" "$HY_PQ_INPUT_CHAIN" udp dport "$port" drop comment "$(hy_pq_comment_drop_in "$port")" >/dev/null 2>&1 || true
  nft add rule inet "$HY_PQ_TABLE" "$HY_PQ_OUTPUT_CHAIN" udp sport "$port" drop comment "$(hy_pq_comment_drop_out "$port")" >/dev/null 2>&1 || true
}

hy_pq_rebuild_port() {
  local port="$1" remaining_bytes="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || hy_die "hy_pq_rebuild_port: 端口非法 ${port}"
  [[ "$remaining_bytes" =~ ^[0-9]+$ ]] || hy_die "hy_pq_rebuild_port: 配额非法 ${remaining_bytes}"

  hy_pq_lock
  hy_pq_ensure_base
  hy_pq_delete_port_rules "$port"
  hy_pq_delete_port_objects "$port"

  if (( remaining_bytes > 0 )); then
    if ! nft -f - <<EOF_RULES
add counter inet ${HY_PQ_TABLE} $(hy_pq_counter_in "$port")
add counter inet ${HY_PQ_TABLE} $(hy_pq_counter_out "$port")
add quota inet ${HY_PQ_TABLE} $(hy_pq_quota_obj "$port") { over ${remaining_bytes} bytes }
add rule inet ${HY_PQ_TABLE} ${HY_PQ_INPUT_CHAIN} udp dport ${port} quota name "$(hy_pq_quota_obj "$port")" drop comment "$(hy_pq_comment_drop_in "$port")"
add rule inet ${HY_PQ_TABLE} ${HY_PQ_INPUT_CHAIN} udp dport ${port} counter name "$(hy_pq_counter_in "$port")" comment "$(hy_pq_comment_count_in "$port")"
add rule inet ${HY_PQ_TABLE} ${HY_PQ_OUTPUT_CHAIN} udp sport ${port} quota name "$(hy_pq_quota_obj "$port")" drop comment "$(hy_pq_comment_drop_out "$port")"
add rule inet ${HY_PQ_TABLE} ${HY_PQ_OUTPUT_CHAIN} udp sport ${port} counter name "$(hy_pq_counter_out "$port")" comment "$(hy_pq_comment_count_out "$port")"
EOF_RULES
    then
      hy_pq_failsafe_block_port "$port"
      return 1
    fi
  else
    if ! nft -f - <<EOF_RULES
add rule inet ${HY_PQ_TABLE} ${HY_PQ_INPUT_CHAIN} udp dport ${port} drop comment "$(hy_pq_comment_drop_in "$port")"
add rule inet ${HY_PQ_TABLE} ${HY_PQ_OUTPUT_CHAIN} udp sport ${port} drop comment "$(hy_pq_comment_drop_out "$port")"
EOF_RULES
    then
      hy_pq_failsafe_block_port "$port"
      return 1
    fi
  fi
}

hy_pq_counter_bytes() {
  local obj="$1"
  nft list counter inet "$HY_PQ_TABLE" "$obj" 2>/dev/null \
    | awk '/bytes/ { for (i = 1; i <= NF; i++) if ($i == "bytes") { gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit } }'
}

hy_pq_live_used_bytes() {
  local port="$1" in_b out_b
  in_b="$(hy_pq_counter_bytes "$(hy_pq_counter_in "$port")" || true)"
  out_b="$(hy_pq_counter_bytes "$(hy_pq_counter_out "$port")" || true)"
  in_b="${in_b:-0}"
  out_b="${out_b:-0}"
  [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
  [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
  printf '%s\n' $((in_b + out_b))
}

hy_pq_state() {
  local port="$1" meta original saved live used left
  meta="$(hy_quota_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  original="$(hy_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left <= 0 )); then
    printf 'exhausted\n'
    return 0
  fi
  if nft list counter inet "$HY_PQ_TABLE" "$(hy_pq_counter_in "$port")" >/dev/null 2>&1 \
    && nft list counter inet "$HY_PQ_TABLE" "$(hy_pq_counter_out "$port")" >/dev/null 2>&1 \
    && nft list quota inet "$HY_PQ_TABLE" "$(hy_pq_quota_obj "$port")" >/dev/null 2>&1
  then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}

hy_pq_write_meta() {
  local port="$1" original="$2" saved="$3" remaining="$4" owner_kind="$5" owner_tag="$6" duration_seconds="$7" expire_epoch="$8" next_reset_epoch="$9" interval_seconds="${10}" created_epoch="${11}" last_reset_epoch="${12}" last_save_epoch="${13}"
  local cycle_days=0
  if [[ "$interval_seconds" =~ ^[0-9]+$ ]] && (( interval_seconds > 0 )); then
    cycle_days=$((interval_seconds / 86400))
  fi
  hy_write_meta "$(hy_quota_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "ORIGINAL_LIMIT_BYTES=${original}" \
    "SAVED_USED_BYTES=${saved}" \
    "LIMIT_BYTES=${remaining}" \
    "DURATION_SECONDS=${duration_seconds}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "RESET_INTERVAL_SECONDS=${interval_seconds}" \
    "RESET_CYCLE_DAYS=${cycle_days}" \
    "NEXT_RESET_EPOCH=${next_reset_epoch}" \
    "CREATED_EPOCH=${created_epoch}" \
    "LAST_RESET_EPOCH=${last_reset_epoch}" \
    "LAST_SAVE_EPOCH=${last_save_epoch}"
}

hy_pq_add_managed_port() {
  local port="$1" original_bytes="$2" owner_kind="${3:-manual}" owner_tag="${4:-}" duration_seconds="${5:-0}" expire_epoch="${6:-0}" created_epoch="${7:-$(date +%s)}"
  [[ "$port" =~ ^[0-9]+$ ]] || hy_die "端口必须为整数"
  [[ "$original_bytes" =~ ^[0-9]+$ ]] || hy_die "配额必须为整数"
  (( original_bytes > 0 )) || hy_die "配额必须大于 0"
  [[ "$duration_seconds" =~ ^[0-9]+$ ]] || duration_seconds=0
  [[ "$expire_epoch" =~ ^[0-9]+$ ]] || expire_epoch=0
  [[ "$created_epoch" =~ ^[0-9]+$ ]] || created_epoch="$(date +%s)"

  hy_pq_lock
  hy_pq_ensure_base

  local interval_seconds=0 next_reset_epoch=0
  if (( duration_seconds > 2592000 )); then
    interval_seconds=2592000
    next_reset_epoch=$((created_epoch + interval_seconds))
  fi

  hy_pq_write_meta "$port" "$original_bytes" 0 "$original_bytes" "$owner_kind" "$owner_tag" "$duration_seconds" "$expire_epoch" "$next_reset_epoch" "$interval_seconds" "$created_epoch" 0 "$created_epoch"
  hy_pq_rebuild_port "$port" "$original_bytes"
}

hy_pq_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  hy_pq_lock
  if nft list table inet "$HY_PQ_TABLE" >/dev/null 2>&1; then
    hy_pq_delete_port_rules "$port"
    hy_pq_delete_port_objects "$port"
  fi
  rm -f "$(hy_quota_meta_file "$port")"
}

hy_pq_save_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy_pq_meta_owner_exists "$meta" || return 0
  local port original saved live new_saved left next_reset_epoch interval_seconds created_epoch last_reset_epoch owner_kind owner_tag duration_seconds expire_epoch
  port="$(hy_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(hy_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy_meta_get "$meta" SAVED_USED_BYTES || true)"
  owner_kind="$(hy_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(hy_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(hy_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
  next_reset_epoch="$(hy_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  interval_seconds="$(hy_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  created_epoch="$(hy_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(hy_meta_get "$meta" LAST_RESET_EPOCH || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  new_saved=$((saved + live))
  if (( new_saved > original )); then
    new_saved="$original"
  fi
  left=$((original - new_saved))
  (( left < 0 )) && left=0
  hy_pq_write_meta "$port" "$original" "$new_saved" "$left" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "${next_reset_epoch:-0}" "${interval_seconds:-0}" "${created_epoch:-$(date +%s)}" "${last_reset_epoch:-0}" "$(date +%s)"
  hy_pq_rebuild_port "$port" "$left"
}

hy_pq_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy_pq_meta_owner_exists "$meta" || return 0
  local port remaining
  port="$(hy_meta_get "$meta" PORT || true)"
  remaining="$(hy_meta_get "$meta" LIMIT_BYTES || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  hy_pq_rebuild_port "$port" "$remaining"
}

hy_pq_reset_due_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy_pq_meta_owner_exists "$meta" || return 0
  local port original owner_kind owner_tag duration_seconds expire_epoch interval_seconds next_reset_epoch created_epoch now last_reset_epoch
  port="$(hy_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(hy_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  owner_kind="$(hy_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(hy_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(hy_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
  interval_seconds="$(hy_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  next_reset_epoch="$(hy_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  created_epoch="$(hy_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(hy_meta_get "$meta" LAST_RESET_EPOCH || true)"

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
  if [[ "$expire_epoch" =~ ^[0-9]+$ ]] && (( expire_epoch > 0 && next_reset_epoch >= expire_epoch )); then
    next_reset_epoch=0
  fi

  hy_pq_write_meta "$port" "$original" 0 "$original" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "${created_epoch:-$now}" "$now" "$now"
  hy_pq_rebuild_port "$port" "$original"
}

hy_pq_owner_text() {
  local meta="$1" owner_kind owner_tag
  owner_kind="$(hy_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(hy_meta_get "$meta" OWNER_TAG || true)"
  owner_kind="${owner_kind:-manual}"
  if [[ -n "$owner_tag" ]]; then
    printf '%s:%s\n' "$owner_kind" "$owner_tag"
  else
    printf '%s\n' "$owner_kind"
  fi
}
__HY_QUOTA_LIB__
  chmod 644 /usr/local/lib/hy2/quota-lib.sh
}

write_iplimit_lib() {
  cat >/usr/local/lib/hy2/iplimit-lib.sh <<'__HY_IPLIMIT_LIB__'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

HY_IL_TABLE="hy2_iplimit"
HY_IL_INPUT_CHAIN="input"
HY_IL_LOCK_FILE="${HY_RUN_DIR}/iplimit.lock"

hy_il_lock() {
  if [[ "${HY_IL_LOCK_HELD:-0}" != "1" ]]; then
    hy_acquire_lock_fd 8 "$HY_IL_LOCK_FILE" 20 "iplimit 锁繁忙"
    export HY_IL_LOCK_HELD=1
  fi
}

hy_il_set_name() { printf 'hy2_il_%s\n' "$1"; }
hy_il_comment_refresh() { printf 'hy2-il-refresh-%s\n' "$1"; }
hy_il_comment_claim() { printf 'hy2-il-claim-%s\n' "$1"; }
hy_il_comment_drop() { printf 'hy2-il-drop-%s\n' "$1"; }

hy_il_meta_owner_exists() {
  local meta="$1" owner_tag owner_kind port main_port
  owner_tag="$(hy_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(hy_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  port="$(hy_meta_get "$meta" PORT 2>/dev/null || true)"
  case "$owner_kind" in
    temp)
      [[ -n "$owner_tag" ]] || return 1
      [[ -f "$(hy_temp_meta_file "$owner_tag")" ]] || return 1
      ;;
    main)
      main_port="$(hy_main_listen_port || true)"
      [[ "$port" == "$main_port" ]] || return 1
      hy_main_exists || return 1
      ;;
    manual|"")
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

hy_il_ensure_base() {
  hy_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$HY_IL_TABLE" >/dev/null 2>&1 || nft add table inet "$HY_IL_TABLE"
  nft list chain inet "$HY_IL_TABLE" "$HY_IL_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY_IL_TABLE" "$HY_IL_INPUT_CHAIN" '{ type filter hook input priority -10; policy accept; }'
}

hy_il_reset_runtime() {
  hy_il_lock
  nft delete table inet "$HY_IL_TABLE" >/dev/null 2>&1 || true
  hy_il_ensure_base
}

hy_il_delete_rules_with_comment() {
  local comment="$1"
  nft -a list chain inet "$HY_IL_TABLE" "$HY_IL_INPUT_CHAIN" 2>/dev/null \
    | awk -v c="comment \\\""comment"\\\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$HY_IL_TABLE" "$HY_IL_INPUT_CHAIN" handle "$handle" >/dev/null 2>&1 || true
      done
}

hy_il_delete_port_rules() {
  local port="$1"
  hy_il_delete_rules_with_comment "$(hy_il_comment_refresh "$port")"
  hy_il_delete_rules_with_comment "$(hy_il_comment_claim "$port")"
  hy_il_delete_rules_with_comment "$(hy_il_comment_drop "$port")"
}

hy_il_delete_port_set() {
  local port="$1"
  nft delete set inet "$HY_IL_TABLE" "$(hy_il_set_name "$port")" >/dev/null 2>&1 || true
}

hy_il_failsafe_block_port() {
  local port="$1"
  hy_il_ensure_base
  hy_il_delete_port_rules "$port"
  nft add rule inet "$HY_IL_TABLE" "$HY_IL_INPUT_CHAIN" udp dport "$port" drop comment "$(hy_il_comment_drop "$port")" >/dev/null 2>&1 || true
}

hy_il_rebuild_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3"
  [[ "$port" =~ ^[0-9]+$ ]] || hy_die "hy_il_rebuild_port: 端口非法 ${port}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || hy_die "hy_il_rebuild_port: IP_LIMIT 非法 ${ip_limit}"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || hy_die "hy_il_rebuild_port: STICKY 非法 ${sticky_seconds}"

  hy_il_lock
  hy_il_ensure_base
  hy_il_delete_port_rules "$port"
  hy_il_delete_port_set "$port"

  if ! nft -f - <<EOF_RULES
add set inet ${HY_IL_TABLE} $(hy_il_set_name "$port") { type ipv4_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add rule inet ${HY_IL_TABLE} ${HY_IL_INPUT_CHAIN} udp dport ${port} ip saddr @$(hy_il_set_name "$port") update @$(hy_il_set_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(hy_il_comment_refresh "$port")"
add rule inet ${HY_IL_TABLE} ${HY_IL_INPUT_CHAIN} udp dport ${port} add @$(hy_il_set_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(hy_il_comment_claim "$port")"
add rule inet ${HY_IL_TABLE} ${HY_IL_INPUT_CHAIN} udp dport ${port} drop comment "$(hy_il_comment_drop "$port")"
EOF_RULES
  then
    hy_il_failsafe_block_port "$port"
    return 1
  fi
}

hy_il_write_meta() {
  local port="$1" owner_kind="$2" owner_tag="$3" ip_limit="$4" sticky_seconds="$5"
  hy_write_meta "$(hy_iplimit_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "IP_LIMIT=${ip_limit}" \
    "IP_STICKY_SECONDS=${sticky_seconds}" \
    "SET_NAME=$(hy_il_set_name "$port")" \
    "CREATED_EPOCH=$(date +%s)"
}

hy_il_add_managed_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3" owner_kind="${4:-manual}" owner_tag="${5:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || hy_die "端口必须为整数"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || hy_die "IP_LIMIT 必须为正整数"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || hy_die "STICKY 必须为正整数"
  hy_il_lock
  hy_il_ensure_base
  hy_il_write_meta "$port" "$owner_kind" "$owner_tag" "$ip_limit" "$sticky_seconds"
  hy_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

hy_il_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  hy_il_lock
  if nft list table inet "$HY_IL_TABLE" >/dev/null 2>&1; then
    hy_il_delete_port_rules "$port"
    hy_il_delete_port_set "$port"
  fi
  rm -f "$(hy_iplimit_meta_file "$port")"
}

hy_il_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy_il_meta_owner_exists "$meta" || return 0
  local port ip_limit sticky_seconds
  port="$(hy_meta_get "$meta" PORT || true)"
  ip_limit="$(hy_meta_get "$meta" IP_LIMIT || true)"
  sticky_seconds="$(hy_meta_get "$meta" IP_STICKY_SECONDS || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || return 0
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || return 0
  hy_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

hy_il_active_ips() {
  local port="$1" set_name
  set_name="$(hy_il_set_name "$port")"
  nft list set inet "$HY_IL_TABLE" "$set_name" 2>/dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | awk '!seen[$0]++' \
    | xargs echo -n
  printf '\n'
}

hy_il_active_count() {
  local port="$1" ips
  ips="$(hy_il_active_ips "$port" || true)"
  if [[ -z "$ips" ]]; then
    printf '0\n'
  else
    wc -w <<<"$ips" | tr -d ' '
  fi
}

hy_il_state() {
  local port="$1" meta
  meta="$(hy_iplimit_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  if nft list set inet "$HY_IL_TABLE" "$(hy_il_set_name "$port")" >/dev/null 2>&1; then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}
__HY_IPLIMIT_LIB__
  chmod 644 /usr/local/lib/hy2/iplimit-lib.sh
}

write_render_table() {
  cat >/usr/local/lib/hy2/render_table.py <<'__HY_RENDER_TABLE__'
#!/usr/bin/env python3
import os
import shutil
import sys
import unicodedata

SCHEMAS = {
    "hy2": [
        {"name": "NAME",  "min":  8, "ideal": 15, "max": 32, "align": "left",  "weight": 10},
        {"name": "STATE", "min":  6, "ideal":  6, "max":  8, "align": "left",  "weight":  1},
        {"name": "PORT",  "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "LISN",  "min":  4, "ideal":  4, "max":  4, "align": "left",  "weight":  1},
        {"name": "QUOTA", "min":  6, "ideal":  6, "max":  9, "align": "left",  "weight":  1},
        {"name": "LIMIT", "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USED",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "LEFT",  "min":  7, "ideal":  8, "max": 12, "align": "right", "weight":  1},
        {"name": "USE%",  "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "TTL",   "min":  6, "ideal":  8, "max": 12, "align": "left",  "weight":  2},
        {"name": "EXPBJ", "min":  8, "ideal": 12, "max": 19, "align": "left",  "weight":  3},
        {"name": "IPLM",  "min":  4, "ideal":  4, "max":  5, "align": "right", "weight":  1},
        {"name": "IPACT", "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "STKY",  "min":  4, "ideal":  4, "max":  5, "align": "right", "weight":  1},
    ],
    "pq": [
        {"name": "PORT",   "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "OWNER",  "min": 10, "ideal": 18, "max": 40, "align": "left",  "weight": 10},
        {"name": "STATE",  "min":  6, "ideal":  6, "max":  9, "align": "left",  "weight":  1},
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
        print("用法: render_table.py <hy2|pq>", file=sys.stderr)
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
__HY_RENDER_TABLE__
  chmod 755 /usr/local/lib/hy2/render_table.py
}

write_wrappers() {
  cat >/root/onekey_hy2_main_tls.sh <<'__HY_WRAPPER_MAIN__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
exec /root/onekey_hy2_managed.sh --install-main "$@"
__HY_WRAPPER_MAIN__
  chmod 700 /root/onekey_hy2_main_tls.sh

  cat >/root/hy2_temp_audit_all.sh <<'__HY_WRAPPER_LATER__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
exec /root/onekey_hy2_managed.sh --install-later "$@"
__HY_WRAPPER_LATER__
  chmod 700 /root/hy2_temp_audit_all.sh
}

write_maintenance() {
  cat >/etc/logrotate.d/hy2-managed <<'__HY_LOGROTATE__'
/var/log/hy2-managed.log /var/log/hy2-gc.log /var/log/hy2-quota.log {
    daily
    rotate 7
    maxage 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    create 0640 root adm
}
__HY_LOGROTATE__
  chmod 644 /etc/logrotate.d/hy2-managed
}

write_shell_scripts() {
  cat >/usr/local/sbin/hy2_cleanup_one.sh <<'__HY_CLEANUP_ONE__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

TAG="${1:?缺少 TAG 参数}"
MODE="${2:-}"
FORCE="${FORCE:-0}"
FROM_STOP_POST=0
[[ "$MODE" == "--from-stop-post" ]] && FROM_STOP_POST=1

META="$(hy_temp_meta_file "$TAG")"
CFG="$(hy_temp_cfg_file "$TAG")"
UNIT_FILE="$(hy_temp_unit_file "$TAG")"
URL_FILE="$(hy_temp_url_file "$TAG")"
AUX_FILE="$(hy_temp_aux_file "$TAG")"
UNIT_NAME="${TAG}.service"

hy_ensure_runtime_dirs
if [[ "${HY_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  if (( FROM_STOP_POST == 1 )); then
    if ! hy_try_lock_fd 7 "${HY_RUN_DIR}/temp.lock"; then
      exit 0
    fi
  else
    hy_acquire_lock_fd 7 "${HY_RUN_DIR}/temp.lock" 20 "temp 锁繁忙"
  fi
  export HY_TEMP_LOCK_HELD=1
fi

PORT="$(hy_temp_port_from_any "$TAG" 2>/dev/null || true)"

if (( FROM_STOP_POST == 1 )) && [[ "$PORT" =~ ^[0-9]+$ ]]; then
  hy_pq_save_one "$(hy_quota_meta_file "$PORT")" >/dev/null 2>&1 || true
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(hy_meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW="$(date +%s)"
    if (( EXPIRE_EPOCH > NOW )); then
      exit 0
    fi
  fi
fi

if [[ -f "$UNIT_FILE" ]] || systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1; then
  if (( FROM_STOP_POST == 0 )) && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    timeout 15 systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || systemctl kill "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true
fi

if [[ "$PORT" =~ ^[0-9]+$ ]]; then
  hy_pq_delete_managed_port "$PORT" || true
  hy_il_delete_managed_port "$PORT" || true
fi

rm -f "$CFG" "$META" "$UNIT_FILE" "$URL_FILE" "$AUX_FILE"
systemctl daemon-reload >/dev/null 2>&1 || true
__HY_CLEANUP_ONE__
  chmod 755 /usr/local/sbin/hy2_cleanup_one.sh

  cat >/usr/local/sbin/hy2_clear_all.sh <<'__HY_CLEAR_ALL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

hy_ensure_runtime_dirs
hy_acquire_lock_fd 7 "${HY_RUN_DIR}/temp.lock" 20 "temp 锁繁忙"
export HY_TEMP_LOCK_HELD=1

mapfile -t TAGS < <(hy_collect_temp_tags)
for tag in "${TAGS[@]:-}"; do
  [[ -n "$tag" ]] || continue
  FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" || true
done
systemctl daemon-reload >/dev/null 2>&1 || true
echo "✅ 已清空全部临时节点"
__HY_CLEAR_ALL__
  chmod 755 /usr/local/sbin/hy2_clear_all.sh

  cat >/usr/local/sbin/hy2_gc.sh <<'__HY_GC__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

hy_ensure_runtime_dirs
if ! hy_try_lock_fd 7 "${HY_RUN_DIR}/temp.lock"; then
  exit 0
fi
export HY_TEMP_LOCK_HELD=1

NOW="$(date +%s)"
for meta in "$HY_TEMP_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  TAG="$(hy_meta_get "$meta" TAG || true)"
  EXPIRE_EPOCH="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
  [[ -n "$TAG" ]] || continue
  [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || continue
  if (( EXPIRE_EPOCH <= NOW )); then
    FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" || true
  fi
done
__HY_GC__
  chmod 755 /usr/local/sbin/hy2_gc.sh

  cat >/usr/local/sbin/hy2_run_temp.sh <<'__HY_RUN_TEMP__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

TAG="${1:?缺少 TAG 参数}"
CFG="${2:?缺少配置文件参数}"
META="$(hy_temp_meta_file "$TAG")"
HY_BIN="$(command -v hysteria || echo /usr/local/bin/hysteria)"

[[ -x "$HY_BIN" ]] || hy_die "未找到 hysteria 可执行文件"
[[ -f "$CFG" ]] || hy_die "配置不存在: ${CFG}"
[[ -f "$META" ]] || hy_die "meta 不存在: ${META}"

EXPIRE_EPOCH="$(hy_meta_get "$META" EXPIRE_EPOCH || true)"
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || hy_die "EXPIRE_EPOCH 非法: ${META}"

NOW="$(date +%s)"
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  exit 0
fi

exec timeout --foreground "$REMAIN" "$HY_BIN" server -c "$CFG"
__HY_RUN_TEMP__
  chmod 755 /usr/local/sbin/hy2_run_temp.sh

  cat >/usr/local/sbin/hy2_restore_all.sh <<'__HY_RESTORE_ALL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

rc=0
systemctl daemon-reload >/dev/null 2>&1 || true
/usr/local/sbin/hy2_gc.sh || rc=1
/usr/local/sbin/pq_restore_all.sh || rc=1
/usr/local/sbin/iplimit_restore_all.sh || rc=1
exit "$rc"
__HY_RESTORE_ALL__
  chmod 755 /usr/local/sbin/hy2_restore_all.sh

  cat >/usr/local/sbin/pq_save_state.sh <<'__HY_PQ_SAVE__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy_ensure_runtime_dirs
hy_pq_lock
rc=0
for meta in "$HY_QUOTA_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy_pq_save_one "$meta" || rc=1
done
exit "$rc"
__HY_PQ_SAVE__
  chmod 755 /usr/local/sbin/pq_save_state.sh

  cat >/usr/local/sbin/pq_restore_all.sh <<'__HY_PQ_RESTORE__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy_ensure_runtime_dirs
hy_pq_lock
hy_pq_reset_runtime
rc=0
for meta in "$HY_QUOTA_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy_pq_restore_one "$meta" || rc=1
done
exit "$rc"
__HY_PQ_RESTORE__
  chmod 755 /usr/local/sbin/pq_restore_all.sh

  cat >/usr/local/sbin/pq_reset_due.sh <<'__HY_PQ_RESET__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy_ensure_runtime_dirs
hy_pq_lock
rc=0
for meta in "$HY_QUOTA_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy_pq_reset_due_one "$meta" || rc=1
done
exit "$rc"
__HY_PQ_RESET__
  chmod 755 /usr/local/sbin/pq_reset_due.sh

  cat >/usr/local/sbin/iplimit_restore_all.sh <<'__HY_IP_RESTORE__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

hy_ensure_runtime_dirs
hy_il_lock
hy_il_reset_runtime
rc=0
for meta in "$HY_IPLIMIT_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy_il_restore_one "$meta" || rc=1
done
exit "$rc"
__HY_IP_RESTORE__
  chmod 755 /usr/local/sbin/iplimit_restore_all.sh

  cat >/usr/local/sbin/pq_add.sh <<'__HY_PQ_ADD__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

PORT="${1:-}"
GIB="${2:-}"
DURATION_SECONDS="${3:-}"
EXPIRE_EPOCH="${4:-}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy_die "用法: pq_add.sh <端口> <GiB> [服务秒数] [到期Epoch]"
[[ -n "$GIB" ]] || hy_die "用法: pq_add.sh <端口> <GiB> [服务秒数] [到期Epoch]"
BYTES="$(hy_parse_gib_to_bytes "$GIB")" || hy_die "GiB 必须是正数"

read -r OWNER_KIND OWNER_TAG < <(hy_owner_from_port "$PORT")
if [[ -z "$DURATION_SECONDS" && "$OWNER_KIND" == "temp" && -f "$(hy_temp_meta_file "$OWNER_TAG")" ]]; then
  DURATION_SECONDS="$(hy_meta_get "$(hy_temp_meta_file "$OWNER_TAG")" DURATION_SECONDS || true)"
fi
if [[ -z "$EXPIRE_EPOCH" && "$OWNER_KIND" == "temp" && -f "$(hy_temp_meta_file "$OWNER_TAG")" ]]; then
  EXPIRE_EPOCH="$(hy_meta_get "$(hy_temp_meta_file "$OWNER_TAG")" EXPIRE_EPOCH || true)"
fi

[[ -z "$DURATION_SECONDS" || "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || hy_die "duration_seconds 必须为整数"
[[ -z "$EXPIRE_EPOCH" || "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || hy_die "expire_epoch 必须为整数"

hy_pq_add_managed_port "$PORT" "$BYTES" "${OWNER_KIND:-manual}" "${OWNER_TAG:-}" "${DURATION_SECONDS:-0}" "${EXPIRE_EPOCH:-0}"
echo "✅ 已为端口 ${PORT} 设置配额 $(hy_human_bytes "$BYTES")"
__HY_PQ_ADD__
  chmod 755 /usr/local/sbin/pq_add.sh

  cat >/usr/local/sbin/pq_del.sh <<'__HY_PQ_DEL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy_die "用法: pq_del.sh <端口>"
hy_pq_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的配额管理"
__HY_PQ_DEL__
  chmod 755 /usr/local/sbin/pq_del.sh

  cat >/usr/local/sbin/ip_set.sh <<'__HY_IP_SET__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

PORT="${1:-}"
IP_LIMIT="${2:-}"
STICKY_SECONDS="${3:-}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy_die "用法: ip_set.sh <端口> <限制数> [粘滞秒数]"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] && (( IP_LIMIT > 0 )) || hy_die "IP_LIMIT 必须为正整数"

read -r OWNER_KIND OWNER_TAG < <(hy_owner_from_port "$PORT")
if [[ -z "$STICKY_SECONDS" && -f "$(hy_iplimit_meta_file "$PORT")" ]]; then
  STICKY_SECONDS="$(hy_meta_get "$(hy_iplimit_meta_file "$PORT")" IP_STICKY_SECONDS || true)"
fi
STICKY_SECONDS="${STICKY_SECONDS:-120}"
[[ "$STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( STICKY_SECONDS > 0 )) || hy_die "sticky_seconds 必须为正整数"

hy_il_add_managed_port "$PORT" "$IP_LIMIT" "$STICKY_SECONDS" "${OWNER_KIND:-manual}" "${OWNER_TAG:-}"
echo "✅ 已为端口 ${PORT} 设置 IP_LIMIT=${IP_LIMIT}，STICKY=${STICKY_SECONDS}s"
__HY_IP_SET__
  chmod 755 /usr/local/sbin/ip_set.sh

  cat >/usr/local/sbin/ip_del.sh <<'__HY_IP_DEL__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy_die "用法: ip_del.sh <端口>"
hy_il_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的 IP 限制"
__HY_IP_DEL__
  chmod 755 /usr/local/sbin/ip_del.sh

  cat >/usr/local/sbin/pq_audit.sh <<'__HY_PQ_AUDIT__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

FILTER_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      FILTER_TAG="${2:-}"
      shift 2
      ;;
    *)
      hy_die "未知参数: $1"
      ;;
  esac
done

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

FOUND=0
for meta in "$HY_QUOTA_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  PORT="$(hy_meta_get "$meta" PORT || true)"
  OWNER_KIND="$(hy_meta_get "$meta" OWNER_KIND || true)"
  OWNER_TAG="$(hy_meta_get "$meta" OWNER_TAG || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue

  if [[ -n "$FILTER_TAG" ]]; then
    if [[ "$FILTER_TAG" == "main" || "$FILTER_TAG" == "hy2-main" ]]; then
      [[ "${OWNER_KIND:-}" == "main" ]] || continue
    else
      [[ "${OWNER_TAG:-}" == "$FILTER_TAG" ]] || continue
    fi
  fi

  FOUND=1
  ORIGINAL="$(hy_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  SAVED="$(hy_meta_get "$meta" SAVED_USED_BYTES || true)"
  NEXT_RESET_EPOCH="$(hy_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(hy_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  ORIGINAL="${ORIGINAL:-0}"
  SAVED="${SAVED:-0}"
  LIVE="$(hy_pq_live_used_bytes "$PORT" || true)"
  LIVE="${LIVE:-0}"
  USED=$((SAVED + LIVE))
  LEFT=$((ORIGINAL - USED))
  (( LEFT < 0 )) && LEFT=0

  case "${OWNER_KIND:-manual}" in
    main) OWNER="主节点" ;;
    temp) OWNER="临时节点" ;;
    *) OWNER="手动" ;;
  esac
  if [[ -n "${OWNER_TAG:-}" ]]; then
    OWNER="${OWNER}:${OWNER_TAG}"
  fi
  STATE_RAW="$(hy_pq_state "$PORT")"
  case "$STATE_RAW" in
    none) STATE="无" ;;
    active) STATE="生效" ;;
    stale) STATE="待恢复" ;;
    exhausted) STATE="用尽" ;;
    *) STATE="$STATE_RAW" ;;
  esac
  if [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && (( RESET_INTERVAL_SECONDS > 0 )); then
    RESET='30天'
    NEXT_RESET_BJ="$(hy_beijing_time "$NEXT_RESET_EPOCH")"
  else
    RESET='-'
    NEXT_RESET_BJ='-'
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PORT" \
    "$OWNER" \
    "$STATE" \
    "$(hy_human_bytes "$ORIGINAL")" \
    "$(hy_human_bytes "$USED")" \
    "$(hy_human_bytes "$LEFT")" \
    "$(hy_pct_text "$USED" "$ORIGINAL")" \
    "$RESET" \
    "$NEXT_RESET_BJ" >>"$TMP_ROWS"
done

if [[ -n "$FILTER_TAG" && "$FOUND" -eq 0 ]]; then
  exit 1
fi

sort -t $'\t' -k1,1n "$TMP_ROWS" | /usr/local/lib/hy2/render_table.py pq
__HY_PQ_AUDIT__
  chmod 755 /usr/local/sbin/pq_audit.sh

  cat >/usr/local/sbin/hy2_audit.sh <<'__HY_AUDIT__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

FILTER_TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      FILTER_TAG="${2:-}"
      shift 2
      ;;
    *)
      hy_die "未知参数: $1"
      ;;
  esac
done

state_cn() {
  case "$1" in
    active) echo "运行" ;;
    inactive) echo "已停" ;;
    failed) echo "失败" ;;
    activating) echo "启动中" ;;
    deactivating) echo "停止中" ;;
    reloading) echo "重载中" ;;
    missing) echo "缺失" ;;
    *) echo "$1" ;;
  esac
}

quota_cn() {
  case "$1" in
    none|无) echo "无" ;;
    active) echo "生效" ;;
    stale) echo "待恢复" ;;
    exhausted) echo "用尽" ;;
    *) echo "$1" ;;
  esac
}

quota_summary() {
  local port="$1" meta original saved live used left state
  meta="$(hy_quota_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf '无|-|-|-|-\n'
    return 0
  fi
  original="$(hy_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  (( left < 0 )) && left=0
  state="$(hy_pq_state "$port")"
  printf '%s|%s|%s|%s|%s\n' \
    "$state" \
    "$(hy_human_bytes "$original")" \
    "$(hy_human_bytes "$used")" \
    "$(hy_human_bytes "$left")" \
    "$(hy_pct_text "$used" "$original")"
}

ip_summary() {
  local port="$1" meta ip_limit sticky active_count
  meta="$(hy_iplimit_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf '%s\n' '-|-|-'
    return 0
  fi
  ip_limit="$(hy_meta_get "$meta" IP_LIMIT || true)"
  sticky="$(hy_meta_get "$meta" IP_STICKY_SECONDS || true)"
  active_count="$(hy_il_active_count "$port" || true)"
  printf '%s|%s|%s\n' "${ip_limit:-0}" "${active_count:-0}" "${sticky:-0}"
}

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

FOUND=0
if [[ -z "$FILTER_TAG" || "$FILTER_TAG" == "main" || "$FILTER_TAG" == "hy2-main" ]]; then
  if hy_main_exists; then
    MAIN_PORT="$(hy_main_listen_port || true)"
    IFS='|' read -r QSTATE LIMIT USED LEFT_Q PCT <<<"$(quota_summary "$MAIN_PORT")"
    IFS='|' read -r IPLIM IPACT STICKY <<<"$(ip_summary "$MAIN_PORT")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "main/hy2.service" \
      "$(hy_unit_state hy2.service)" \
      "$MAIN_PORT" \
      "$(if hy_udp_port_is_listening "$MAIN_PORT"; then echo 是; else echo 否; fi)" \
      "$QSTATE" \
      "$LIMIT" \
      "$USED" \
      "$LEFT_Q" \
      "$PCT" \
      "永久" \
      "-" \
      "$IPLIM" \
      "$IPACT" \
      "$STICKY" >>"$TMP_ROWS"
  fi
fi

for TAG in $(hy_collect_temp_tags); do
  [[ -n "$TAG" ]] || continue
  if [[ -n "$FILTER_TAG" && "$FILTER_TAG" != "$TAG" ]]; then
    continue
  fi
  FOUND=1
  META="$(hy_temp_meta_file "$TAG")"
  PORT="$(hy_temp_port_from_any "$TAG" 2>/dev/null || true)"
  UNIT_STATE="$(state_cn "$(hy_unit_state "${TAG}.service")")"
  if [[ "$PORT" =~ ^[0-9]+$ ]] && hy_udp_port_is_listening "$PORT"; then
    LISTEN="是"
  else
    LISTEN="否"
  fi

  if [[ -f "$META" ]]; then
    EXPIRE_EPOCH="$(hy_meta_get "$META" EXPIRE_EPOCH || true)"
    TTL_TEXT="$(hy_ttl_human "$EXPIRE_EPOCH")"
    EXPIRE_BJ="$(hy_beijing_time "$EXPIRE_EPOCH")"
  else
    TTL_TEXT="缺失"
    EXPIRE_BJ="缺失"
  fi

  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    IFS='|' read -r QSTATE LIMIT USED LEFT_Q PCT <<<"$(quota_summary "$PORT")"
    IFS='|' read -r IPLIM IPACT STICKY <<<"$(ip_summary "$PORT")"
    QSTATE="$(quota_cn "$QSTATE")"
  else
    QSTATE='无'; LIMIT='-'; USED='-'; LEFT_Q='-'; PCT='-'
    IPLIM='-'; IPACT='-'; STICKY='-'
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TAG" \
    "$UNIT_STATE" \
    "${PORT:-0}" \
    "$LISTEN" \
    "$QSTATE" \
    "$LIMIT" \
    "$USED" \
    "$LEFT_Q" \
    "$PCT" \
    "$TTL_TEXT" \
    "$EXPIRE_BJ" \
    "$IPLIM" \
    "$IPACT" \
    "$STICKY" >>"$TMP_ROWS"
done

if [[ -n "$FILTER_TAG" && "$FILTER_TAG" != "main" && "$FILTER_TAG" != "hy2-main" && "$FOUND" -eq 0 ]]; then
  exit 1
fi

sort -t $'\t' -k3,3n "$TMP_ROWS" | /usr/local/lib/hy2/render_table.py hy2
__HY_AUDIT__
  chmod 755 /usr/local/sbin/hy2_audit.sh

  cat >/usr/local/sbin/hy2_mktemp.sh <<'__HY_MKTEMP__'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

: "${D:?请用 D=秒 hy2_mktemp.sh 调用，例如：id=tmp001 IP_LIMIT=1 PQ_GIB=50 D=1200 hy2_mktemp.sh}"
[[ "$D" =~ ^[0-9]+$ ]] && (( D > 0 )) || hy_die "D 必须是正整数秒"

RAW_ID="${id:-tmp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)}"
SAFE_ID="$(hy_safe_id "$RAW_ID")"
TAG="$(hy_temp_tag_from_id "$SAFE_ID")"
PORT_START="${PORT_START:-${TEMP_PORT_START:-40000}}"
PORT_END="${PORT_END:-${TEMP_PORT_END:-50050}}"
MAX_START_RETRIES="${MAX_START_RETRIES:-24}"
IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
PQ_GIB="${PQ_GIB:-}"

[[ "$PORT_START" =~ ^[0-9]+$ && "$PORT_END" =~ ^[0-9]+$ ]] || hy_die "PORT_START/PORT_END 无效"
(( PORT_START >= 1 && PORT_END <= 65535 && PORT_START <= PORT_END )) || hy_die "PORT_START/PORT_END 无效"
[[ "$MAX_START_RETRIES" =~ ^[0-9]+$ ]] && (( MAX_START_RETRIES > 0 )) || hy_die "MAX_START_RETRIES 必须是正整数"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] || hy_die "IP_LIMIT 必须是非负整数"
[[ "$IP_STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( IP_STICKY_SECONDS > 0 )) || hy_die "IP_STICKY_SECONDS 必须是正整数"

hy_ensure_runtime_dirs
hy_load_env

CERT_FILE="/etc/letsencrypt/live/${HY_DOMAIN}/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/${HY_DOMAIN}/privkey.pem"
[[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || hy_die "缺少正式证书，请先执行：bash /root/onekey_hy2_main_tls.sh"
[[ -f "$HY_MAIN_STATE_FILE" ]] || hy_die "未检测到主节点状态，请先执行：bash /root/onekey_hy2_main_tls.sh"

if [[ "${HY_TEMP_LOCK_HELD:-0}" != "1" ]]; then
  hy_acquire_lock_fd 7 "${HY_RUN_DIR}/temp.lock" 20 "temp 锁繁忙"
  export HY_TEMP_LOCK_HELD=1
fi

PQ_LIMIT_BYTES=""
if [[ -n "$PQ_GIB" ]]; then
  PQ_LIMIT_BYTES="$(hy_parse_gib_to_bytes "$PQ_GIB")" || hy_die "PQ_GIB 必须是正数"
  [[ "$PQ_LIMIT_BYTES" =~ ^[0-9]+$ ]] && (( PQ_LIMIT_BYTES > 0 )) || hy_die "PQ_GIB 转换失败"
fi

META_FILE="$(hy_temp_meta_file "$TAG")"
CFG_FILE="$(hy_temp_cfg_file "$TAG")"
UNIT_FILE="$(hy_temp_unit_file "$TAG")"
URL_FILE="$(hy_temp_url_file "$TAG")"
AUX_FILE="$(hy_temp_aux_file "$TAG")"

write_unit() {
  local tag="$1" cfg="$2" meta="$3" unit="$4"
  cat >"$unit" <<UNIT
[Unit]
Description=Managed HY2 Temporary ${tag}
After=network-online.target hy2-managed-restore.service
Wants=network-online.target
ConditionPathExists=${cfg}
ConditionPathExists=${meta}

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/sbin/hy2_run_temp.sh ${tag} ${cfg}
ExecStopPost=/usr/local/sbin/hy2_cleanup_one.sh ${tag} --from-stop-post
Restart=no
SuccessExitStatus=0 124 143

[Install]
WantedBy=multi-user.target
UNIT
}

write_cfg() {
  local cfg="$1" port="$2" password="$3"
  local cert_q key_q pw_q masq_q salam_q
  cert_q="$(hy_yaml_quote "$CERT_FILE")"
  key_q="$(hy_yaml_quote "$KEY_FILE")"
  pw_q="$(hy_yaml_quote "$password")"
  masq_q="$(hy_yaml_quote "$MASQ_URL")"
  salam_q="$(hy_yaml_quote "$SALAMANDER_PASSWORD")"
  {
    echo "listen: :${port}"
    echo
    echo "tls:"
    echo "  cert: ${cert_q}"
    echo "  key: ${key_q}"
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: ${pw_q}"
    echo
    if [[ "${ENABLE_SALAMANDER:-0}" == "1" ]]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${salam_q}"
      echo
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: ${masq_q}"
    echo "    rewriteHost: true"
    echo
    echo "speedTest: false"
    echo "disableUDP: false"
    echo "udpIdleTimeout: 60s"
  } >"$cfg"
  chmod 600 "$cfg"
}

write_meta_file() {
  local meta="$1" port="$2" password="$3" create_epoch="$4" expire_epoch="$5"
  hy_write_meta "$meta" \
    "TAG=${TAG}" \
    "ID=${SAFE_ID}" \
    "PORT=${port}" \
    "CREATE_EPOCH=${create_epoch}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "DURATION_SECONDS=${D}" \
    "AUTH_PASSWORD=${password}" \
    "PUBLISHED_DOMAIN=${HY_DOMAIN}" \
    "SNI=${HY_DOMAIN}" \
    "CERT_FILE=${CERT_FILE}" \
    "KEY_FILE=${KEY_FILE}" \
    "MASQ_URL=${MASQ_URL}" \
    "OBFS_ENABLED=${ENABLE_SALAMANDER:-0}" \
    "OBFS_PASSWORD=${SALAMANDER_PASSWORD:-}" \
    "PQ_GIB=${PQ_GIB}" \
    "PQ_LIMIT_BYTES=${PQ_LIMIT_BYTES}" \
    "IP_LIMIT=${IP_LIMIT}" \
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}"
}

rollback_current() {
  FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
}

collect_used_ports() {
  ss -lunH 2>/dev/null | awk '{print $5}' | sed -nE 's/.*:([0-9]+)$/\1/p'
  if hy_main_exists; then
    hy_main_listen_port || true
  fi
  for meta in "$HY_TEMP_DIR"/*.env "$HY_QUOTA_DIR"/*.env "$HY_IPLIMIT_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    hy_meta_get "$meta" PORT || true
  done
  for cfg in "$HY_TEMP_CFG_DIR"/*.yaml; do
    [[ -f "$cfg" ]] || continue
    hy_cfg_listen_port "$cfg" || true
  done
  for tag in $(hy_collect_temp_tags); do
    hy_temp_port_from_any "$tag" 2>/dev/null || true
  done
}

validate_full_state() {
  local meta="$1" port="$2" url expected_url aux unit_name
  [[ -f "$meta" ]] || return 1
  [[ -f "$CFG_FILE" ]] || return 1
  [[ -f "$UNIT_FILE" ]] || return 1
  [[ -f "$URL_FILE" ]] || return 1
  [[ -f "$AUX_FILE" ]] || return 1
  [[ "$(hy_meta_get "$meta" TAG || true)" == "$TAG" ]] || return 1
  [[ "$(hy_meta_get "$meta" PORT || true)" == "$port" ]] || return 1
  [[ "$(hy_cfg_listen_port "$CFG_FILE" || true)" == "$port" ]] || return 1
  unit_name="${TAG}.service"
  systemctl is-enabled "$unit_name" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$unit_name" || return 1
  hy_udp_port_is_listening "$port" || return 1

  expected_url="$(hy_temp_url_from_meta "$meta")" || return 1
  url="$(sed -n '1p' "$URL_FILE" 2>/dev/null || true)"
  [[ "$url" == "$expected_url" ]] || return 1
  [[ "$(hy_meta_get "$AUX_FILE" TAG || true)" == "$TAG" ]] || return 1
  [[ "$(hy_meta_get "$AUX_FILE" PORT || true)" == "$port" ]] || return 1
  [[ "$(hy_meta_get "$AUX_FILE" URL || true)" == "$expected_url" ]] || return 1

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta
    qmeta="$(hy_quota_meta_file "$port")"
    [[ -f "$qmeta" ]] || return 1
    [[ "$(hy_meta_get "$qmeta" OWNER_KIND || true)" == "temp" ]] || return 1
    [[ "$(hy_meta_get "$qmeta" OWNER_TAG || true)" == "$TAG" ]] || return 1
    [[ "$(hy_meta_get "$qmeta" PORT || true)" == "$port" ]] || return 1
    [[ "$(hy_meta_get "$qmeta" ORIGINAL_LIMIT_BYTES || true)" == "$PQ_LIMIT_BYTES" ]] || return 1
  fi

  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(hy_iplimit_meta_file "$port")"
    [[ -f "$imeta" ]] || return 1
    [[ "$(hy_meta_get "$imeta" OWNER_KIND || true)" == "temp" ]] || return 1
    [[ "$(hy_meta_get "$imeta" OWNER_TAG || true)" == "$TAG" ]] || return 1
    [[ "$(hy_meta_get "$imeta" PORT || true)" == "$port" ]] || return 1
    [[ "$(hy_meta_get "$imeta" IP_LIMIT || true)" == "$IP_LIMIT" ]] || return 1
    [[ "$(hy_meta_get "$imeta" IP_STICKY_SECONDS || true)" == "$IP_STICKY_SECONDS" ]] || return 1
  fi

  /usr/local/sbin/hy2_audit.sh --tag "$TAG" >/dev/null 2>&1 || return 1
}

repair_current_state() {
  local meta="$1" port="$2"
  [[ -f "$meta" ]] || return 1
  [[ -f "$CFG_FILE" ]] || {
    local password
    password="$(hy_meta_get "$meta" AUTH_PASSWORD || true)"
    [[ -n "$password" ]] || return 1
    write_cfg "$CFG_FILE" "$port" "$password"
  }
  [[ -f "$UNIT_FILE" ]] || write_unit "$TAG" "$CFG_FILE" "$meta" "$UNIT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "${TAG}.service" >/dev/null 2>&1 || true
  hy_write_temp_url_aux_from_meta "$meta" || true

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta
    qmeta="$(hy_quota_meta_file "$port")"
    if [[ ! -f "$qmeta" ]] || [[ "$(hy_meta_get "$qmeta" OWNER_TAG || true)" != "$TAG" ]]; then
      hy_pq_add_managed_port "$port" "$PQ_LIMIT_BYTES" temp "$TAG" "$D" "$(hy_meta_get "$meta" EXPIRE_EPOCH || true)" "$(hy_meta_get "$meta" CREATE_EPOCH || true)" || true
    else
      hy_pq_restore_one "$qmeta" || true
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(hy_iplimit_meta_file "$port")"
    if [[ ! -f "$imeta" ]] || [[ "$(hy_meta_get "$imeta" OWNER_TAG || true)" != "$TAG" ]]; then
      hy_il_add_managed_port "$port" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG" || true
    else
      hy_il_restore_one "$imeta" || true
    fi
  fi
}

print_success_from_meta() {
  local meta="$1" port exp url
  port="$(hy_meta_get "$meta" PORT || true)"
  exp="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
  url="$(hy_temp_url_from_meta "$meta")"
  echo "✅ 临时节点创建成功"
  echo "标签: ${TAG}"
  echo "端口: ${port}"
  echo "剩余时长: $(hy_ttl_human "$exp")"
  echo "到期北京时间: $(hy_beijing_time "$exp")"
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    echo "配额: $(hy_human_bytes "$PQ_LIMIT_BYTES")"
  fi
  if (( IP_LIMIT > 0 )); then
    echo "IP限制: ${IP_LIMIT}"
    echo "粘滞秒数: ${IP_STICKY_SECONDS}"
  fi
  echo "链接: ${url}"
}

handle_existing_tag() {
  local meta port exp
  meta="$(hy_temp_meta_file "$TAG")"
  if [[ -f "$meta" ]]; then
    exp="$(hy_meta_get "$meta" EXPIRE_EPOCH || true)"
    if [[ "$exp" =~ ^[0-9]+$ ]] && (( exp <= $(date +%s) )); then
      FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
      return 1
    fi
    port="$(hy_temp_port_from_any "$TAG" 2>/dev/null || true)"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
      FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
      return 1
    fi
    repair_current_state "$meta" "$port" || true
    systemctl start "${TAG}.service" >/dev/null 2>&1 || true
    hy_wait_unit_and_udp_port "${TAG}.service" "$port" 2 8 >/dev/null 2>&1 || true
    if validate_full_state "$meta" "$port"; then
      print_success_from_meta "$meta"
      return 0
    fi
    if systemctl is-active --quiet "${TAG}.service" 2>/dev/null && hy_udp_port_is_listening "$port"; then
      hy_write_temp_url_aux_from_meta "$meta" >/dev/null 2>&1 || true
      print_success_from_meta "$meta"
      return 0
    fi
    FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -f "$CFG_FILE" || -f "$UNIT_FILE" || -f "$URL_FILE" || -f "$AUX_FILE" ]]; then
    FORCE=1 HY_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  fi
  return 1
}

if handle_existing_tag; then
  exit 0
fi

ATTEMPT=0
declare -A USED=()
while (( ATTEMPT < MAX_START_RETRIES )); do
  ATTEMPT=$((ATTEMPT + 1))

  mapfile -t USED_PORTS < <(collect_used_ports | awk '/^[0-9]+$/ {print}' | sort -n -u)
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

  [[ -n "$PORT" ]] || hy_die "在 ${PORT_START}-${PORT_END} 范围内没有空闲端口"

  AUTH_PASSWORD="$(openssl rand -hex 16)"
  CREATE_EPOCH="$(date +%s)"
  EXPIRE_EPOCH=$((CREATE_EPOCH + D))

  write_cfg "$CFG_FILE" "$PORT" "$AUTH_PASSWORD"
  write_meta_file "$META_FILE" "$PORT" "$AUTH_PASSWORD" "$CREATE_EPOCH" "$EXPIRE_EPOCH"
  write_unit "$TAG" "$CFG_FILE" "$META_FILE" "$UNIT_FILE"

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    if ! hy_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "$D" "$EXPIRE_EPOCH" "$CREATE_EPOCH"; then
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    if ! hy_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG"; then
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

  if ! hy_wait_unit_and_udp_port "${TAG}.service" "$PORT" 3 12; then
    rollback_current
    USED["$PORT"]=1
    continue
  fi

  hy_write_temp_url_aux_from_meta "$META_FILE" || true
  if ! validate_full_state "$META_FILE" "$PORT"; then
    if systemctl is-active --quiet "${TAG}.service" 2>/dev/null && hy_udp_port_is_listening "$PORT"; then
      repair_current_state "$META_FILE" "$PORT" || true
      if ! validate_full_state "$META_FILE" "$PORT"; then
        hy_write_temp_url_aux_from_meta "$META_FILE" >/dev/null 2>&1 || true
      fi
    else
      rollback_current
      USED["$PORT"]=1
      continue
    fi
  fi

  print_success_from_meta "$META_FILE"
  exit 0
done

hy_die "临时节点创建失败，已回滚（尝试次数: ${MAX_START_RETRIES}）"
__HY_MKTEMP__
  chmod 755 /usr/local/sbin/hy2_mktemp.sh
}

write_systemd_units() {
  cat >/etc/systemd/system/hy2-managed-restore.service <<'__HY_UNIT_RESTORE__'
[Unit]
Description=Restore managed HY2 runtime state
After=local-fs.target nftables.service systemd-tmpfiles-setup.service
Wants=nftables.service
Before=multi-user.target
ConditionPathIsDirectory=/var/lib/hy2

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/hy2
ExecStartPre=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/hy2.conf
ExecStart=/usr/local/sbin/hy2_restore_all.sh

[Install]
WantedBy=multi-user.target
__HY_UNIT_RESTORE__
  chmod 644 /etc/systemd/system/hy2-managed-restore.service

  cat >/etc/systemd/system/hy2-managed-shutdown-save.service <<'__HY_UNIT_SHUTSAVE__'
[Unit]
Description=Save managed HY2 quota state before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target kexec.target
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /run/hy2
ExecStart=/usr/local/sbin/pq_save_state.sh
TimeoutStartSec=120

[Install]
WantedBy=shutdown.target
WantedBy=halt.target
WantedBy=reboot.target
WantedBy=poweroff.target
WantedBy=kexec.target
__HY_UNIT_SHUTSAVE__
  chmod 644 /etc/systemd/system/hy2-managed-shutdown-save.service

  cat >/etc/systemd/system/hy2-gc.service <<'__HY_UNIT_GC__'
[Unit]
Description=GC expired managed HY2 temporary nodes
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2_gc.sh
__HY_UNIT_GC__
  chmod 644 /etc/systemd/system/hy2-gc.service

  cat >/etc/systemd/system/hy2-gc.timer <<'__HY_UNIT_GC_TIMER__'
[Unit]
Description=Run HY2 managed GC regularly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
__HY_UNIT_GC_TIMER__
  chmod 644 /etc/systemd/system/hy2-gc.timer

  cat >/etc/systemd/system/pq-save.service <<'__HY_UNIT_PQSAVE__'
[Unit]
Description=Persist managed HY2 quota usage
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
__HY_UNIT_PQSAVE__
  chmod 644 /etc/systemd/system/pq-save.service

  cat >/etc/systemd/system/pq-save.timer <<'__HY_UNIT_PQSAVE_TIMER__'
[Unit]
Description=Run managed HY2 quota save periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
__HY_UNIT_PQSAVE_TIMER__
  chmod 644 /etc/systemd/system/pq-save.timer

  cat >/etc/systemd/system/pq-reset.service <<'__HY_UNIT_PQRESET__'
[Unit]
Description=Reset eligible managed HY2 quotas every 30 days
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset_due.sh
__HY_UNIT_PQRESET__
  chmod 644 /etc/systemd/system/pq-reset.service

  cat >/etc/systemd/system/pq-reset.timer <<'__HY_UNIT_PQRESET_TIMER__'
[Unit]
Description=Check due managed HY2 quota resets

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
__HY_UNIT_PQRESET_TIMER__
  chmod 644 /etc/systemd/system/pq-reset.timer

  cat >/etc/systemd/system/journal-vacuum.service <<'__HY_UNIT_JOURNAL__'
[Unit]
Description=Vacuum systemd journal (keep 7 days)

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=7d
__HY_UNIT_JOURNAL__
  chmod 644 /etc/systemd/system/journal-vacuum.service

  cat >/etc/systemd/system/journal-vacuum.timer <<'__HY_UNIT_JOURNAL_TIMER__'
[Unit]
Description=Run journal vacuum daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
__HY_UNIT_JOURNAL_TIMER__
  chmod 644 /etc/systemd/system/journal-vacuum.timer
}

enable_base_automation() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now nftables >/dev/null 2>&1 || true
  systemctl enable --now hy2-gc.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
  systemctl enable --now journal-vacuum.timer >/dev/null 2>&1 || true
  systemctl enable hy2-managed-restore.service >/dev/null 2>&1 || true
  systemctl start hy2-managed-restore.service >/dev/null 2>&1 || true
  systemctl enable hy2-managed-shutdown-save.service >/dev/null 2>&1 || true
}

install_main_core() {
  # shellcheck disable=SC1091
  source /usr/local/lib/hy2/common.sh

  hy_require_root_debian12
  hy_ensure_runtime_dirs
  hy_require_main_env_ready

  local server_ip listen_port cert_file key_file main_password hy_bin url base64_file url_file info_file renew_hook certbot_state
  if server_ip="$(hy_get_public_ipv4 2>/dev/null || true)"; then
    if [[ -n "$server_ip" ]]; then
      hy_require_domain_points_here "$HY_DOMAIN" "$server_ip"
    fi
  fi

  enable_bbr
  install_hysteria_binary

  certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --keep-until-expiring \
    -m "$ACME_EMAIL" \
    -d "$HY_DOMAIN"

  cert_file="/etc/letsencrypt/live/${HY_DOMAIN}/fullchain.pem"
  key_file="/etc/letsencrypt/live/${HY_DOMAIN}/privkey.pem"
  [[ -s "$cert_file" && -s "$key_file" ]] || hy_die "证书文件不存在：${cert_file} / ${key_file}"

  if [[ ! -f "$HY_MAIN_PASSWORD_FILE" ]]; then
    openssl rand -hex 16 > "$HY_MAIN_PASSWORD_FILE"
    chmod 600 "$HY_MAIN_PASSWORD_FILE"
  fi
  main_password="$(tr -d '\r\n' < "$HY_MAIN_PASSWORD_FILE")"
  listen_port="$(hy_main_listen_port || true)"
  [[ "$listen_port" =~ ^[0-9]+$ ]] || listen_port=443

  local cert_q key_q pw_q masq_q salam_q
  cert_q="$(hy_yaml_quote "$cert_file")"
  key_q="$(hy_yaml_quote "$key_file")"
  pw_q="$(hy_yaml_quote "$main_password")"
  masq_q="$(hy_yaml_quote "$MASQ_URL")"
  salam_q="$(hy_yaml_quote "$SALAMANDER_PASSWORD")"

  {
    echo "listen: ${HY_LISTEN}"
    echo
    echo "tls:"
    echo "  cert: ${cert_q}"
    echo "  key: ${key_q}"
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: ${pw_q}"
    echo
    if [[ "$ENABLE_SALAMANDER" == "1" ]]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${salam_q}"
      echo
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: ${masq_q}"
    echo "    rewriteHost: true"
    echo
    echo "speedTest: false"
    echo "disableUDP: false"
    echo "udpIdleTimeout: 60s"
  } >"$HY_MAIN_CFG_FILE"
  chmod 600 "$HY_MAIN_CFG_FILE"

  hy_write_meta "$HY_MAIN_STATE_FILE" \
    "HY_DOMAIN=${HY_DOMAIN}" \
    "HY_LISTEN=${HY_LISTEN}" \
    "PORT=${listen_port}" \
    "SNI=${HY_DOMAIN}" \
    "NODE_NAME=${NODE_NAME}" \
    "CERT_FILE=${cert_file}" \
    "KEY_FILE=${key_file}" \
    "MASQ_URL=${MASQ_URL}" \
    "OBFS_ENABLED=${ENABLE_SALAMANDER}" \
    "OBFS_PASSWORD=${SALAMANDER_PASSWORD}" \
    "PASSWORD_FILE=${HY_MAIN_PASSWORD_FILE}" \
    "INSTALL_EPOCH=$(date +%s)"

  hy_bin="$(command -v hysteria)"
  cat >/etc/systemd/system/hy2.service <<UNIT
[Unit]
Description=Managed Hysteria 2 Main Service
After=network-online.target
Wants=network-online.target
ConditionPathExists=${HY_MAIN_CFG_FILE}

[Service]
Type=simple
User=root
Group=root
ExecStart=${hy_bin} server -c ${HY_MAIN_CFG_FILE}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/hy2.service

  renew_hook="/etc/letsencrypt/renewal-hooks/deploy/reload-hy2-managed.sh"
  install -d -m 755 "$(dirname "$renew_hook")"
  cat >"$renew_hook" <<'__HY_RENEW_HOOK__'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart hy2.service || true
while read -r unit; do
  [[ -n "$unit" ]] || continue
  systemctl restart "$unit" || true
done < <(systemctl list-units --type=service --state=active --no-legend 'hy2-temp-*.service' | awk '{print $1}')
__HY_RENEW_HOOK__
  chmod 755 "$renew_hook"

  systemctl enable certbot.timer >/dev/null 2>&1 || true
  systemctl start certbot.timer >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable hy2.service >/dev/null 2>&1 || true
  systemctl restart hy2.service

  if ! hy_wait_unit_and_udp_port hy2.service "$listen_port" 3 12; then
    systemctl --no-pager --full status hy2.service >&2 || true
    journalctl -u hy2.service --no-pager -n 120 >&2 || true
    hy_die "主节点稳定性校验失败"
  fi

  url="$(hy_main_url_from_state)"
  url_file="/root/hy2_main_url.txt"
  base64_file="/root/hy2_main_subscription_base64.txt"
  info_file="/root/hy2_main_info.env"
  printf '%s\n' "$url" >"$url_file"
  printf '%s' "$url" | hy_base64_one_line >"$base64_file"
  cp "$HY_MAIN_STATE_FILE" "$info_file"
  chmod 600 "$url_file" "$base64_file" "$info_file" 2>/dev/null || true

  echo "================== 主节点信息 =================="
  echo "$url"
  echo
  echo "Base64 订阅："
  cat "$base64_file"
  echo
  echo "保存位置："
  echo "  ${url_file}"
  echo "  ${base64_file}"
  echo "  ${info_file}"
}

print_summary_no_main() {
  cat <<'__HY_DONE__'
==================================================
✅ 新版 HY2 受管系统脚本、配置模板、systemd 单元已全部生成

请先编辑：
  /etc/default/hy2-main

然后执行：
  bash /root/onekey_hy2_main_tls.sh

常用命令：
  id=tmp001 PQ_GIB=50 IP_LIMIT=1 D=1200 hy2_mktemp.sh
  hy2_audit.sh
  pq_audit.sh
  hy2_clear_all.sh
  pq_add.sh 443 500
  ip_set.sh 443 1 120
==================================================
__HY_DONE__
}

main() {
  check_debian12
  need_basic_tools
  cache_self_copy
  install_base_dirs
  install_update_all
  install_env_template
  install_tmpfiles
  write_common_lib
  write_quota_lib
  write_iplimit_lib
  write_render_table
  write_wrappers
  write_maintenance
  write_shell_scripts
  write_systemd_units
  enable_base_automation

  case "$MODE" in
    install-all|--install-all)
      if main_env_ready; then
        install_main_core
      else
        print_summary_no_main
      fi
      ;;
    --install-main|install-main)
      if ! main_env_ready; then
        echo "❌ /etc/default/hy2-main 还未配置完成，请先填写 HY_DOMAIN / ACME_EMAIL / MASQ_URL 等参数" >&2
        exit 1
      fi
      install_main_core
      ;;
    --install-later|install-later)
      cat <<'__HY_LATER__'
✅ 后续模块已安装/刷新：
  - 临时 HY2 节点受管系统
  - UDP 端口配额 save/restore/reset
  - source-IP 限制
  - 统一审计表格
  - GC/save/reset/restore/shutdown-save 自动化

命令：
  id=tmp001 PQ_GIB=50 IP_LIMIT=1 D=1200 hy2_mktemp.sh
  hy2_audit.sh
  pq_audit.sh
  hy2_clear_all.sh
__HY_LATER__
      ;;
    *)
      echo "❌ 未知参数: $MODE" >&2
      exit 1
      ;;
  esac
}

main "$@"
