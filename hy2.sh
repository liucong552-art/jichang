#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

ENV_FILE="/etc/default/hy2-main"
HY2_LIB_DIR="/usr/local/lib/hy2"
HY2_SBIN_DIR="/usr/local/sbin"
HY2_ROOT_DIR="/root"
HY2_TMPFILES="/etc/tmpfiles.d/hy2.conf"
HY2_LOGROTATE="/etc/logrotate.d/hy2-managed"

check_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "❌ 请以 root 运行本脚本" >&2
    exit 1
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || {
    echo "❌ 本脚本仅适用于 Debian 12 (bookworm)，当前: ${codename:-未知}" >&2
    exit 1
  }
}

need_basic_tools() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 cron socat nftables iproute2 util-linux coreutils grep sed gawk logrotate systemd
}

install_dirs() {
  install -d -m 755 "$HY2_LIB_DIR" "$HY2_SBIN_DIR" /etc/hysteria/temp /var/lib/hy2/main /var/lib/hy2/temp /var/lib/hy2/quota /var/lib/hy2/iplimit /run/hy2 /var/log/hy2
}

install_env_template() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cat >"$ENV_FILE" <<'EOF'
# ==================================================
# HY2 主配置文件
# ==================================================
#
# 说明：
# 1) 主节点固定使用正式证书，监听 443。
# 2) 临时节点使用高端口，复用同一张正式证书。
# 3) 如需切换域名，请先修改 DNS 再更新这里的 HY_DOMAIN。
# 4) 使用 ZeroSSL + acme.sh standalone 申请证书，需要 TCP/80 可达。
#
# 客户端连接域名
HY_DOMAIN=

# 主节点监听地址
HY_LISTEN=:443

# ZeroSSL 一次性注册 / 证书通知邮箱
ACME_EMAIL=

# HTTP/3 / 反向代理伪装目标
MASQ_URL=https://www.apple.com/

# 是否启用 Salamander：0=关闭，1=开启
ENABLE_SALAMANDER=0

# Salamander 密码（仅在 ENABLE_SALAMANDER=1 时填写）
SALAMANDER_PASSWORD=

# 主节点名称
NODE_NAME=HY2-MAIN

# 临时节点默认端口范围
TEMP_PORT_START=40000
TEMP_PORT_END=50050
EOF
    chmod 600 "$ENV_FILE"
  else
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
}

install_tmpfiles() {
  cat >"$HY2_TMPFILES" <<'EOF'
d /run/hy2 0755 root root -
d /var/log/hy2 0755 root root -
EOF
  chmod 644 "$HY2_TMPFILES"
  systemd-tmpfiles --create "$HY2_TMPFILES" >/dev/null 2>&1 || true
}

install_common_lib() {
  cat >"${HY2_LIB_DIR}/common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

HY2_LIB_DIR="/usr/local/lib/hy2"
HY2_SBIN_DIR="/usr/local/sbin"
HY2_STATE_DIR="/var/lib/hy2"
HY2_MAIN_STATE_DIR="${HY2_STATE_DIR}/main"
HY2_TEMP_STATE_DIR="${HY2_STATE_DIR}/temp"
HY2_QUOTA_STATE_DIR="${HY2_STATE_DIR}/quota"
HY2_IPLIMIT_STATE_DIR="${HY2_STATE_DIR}/iplimit"
HY2_ETC_DIR="/etc/hysteria"
HY2_TEMP_CFG_DIR="${HY2_ETC_DIR}/temp"
HY2_DEFAULTS_FILE="/etc/default/hy2-main"
HY2_MAIN_CFG="${HY2_ETC_DIR}/main.yaml"
HY2_MAIN_SERVICE="hy2.service"
HY2_MAIN_STATE_FILE="${HY2_MAIN_STATE_DIR}/main.env"
HY2_MAIN_PASSWORD_FILE="${HY2_MAIN_STATE_DIR}/main.password"
HY2_RENEW_HOOK="/usr/local/lib/hy2/acme-reload.sh"
HY2_LOCK_DIR="/run/hy2"
HY2_LOG_DIR="/var/log/hy2"

hy2_die() {
  echo "❌ $*" >&2
  exit 1
}

hy2_require_root_debian12() {
  if [[ "$(id -u)" -ne 0 ]]; then
    hy2_die "请以 root 身份运行"
  fi
  local codename
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  [[ "$codename" == "bookworm" ]] || hy2_die "仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"
}

hy2_ensure_runtime_dirs() {
  install -d -m 755 \
    "$HY2_LIB_DIR" \
    "$HY2_SBIN_DIR" \
    "$HY2_STATE_DIR" \
    "$HY2_MAIN_STATE_DIR" \
    "$HY2_TEMP_STATE_DIR" \
    "$HY2_QUOTA_STATE_DIR" \
    "$HY2_IPLIMIT_STATE_DIR" \
    "$HY2_ETC_DIR" \
    "$HY2_TEMP_CFG_DIR" \
    "$HY2_LOCK_DIR" \
    "$HY2_LOG_DIR"
}

hy2_ensure_lock_dir() {
  install -d -m 755 "$HY2_LOCK_DIR"
}

hy2_acquire_lock_fd() {
  local fd="$1" file="$2" wait_seconds="${3:-20}" fail_msg="${4:-锁繁忙}"
  hy2_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -w "$wait_seconds" "$fd" || hy2_die "$fail_msg"
}

hy2_try_lock_fd() {
  local fd="$1" file="$2"
  hy2_ensure_lock_dir
  eval "exec ${fd}>\"${file}\""
  flock -n "$fd"
}

hy2_meta_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$0 !~ /^[[:space:]]*#/ && $1==k {sub($1"=",""); print; exit}' "$file"
}

hy2_write_meta() {
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

hy2_meta_upsert() {
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

hy2_yaml_quote() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1]
print("'" + s.replace("'", "''") + "'")
PY
}

hy2_urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

hy2_parse_gib_to_bytes() {
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

hy2_base64_one_line() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

hy2_human_bytes() {
  python3 - "$1" <<'PY'
import sys
n = int(sys.argv[1])
units = ['B','KiB','MiB','GiB','TiB']
v = float(n)
for u in units:
    if v < 1024 or u == units[-1]:
        print(f"{v:.2f}{u}")
        break
    v /= 1024.0
PY
}

hy2_pct_text() {
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

hy2_ttl_human() {
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

hy2_beijing_time() {
  local epoch="${1:-0}"
  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf 'N/A\n'
    return 0
  fi
  TZ='Asia/Shanghai' date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'N/A\n'
}

hy2_port_is_listening_udp() {
  local port="$1"
  ss -lunH 2>/dev/null | awk -v p="$port" '$4 ~ ":" p "$" {found=1} END{exit !found}'
}

hy2_wait_unit_and_udp_port() {
  local unit="$1" port="$2"
  local need_consecutive="${3:-3}" max_checks="${4:-12}"
  local consecutive=0 i
  for i in $(seq 1 "$max_checks"); do
    if systemctl is-active --quiet "$unit" 2>/dev/null && hy2_port_is_listening_udp "$port"; then
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

hy2_unit_state() {
  local unit="$1"
  local state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active|reloading|inactive|failed|activating|deactivating)
      ;;
    "")
      if [[ -f "/etc/systemd/system/${unit}" || -f "/lib/systemd/system/${unit}" ]]; then
        state="inactive"
      else
        state="missing"
      fi
      ;;
  esac
  printf '%s\n' "${state:-missing}"
}

hy2_parse_port_from_listen() {
  local listen="${1:-}"
  if [[ "$listen" =~ ([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

hy2_parse_port_from_cfg() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 1
  sed -nE "s/^[[:space:]]*listen:[[:space:]]*['\"]?:?([0-9]+)['\"]?[[:space:]]*$/\1/p" "$cfg" | head -n 1
}

hy2_main_port() {
  local port=""
  port="$(hy2_meta_get "$HY2_MAIN_STATE_FILE" MAIN_PORT 2>/dev/null || true)"
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$port"
    return 0
  fi
  if [[ -f "$HY2_DEFAULTS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$HY2_DEFAULTS_FILE"
    port="$(hy2_parse_port_from_listen "${HY_LISTEN:-:443}" || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  printf '443\n'
}

hy2_temp_meta_file() {
  printf '%s/%s.env\n' "$HY2_TEMP_STATE_DIR" "$1"
}

hy2_temp_cfg_file() {
  printf '%s/%s.yaml\n' "$HY2_TEMP_CFG_DIR" "$1"
}

hy2_temp_unit_file() {
  printf '/etc/systemd/system/%s.service\n' "$1"
}

hy2_temp_url_file() {
  printf '%s/%s.url\n' "$HY2_TEMP_STATE_DIR" "$1"
}

hy2_quota_meta_file() {
  printf '%s/%s.env\n' "$HY2_QUOTA_STATE_DIR" "$1"
}

hy2_iplimit_meta_file() {
  printf '%s/%s.env\n' "$HY2_IPLIMIT_STATE_DIR" "$1"
}

hy2_collect_temp_tags() {
  {
    for meta in "$HY2_TEMP_STATE_DIR"/*.env; do
      [[ -f "$meta" ]] || continue
      hy2_meta_get "$meta" TAG || true
    done
    for unit in /etc/systemd/system/hy2-temp-*.service; do
      [[ -f "$unit" ]] || continue
      basename "$unit" .service
    done
  } | awk 'NF {print}' | sort -u
}

hy2_temp_owner_port_from_aux() {
  local tag="$1"
  local file port
  for file in "$HY2_QUOTA_STATE_DIR"/*.env "$HY2_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    if [[ "$(hy2_meta_get "$file" OWNER_TAG 2>/dev/null || true)" == "$tag" ]]; then
      port="$(hy2_meta_get "$file" PORT 2>/dev/null || true)"
      if [[ "$port" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    fi
  done
  return 1
}

hy2_temp_port_from_any() {
  local tag="$1"
  local meta cfg port
  meta="$(hy2_temp_meta_file "$tag")"
  if [[ -f "$meta" ]]; then
    port="$(hy2_meta_get "$meta" PORT 2>/dev/null || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  if port="$(hy2_temp_owner_port_from_aux "$tag" 2>/dev/null || true)"; then
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  cfg="$(hy2_temp_cfg_file "$tag")"
  if [[ -f "$cfg" ]]; then
    port="$(hy2_parse_port_from_cfg "$cfg" 2>/dev/null || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  fi
  return 1
}

hy2_safe_id() {
  local raw="$1"
  [[ "$raw" =~ ^[A-Za-z0-9._-]+$ ]] || hy2_die "非法 id/tag：${raw}；仅允许字母、数字、点、下划线、连字符"
  printf '%s\n' "$raw"
}

hy2_temp_tag_from_id() {
  local raw_id="$1"
  printf 'hy2-temp-%s\n' "$raw_id"
}

hy2_guess_owner_for_port() {
  local port="$1"
  local temp_meta temp_port tag main_port
  for temp_meta in "$HY2_TEMP_STATE_DIR"/*.env; do
    [[ -f "$temp_meta" ]] || continue
    temp_port="$(hy2_meta_get "$temp_meta" PORT 2>/dev/null || true)"
    if [[ "$temp_port" == "$port" ]]; then
      tag="$(hy2_meta_get "$temp_meta" TAG 2>/dev/null || true)"
      printf 'temp:%s\n' "$tag"
      return 0
    fi
  done
  main_port="$(hy2_main_port)"
  if [[ "$main_port" == "$port" ]]; then
    printf 'main:main\n'
    return 0
  fi
  printf 'manual:\n'
}

hy2_collect_used_ports() {
  ss -lunH 2>/dev/null | awk '{print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p'
  for meta in "$HY2_TEMP_STATE_DIR"/*.env "$HY2_QUOTA_STATE_DIR"/*.env "$HY2_IPLIMIT_STATE_DIR"/*.env; do
    [[ -f "$meta" ]] || continue
    hy2_meta_get "$meta" PORT || true
  done
  for cfg in "$HY2_TEMP_CFG_DIR"/*.yaml; do
    [[ -f "$cfg" ]] || continue
    hy2_parse_port_from_cfg "$cfg" || true
  done
  hy2_main_port || true
}

hy2_load_defaults() {
  [[ -f "$HY2_DEFAULTS_FILE" ]] || hy2_die "缺少 ${HY2_DEFAULTS_FILE}"
  # shellcheck disable=SC1090
  set -a
  . "$HY2_DEFAULTS_FILE"
  set +a
  : "${HY_DOMAIN:?缺少 HY_DOMAIN}"
  : "${HY_LISTEN:=:443}"
  : "${MASQ_URL:?缺少 MASQ_URL}"
  : "${ENABLE_SALAMANDER:=0}"
  : "${SALAMANDER_PASSWORD:=}"
  : "${NODE_NAME:=HY2-MAIN}"
  : "${TEMP_PORT_START:=40000}"
  : "${TEMP_PORT_END:=50050}"
}

hy2_main_cert_paths() {
  local domain="${1:?need domain}"
  printf '%s\n%s\n' "/etc/hysteria/certs/${domain}/fullchain.pem" "/etc/hysteria/certs/${domain}/privkey.pem"
}

hy2_build_url() {
  local auth="$1" domain="$2" port="$3" node_name="$4" enable_obfs="${5:-0}" obfs_pass="${6:-}" sni="${7:-$domain}"
  local auth_q sni_q node_q obfs_q url
  auth_q="$(hy2_urlencode "$auth")"
  sni_q="$(hy2_urlencode "$sni")"
  node_q="$(hy2_urlencode "$node_name")"
  url="hy2://${auth_q}@${domain}:${port}/?sni=${sni_q}"
  if [[ "$enable_obfs" == "1" ]]; then
    obfs_q="$(hy2_urlencode "$obfs_pass")"
    url="${url}&obfs=salamander&obfs-password=${obfs_q}"
  fi
  url="${url}#${node_q}"
  printf '%s\n' "$url"
}

hy2_write_server_cfg() {
  local cfg="$1" listen_value="$2" password="$3" cert="$4" key="$5" masq_url="$6" enable_obfs="${7:-0}" obfs_pass="${8:-}"
  local cert_q key_q pwd_q masq_q obfs_q listen_q
  cert_q="$(hy2_yaml_quote "$cert")"
  key_q="$(hy2_yaml_quote "$key")"
  pwd_q="$(hy2_yaml_quote "$password")"
  masq_q="$(hy2_yaml_quote "$masq_url")"
  obfs_q="$(hy2_yaml_quote "$obfs_pass")"
  if [[ "$listen_value" =~ ^[0-9]+$ ]]; then
    listen_value=":${listen_value}"
  fi
  listen_q="$(hy2_yaml_quote "$listen_value")"

  {
    printf 'listen: %s\n\n' "$listen_q"
    printf 'tls:\n'
    printf '  cert: %s\n' "$cert_q"
    printf '  key: %s\n\n' "$key_q"
    printf 'auth:\n'
    printf '  type: password\n'
    printf '  password: %s\n\n' "$pwd_q"
    if [[ "$enable_obfs" == "1" ]]; then
      printf 'obfs:\n'
      printf '  type: salamander\n'
      printf '  salamander:\n'
      printf '    password: %s\n\n' "$obfs_q"
    fi
    printf 'masquerade:\n'
    printf '  type: proxy\n'
    printf '  proxy:\n'
    printf '    url: %s\n' "$masq_q"
    printf '    rewriteHost: true\n\n'
    printf 'speedTest: false\n'
    printf 'disableUDP: false\n'
    printf 'udpIdleTimeout: 60s\n'
  } >"$cfg"
  chmod 600 "$cfg" 2>/dev/null || true
}

hy2_temp_unit_text() {
  local tag="$1" cfg="$2"
  cat <<UNIT
[Unit]
Description=Temporary Hysteria 2 ${tag}
After=network-online.target hy2-managed-restore.service
Wants=network-online.target
ConditionPathExists=${cfg}
ConditionPathExists=$(hy2_temp_meta_file "$tag")

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

hy2_write_temp_unit() {
  local tag="$1" cfg="$2" unit_file
  unit_file="$(hy2_temp_unit_file "$tag")"
  hy2_temp_unit_text "$tag" "$cfg" >"$unit_file"
  chmod 644 "$unit_file"
}

hy2_log() {
  local file="$1"
  shift
  install -d -m 755 "$HY2_LOG_DIR" >/dev/null 2>&1 || true
  printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >>"${HY2_LOG_DIR}/${file}"
}
EOF
  chmod 644 "${HY2_LIB_DIR}/common.sh"
}

install_render_table() {
  cat >"${HY2_LIB_DIR}/render_table.py" <<'EOF'
#!/usr/bin/env python3
import os
import shutil
import sys
import unicodedata

SCHEMAS = {
    "hy2": [
        {"name": "NAME",  "min": 12, "ideal": 18, "max": 34, "align": "left",  "weight": 10},
        {"name": "STATE", "min":  6, "ideal":  7, "max": 10, "align": "left",  "weight":  2},
        {"name": "PORT",  "min":  5, "ideal":  5, "max":  5, "align": "right", "weight":  1},
        {"name": "LISN",  "min":  4, "ideal":  4, "max":  4, "align": "left",  "weight":  1},
        {"name": "QUOTA", "min":  6, "ideal":  8, "max": 10, "align": "left",  "weight":  1},
        {"name": "LIMIT", "min":  7, "ideal":  9, "max": 14, "align": "right", "weight":  1},
        {"name": "USED",  "min":  7, "ideal":  9, "max": 14, "align": "right", "weight":  1},
        {"name": "LEFT",  "min":  7, "ideal":  9, "max": 14, "align": "right", "weight":  1},
        {"name": "USE%",  "min":  6, "ideal":  6, "max":  6, "align": "right", "weight":  1},
        {"name": "TTL",   "min":  6, "ideal": 10, "max": 14, "align": "left",  "weight":  2},
        {"name": "EXPBJ", "min": 10, "ideal": 19, "max": 19, "align": "left",  "weight":  3},
        {"name": "IPLM",  "min":  4, "ideal":  4, "max":  6, "align": "right", "weight":  1},
        {"name": "IPACT", "min":  5, "ideal":  5, "max":  7, "align": "right", "weight":  1},
        {"name": "STKY",  "min":  4, "ideal":  6, "max":  8, "align": "right", "weight":  1},
    ],
    "pq": [
        {"name": "PORT",   "min":  5, "ideal":  5, "max":  5, "align": "right", "weight": 1},
        {"name": "OWNER",  "min": 10, "ideal": 20, "max": 40, "align": "left",  "weight": 8},
        {"name": "STATE",  "min":  6, "ideal":  8, "max": 10, "align": "left",  "weight": 2},
        {"name": "LIMIT",  "min":  7, "ideal":  9, "max": 14, "align": "right", "weight": 1},
        {"name": "USED",   "min":  7, "ideal":  9, "max": 14, "align": "right", "weight": 1},
        {"name": "LEFT",   "min":  7, "ideal":  9, "max": 14, "align": "right", "weight": 1},
        {"name": "USE%",   "min":  6, "ideal":  6, "max":  6, "align": "right", "weight": 1},
        {"name": "RESET",  "min":  5, "ideal":  5, "max": 10, "align": "left",  "weight": 1},
        {"name": "NEXTBJ", "min": 10, "ideal": 19, "max": 19, "align": "left",  "weight": 3},
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
    return shutil.get_terminal_size(fallback=(160, 24)).columns

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
        print("usage: render_table.py <hy2|pq>", file=sys.stderr)
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
EOF
  chmod 755 "${HY2_LIB_DIR}/render_table.py"
}

install_quota_lib() {
  cat >"${HY2_LIB_DIR}/quota-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

HY2_PQ_TABLE="hy2_pq"
HY2_PQ_INPUT_CHAIN="pq_input"
HY2_PQ_OUTPUT_CHAIN="pq_output"
HY2_PQ_LOCK_FILE="${HY2_LOCK_DIR}/quota.lock"

hy2_pq_lock() {
  if [[ "${HY2_PQ_LOCK_HELD:-0}" != "1" ]]; then
    hy2_acquire_lock_fd 9 "$HY2_PQ_LOCK_FILE" 20 "quota 锁繁忙"
    export HY2_PQ_LOCK_HELD=1
  fi
}

hy2_pq_counter_in() { printf 'hy2_pq_in_%s\n' "$1"; }
hy2_pq_counter_out() { printf 'hy2_pq_out_%s\n' "$1"; }
hy2_pq_quota_obj() { printf 'hy2_pq_q_%s\n' "$1"; }
hy2_pq_comment_count_in() { printf 'hy2-pq-count-in-%s\n' "$1"; }
hy2_pq_comment_count_out() { printf 'hy2-pq-count-out-%s\n' "$1"; }
hy2_pq_comment_drop_in() { printf 'hy2-pq-drop-in-%s\n' "$1"; }
hy2_pq_comment_drop_out() { printf 'hy2-pq-drop-out-%s\n' "$1"; }

hy2_pq_meta_owner_exists() {
  local meta="$1"
  local owner_tag owner_kind
  owner_tag="$(hy2_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(hy2_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(hy2_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  if [[ "$owner_kind" == "main" ]]; then
    [[ -f "$HY2_MAIN_STATE_FILE" ]] || return 1
  fi
  return 0
}

hy2_pq_ensure_base() {
  hy2_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$HY2_PQ_TABLE" >/dev/null 2>&1 || nft add table inet "$HY2_PQ_TABLE"
  nft list chain inet "$HY2_PQ_TABLE" "$HY2_PQ_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY2_PQ_TABLE" "$HY2_PQ_INPUT_CHAIN" '{ type filter hook input priority 0; policy accept; }'
  nft list chain inet "$HY2_PQ_TABLE" "$HY2_PQ_OUTPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY2_PQ_TABLE" "$HY2_PQ_OUTPUT_CHAIN" '{ type filter hook output priority 0; policy accept; }'
}

hy2_pq_wipe_runtime_table() {
  hy2_pq_lock
  nft delete table inet "$HY2_PQ_TABLE" >/dev/null 2>&1 || true
  hy2_pq_ensure_base
}

hy2_pq_delete_rules_with_comment() {
  local chain="$1" comment="$2"
  nft -a list chain inet "$HY2_PQ_TABLE" "$chain" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$HY2_PQ_TABLE" "$chain" handle "$handle" >/dev/null 2>&1 || true
      done
}

hy2_pq_delete_port_rules() {
  local port="$1"
  hy2_pq_delete_rules_with_comment "$HY2_PQ_INPUT_CHAIN" "$(hy2_pq_comment_drop_in "$port")"
  hy2_pq_delete_rules_with_comment "$HY2_PQ_INPUT_CHAIN" "$(hy2_pq_comment_count_in "$port")"
  hy2_pq_delete_rules_with_comment "$HY2_PQ_OUTPUT_CHAIN" "$(hy2_pq_comment_drop_out "$port")"
  hy2_pq_delete_rules_with_comment "$HY2_PQ_OUTPUT_CHAIN" "$(hy2_pq_comment_count_out "$port")"
}

hy2_pq_delete_port_objects() {
  local port="$1"
  nft delete counter inet "$HY2_PQ_TABLE" "$(hy2_pq_counter_in "$port")" >/dev/null 2>&1 || true
  nft delete counter inet "$HY2_PQ_TABLE" "$(hy2_pq_counter_out "$port")" >/dev/null 2>&1 || true
  nft delete quota inet "$HY2_PQ_TABLE" "$(hy2_pq_quota_obj "$port")" >/dev/null 2>&1 || true
}

hy2_pq_failsafe_block_port() {
  local port="$1"
  hy2_pq_ensure_base
  hy2_pq_delete_port_rules "$port"
  hy2_pq_delete_port_objects "$port"
  nft add rule inet "$HY2_PQ_TABLE" "$HY2_PQ_INPUT_CHAIN" udp dport "$port" drop comment "$(hy2_pq_comment_drop_in "$port")" >/dev/null 2>&1 || true
  nft add rule inet "$HY2_PQ_TABLE" "$HY2_PQ_OUTPUT_CHAIN" udp sport "$port" drop comment "$(hy2_pq_comment_drop_out "$port")" >/dev/null 2>&1 || true
}

hy2_pq_rebuild_port() {
  local port="$1" remaining_bytes="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || hy2_die "hy2_pq_rebuild_port: bad port ${port}"
  [[ "$remaining_bytes" =~ ^[0-9]+$ ]] || hy2_die "hy2_pq_rebuild_port: bad remaining ${remaining_bytes}"

  hy2_pq_lock
  hy2_pq_ensure_base
  hy2_pq_delete_port_rules "$port"
  hy2_pq_delete_port_objects "$port"

  if (( remaining_bytes > 0 )); then
    if ! nft -f - <<EOF_RULES
add counter inet ${HY2_PQ_TABLE} $(hy2_pq_counter_in "$port")
add counter inet ${HY2_PQ_TABLE} $(hy2_pq_counter_out "$port")
add quota inet ${HY2_PQ_TABLE} $(hy2_pq_quota_obj "$port") { over ${remaining_bytes} bytes used 0 bytes }
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_INPUT_CHAIN} udp dport ${port} quota name "$(hy2_pq_quota_obj "$port")" drop comment "$(hy2_pq_comment_drop_in "$port")"
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_INPUT_CHAIN} udp dport ${port} counter name "$(hy2_pq_counter_in "$port")" comment "$(hy2_pq_comment_count_in "$port")"
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_OUTPUT_CHAIN} udp sport ${port} quota name "$(hy2_pq_quota_obj "$port")" drop comment "$(hy2_pq_comment_drop_out "$port")"
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_OUTPUT_CHAIN} udp sport ${port} counter name "$(hy2_pq_counter_out "$port")" comment "$(hy2_pq_comment_count_out "$port")"
EOF_RULES
    then
      hy2_pq_failsafe_block_port "$port"
      return 1
    fi
  else
    if ! nft -f - <<EOF_RULES
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_INPUT_CHAIN} udp dport ${port} drop comment "$(hy2_pq_comment_drop_in "$port")"
add rule inet ${HY2_PQ_TABLE} ${HY2_PQ_OUTPUT_CHAIN} udp sport ${port} drop comment "$(hy2_pq_comment_drop_out "$port")"
EOF_RULES
    then
      hy2_pq_failsafe_block_port "$port"
      return 1
    fi
  fi
}

hy2_pq_counter_bytes() {
  local obj="$1"
  nft list counter inet "$HY2_PQ_TABLE" "$obj" 2>/dev/null \
    | awk '/bytes/ { for (i = 1; i <= NF; i++) if ($i == "bytes") { gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit } }'
}

hy2_pq_live_used_bytes() {
  local port="$1"
  local in_b out_b
  in_b="$(hy2_pq_counter_bytes "$(hy2_pq_counter_in "$port")" || true)"
  out_b="$(hy2_pq_counter_bytes "$(hy2_pq_counter_out "$port")" || true)"
  in_b="${in_b:-0}"
  out_b="${out_b:-0}"
  [[ "$in_b" =~ ^[0-9]+$ ]] || in_b=0
  [[ "$out_b" =~ ^[0-9]+$ ]] || out_b=0
  printf '%s\n' $((in_b + out_b))
}

hy2_pq_state() {
  local port="$1"
  local meta original saved live used left
  meta="$(hy2_quota_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  if ! hy2_pq_meta_owner_exists "$meta"; then
    printf 'orphan\n'
    return 0
  fi
  original="$(hy2_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy2_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy2_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  if (( left <= 0 )); then
    printf 'exhausted\n'
    return 0
  fi
  if nft list counter inet "$HY2_PQ_TABLE" "$(hy2_pq_counter_in "$port")" >/dev/null 2>&1 \
    && nft list counter inet "$HY2_PQ_TABLE" "$(hy2_pq_counter_out "$port")" >/dev/null 2>&1 \
    && nft list quota inet "$HY2_PQ_TABLE" "$(hy2_pq_quota_obj "$port")" >/dev/null 2>&1
  then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}

hy2_pq_write_meta() {
  local port="$1" original="$2" saved="$3" remaining="$4" owner_kind="$5" owner_tag="$6" duration_seconds="$7" expire_epoch="$8" next_reset_epoch="$9" interval_seconds="${10}" created_epoch="${11}" last_reset_epoch="${12}" last_save_epoch="${13}"
  hy2_write_meta "$(hy2_quota_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "ORIGINAL_LIMIT_BYTES=${original}" \
    "SAVED_USED_BYTES=${saved}" \
    "LIMIT_BYTES=${remaining}" \
    "USED_BYTES=${saved}" \
    "LEFT_BYTES=${remaining}" \
    "RESET_INTERVAL_SECONDS=${interval_seconds}" \
    "NEXT_RESET_EPOCH=${next_reset_epoch}" \
    "DURATION_SECONDS=${duration_seconds}" \
    "EXPIRE_EPOCH=${expire_epoch}" \
    "CREATED_EPOCH=${created_epoch}" \
    "LAST_RESET_EPOCH=${last_reset_epoch}" \
    "LAST_SAVE_EPOCH=${last_save_epoch}"
}

hy2_pq_add_managed_port() {
  local port="$1" original_bytes="$2" owner_kind="${3:-manual}" owner_tag="${4:-}" duration_seconds="${5:-0}" expire_epoch="${6:-0}"
  [[ "$port" =~ ^[0-9]+$ ]] || hy2_die "端口必须为整数"
  [[ "$original_bytes" =~ ^[0-9]+$ ]] || hy2_die "original_bytes 必须为整数"
  (( original_bytes > 0 )) || hy2_die "配额必须大于 0"

  hy2_pq_lock
  hy2_pq_ensure_base

  local created_epoch interval_seconds next_reset_epoch
  created_epoch="$(date +%s)"
  interval_seconds=0
  next_reset_epoch=0
  if [[ "$duration_seconds" =~ ^[0-9]+$ ]] && (( duration_seconds > 2592000 )); then
    interval_seconds=2592000
    next_reset_epoch=$((created_epoch + interval_seconds))
  fi

  hy2_pq_write_meta "$port" "$original_bytes" 0 "$original_bytes" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "$created_epoch" 0 "$created_epoch"
  hy2_pq_rebuild_port "$port" "$original_bytes"
}

hy2_pq_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  hy2_pq_lock
  if nft list table inet "$HY2_PQ_TABLE" >/dev/null 2>&1; then
    hy2_pq_delete_port_rules "$port"
    hy2_pq_delete_port_objects "$port"
  fi
  rm -f "$(hy2_quota_meta_file "$port")"
}

hy2_pq_save_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy2_pq_meta_owner_exists "$meta" || return 0

  local port original saved live new_saved left next_reset_epoch interval_seconds created_epoch last_reset_epoch owner_kind owner_tag duration_seconds expire_epoch
  port="$(hy2_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(hy2_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy2_meta_get "$meta" SAVED_USED_BYTES || true)"
  owner_kind="$(hy2_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(hy2_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(hy2_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(hy2_meta_get "$meta" EXPIRE_EPOCH || true)"
  next_reset_epoch="$(hy2_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  interval_seconds="$(hy2_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  created_epoch="$(hy2_meta_get "$meta" CREATED_EPOCH || true)"
  last_reset_epoch="$(hy2_meta_get "$meta" LAST_RESET_EPOCH || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy2_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  new_saved=$((saved + live))
  if (( new_saved > original )); then
    new_saved="$original"
  fi
  left=$((original - new_saved))
  if (( left < 0 )); then
    left=0
  fi
  hy2_pq_write_meta "$port" "$original" "$new_saved" "$left" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "${next_reset_epoch:-0}" "${interval_seconds:-0}" "${created_epoch:-$(date +%s)}" "${last_reset_epoch:-0}" "$(date +%s)"
  hy2_pq_rebuild_port "$port" "$left"
  hy2_log pq.log "[save] port=${port} used=${new_saved} left=${left}"
}

hy2_pq_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy2_pq_meta_owner_exists "$meta" || return 0
  local port remaining
  port="$(hy2_meta_get "$meta" PORT || true)"
  remaining="$(hy2_meta_get "$meta" LIMIT_BYTES || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
  hy2_pq_rebuild_port "$port" "$remaining"
}

hy2_pq_reset_due_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy2_pq_meta_owner_exists "$meta" || return 0

  local port original owner_kind owner_tag duration_seconds expire_epoch interval_seconds next_reset_epoch created_epoch now
  port="$(hy2_meta_get "$meta" PORT || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  original="$(hy2_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  owner_kind="$(hy2_meta_get "$meta" OWNER_KIND || true)"
  owner_tag="$(hy2_meta_get "$meta" OWNER_TAG || true)"
  duration_seconds="$(hy2_meta_get "$meta" DURATION_SECONDS || true)"
  expire_epoch="$(hy2_meta_get "$meta" EXPIRE_EPOCH || true)"
  interval_seconds="$(hy2_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  next_reset_epoch="$(hy2_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  created_epoch="$(hy2_meta_get "$meta" CREATED_EPOCH || true)"

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

  hy2_pq_write_meta "$port" "$original" 0 "$original" "$owner_kind" "$owner_tag" "${duration_seconds:-0}" "${expire_epoch:-0}" "$next_reset_epoch" "$interval_seconds" "${created_epoch:-$now}" "$now" "$now"
  hy2_pq_rebuild_port "$port" "$original"
  hy2_log pq.log "[reset] port=${port} reset_to=${original} next_reset=${next_reset_epoch}"
}
EOF
  chmod 644 "${HY2_LIB_DIR}/quota-lib.sh"
}

install_iplimit_lib() {
  cat >"${HY2_LIB_DIR}/iplimit-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

HY2_IL_TABLE="hy2_iplimit"
HY2_IL_INPUT_CHAIN="il_input"
HY2_IL_LOCK_FILE="${HY2_LOCK_DIR}/iplimit.lock"

hy2_il_lock() {
  if [[ "${HY2_IL_LOCK_HELD:-0}" != "1" ]]; then
    hy2_acquire_lock_fd 8 "$HY2_IL_LOCK_FILE" 20 "iplimit 锁繁忙"
    export HY2_IL_LOCK_HELD=1
  fi
}

hy2_il_set4_name() { printf 'hy2_il4_%s\n' "$1"; }
hy2_il_set6_name() { printf 'hy2_il6_%s\n' "$1"; }
hy2_il_comment_refresh4() { printf 'hy2-il4-refresh-%s\n' "$1"; }
hy2_il_comment_claim4() { printf 'hy2-il4-claim-%s\n' "$1"; }
hy2_il_comment_refresh6() { printf 'hy2-il6-refresh-%s\n' "$1"; }
hy2_il_comment_claim6() { printf 'hy2-il6-claim-%s\n' "$1"; }
hy2_il_comment_drop() { printf 'hy2-il-drop-%s\n' "$1"; }

hy2_il_meta_owner_exists() {
  local meta="$1" owner_tag owner_kind
  owner_tag="$(hy2_meta_get "$meta" OWNER_TAG 2>/dev/null || true)"
  owner_kind="$(hy2_meta_get "$meta" OWNER_KIND 2>/dev/null || true)"
  if [[ "$owner_kind" == "temp" && -n "$owner_tag" ]]; then
    [[ -f "$(hy2_temp_meta_file "$owner_tag")" ]] || return 1
  fi
  if [[ "$owner_kind" == "main" ]]; then
    [[ -f "$HY2_MAIN_STATE_FILE" ]] || return 1
  fi
  return 0
}

hy2_il_ensure_base() {
  hy2_ensure_runtime_dirs
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft list table inet "$HY2_IL_TABLE" >/dev/null 2>&1 || nft add table inet "$HY2_IL_TABLE"
  nft list chain inet "$HY2_IL_TABLE" "$HY2_IL_INPUT_CHAIN" >/dev/null 2>&1 || \
    nft add chain inet "$HY2_IL_TABLE" "$HY2_IL_INPUT_CHAIN" '{ type filter hook input priority -10; policy accept; }'
}

hy2_il_wipe_runtime_table() {
  hy2_il_lock
  nft delete table inet "$HY2_IL_TABLE" >/dev/null 2>&1 || true
  hy2_il_ensure_base
}

hy2_il_delete_rules_with_comment() {
  local comment="$1"
  nft -a list chain inet "$HY2_IL_TABLE" "$HY2_IL_INPUT_CHAIN" 2>/dev/null \
    | awk -v c="comment \"${comment}\"" '$0 ~ c {print $NF}' \
    | sort -rn \
    | while read -r handle; do
        [[ -n "$handle" ]] || continue
        nft delete rule inet "$HY2_IL_TABLE" "$HY2_IL_INPUT_CHAIN" handle "$handle" >/dev/null 2>&1 || true
      done
}

hy2_il_delete_port_rules() {
  local port="$1"
  hy2_il_delete_rules_with_comment "$(hy2_il_comment_refresh4 "$port")"
  hy2_il_delete_rules_with_comment "$(hy2_il_comment_claim4 "$port")"
  hy2_il_delete_rules_with_comment "$(hy2_il_comment_refresh6 "$port")"
  hy2_il_delete_rules_with_comment "$(hy2_il_comment_claim6 "$port")"
  hy2_il_delete_rules_with_comment "$(hy2_il_comment_drop "$port")"
}

hy2_il_delete_port_sets() {
  local port="$1"
  nft delete set inet "$HY2_IL_TABLE" "$(hy2_il_set4_name "$port")" >/dev/null 2>&1 || true
  nft delete set inet "$HY2_IL_TABLE" "$(hy2_il_set6_name "$port")" >/dev/null 2>&1 || true
}

hy2_il_failsafe_block_port() {
  local port="$1"
  hy2_il_ensure_base
  hy2_il_delete_port_rules "$port"
  hy2_il_delete_port_sets "$port"
  nft add rule inet "$HY2_IL_TABLE" "$HY2_IL_INPUT_CHAIN" udp dport "$port" drop comment "$(hy2_il_comment_drop "$port")" >/dev/null 2>&1 || true
}

hy2_il_rebuild_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3"
  [[ "$port" =~ ^[0-9]+$ ]] || hy2_die "hy2_il_rebuild_port: bad port ${port}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || hy2_die "hy2_il_rebuild_port: bad limit ${ip_limit}"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || hy2_die "hy2_il_rebuild_port: bad sticky ${sticky_seconds}"

  hy2_il_lock
  hy2_il_ensure_base
  hy2_il_delete_port_rules "$port"
  hy2_il_delete_port_sets "$port"

  if ! nft -f - <<EOF_RULES
add set inet ${HY2_IL_TABLE} $(hy2_il_set4_name "$port") { type ipv4_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add set inet ${HY2_IL_TABLE} $(hy2_il_set6_name "$port") { type ipv6_addr; size ${ip_limit}; flags timeout,dynamic; timeout ${sticky_seconds}s; }
add rule inet ${HY2_IL_TABLE} ${HY2_IL_INPUT_CHAIN} udp dport ${port} ip saddr @$(hy2_il_set4_name "$port") update @$(hy2_il_set4_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(hy2_il_comment_refresh4 "$port")"
add rule inet ${HY2_IL_TABLE} ${HY2_IL_INPUT_CHAIN} udp dport ${port} ip saddr != 0.0.0.0 add @$(hy2_il_set4_name "$port") { ip saddr timeout ${sticky_seconds}s } accept comment "$(hy2_il_comment_claim4 "$port")"
add rule inet ${HY2_IL_TABLE} ${HY2_IL_INPUT_CHAIN} udp dport ${port} ip6 saddr @$(hy2_il_set6_name "$port") update @$(hy2_il_set6_name "$port") { ip6 saddr timeout ${sticky_seconds}s } accept comment "$(hy2_il_comment_refresh6 "$port")"
add rule inet ${HY2_IL_TABLE} ${HY2_IL_INPUT_CHAIN} udp dport ${port} ip6 saddr != :: add @$(hy2_il_set6_name "$port") { ip6 saddr timeout ${sticky_seconds}s } accept comment "$(hy2_il_comment_claim6 "$port")"
add rule inet ${HY2_IL_TABLE} ${HY2_IL_INPUT_CHAIN} udp dport ${port} drop comment "$(hy2_il_comment_drop "$port")"
EOF_RULES
  then
    hy2_il_failsafe_block_port "$port"
    return 1
  fi
}

hy2_il_write_meta() {
  local port="$1" owner_kind="$2" owner_tag="$3" ip_limit="$4" sticky_seconds="$5"
  hy2_write_meta "$(hy2_iplimit_meta_file "$port")" \
    "PORT=${port}" \
    "OWNER_KIND=${owner_kind}" \
    "OWNER_TAG=${owner_tag}" \
    "IP_LIMIT=${ip_limit}" \
    "IP_STICKY_SECONDS=${sticky_seconds}" \
    "SET4_NAME=$(hy2_il_set4_name "$port")" \
    "SET6_NAME=$(hy2_il_set6_name "$port")" \
    "CREATED_EPOCH=$(date +%s)"
}

hy2_il_add_managed_port() {
  local port="$1" ip_limit="$2" sticky_seconds="$3" owner_kind="${4:-manual}" owner_tag="${5:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || hy2_die "端口必须为整数"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || hy2_die "IP_LIMIT 必须为正整数"
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || hy2_die "IP_STICKY_SECONDS 必须为正整数"
  hy2_il_lock
  hy2_il_ensure_base
  hy2_il_write_meta "$port" "$owner_kind" "$owner_tag" "$ip_limit" "$sticky_seconds"
  hy2_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

hy2_il_delete_managed_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  hy2_il_lock
  if nft list table inet "$HY2_IL_TABLE" >/dev/null 2>&1; then
    hy2_il_delete_port_rules "$port"
    hy2_il_delete_port_sets "$port"
  fi
  rm -f "$(hy2_iplimit_meta_file "$port")"
}

hy2_il_restore_one() {
  local meta="$1"
  [[ -f "$meta" ]] || return 0
  hy2_il_meta_owner_exists "$meta" || return 0
  local port ip_limit sticky_seconds
  port="$(hy2_meta_get "$meta" PORT || true)"
  ip_limit="$(hy2_meta_get "$meta" IP_LIMIT || true)"
  sticky_seconds="$(hy2_meta_get "$meta" IP_STICKY_SECONDS || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ "$ip_limit" =~ ^[0-9]+$ ]] && (( ip_limit > 0 )) || return 0
  [[ "$sticky_seconds" =~ ^[0-9]+$ ]] && (( sticky_seconds > 0 )) || return 0
  hy2_il_rebuild_port "$port" "$ip_limit" "$sticky_seconds"
}

hy2_il_active_ips() {
  local port="$1"
  {
    nft list set inet "$HY2_IL_TABLE" "$(hy2_il_set4_name "$port")" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
    nft list set inet "$HY2_IL_TABLE" "$(hy2_il_set6_name "$port")" 2>/dev/null | grep -oE '([0-9a-fA-F:]{2,})' | grep ':' || true
  } | awk '!seen[$0]++' | xargs echo -n
  printf '\n'
}

hy2_il_active_count() {
  local port="$1" ips
  ips="$(hy2_il_active_ips "$port" || true)"
  if [[ -z "$ips" ]]; then
    printf '0\n'
  else
    wc -w <<<"$ips" | tr -d ' '
  fi
}

hy2_il_state() {
  local port="$1" meta
  meta="$(hy2_iplimit_meta_file "$port")"
  [[ -f "$meta" ]] || { printf 'none\n'; return 0; }
  if ! hy2_il_meta_owner_exists "$meta"; then
    printf 'orphan\n'
    return 0
  fi
  if nft list set inet "$HY2_IL_TABLE" "$(hy2_il_set4_name "$port")" >/dev/null 2>&1 \
    && nft list set inet "$HY2_IL_TABLE" "$(hy2_il_set6_name "$port")" >/dev/null 2>&1
  then
    printf 'active\n'
  else
    printf 'stale\n'
  fi
}
EOF
  chmod 644 "${HY2_LIB_DIR}/iplimit-lib.sh"
}

install_main_script() {
  cat >"/root/onekey_hy2_main_tls.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
umask 077

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

install_or_upgrade_hysteria() {
  install -d -m 755 /usr/local/src/hy2-upstream
  local installer="/usr/local/src/hy2-upstream/get_hy2.sh"
  if [[ ! -x "$installer" ]]; then
    curl -fsSL https://get.hy2.sh/ -o "$installer"
    chmod +x "$installer"
  fi
  echo "⚙ 安装 / 更新 Hysteria 2 ..."
  HYSTERIA_USER=root bash "$installer"
  command -v hysteria >/dev/null 2>&1 || hy2_die "未找到 hysteria 可执行文件"
  systemctl disable --now hysteria-server.service >/dev/null 2>&1 || true
}

ensure_acmesh_zerossl() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=3 >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends socat cron >/dev/null 2>&1
  systemctl enable --now cron >/dev/null 2>&1 || true

  local acme_home="/root/.acme.sh"
  local acme_sh="${acme_home}/acme.sh"
  if [[ ! -x "$acme_sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
  fi
  [[ -x "$acme_sh" ]] || hy2_die "acme.sh 安装失败"

  "$acme_sh" --set-default-ca --server zerossl >/dev/null 2>&1 || true
  "$acme_sh" --register-account -m "$ACME_EMAIL" --server zerossl >/dev/null 2>&1 || true
}

issue_or_renew_cert_zerossl() {
  local domain="$1"
  local acme_home="/root/.acme.sh"
  local acme_sh="${acme_home}/acme.sh"
  local cert_dir="/etc/hysteria/certs/${domain}"

  [[ -x "$acme_sh" ]] || hy2_die "acme.sh 不可用"
  install -d -m 700 "$cert_dir"
  write_renew_hook

  "$acme_sh" --set-default-ca --server zerossl >/dev/null 2>&1 || true
  if ! "$acme_sh" --issue --server zerossl --standalone -d "$domain"; then
    if [[ ! -s "${acme_home}/${domain}_ecc/fullchain.cer" && ! -s "${acme_home}/${domain}/fullchain.cer" ]]; then
      hy2_die "ZeroSSL 签发失败：$domain"
    fi
  fi
  "$acme_sh" --install-cert -d "$domain"     --key-file "${cert_dir}/privkey.pem"     --fullchain-file "${cert_dir}/fullchain.pem"     --reloadcmd "$HY2_RENEW_HOOK"

  chmod 600 "${cert_dir}/privkey.pem" "${cert_dir}/fullchain.pem"
}

enable_bbr() {
  echo "=== 1. 启用 BBR ==="
  cat >/etc/sysctl.d/99-hy2-bbr.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYS
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -p /etc/sysctl.d/99-hy2-bbr.conf >/dev/null 2>&1 || true
  echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
}

write_main_unit() {
  local hy_bin="$1"
  cat >/etc/systemd/system/hy2.service <<UNIT
[Unit]
Description=Managed Hysteria 2 Main Service
After=network-online.target hy2-managed-restore.service
Wants=network-online.target
ConditionPathExists=${HY2_MAIN_CFG}

[Service]
Type=simple
User=root
Group=root
ExecStart=${hy_bin} server -c ${HY2_MAIN_CFG}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/hy2.service
}

write_renew_hook() {
  install -d -m 700 "$(dirname "${HY2_RENEW_HOOK}")"
  cat >"${HY2_RENEW_HOOK}" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart hy2.service >/dev/null 2>&1 || true
for svc in $(systemctl list-units --type=service --state=active --no-legend 'hy2-temp-*.service' | awk '{print $1}'); do
  systemctl restart "$svc" >/dev/null 2>&1 || true
done
HOOK
  chmod +x "${HY2_RENEW_HOOK}"
}

main() {
  hy2_require_root_debian12
  hy2_ensure_runtime_dirs
  hy2_load_defaults

  : "${ACME_EMAIL:?缺少 ACME_EMAIL}"
  : "${MASQ_URL:?缺少 MASQ_URL}"
  : "${HY_DOMAIN:?缺少 HY_DOMAIN}"
  : "${HY_LISTEN:=:443}"
  : "${ENABLE_SALAMANDER:=0}"
  : "${SALAMANDER_PASSWORD:=}"
  : "${NODE_NAME:=HY2-MAIN}"

  if [[ "$ENABLE_SALAMANDER" == "1" && -z "$SALAMANDER_PASSWORD" ]]; then
    hy2_die "ENABLE_SALAMANDER=1 时必须设置 SALAMANDER_PASSWORD"
  fi

  enable_bbr

  echo
  echo "=== 2. 安装 / 更新 Hysteria 2 ==="
  install_or_upgrade_hysteria
  local hy_bin
  hy_bin="$(command -v hysteria)"

  echo
  echo "=== 3. 申请 / 续期正式证书（ZeroSSL + acme.sh standalone） ==="
  ensure_acmesh_zerossl
  issue_or_renew_cert_zerossl "$HY_DOMAIN"

  local crt key main_port
  mapfile -t certs < <(hy2_main_cert_paths "$HY_DOMAIN")
  crt="${certs[0]}"
  key="${certs[1]}"
  [[ -s "$crt" && -s "$key" ]] || hy2_die "证书文件不存在：$crt / $key"

  install -m 600 /dev/null "$HY2_MAIN_PASSWORD_FILE" 2>/dev/null || true
  if [[ ! -s "$HY2_MAIN_PASSWORD_FILE" ]]; then
    openssl rand -hex 16 >"$HY2_MAIN_PASSWORD_FILE"
    chmod 600 "$HY2_MAIN_PASSWORD_FILE"
  fi
  local main_password
  main_password="$(tr -d '\r\n' < "$HY2_MAIN_PASSWORD_FILE")"
  [[ -n "$main_password" ]] || hy2_die "主节点密码生成失败"

  main_port="$(hy2_parse_port_from_listen "$HY_LISTEN" || true)"
  [[ "$main_port" =~ ^[0-9]+$ ]] || hy2_die "HY_LISTEN 非法：$HY_LISTEN"
  (( main_port == 443 )) || hy2_die "主节点必须监听 443"

  echo
  echo "=== 4. 写入主节点配置与 systemd ==="
  hy2_write_server_cfg "$HY2_MAIN_CFG" "$HY_LISTEN" "$main_password" "$crt" "$key" "$MASQ_URL" "$ENABLE_SALAMANDER" "$SALAMANDER_PASSWORD"
  write_main_unit "$hy_bin"

  hy2_write_meta "$HY2_MAIN_STATE_FILE" \
    "HY_DOMAIN=${HY_DOMAIN}" \
    "HY_LISTEN=${HY_LISTEN}" \
    "MAIN_PORT=${main_port}" \
    "ACME_EMAIL=${ACME_EMAIL}" \
    "MASQ_URL=${MASQ_URL}" \
    "ENABLE_SALAMANDER=${ENABLE_SALAMANDER}" \
    "SALAMANDER_PASSWORD=${SALAMANDER_PASSWORD}" \
    "NODE_NAME=${NODE_NAME}" \
    "TLS_CERT=${crt}" \
    "TLS_KEY=${key}" \
    "MAIN_PASSWORD_FILE=${HY2_MAIN_PASSWORD_FILE}" \
    "MAIN_PASSWORD=${main_password}" \
    "INSTALL_EPOCH=$(date +%s)"

  systemctl daemon-reload
  systemctl enable hy2.service >/dev/null 2>&1 || true
  systemctl restart hy2.service

  echo
  echo "=== 5. 启动并稳定性校验 ==="
  if ! hy2_wait_unit_and_udp_port hy2.service "$main_port" 3 12; then
    systemctl --no-pager --full status hy2.service >&2 || true
    journalctl -u hy2.service --no-pager -n 120 >&2 || true
    hy2_die "主节点启动失败或未通过稳定性校验"
  fi

  local url
  url="$(hy2_build_url "$main_password" "$HY_DOMAIN" "$main_port" "$NODE_NAME" "$ENABLE_SALAMANDER" "$SALAMANDER_PASSWORD" "$HY_DOMAIN")"
  printf '%s\n' "$url" >/root/hy2_main_url.txt
  printf '%s' "$url" | hy2_base64_one_line >/root/hy2_main_subscription_base64.txt
  chmod 600 /root/hy2_main_url.txt /root/hy2_main_subscription_base64.txt 2>/dev/null || true

  echo
  echo "================== 主节点信息 =================="
  cat /root/hy2_main_url.txt
  echo
  echo "Base64 订阅："
  cat /root/hy2_main_subscription_base64.txt
  echo
  echo "保存位置："
  echo "  /root/hy2_main_url.txt"
  echo "  /root/hy2_main_subscription_base64.txt"
  echo "✅ HY2 主节点安装完成"
}

main "$@"
EOF
  chmod 755 /root/onekey_hy2_main_tls.sh
}

install_quota_scripts() {
  cat >"${HY2_SBIN_DIR}/pq_add.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

PORT="${1:-}"
GIB="${2:-}"
DURATION_SECONDS="${3:-${DURATION_SECONDS:-0}}"
EXPIRE_EPOCH="${4:-${EXPIRE_EPOCH:-0}}"

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy2_die "用法: pq_add.sh <端口> <GiB> [duration_seconds] [expire_epoch]"
[[ -n "$GIB" ]] || hy2_die "用法: pq_add.sh <端口> <GiB> [duration_seconds] [expire_epoch]"
BYTES="$(hy2_parse_gib_to_bytes "$GIB")" || hy2_die "GiB 必须为正数"

OWNER_KIND="${OWNER_KIND:-}"
OWNER_TAG="${OWNER_TAG:-}"
if [[ -z "$OWNER_KIND" ]]; then
  IFS=: read -r OWNER_KIND OWNER_TAG <<<"$(hy2_guess_owner_for_port "$PORT")"
fi
[[ -n "$OWNER_KIND" ]] || OWNER_KIND="manual"

hy2_pq_add_managed_port "$PORT" "$BYTES" "$OWNER_KIND" "$OWNER_TAG" "${DURATION_SECONDS:-0}" "${EXPIRE_EPOCH:-0}"
echo "✅ 已为端口 ${PORT} 设置 HY2 UDP 总配额 $(hy2_human_bytes "$BYTES")"
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_add.sh"

  cat >"${HY2_SBIN_DIR}/pq_del.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy2_die "用法: pq_del.sh <端口>"
hy2_pq_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的配额管理"
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_del.sh"

  cat >"${HY2_SBIN_DIR}/pq_save_state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy2_ensure_runtime_dirs
hy2_pq_lock
rc=0
for meta in "$HY2_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy2_pq_save_one "$meta" || rc=1
done
exit "$rc"
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_save_state.sh"

  cat >"${HY2_SBIN_DIR}/pq_restore_all.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy2_ensure_runtime_dirs
hy2_pq_wipe_runtime_table
rc=0
for meta in "$HY2_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy2_pq_restore_one "$meta" || rc=1
done
exit "$rc"
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_restore_all.sh"

  cat >"${HY2_SBIN_DIR}/pq_reset_due.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

hy2_ensure_runtime_dirs
hy2_pq_lock
rc=0
for meta in "$HY2_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy2_pq_reset_due_one "$meta" || rc=1
done
exit "$rc"
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_reset_due.sh"

  cat >"${HY2_SBIN_DIR}/pq_audit.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh

FILTER_PORT="${1:-}"
if [[ -n "$FILTER_PORT" && ! "$FILTER_PORT" =~ ^[0-9]+$ ]]; then
  hy2_die "用法: pq_audit.sh [port]"
fi

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT

for meta in "$HY2_QUOTA_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  PORT="$(hy2_meta_get "$meta" PORT || true)"
  [[ "$PORT" =~ ^[0-9]+$ ]] || continue
  if [[ -n "$FILTER_PORT" && "$PORT" != "$FILTER_PORT" ]]; then
    continue
  fi
  OWNER_KIND="$(hy2_meta_get "$meta" OWNER_KIND || true)"
  OWNER_TAG="$(hy2_meta_get "$meta" OWNER_TAG || true)"
  ORIGINAL="$(hy2_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  SAVED="$(hy2_meta_get "$meta" SAVED_USED_BYTES || true)"
  NEXT_RESET_EPOCH="$(hy2_meta_get "$meta" NEXT_RESET_EPOCH || true)"
  RESET_INTERVAL_SECONDS="$(hy2_meta_get "$meta" RESET_INTERVAL_SECONDS || true)"
  ORIGINAL="${ORIGINAL:-0}"
  SAVED="${SAVED:-0}"
  LIVE="$(hy2_pq_live_used_bytes "$PORT" || true)"
  LIVE="${LIVE:-0}"
  USED=$((SAVED + LIVE))
  LEFT=$((ORIGINAL - USED))
  (( LEFT < 0 )) && LEFT=0
  OWNER="${OWNER_KIND:-manual}"
  if [[ -n "$OWNER_TAG" ]]; then
    OWNER="${OWNER_KIND:-manual}:${OWNER_TAG}"
  fi
  STATE="$(hy2_pq_state "$PORT")"
  if [[ "$RESET_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && (( RESET_INTERVAL_SECONDS > 0 )); then
    RESET="30d"
    NEXT_RESET_BJ="$(hy2_beijing_time "$NEXT_RESET_EPOCH")"
  else
    RESET="-"
    NEXT_RESET_BJ="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PORT" \
    "$OWNER" \
    "$STATE" \
    "$(hy2_human_bytes "$ORIGINAL")" \
    "$(hy2_human_bytes "$USED")" \
    "$(hy2_human_bytes "$LEFT")" \
    "$(hy2_pct_text "$USED" "$ORIGINAL")" \
    "$RESET" \
    "$NEXT_RESET_BJ" >>"$TMP_ROWS"
done

sort -t $'\t' -k1,1n "$TMP_ROWS" | /usr/local/lib/hy2/render_table.py pq
EOF
  chmod 755 "${HY2_SBIN_DIR}/pq_audit.sh"
}

install_iplimit_scripts() {
  cat >"${HY2_SBIN_DIR}/ip_set.sh" <<'EOF'
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

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy2_die "用法: ip_set.sh <port> <limit> [sticky_seconds]"
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] && (( IP_LIMIT > 0 )) || hy2_die "limit 必须是正整数"

META="$(hy2_iplimit_meta_file "$PORT")"
OWNER_KIND="manual"
OWNER_TAG=""

if [[ -f "$META" ]]; then
  OWNER_KIND="$(hy2_meta_get "$META" OWNER_KIND || true)"
  OWNER_TAG="$(hy2_meta_get "$META" OWNER_TAG || true)"
  if [[ -z "$STICKY_SECONDS" ]]; then
    STICKY_SECONDS="$(hy2_meta_get "$META" IP_STICKY_SECONDS || true)"
  fi
fi

if [[ -z "$OWNER_TAG" || "$OWNER_KIND" == "manual" || -z "$OWNER_KIND" ]]; then
  IFS=: read -r OWNER_KIND OWNER_TAG <<<"$(hy2_guess_owner_for_port "$PORT")"
fi
[[ -n "$OWNER_KIND" ]] || OWNER_KIND="manual"
STICKY_SECONDS="${STICKY_SECONDS:-120}"
[[ "$STICKY_SECONDS" =~ ^[0-9]+$ ]] && (( STICKY_SECONDS > 0 )) || hy2_die "sticky_seconds 必须是正整数"

hy2_il_add_managed_port "$PORT" "$IP_LIMIT" "$STICKY_SECONDS" "$OWNER_KIND" "$OWNER_TAG"
echo "✅ 已将端口 ${PORT} 的 source-IP 限制设为 ${IP_LIMIT}（STICKY=${STICKY_SECONDS}s）"
EOF
  chmod 755 "${HY2_SBIN_DIR}/ip_set.sh"

  cat >"${HY2_SBIN_DIR}/ip_del.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

PORT="${1:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || hy2_die "用法: ip_del.sh <port>"
hy2_il_delete_managed_port "$PORT"
echo "✅ 已删除端口 ${PORT} 的 source-IP 限制"
EOF
  chmod 755 "${HY2_SBIN_DIR}/ip_del.sh"

  cat >"${HY2_SBIN_DIR}/iplimit_restore_all.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

hy2_ensure_runtime_dirs
hy2_il_wipe_runtime_table
rc=0
for meta in "$HY2_IPLIMIT_STATE_DIR"/*.env; do
  [[ -f "$meta" ]] || continue
  hy2_il_restore_one "$meta" || rc=1
done
exit "$rc"
EOF
  chmod 755 "${HY2_SBIN_DIR}/iplimit_restore_all.sh"
}

install_hy2_management_scripts() {
  cat >"${HY2_SBIN_DIR}/hy2_run_temp.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

TAG="${1:?need TAG}"
CFG="${2:?need CONFIG}"
META="$(hy2_temp_meta_file "$TAG")"
HY_BIN="$(command -v hysteria || true)"

[[ -x "$HY_BIN" ]] || hy2_die "未找到 hysteria 可执行文件"
[[ -f "$CFG" ]] || hy2_die "配置不存在：${CFG}"
[[ -f "$META" ]] || hy2_die "meta 不存在：${META}"

EXPIRE_EPOCH="$(hy2_meta_get "$META" EXPIRE_EPOCH || true)"
[[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]] || hy2_die "meta 中 EXPIRE_EPOCH 非法"

NOW="$(date +%s)"
REMAIN=$((EXPIRE_EPOCH - NOW))
if (( REMAIN <= 0 )); then
  FORCE=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
  exit 0
fi

exec timeout --foreground "$REMAIN" "$HY_BIN" server -c "$CFG"
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_run_temp.sh"

  cat >"${HY2_SBIN_DIR}/hy2_cleanup_one.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

TAG="${1:?need TAG}"
MODE="${2:-}"
FORCE="${FORCE:-0}"
META="$(hy2_temp_meta_file "$TAG")"
CFG="$(hy2_temp_cfg_file "$TAG")"
UNIT_FILE="$(hy2_temp_unit_file "$TAG")"
URL_FILE="$(hy2_temp_url_file "$TAG")"
UNIT_NAME="${TAG}.service"
FROM_STOP_POST=0
[[ "$MODE" == "--from-stop-post" ]] && FROM_STOP_POST=1
STOPPOST_BYPASS_FILE="${HY2_LOCK_DIR}/stoppost-bypass.${TAG}"
SKIP_LOCK=0

hy2_ensure_runtime_dirs

if (( FROM_STOP_POST == 1 )) && [[ -f "$STOPPOST_BYPASS_FILE" ]]; then
  BYPASS_PID="$(cat "$STOPPOST_BYPASS_FILE" 2>/dev/null || true)"
  if [[ "$BYPASS_PID" =~ ^[0-9]+$ ]] && kill -0 "$BYPASS_PID" 2>/dev/null; then
    SKIP_LOCK=1
  else
    rm -f "$STOPPOST_BYPASS_FILE"
  fi
fi

if [[ "${HY2_TEMP_LOCK_HELD:-0}" != "1" && "$SKIP_LOCK" != "1" ]]; then
  hy2_acquire_lock_fd 7 "${HY2_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
  export HY2_TEMP_LOCK_HELD=1
fi

PORT="$(hy2_temp_port_from_any "$TAG" 2>/dev/null || true)"

if (( FROM_STOP_POST == 1 )) && [[ "$FORCE" != "1" ]] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
  hy2_pq_save_one "$(hy2_quota_meta_file "$PORT")" >/dev/null 2>&1 || true
fi

if [[ "$FORCE" != "1" && -f "$META" ]]; then
  EXPIRE_EPOCH="$(hy2_meta_get "$META" EXPIRE_EPOCH || true)"
  if [[ "$EXPIRE_EPOCH" =~ ^[0-9]+$ ]]; then
    NOW="$(date +%s)"
    if (( EXPIRE_EPOCH > NOW )); then
      exit 0
    fi
  fi
fi

if (( FROM_STOP_POST == 0 )); then
  if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    printf '%s\n' "$$" >"$STOPPOST_BYPASS_FILE"
    timeout 15 systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || systemctl kill "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$STOPPOST_BYPASS_FILE"
  fi
  if [[ "$PORT" =~ ^[0-9]+$ ]]; then
    hy2_pq_save_one "$(hy2_quota_meta_file "$PORT")" >/dev/null 2>&1 || true
  fi
fi

systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
systemctl reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true

if [[ "$PORT" =~ ^[0-9]+$ ]]; then
  HY2_PQ_LOCK_HELD=0 hy2_pq_delete_managed_port "$PORT" || true
  HY2_IL_LOCK_HELD=0 hy2_il_delete_managed_port "$PORT" || true
fi

rm -f "$STOPPOST_BYPASS_FILE"
rm -f "$CFG" "$META" "$UNIT_FILE" "$URL_FILE"
systemctl daemon-reload >/dev/null 2>&1 || true
hy2_log gc.log "[cleanup] tag=${TAG} port=${PORT:-unknown} mode=${MODE:-normal} force=${FORCE}"
echo "✅ 已清理临时节点：${TAG}"

EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_cleanup_one.sh"

  cat >"${HY2_SBIN_DIR}/hy2_clear_all.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
shopt -s nullglob

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

hy2_ensure_runtime_dirs
hy2_acquire_lock_fd 7 "${HY2_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
export HY2_TEMP_LOCK_HELD=1

mapfile -t TAGS < <(hy2_collect_temp_tags)
if (( ${#TAGS[@]} == 0 )); then
  echo "当前没有任何临时 HY2 节点。"
  exit 0
fi

for tag in "${TAGS[@]}"; do
  [[ -n "$tag" ]] || continue
  FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" || true
done

echo "✅ 所有临时 HY2 节点已清理。"
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_clear_all.sh"

  cat >"${HY2_SBIN_DIR}/hy2_gc.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

hy2_ensure_runtime_dirs
if ! hy2_try_lock_fd 7 "${HY2_LOCK_DIR}/temp.lock"; then
  exit 0
fi
export HY2_TEMP_LOCK_HELD=1

NOW="$(date +%s)"
mapfile -t TAGS < <(hy2_collect_temp_tags)

for tag in "${TAGS[@]}"; do
  [[ -n "$tag" ]] || continue
  meta="$(hy2_temp_meta_file "$tag")"
  cfg="$(hy2_temp_cfg_file "$tag")"
  unit="$(hy2_temp_unit_file "$tag")"

  if [[ ! -f "$meta" ]]; then
    FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" >/dev/null 2>&1 || true
    continue
  fi

  expire_epoch="$(hy2_meta_get "$meta" EXPIRE_EPOCH || true)"
  if [[ ! "$expire_epoch" =~ ^[0-9]+$ ]]; then
    FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" >/dev/null 2>&1 || true
    continue
  fi

  if (( expire_epoch <= NOW )); then
    HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" >/dev/null 2>&1 || true
    continue
  fi

  if [[ ! -f "$cfg" || ! -f "$unit" ]]; then
    if ! systemctl is-active --quiet "${tag}.service" 2>/dev/null; then
      FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$tag" >/dev/null 2>&1 || true
    fi
  fi
done
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_gc.sh"

  cat >"${HY2_SBIN_DIR}/hy2_restore_all.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh

hy2_ensure_runtime_dirs

rc=0

/usr/local/sbin/hy2_gc.sh || rc=1
/usr/local/sbin/pq_restore_all.sh || rc=1
/usr/local/sbin/iplimit_restore_all.sh || rc=1

systemctl daemon-reload >/dev/null 2>&1 || true

exit "$rc"
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_restore_all.sh"

  cat >"${HY2_SBIN_DIR}/hy2_audit.sh" <<'EOF'
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
if [[ "${1:-}" == "--tag" ]]; then
  FILTER_TAG="${2:-}"
elif [[ -n "${1:-}" ]]; then
  FILTER_TAG="${1:-}"
fi

quota_summary() {
  local port="$1"
  local meta state original saved live used left
  meta="$(hy2_quota_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf 'none|-|-|-|-\n'
    return 0
  fi
  original="$(hy2_meta_get "$meta" ORIGINAL_LIMIT_BYTES || true)"
  saved="$(hy2_meta_get "$meta" SAVED_USED_BYTES || true)"
  original="${original:-0}"
  saved="${saved:-0}"
  live="$(hy2_pq_live_used_bytes "$port" || true)"
  live="${live:-0}"
  used=$((saved + live))
  left=$((original - used))
  (( left < 0 )) && left=0
  state="$(hy2_pq_state "$port")"
  printf '%s|%s|%s|%s|%s\n' \
    "$state" \
    "$(hy2_human_bytes "$original")" \
    "$(hy2_human_bytes "$used")" \
    "$(hy2_human_bytes "$left")" \
    "$(hy2_pct_text "$used" "$original")"
}

ip_summary() {
  local port="$1"
  local meta ip_limit sticky active_count
  meta="$(hy2_iplimit_meta_file "$port")"
  if [[ ! -f "$meta" ]]; then
    printf '%s\n' '-|-|-'
    return 0
  fi
  ip_limit="$(hy2_meta_get "$meta" IP_LIMIT || true)"
  sticky="$(hy2_meta_get "$meta" IP_STICKY_SECONDS || true)"
  active_count="$(hy2_il_active_count "$port" || true)"
  printf '%s|%s|%s\n' "${ip_limit:-0}" "${active_count:-0}" "${sticky:-0}"
}

TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_ROWS"' EXIT
FOUND=0

main_port="$(hy2_main_port)"
if [[ -z "$FILTER_TAG" ]]; then
  main_state="$(hy2_unit_state hy2.service)"
  main_lisn="no"
  if [[ "$main_state" == "active" ]] && hy2_port_is_listening_udp "$main_port"; then
    main_lisn="yes"
  fi
  IFS='|' read -r qstate limit used left pct <<<"$(quota_summary "$main_port")"
  IFS='|' read -r ip_limit ip_active sticky <<<"$(ip_summary "$main_port")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "hy2.service" \
    "$main_state" \
    "$main_port" \
    "$main_lisn" \
    "$qstate" \
    "$limit" \
    "$used" \
    "$left" \
    "$pct" \
    "-" \
    "-" \
    "${ip_limit:-0}" \
    "${ip_active:-0}" \
    "${sticky:-0}" >>"$TMP_ROWS"
fi

mapfile -t TAGS < <(hy2_collect_temp_tags)
for tag in "${TAGS[@]}"; do
  [[ -n "$tag" ]] || continue
  if [[ -n "$FILTER_TAG" && "$tag" != "$FILTER_TAG" ]]; then
    continue
  fi
  FOUND=1
  meta="$(hy2_temp_meta_file "$tag")"
  port="$(hy2_temp_port_from_any "$tag" 2>/dev/null || true)"
  expire_epoch="$(hy2_meta_get "$meta" EXPIRE_EPOCH 2>/dev/null || true)"
  [[ "$port" =~ ^[0-9]+$ ]] || port="-"
  state="$(hy2_unit_state "${tag}.service")"
  lisn="no"
  if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$state" == "active" ]] && hy2_port_is_listening_udp "$port"; then
    lisn="yes"
  fi
  IFS='|' read -r qstate limit used left pct <<<"$(quota_summary "$port")"
  IFS='|' read -r ip_limit ip_active sticky <<<"$(ip_summary "$port")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${tag}.service" \
    "$state" \
    "$port" \
    "$lisn" \
    "$qstate" \
    "$limit" \
    "$used" \
    "$left" \
    "$pct" \
    "$(hy2_ttl_human "$expire_epoch")" \
    "$(hy2_beijing_time "$expire_epoch")" \
    "${ip_limit:-0}" \
    "${ip_active:-0}" \
    "${sticky:-0}" >>"$TMP_ROWS"
done

if [[ -n "$FILTER_TAG" && "$FOUND" -eq 0 ]]; then
  exit 1
fi

sort -t $'\t' -k3,3n "$TMP_ROWS" | /usr/local/lib/hy2/render_table.py hy2
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_audit.sh"

  cat >"${HY2_SBIN_DIR}/hy2_mktemp.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# shellcheck disable=SC1091
source /usr/local/lib/hy2/common.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/quota-lib.sh
# shellcheck disable=SC1091
source /usr/local/lib/hy2/iplimit-lib.sh

: "${D:?请用 D=秒 的方式调用，例如：D=600 hy2_mktemp.sh}"

[[ "$D" =~ ^[0-9]+$ ]] && (( D > 0 )) || hy2_die "D 必须是正整数秒"
[[ -z "${PQ_GIB:-}" || "$PQ_GIB" =~ ^[0-9]+([.][0-9]+)?$ ]] || hy2_die "PQ_GIB 必须是正数"
[[ -z "${IP_LIMIT:-}" || "$IP_LIMIT" =~ ^[0-9]+$ ]] || hy2_die "IP_LIMIT 必须是非负整数"
[[ -z "${IP_STICKY_SECONDS:-}" || "$IP_STICKY_SECONDS" =~ ^[0-9]+$ ]] || hy2_die "IP_STICKY_SECONDS 必须是非负整数"

hy2_ensure_runtime_dirs
hy2_acquire_lock_fd 7 "${HY2_LOCK_DIR}/temp.lock" 20 "temp 锁繁忙"
export HY2_TEMP_LOCK_HELD=1

hy2_load_defaults
[[ "$ENABLE_SALAMANDER" == "0" || -n "$SALAMANDER_PASSWORD" ]] || hy2_die "启用 Salamander 时必须设置 SALAMANDER_PASSWORD"

mapfile -t certs < <(hy2_main_cert_paths "$HY_DOMAIN")
CRT="${certs[0]}"
KEY="${certs[1]}"
[[ -s "$CRT" && -s "$KEY" ]] || hy2_die "缺少正式证书，请先执行：bash /root/onekey_hy2_main_tls.sh"

MAIN_PORT="$(hy2_main_port)"
[[ "$TEMP_PORT_START" =~ ^[0-9]+$ && "$TEMP_PORT_END" =~ ^[0-9]+$ ]] || hy2_die "端口范围非法"
(( TEMP_PORT_START >= 1 && TEMP_PORT_END <= 65535 && TEMP_PORT_START < TEMP_PORT_END )) || hy2_die "端口范围非法"

SAFE_ID=""
TAG=""
if [[ -n "${id:-}" ]]; then
  SAFE_ID="$(hy2_safe_id "$id")"
  TAG="$(hy2_temp_tag_from_id "$SAFE_ID")"
else
  TAG="hy2-temp-$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
fi

META="$(hy2_temp_meta_file "$TAG")"
CFG="$(hy2_temp_cfg_file "$TAG")"
UNIT_FILE="$(hy2_temp_unit_file "$TAG")"
URL_FILE="$(hy2_temp_url_file "$TAG")"
UNIT_NAME="${TAG}.service"

if [[ -n "${PQ_GIB:-}" ]]; then
  PQ_LIMIT_BYTES="$(hy2_parse_gib_to_bytes "$PQ_GIB")" || hy2_die "PQ_GIB 转换失败"
else
  PQ_LIMIT_BYTES=""
fi

IP_LIMIT="${IP_LIMIT:-0}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
(( IP_LIMIT >= 0 )) || hy2_die "IP_LIMIT 不能为负数"
(( IP_STICKY_SECONDS > 0 )) || hy2_die "IP_STICKY_SECONDS 必须大于 0"

CREATE_EPOCH="$(date +%s)"
EXPIRE_EPOCH=$((CREATE_EPOCH + D))

rollback_current() {
  FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
}

write_meta_from_current() {
  hy2_write_meta "$META" \
    "TAG=${TAG}" \
    "ID=${SAFE_ID}" \
    "PORT=${PORT}" \
    "HY_DOMAIN=${HY_DOMAIN}" \
    "PASSWORD=${PASSWORD}" \
    "CREATE_EPOCH=${CREATE_EPOCH}" \
    "EXPIRE_EPOCH=${EXPIRE_EPOCH}" \
    "DURATION_SECONDS=${D}" \
    "MASQ_URL=${MASQ_URL}" \
    "ENABLE_SALAMANDER=${ENABLE_SALAMANDER}" \
    "SALAMANDER_PASSWORD=${SALAMANDER_PASSWORD}" \
    "PQ_GIB=${PQ_GIB:-}" \
    "PQ_LIMIT_BYTES=${PQ_LIMIT_BYTES:-}" \
    "IP_LIMIT=${IP_LIMIT}" \
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}"
}

write_url_from_meta() {
  local password domain port enable_obfs obfs_pass
  password="$(hy2_meta_get "$META" PASSWORD || true)"
  domain="$(hy2_meta_get "$META" HY_DOMAIN || true)"
  port="$(hy2_meta_get "$META" PORT || true)"
  enable_obfs="$(hy2_meta_get "$META" ENABLE_SALAMANDER || true)"
  obfs_pass="$(hy2_meta_get "$META" SALAMANDER_PASSWORD || true)"
  [[ -n "$password" && -n "$domain" && "$port" =~ ^[0-9]+$ ]] || return 1
  hy2_build_url "$password" "$domain" "$port" "$TAG" "${enable_obfs:-0}" "$obfs_pass" "$domain" >"$URL_FILE"
  chmod 600 "$URL_FILE" 2>/dev/null || true
}

validate_full_state() {
  local meta="$1" port="$2"
  [[ -f "$meta" ]] || return 1
  [[ -f "$CFG" ]] || return 1
  [[ -f "$UNIT_FILE" ]] || return 1
  [[ -f "$URL_FILE" ]] || return 1
  [[ -n "$(hy2_meta_get "$meta" EXPIRE_EPOCH || true)" ]] || return 1
  [[ -n "$(hy2_meta_get "$meta" PORT || true)" ]] || return 1
  systemctl is-active --quiet "$UNIT_NAME" || return 1
  hy2_port_is_listening_udp "$port" || return 1
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    local qmeta
    qmeta="$(hy2_quota_meta_file "$port")"
    [[ -f "$qmeta" ]] || return 1
    [[ "$(hy2_meta_get "$qmeta" OWNER_KIND || true)" == "temp" ]] || return 1
    [[ "$(hy2_meta_get "$qmeta" OWNER_TAG || true)" == "$TAG" ]] || return 1
    [[ -n "$(hy2_meta_get "$qmeta" ORIGINAL_LIMIT_BYTES || true)" ]] || return 1
    [[ -n "$(hy2_meta_get "$qmeta" LIMIT_BYTES || true)" ]] || return 1
  fi
  if (( IP_LIMIT > 0 )); then
    local imeta
    imeta="$(hy2_iplimit_meta_file "$port")"
    [[ -f "$imeta" ]] || return 1
    [[ "$(hy2_meta_get "$imeta" OWNER_KIND || true)" == "temp" ]] || return 1
    [[ "$(hy2_meta_get "$imeta" OWNER_TAG || true)" == "$TAG" ]] || return 1
    [[ -n "$(hy2_meta_get "$imeta" IP_LIMIT || true)" ]] || return 1
    [[ -n "$(hy2_meta_get "$imeta" IP_STICKY_SECONDS || true)" ]] || return 1
  fi
  /usr/local/sbin/hy2_audit.sh --tag "$TAG" >/dev/null 2>&1
}

repair_existing_node() {
  local meta="$1"
  local exist_expire exist_port exist_password exist_pq_bytes exist_ip_limit exist_sticky exist_obfs exist_obfs_pass exist_masq exist_duration
  exist_expire="$(hy2_meta_get "$meta" EXPIRE_EPOCH || true)"
  [[ "$exist_expire" =~ ^[0-9]+$ ]] || return 1
  if (( exist_expire <= $(date +%s) )); then
    FORCE=1 HY2_TEMP_LOCK_HELD=1 /usr/local/sbin/hy2_cleanup_one.sh "$TAG" >/dev/null 2>&1 || true
    return 2
  fi

  exist_port="$(hy2_meta_get "$meta" PORT || true)"
  exist_password="$(hy2_meta_get "$meta" PASSWORD || true)"
  exist_pq_bytes="$(hy2_meta_get "$meta" PQ_LIMIT_BYTES || true)"
  exist_ip_limit="$(hy2_meta_get "$meta" IP_LIMIT || true)"
  exist_sticky="$(hy2_meta_get "$meta" IP_STICKY_SECONDS || true)"
  exist_obfs="$(hy2_meta_get "$meta" ENABLE_SALAMANDER || true)"
  exist_obfs_pass="$(hy2_meta_get "$meta" SALAMANDER_PASSWORD || true)"
  exist_masq="$(hy2_meta_get "$meta" MASQ_URL || true)"
  exist_duration="$(hy2_meta_get "$meta" DURATION_SECONDS || true)"
  [[ "$exist_port" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$exist_password" ]] || return 1

  PORT="$exist_port"
  PASSWORD="$exist_password"
  EXPIRE_EPOCH="$exist_expire"
  D="$((EXPIRE_EPOCH - $(date +%s)))"
  (( D > 0 )) || D=1
  PQ_LIMIT_BYTES="${exist_pq_bytes:-}"
  IP_LIMIT="${exist_ip_limit:-0}"
  IP_STICKY_SECONDS="${exist_sticky:-120}"

  hy2_write_server_cfg "$CFG" "$PORT" "$PASSWORD" "$CRT" "$KEY" "${exist_masq:-$MASQ_URL}" "${exist_obfs:-0}" "${exist_obfs_pass:-}"
  hy2_write_temp_unit "$TAG" "$CFG"
  write_url_from_meta || true

  if [[ -n "$PQ_LIMIT_BYTES" && ! -f "$(hy2_quota_meta_file "$PORT")" ]]; then
    hy2_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "${exist_duration:-0}" "$EXPIRE_EPOCH" || return 1
  fi

  if (( IP_LIMIT > 0 )) && [[ ! -f "$(hy2_iplimit_meta_file "$PORT")" ]]; then
    hy2_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG" || return 1
  fi

  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl start "$UNIT_NAME" >/dev/null 2>&1 || return 1
  fi
  hy2_wait_unit_and_udp_port "$UNIT_NAME" "$PORT" 3 12 || return 1
  validate_full_state "$meta" "$PORT" || return 1

  echo "✅ 发现同 TAG 现有节点，已补齐缺失状态：${TAG}"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "TTL: $(hy2_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(hy2_beijing_time "$EXPIRE_EPOCH")"
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    echo "配额: $(hy2_human_bytes "$PQ_LIMIT_BYTES")"
  fi
  if (( IP_LIMIT > 0 )); then
    echo "IP_LIMIT: ${IP_LIMIT}"
    echo "IP_STICKY_SECONDS: ${IP_STICKY_SECONDS}"
  fi
  echo "URL: $(cat "$URL_FILE")"
  exit 0
}

if [[ -f "$META" ]]; then
  if repair_existing_node "$META"; then
    exit 0
  fi
fi

MAX_START_RETRIES=25
ATTEMPT=0
declare -A TRIED=()
while (( ATTEMPT < MAX_START_RETRIES )); do
  ATTEMPT=$((ATTEMPT + 1))

  mapfile -t USED_PORTS < <(hy2_collect_used_ports | awk '/^[0-9]+$/ {print}' | sort -n -u)
  declare -A USED=()
  for p in "${USED_PORTS[@]}"; do
    USED["$p"]=1
  done
  for p in "${!TRIED[@]}"; do
    USED["$p"]=1
  done

  PORT=""
  for candidate in $(seq "$TEMP_PORT_START" "$TEMP_PORT_END"); do
    if [[ -z "${USED[$candidate]+x}" ]]; then
      PORT="$candidate"
      break
    fi
  done
  [[ -n "$PORT" ]] || hy2_die "在 ${TEMP_PORT_START}-${TEMP_PORT_END} 范围内没有空闲端口"

  PASSWORD="$(openssl rand -hex 16)"
  CFG="$(hy2_temp_cfg_file "$TAG")"
  UNIT_FILE="$(hy2_temp_unit_file "$TAG")"
  URL_FILE="$(hy2_temp_url_file "$TAG")"

  hy2_write_server_cfg "$CFG" "$PORT" "$PASSWORD" "$CRT" "$KEY" "$MASQ_URL" "$ENABLE_SALAMANDER" "$SALAMANDER_PASSWORD"
  write_meta_from_current
  hy2_write_temp_unit "$TAG" "$CFG"
  write_url_from_meta

  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    if ! hy2_pq_add_managed_port "$PORT" "$PQ_LIMIT_BYTES" temp "$TAG" "$D" "$EXPIRE_EPOCH"; then
      rollback_current
      TRIED["$PORT"]=1
      continue
    fi
  fi

  if (( IP_LIMIT > 0 )); then
    if ! hy2_il_add_managed_port "$PORT" "$IP_LIMIT" "$IP_STICKY_SECONDS" temp "$TAG"; then
      rollback_current
      TRIED["$PORT"]=1
      continue
    fi
  fi

  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true

  if ! systemctl start "$UNIT_NAME"; then
    rollback_current
    TRIED["$PORT"]=1
    continue
  fi

  if ! hy2_wait_unit_and_udp_port "$UNIT_NAME" "$PORT" 3 12; then
    rollback_current
    TRIED["$PORT"]=1
    continue
  fi

  if ! validate_full_state "$META" "$PORT"; then
    if systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null && hy2_port_is_listening_udp "$PORT"; then
      if ! repair_existing_node "$META"; then
        echo "⚠ 节点已监听，但附属状态修复失败；为避免重复创建，不再重试同 TAG。" >&2
      fi
      exit 0
    else
      rollback_current
      TRIED["$PORT"]=1
      continue
    fi
  fi

  echo "✅ 临时节点创建成功"
  echo "TAG: ${TAG}"
  echo "PORT: ${PORT}"
  echo "TTL: $(hy2_ttl_human "$EXPIRE_EPOCH")"
  echo "到期(北京时间): $(hy2_beijing_time "$EXPIRE_EPOCH")"
  if [[ -n "$PQ_LIMIT_BYTES" ]]; then
    echo "配额: $(hy2_human_bytes "$PQ_LIMIT_BYTES")"
  fi
  if (( IP_LIMIT > 0 )); then
    echo "IP_LIMIT: ${IP_LIMIT}"
    echo "IP_STICKY_SECONDS: ${IP_STICKY_SECONDS}"
  fi
  echo "URL: $(cat "$URL_FILE")"
  exit 0
done

hy2_die "临时节点创建失败，已彻底回滚（尝试次数：${MAX_START_RETRIES}）"
EOF
  chmod 755 "${HY2_SBIN_DIR}/hy2_mktemp.sh"
}

install_root_helper() {
  cat >"/root/hy2_temp_audit_all.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

echo "=== HY2 统一审计 ==="
/usr/local/sbin/hy2_audit.sh "${@:-}"
echo
echo "=== 配额审计 ==="
/usr/local/sbin/pq_audit.sh
EOF
  chmod 755 /root/hy2_temp_audit_all.sh
}

install_systemd_units() {
  cat >/etc/systemd/system/hy2-managed-restore.service <<'EOF'
[Unit]
Description=Restore managed HY2 quota / IP-limit / temp state
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
EOF
  chmod 644 /etc/systemd/system/hy2-managed-restore.service

  cat >/etc/systemd/system/hy2-managed-shutdown-save.service <<'EOF'
[Unit]
Description=Save managed HY2 quota usage before shutdown/reboot
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
EOF
  chmod 644 /etc/systemd/system/hy2-managed-shutdown-save.service

  cat >/etc/systemd/system/hy2-gc.service <<'EOF'
[Unit]
Description=GC expired temporary HY2 nodes
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2_gc.sh
EOF
  chmod 644 /etc/systemd/system/hy2-gc.service

  cat >/etc/systemd/system/hy2-gc.timer <<'EOF'
[Unit]
Description=Run HY2 temp GC regularly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/hy2-gc.timer

  cat >/etc/systemd/system/pq-save.service <<'EOF'
[Unit]
Description=Persist managed HY2 quota usage
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_save_state.sh
EOF
  chmod 644 /etc/systemd/system/pq-save.service

  cat >/etc/systemd/system/pq-save.timer <<'EOF'
[Unit]
Description=Run HY2 quota save every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/pq-save.timer

  cat >/etc/systemd/system/pq-reset.service <<'EOF'
[Unit]
Description=Reset due HY2 quota windows

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pq_reset_due.sh
EOF
  chmod 644 /etc/systemd/system/pq-reset.service

  cat >/etc/systemd/system/pq-reset.timer <<'EOF'
[Unit]
Description=Check due HY2 quota resets

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/pq-reset.timer

  cat >/etc/systemd/system/journal-vacuum.service <<'EOF'
[Unit]
Description=Vacuum systemd journal (keep 2 days)

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-time=2d
EOF
  chmod 644 /etc/systemd/system/journal-vacuum.service

  cat >/etc/systemd/system/journal-vacuum.timer <<'EOF'
[Unit]
Description=Daily vacuum systemd journal

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/journal-vacuum.timer
}

install_logrotate_rules() {
  cat >"$HY2_LOGROTATE" <<'EOF'
/var/log/hy2/*.log {
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
EOF
  chmod 644 "$HY2_LOGROTATE"
}

install_update_all() {
  cat >/usr/local/bin/update-all <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 身份运行" >&2
  exit 1
fi
codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
[[ "$codename" == "bookworm" ]] || {
  echo "❌ 仅支持 Debian 12 (bookworm)" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get full-upgrade -y
apt-get --purge autoremove -y
apt-get autoclean -y
apt-get clean -y

BACKPORTS_FILE=/etc/apt/sources.list.d/backports.list
if [[ -f "$BACKPORTS_FILE" ]]; then
  cp "$BACKPORTS_FILE" "${BACKPORTS_FILE}.bak.$(date +%F-%H%M%S)"
fi

cat >"$BACKPORTS_FILE" <<'BEOF'
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
BEOF

apt-get update -o Acquire::Retries=3
arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) img=linux-image-amd64; hdr=linux-headers-amd64 ;;
  arm64) img=linux-image-arm64; hdr=linux-headers-arm64 ;;
  *)
    echo "❌ 未支持架构：$arch" >&2
    exit 1
    ;;
esac
apt-get -t bookworm-backports install -y "$img" "$hdr"

echo "✅ 系统更新完成"
echo "🖥 当前正在运行的内核：$(uname -r)"
echo "⚠ 重启后系统才会真正切换到新内核，请执行：reboot"
EOF
  chmod 755 /usr/local/bin/update-all
}

enable_units() {
  systemctl daemon-reload
  systemctl enable --now nftables >/dev/null 2>&1 || true
  systemctl enable --now hy2-gc.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-save.timer >/dev/null 2>&1 || true
  systemctl enable --now pq-reset.timer >/dev/null 2>&1 || true
  systemctl enable hy2-managed-restore.service >/dev/null 2>&1 || true
  systemctl start hy2-managed-restore.service >/dev/null 2>&1 || true
  systemctl enable hy2-managed-shutdown-save.service >/dev/null 2>&1 || true
  systemctl enable --now journal-vacuum.timer >/dev/null 2>&1 || true
}

main() {
  check_debian12
  need_basic_tools
  install_dirs
  install_env_template
  install_tmpfiles
  install_common_lib
  install_render_table
  install_quota_lib
  install_iplimit_lib
  install_main_script
  install_quota_scripts
  install_iplimit_scripts
  install_hy2_management_scripts
  install_root_helper
  install_systemd_units
  install_logrotate_rules
  install_update_all
  enable_units

  cat <<'DONE'
==================================================
✅ 新版 HY2 受管系统已写入完成（Debian 12）

已生成：
- /etc/default/hy2-main
- /root/onekey_hy2_main_tls.sh
- /root/hy2_temp_audit_all.sh

主库：
- /usr/local/lib/hy2/common.sh
- /usr/local/lib/hy2/quota-lib.sh
- /usr/local/lib/hy2/iplimit-lib.sh
- /usr/local/lib/hy2/render_table.py

管理脚本：
- /usr/local/sbin/hy2_mktemp.sh
- /usr/local/sbin/hy2_cleanup_one.sh
- /usr/local/sbin/hy2_clear_all.sh
- /usr/local/sbin/hy2_gc.sh
- /usr/local/sbin/hy2_run_temp.sh
- /usr/local/sbin/hy2_restore_all.sh
- /usr/local/sbin/hy2_audit.sh
- /usr/local/sbin/pq_add.sh
- /usr/local/sbin/pq_del.sh
- /usr/local/sbin/pq_audit.sh
- /usr/local/sbin/pq_save_state.sh
- /usr/local/sbin/pq_restore_all.sh
- /usr/local/sbin/pq_reset_due.sh
- /usr/local/sbin/ip_set.sh
- /usr/local/sbin/ip_del.sh
- /usr/local/sbin/iplimit_restore_all.sh

下一步：
1) 编辑主配置：
   nano /etc/default/hy2-main

2) 部署主节点：
   bash /root/onekey_hy2_main_tls.sh

3) 创建临时节点：
   D=600 hy2_mktemp.sh
   PQ_GIB=50 D=600 hy2_mktemp.sh
   id=test001 PQ_GIB=20 IP_LIMIT=1 D=86400 hy2_mktemp.sh

4) 审计：
   hy2_audit.sh
   pq_audit.sh
   /root/hy2_temp_audit_all.sh

5) 清理：
   hy2_clear_all.sh
   FORCE=1 hy2_cleanup_one.sh hy2-temp-xxxx

6) 系统维护：
   update-all
==================================================
DONE
}

main "$@"
