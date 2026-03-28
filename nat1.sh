#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# NAT 机（出网机）侧：作为 WG 出口，接收来自 VPS 的流量并 MASQUERADE 出网
#
# 目标：支持多台 VPS 共用一台 NAT 机
# 仍然保持：
#   - 开启 IPv4 转发
#   - 配置 iptables FORWARD
#   - 配置 iptables MASQUERADE
#   - 使用 wg-quick@wg-exit
#
# 用法：
#   bash nat.sh init
#   bash nat.sh add <name> <VPS_IP> <VPS_WG_ADDR> '<VPS_WG_PUBLIC_KEY>'
#   bash nat.sh del <name>
#   bash nat.sh list
#   bash nat.sh status
#
# 可覆盖参数（环境变量）：
DEFAULT_WG_IF="wg-exit"
DEFAULT_WG_PORT="51820"
DEFAULT_WG_ADDR="10.66.66.2/24"
DEFAULT_VPS_WG_ADDR="10.66.66.1/32"
DEFAULT_PERSISTENT_KEEPALIVE="25"

WG_IF="${WG_IF:-$DEFAULT_WG_IF}"
WG_PORT="${WG_PORT:-$DEFAULT_WG_PORT}"
WG_ADDR="${WG_ADDR:-$DEFAULT_WG_ADDR}"
VPS_WG_ADDR="${VPS_WG_ADDR:-$DEFAULT_VPS_WG_ADDR}"
PERSISTENT_KEEPALIVE="${PERSISTENT_KEEPALIVE:-$DEFAULT_PERSISTENT_KEEPALIVE}"
WAN_IF="${WAN_IF:-}"

WG_DIR="/etc/wireguard"
CONF_FILE="${WG_DIR}/${WG_IF}.conf"
KEY_FILE="${WG_DIR}/${WG_IF}.key"
PUB_FILE="${WG_DIR}/${WG_IF}.pub"
STATE_FILE="${WG_DIR}/${WG_IF}.env"
PEER_DIR="${WG_DIR}/${WG_IF}-peers.d"

fail(){ echo "❌ $*" >&2; exit 1; }
warn(){ echo "⚠️  $*" >&2; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"; }

ts(){ date +%F_%H%M%S; }
trim(){
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

usage(){
  cat <<EOF_USAGE
用法：
  bash $0 init
  bash $0 add <name> <VPS_IP> <VPS_WG_ADDR> '<VPS_WG_PUBLIC_KEY>'
  bash $0 del <name>
  bash $0 list
  bash $0 status

示例：
  bash $0 init
  bash $0 add vps-1 1.2.3.4 10.66.66.1/32 'PUBLIC_KEY'
  bash $0 del vps-1
  bash $0 list
  bash $0 status
EOF_USAGE
}

install_dirs(){
  install -d -m 700 "$WG_DIR"
  install -d -m 700 "$PEER_DIR"
}

need_packages(){
  export DEBIAN_FRONTEND=noninteractive
  echo "==> 安装依赖（wireguard-tools / iproute2 / iptables / curl）..."
  apt-get update -y >/dev/null
  apt-get install -y wireguard-tools iproute2 iptables curl ca-certificates >/dev/null
}

validate_name(){
  local name="$1"
  [[ -n "$name" ]] || fail "name 不能为空"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "name 非法：仅允许字母、数字、点、下划线、连字符"
}

validate_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local a b c d
  read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
  return 0
}

validate_vps_ip(){
  local ip="$1"
  validate_ipv4 "$ip" || fail "VPS_IP 必须是合法 IPv4：$ip"
}

validate_vps_wg_addr(){
  local addr="$1"
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || fail "VPS_WG_ADDR 格式不正确：$addr（示例：10.66.66.1/32）"
  local ip="${addr%/*}"
  local mask="${addr#*/}"
  validate_ipv4 "$ip" || fail "VPS_WG_ADDR 里的 IP 不合法：$addr"
  [[ "$mask" =~ ^[0-9]+$ ]] || fail "VPS_WG_ADDR 掩码不合法：$addr"
  (( mask >= 0 && mask <= 32 )) || fail "VPS_WG_ADDR 掩码不合法：$addr"
  (( mask == 32 )) || fail "为避免多 Peer 路由冲突，VPS_WG_ADDR 必须使用 /32：$addr"
}

clean_pubkey(){
  local key="$1"
  key="${key//[[:space:]]/}"
  key="${key//\"/}"
  key="${key#<}"
  key="${key%>}"
  printf '%s' "$key"
}

validate_pubkey(){
  local key="$1"
  [[ -n "$key" ]] || fail "VPS_WG_PUBLIC_KEY 不能为空"
  if ! [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    warn "VPS_WG_PUBLIC_KEY 看起来不像标准 WG 公钥（仍继续写入）。值：$key"
  fi
}

peer_file(){
  local name="$1"
  printf '%s/%s.peer\n' "$PEER_DIR" "$name"
}

peer_meta_value(){
  local file="$1" key="$2"
  sed -n "s/^# ${key}: //p" "$file" | head -n1
}

peer_field_value(){
  local file="$1" key="$2"
  awk -F '=' -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$file"
}

render_wg_conf(){
  local out="$1"
  local nat_priv peer

  [[ -f "$KEY_FILE" ]] || fail "缺少 ${KEY_FILE}，请先执行：bash $0 init"
  nat_priv="$(cat "$KEY_FILE")"

  cat >"$out" <<CFG
[Interface]
Address = ${WG_ADDR}
PrivateKey = ${nat_priv}

# 确保能转发 + NAT
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# 允许 wg -> WAN 转发
PostUp = iptables -C FORWARD -i %i -o ${WAN_IF} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -o ${WAN_IF} -j ACCEPT
PostUp = iptables -C FORWARD -i ${WAN_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${WAN_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 出口 NAT
PostUp = iptables -t nat -C POSTROUTING -o ${WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE

PostDown = iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -o ${WAN_IF} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${WAN_IF} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
CFG

  if [[ -d "$PEER_DIR" ]]; then
    while IFS= read -r peer; do
      printf '\n' >>"$out"
      cat "$peer" >>"$out"
    done < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
  fi

  chmod 600 "$out"
}

save_state(){
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF_STATE
WG_PORT=${WG_PORT}
WG_ADDR=${WG_ADDR}
PERSISTENT_KEEPALIVE=${PERSISTENT_KEEPALIVE}
WAN_IF=${WAN_IF}
EOF_STATE
  mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state(){
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  return 0
}

merge_saved_state_if_exists(){
  local saved_wg_port="" saved_wg_addr="" saved_keepalive="" saved_wan_if=""

  [[ -f "$STATE_FILE" ]] || return 0

  saved_wg_port="$(sed -n 's/^WG_PORT=//p' "$STATE_FILE" | head -n1)"
  saved_wg_addr="$(sed -n 's/^WG_ADDR=//p' "$STATE_FILE" | head -n1)"
  saved_keepalive="$(sed -n 's/^PERSISTENT_KEEPALIVE=//p' "$STATE_FILE" | head -n1)"
  saved_wan_if="$(sed -n 's/^WAN_IF=//p' "$STATE_FILE" | head -n1)"

  saved_wg_port="$(trim "$saved_wg_port")"
  saved_wg_addr="$(trim "$saved_wg_addr")"
  saved_keepalive="$(trim "$saved_keepalive")"
  saved_wan_if="$(trim "$saved_wan_if")"

  if [[ "$WG_PORT" == "$DEFAULT_WG_PORT" && -n "$saved_wg_port" ]]; then
    WG_PORT="$saved_wg_port"
  fi
  if [[ "$WG_ADDR" == "$DEFAULT_WG_ADDR" && -n "$saved_wg_addr" ]]; then
    WG_ADDR="$saved_wg_addr"
  fi
  if [[ "$PERSISTENT_KEEPALIVE" == "$DEFAULT_PERSISTENT_KEEPALIVE" && -n "$saved_keepalive" ]]; then
    PERSISTENT_KEEPALIVE="$saved_keepalive"
  fi
  if [[ -z "$WAN_IF" && -n "$saved_wan_if" ]]; then
    WAN_IF="$saved_wan_if"
  fi
}

detect_wan_if(){
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}' || true
}

ensure_nat_keys(){
  local nat_priv
  umask 077

  if [[ -f "$KEY_FILE" && -f "$PUB_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$KEY_FILE" && -f "$CONF_FILE" ]]; then
    nat_priv="$(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
    nat_priv="$(trim "$nat_priv")"
    if [[ -n "$nat_priv" ]]; then
      printf '%s\n' "$nat_priv" >"$KEY_FILE"
      chmod 600 "$KEY_FILE"
    fi
  fi

  if [[ -f "$KEY_FILE" && ! -f "$PUB_FILE" ]]; then
    wg pubkey <"$KEY_FILE" >"$PUB_FILE"
    chmod 600 "$PUB_FILE"
    return 0
  fi

  if [[ ! -f "$KEY_FILE" ]]; then
    echo "==> 生成 NAT 机 WireGuard 密钥（${WG_IF}）..."
    wg genkey | tee "$KEY_FILE" | wg pubkey >"$PUB_FILE"
    chmod 600 "$KEY_FILE" "$PUB_FILE"
  fi
}

import_state_from_existing_conf(){
  local conf_addr conf_wan conf_port conf_keep

  [[ -f "$CONF_FILE" ]] || return 0

  conf_addr="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
  conf_addr="$(trim "$conf_addr")"

  conf_wan="$(sed -n 's#^[[:space:]]*PostUp[[:space:]]*=[[:space:]]*iptables -C FORWARD -i %i -o \([^[:space:]]*\) -j ACCEPT.*$#\1#p' "$CONF_FILE" | head -n1)"
  conf_wan="$(trim "$conf_wan")"

  conf_port="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)$/\1/p' "$CONF_FILE" | head -n1)"
  conf_port="$(trim "$conf_port")"

  conf_keep="$(sed -n 's/^[[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*//p' "$CONF_FILE" | head -n1)"
  conf_keep="$(trim "$conf_keep")"

  if [[ "$WG_ADDR" == "$DEFAULT_WG_ADDR" && -n "$conf_addr" ]]; then
    WG_ADDR="$conf_addr"
  fi
  if [[ "$WG_PORT" == "$DEFAULT_WG_PORT" && -n "$conf_port" ]]; then
    WG_PORT="$conf_port"
  fi
  if [[ "$PERSISTENT_KEEPALIVE" == "$DEFAULT_PERSISTENT_KEEPALIVE" && -n "$conf_keep" ]]; then
    PERSISTENT_KEEPALIVE="$conf_keep"
  fi
  if [[ -z "$WAN_IF" && -n "$conf_wan" ]]; then
    WAN_IF="$conf_wan"
  fi
}

import_existing_peers_if_needed(){
  local peer_count idx line endpoint vps_ip vps_addr vps_pub keep

  [[ -f "$CONF_FILE" ]] || return 0
  peer_count="$(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | wc -l | tr -d ' ')"
  [[ "$peer_count" == "0" ]] || return 0
  grep -q '^[[:space:]]*\[Peer\][[:space:]]*$' "$CONF_FILE" || return 0

  idx=0
  while IFS=$'\t' read -r endpoint vps_addr vps_pub keep; do
    [[ -n "$vps_pub" ]] || continue
    idx=$((idx + 1))
    vps_ip="${endpoint%:*}"
    [[ -n "$vps_ip" ]] || continue
    [[ -n "$keep" ]] || keep="$PERSISTENT_KEEPALIVE"
    write_peer_file "legacy-${idx}" "$vps_ip" "$vps_addr" "$vps_pub" "$keep"
  done < <(
    awk '
      function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      function emit(){ if (in_peer && pub != "") print endpoint "\t" addr "\t" pub "\t" keep }
      /^\[Peer\][[:space:]]*$/ {
        emit()
        in_peer=1
        endpoint=""
        addr=""
        pub=""
        keep=""
        next
      }
      /^\[/ && $0 != "[Peer]" {
        emit()
        in_peer=0
        next
      }
      in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); pub=trim(line); next
      }
      in_peer && /^[[:space:]]*Endpoint[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); endpoint=trim(line); next
      }
      in_peer && /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); addr=trim(line); next
      }
      in_peer && /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ {
        line=$0; sub(/^[^=]*=/, "", line); keep=trim(line); next
      }
      END { emit() }
    ' "$CONF_FILE"
  )

  if (( idx > 0 )); then
    echo "==> 已把旧的 wg 配置里的 Peer 导入到 ${PEER_DIR}/legacy-*.peer"
  fi
}

bootstrap_from_existing_conf_if_needed(){
  install_dirs
  if ! load_state && [[ -f "$CONF_FILE" ]]; then
    import_state_from_existing_conf
    if [[ -z "$WAN_IF" ]]; then
      WAN_IF="$(detect_wan_if)"
    fi
    [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定：WAN_IF=eth0 bash $0 init"
    save_state
  fi
  load_state || true
  import_existing_peers_if_needed
}

write_peer_file(){
  local name="$1" vps_ip="$2" vps_addr="$3" vps_pub="$4" keepalive="$5"
  local file tmp

  file="$(peer_file "$name")"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF_PEER
# name: ${name}
# vps_ip: ${vps_ip}
# vps_wg_addr: ${vps_addr}
[Peer]
PublicKey = ${vps_pub}
Endpoint = ${vps_ip}:${WG_PORT}
AllowedIPs = ${vps_addr}
PersistentKeepalive = ${keepalive}
EOF_PEER
  mv "$tmp" "$file"
  chmod 600 "$file"
}

check_peer_conflicts(){
  local name="$1" vps_ip="$2" vps_addr="$3" vps_pub="$4"
  local file other_name other_ip other_addr other_pub

  while IFS= read -r file; do
    other_name="$(basename "$file" .peer)"
    [[ "$other_name" == "$name" ]] && continue

    other_ip="$(peer_meta_value "$file" vps_ip)"
    other_addr="$(peer_meta_value "$file" vps_wg_addr)"
    other_pub="$(peer_field_value "$file" PublicKey)"

    if [[ -n "$other_addr" && "$other_addr" == "$vps_addr" ]]; then
      fail "VPS_WG_ADDR 冲突：${vps_addr} 已被 ${other_name} 使用"
    fi
    if [[ -n "$other_pub" && "$other_pub" == "$vps_pub" ]]; then
      fail "WireGuard 公钥冲突：该公钥已被 ${other_name} 使用"
    fi
    if [[ -n "$other_ip" && "$other_ip" == "$vps_ip" ]]; then
      fail "VPS_IP 冲突：${vps_ip} 已被 ${other_name} 使用"
    fi
  done < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
}

restart_wg(){
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

  if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "❌ wg-quick@${WG_IF} 启动失败，日志如下：" >&2
    systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
    journalctl -u "wg-quick@${WG_IF}" --no-pager -n 200 >&2 || true
    return 1
  fi
  return 0
}

ensure_runtime_ready(){
  install_dirs
  bootstrap_from_existing_conf_if_needed
  load_state || fail "未找到 ${STATE_FILE}，请先执行：bash $0 init"
  [[ -n "$WAN_IF" ]] || WAN_IF="$(detect_wan_if)"
  [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定后重新 init"
  command -v wg >/dev/null 2>&1 || fail "wg 命令不存在：请先执行 bash $0 init"
  ensure_nat_keys
}

show_nat_pub(){
  [[ -f "$PUB_FILE" ]] || return 0
  echo "==================== NAT 机 WG 公钥 ===================="
  cat "$PUB_FILE"
  echo "========================================================="
}

cmd_init(){
  local old_conf backup_conf tmp_conf

  need_packages
  install_dirs

  merge_saved_state_if_exists

  # 如果是从旧单 Peer 版本升级，尽量自动继承已有配置。
  if [[ -f "$CONF_FILE" && ! -f "$STATE_FILE" ]]; then
    import_state_from_existing_conf
  fi

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if)"
  fi
  [[ -n "$WAN_IF" ]] || fail "无法探测外网网卡 WAN_IF；请手动指定：WAN_IF=eth0 bash $0 init"

  echo "==> 开启 IPv4 转发（并持久化）..."
  cat >/etc/sysctl.d/99-wg-exit.conf <<EOF_SYSCTL
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF_SYSCTL
  sysctl --system >/dev/null 2>&1 || true

  command -v wg >/dev/null 2>&1 || fail "wg 命令不存在：请确认 wireguard-tools 安装成功"

  ensure_nat_keys
  save_state
  import_existing_peers_if_needed

  old_conf=0
  backup_conf=""
  if [[ -f "$CONF_FILE" ]]; then
    old_conf=1
    backup_conf="$(mktemp)"
    cp -a "$CONF_FILE" "$backup_conf"
  fi

  echo "==> 写入 wg-quick 配置（${WG_IF}）..."
  tmp_conf="$(mktemp)"
  render_wg_conf "$tmp_conf"
  mv "$tmp_conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"

  if ! restart_wg; then
    if (( old_conf == 1 )) && [[ -n "$backup_conf" && -f "$backup_conf" ]]; then
      cp -a "$backup_conf" "$CONF_FILE"
      restart_wg >/dev/null 2>&1 || true
    fi
    fail "初始化失败，已尽量回滚到旧配置"
  fi

  echo
  echo "✅ NAT 机 WG-EXIT 初始化完成。"
  echo "外网网卡: ${WAN_IF}"
  echo "接口名: ${WG_IF}"
  echo "Peer 目录: ${PEER_DIR}"
  show_nat_pub
  echo
  echo "下一步：为每台 VPS 执行 add，例如："
  echo "bash $0 add vps-1 1.2.3.4 10.66.66.1/32 'VPS_WG_PUBLIC_KEY'"
}

cmd_add(){
  local name="$1" vps_ip="$2" vps_addr="$3" vps_pub_raw="$4"
  local vps_pub file old_conf old_peer tmp_conf tmp_peer had_old_peer

  ensure_runtime_ready
  validate_name "$name"
  validate_vps_ip "$vps_ip"
  validate_vps_wg_addr "$vps_addr"

  vps_pub="$(clean_pubkey "$vps_pub_raw")"
  validate_pubkey "$vps_pub"
  check_peer_conflicts "$name" "$vps_ip" "$vps_addr" "$vps_pub"

  file="$(peer_file "$name")"
  old_conf="$(mktemp)"
  cp -a "$CONF_FILE" "$old_conf" 2>/dev/null || true

  old_peer="$(mktemp)"
  had_old_peer=0
  if [[ -f "$file" ]]; then
    had_old_peer=1
    cp -a "$file" "$old_peer"
  fi

  write_peer_file "$name" "$vps_ip" "$vps_addr" "$vps_pub" "$PERSISTENT_KEEPALIVE"

  tmp_conf="$(mktemp)"
  render_wg_conf "$tmp_conf"
  mv "$tmp_conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"

  if ! restart_wg; then
    if (( had_old_peer == 1 )); then
      cp -a "$old_peer" "$file"
    else
      rm -f "$file"
    fi
    if [[ -f "$old_conf" && -s "$old_conf" ]]; then
      cp -a "$old_conf" "$CONF_FILE"
      restart_wg >/dev/null 2>&1 || true
    fi
    fail "新增/更新 Peer 失败，已回滚"
  fi

  echo "✅ 已新增/更新 Peer：${name}"
  echo "VPS_IP: ${vps_ip}"
  echo "VPS_WG_ADDR: ${vps_addr}"
}

cmd_del(){
  local name="$1" file old_conf old_peer tmp_conf

  ensure_runtime_ready
  validate_name "$name"
  file="$(peer_file "$name")"
  [[ -f "$file" ]] || fail "Peer 不存在：${name}"

  old_conf="$(mktemp)"
  cp -a "$CONF_FILE" "$old_conf" 2>/dev/null || true
  old_peer="$(mktemp)"
  cp -a "$file" "$old_peer"

  rm -f "$file"

  tmp_conf="$(mktemp)"
  render_wg_conf "$tmp_conf"
  mv "$tmp_conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"

  if ! restart_wg; then
    cp -a "$old_peer" "$file"
    if [[ -f "$old_conf" && -s "$old_conf" ]]; then
      cp -a "$old_conf" "$CONF_FILE"
      restart_wg >/dev/null 2>&1 || true
    fi
    fail "删除 Peer 失败，已回滚"
  fi

  echo "✅ 已删除 Peer：${name}"
}

cmd_list(){
  local file count name vps_ip vps_addr vps_pub endpoint

  install_dirs
  bootstrap_from_existing_conf_if_needed

  mapfile -t PEER_FILES < <(find "$PEER_DIR" -maxdepth 1 -type f -name '*.peer' | LC_ALL=C sort)
  count="${#PEER_FILES[@]}"

  echo "当前 Peer 目录：${PEER_DIR}"
  echo "当前 Peer 数量：${count}"

  if (( count == 0 )); then
    echo "（空）"
    return 0
  fi

  printf '%-20s %-15s %-18s %s\n' "NAME" "VPS_IP" "VPS_WG_ADDR" "PUBLIC_KEY"
  printf '%-20s %-15s %-18s %s\n' "--------------------" "---------------" "------------------" "--------------------------------------------"

  for file in "${PEER_FILES[@]}"; do
    name="$(basename "$file" .peer)"
    vps_ip="$(peer_meta_value "$file" vps_ip)"
    vps_addr="$(peer_meta_value "$file" vps_wg_addr)"
    vps_pub="$(peer_field_value "$file" PublicKey)"
    printf '%-20s %-15s %-18s %s\n' "$name" "$vps_ip" "$vps_addr" "$vps_pub"
  done
}

cmd_status(){
  install_dirs
  bootstrap_from_existing_conf_if_needed
  load_state || true

  echo "接口名: ${WG_IF}"
  [[ -f "$STATE_FILE" ]] && echo "状态文件: ${STATE_FILE}"
  [[ -d "$PEER_DIR" ]] && echo "Peer 目录: ${PEER_DIR}"
  echo

  cmd_list || true
  echo
  echo "==== systemctl status wg-quick@${WG_IF} ===="
  systemctl --no-pager --full status "wg-quick@${WG_IF}" || true
  echo
  echo "==== wg show ${WG_IF} ===="
  if command -v wg >/dev/null 2>&1; then
    wg show "${WG_IF}" || true
  else
    echo "wg 命令不存在"
  fi
}

main(){
  local cmd="${1:-}"
  need_root

  case "$cmd" in
    init)
      [[ $# -eq 1 ]] || fail "用法: bash $0 init"
      cmd_init
      ;;
    add)
      [[ $# -eq 5 ]] || fail "用法: bash $0 add <name> <VPS_IP> <VPS_WG_ADDR> '<VPS_WG_PUBLIC_KEY>'"
      cmd_add "$2" "$3" "$4" "$5"
      ;;
    del)
      [[ $# -eq 2 ]] || fail "用法: bash $0 del <name>"
      cmd_del "$2"
      ;;
    list)
      [[ $# -eq 1 ]] || fail "用法: bash $0 list"
      cmd_list
      ;;
    status)
      [[ $# -eq 1 ]] || fail "用法: bash $0 status"
      cmd_status
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      fail "未知命令：${cmd}"
      ;;
  esac
}

main "$@"
