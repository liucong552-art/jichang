#!/usr/bin/env bash
# =============================================================================
# jichang_v2.sh — Debian 12 一键部署：VLESS Reality + 临时节点 + nftables 配额 + IP 槽位限制
# 版本：v2.0  完全模块化重写，不基于旧脚本补丁
# 运行要求：Debian 12 (bookworm)，root 权限
# =============================================================================
set -Eeuo pipefail
trap 'echo "❌ FATAL ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

# ── 全局目录 ──────────────────────────────────────────────────────────────────
VLESS_LIB_DIR="/usr/local/lib/vless"
VLESS_BIN_DIR="/usr/local/bin"
VLESS_STATE_DIR="/var/lib/vless"
VLESS_NODES_DIR="${VLESS_STATE_DIR}/nodes"
VLESS_QUOTA_DIR="${VLESS_STATE_DIR}/quota"
VLESS_IPLIMIT_DIR="${VLESS_STATE_DIR}/iplimit"
VLESS_LOG_DIR="/var/log/vless"
VLESS_LOCK_DIR="/var/lock/vless"
XRAY_CONF_DIR="/usr/local/etc/xray"
VLESS_DEFAULT="/etc/default/vless-reality"

# ── 前置检查 ──────────────────────────────────────────────────────────────────
pre_check() {
  [[ "$(id -u)" -eq 0 ]] || { echo "❌ 请以 root 运行"; exit 1; }
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [[ "$codename" == "bookworm" ]] || { echo "❌ 仅支持 Debian 12 (bookworm)，当前: ${codename:-未知}"; exit 1; }
}

install_deps() {
  echo "📦 安装依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q -o Acquire::Retries=3
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget openssl python3 nftables \
    iproute2 coreutils util-linux logrotate jq
  for c in curl openssl python3 nft flock ss jq; do
    command -v "$c" >/dev/null 2>&1 || { echo "❌ 缺少命令: $c"; exit 1; }
  done
  echo "✅ 依赖安装完成"
}

make_dirs() {
  mkdir -p "$VLESS_LIB_DIR" "$VLESS_NODES_DIR" "$VLESS_QUOTA_DIR" \
           "$VLESS_IPLIMIT_DIR" "$VLESS_LOG_DIR" "$VLESS_LOCK_DIR" \
           "$XRAY_CONF_DIR" /etc/nftables.d
  chmod 700 "$VLESS_STATE_DIR" "$VLESS_NODES_DIR" \
            "$VLESS_QUOTA_DIR" "$VLESS_IPLIMIT_DIR"
}

# =============================================================================
# 模块 1: lib_common.sh
# =============================================================================
write_lib_common() {
  cat > "${VLESS_LIB_DIR}/lib_common.sh" << 'EOF_LC'
#!/usr/bin/env bash
# lib_common.sh — 公共函数库（只读，被其他脚本 source）
# shellcheck disable=SC2034

VLESS_LIB_DIR="/usr/local/lib/vless"
VLESS_STATE_DIR="/var/lib/vless"
VLESS_NODES_DIR="${VLESS_STATE_DIR}/nodes"
VLESS_QUOTA_DIR="${VLESS_STATE_DIR}/quota"
VLESS_IPLIMIT_DIR="${VLESS_STATE_DIR}/iplimit"
VLESS_LOG_DIR="/var/log/vless"
VLESS_LOCK_DIR="/var/lock/vless"
XRAY_CONF_DIR="/usr/local/etc/xray"
VLESS_DEFAULT="/etc/default/vless-reality"
VLESS_LOCK_FILE="${VLESS_LOCK_DIR}/vless.lock"

# ── 日志 ─────────────────────────────────────────────────────────────────────
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; }

log_to_file() {
  local logfile="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$logfile"
}

# ── 参数校验 ──────────────────────────────────────────────────────────────────
validate_positive_int() {
  local name="$1" val="$2"
  [[ "$val" =~ ^[1-9][0-9]*$ ]] || { log_error "参数 ${name}=${val} 必须是正整数"; return 1; }
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || {
    log_error "非法端口: ${port}"; return 1
  }
}

validate_gib() {
  local val="$1"
  # 支持整数或小数，例如 0.5 1 2.5
  [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && python3 -c "assert float('$val') > 0" 2>/dev/null || {
    log_error "PQ_GIB=${val} 必须是正数（如 0.5 或 2）"; return 1
  }
}

# ── 锁 ───────────────────────────────────────────────────────────────────────
# 用法: with_lock <lockfile> <timeout_seconds> <cmd...>
with_lock() {
  local lockfile="$1"; shift
  local timeout_s="$1"; shift
  mkdir -p "$(dirname "$lockfile")"
  (
    flock -w "$timeout_s" 200 || { log_error "获取锁超时: $lockfile"; exit 1; }
    "$@"
  ) 200>"$lockfile"
}

# ── Meta 文件操作 ─────────────────────────────────────────────────────────────
meta_read() {
  local metafile="$1" key="$2"
  grep -E "^${key}=" "$metafile" 2>/dev/null | head -1 | cut -d= -f2-
}

meta_write() {
  local metafile="$1" key="$2" val="$3"
  mkdir -p "$(dirname "$metafile")"
  if grep -qE "^${key}=" "$metafile" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$metafile"
  else
    echo "${key}=${val}" >> "$metafile"
  fi
}

meta_write_all() {
  # 写入整个 meta 文件，参数为 key=value 对
  local metafile="$1"; shift
  mkdir -p "$(dirname "$metafile")"
  : > "$metafile"
  for kv in "$@"; do
    echo "$kv" >> "$metafile"
  done
  chmod 600 "$metafile"
}

# ── 时间 ─────────────────────────────────────────────────────────────────────
now_epoch() { date +%s; }
epoch_to_beijing() {
  local epoch="$1"
  TZ='Asia/Shanghai' date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
}
seconds_to_human() {
  local s="$1"
  (( s <= 0 )) && { echo "已过期"; return; }
  local d=$(( s / 86400 ))
  local h=$(( (s % 86400) / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local sec=$(( s % 60 ))
  printf "%dd %02dh %02dm %02ds" "$d" "$h" "$m" "$sec"
}

# ── 网络 ─────────────────────────────────────────────────────────────────────
is_port_listening() {
  local port="$1"
  ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
}

get_public_ipv4() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com"; do
    ip=$(curl -4fsSL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d ' \n\r') || true
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"; return 0
    fi
  done
  hostname -I 2>/dev/null | awk '{print $1}' | tr -d ' \n\r'
}

# ── Xray 操作 ─────────────────────────────────────────────────────────────────
xray_unit_name() {
  local tag="$1"
  [[ "$tag" == "main" ]] && echo "xray" || echo "xray-tmp@${tag}"
}

wait_unit_active() {
  local unit="$1" retries="${2:-10}" delay="${3:-1}"
  local i=0
  while (( i < retries )); do
    systemctl is-active --quiet "$unit" 2>/dev/null && return 0
    sleep "$delay"
    (( i++ ))
  done
  return 1
}

wait_port_listening() {
  local port="$1" retries="${2:-15}" delay="${3:-1}"
  local i=0
  while (( i < retries )); do
    is_port_listening "$port" && return 0
    sleep "$delay"
    (( i++ ))
  done
  return 1
}

# ── 已管理节点列表 ────────────────────────────────────────────────────────────
list_managed_tags() {
  # 返回当前存在 meta 的临时节点 TAG 列表
  local tag
  for dir in "${VLESS_NODES_DIR}"/*/; do
    [[ -d "$dir" ]] || continue
    tag=$(basename "$dir")
    [[ -f "${dir}/meta" ]] && echo "$tag"
  done
}

list_managed_quota_ports() {
  local port
  for dir in "${VLESS_QUOTA_DIR}"/*/; do
    [[ -d "$dir" ]] || continue
    port=$(basename "$dir")
    [[ -f "${dir}/meta" ]] && echo "$port"
  done
}
EOF_LC
  chmod 644 "${VLESS_LIB_DIR}/lib_common.sh"
  echo "✅ lib_common.sh 写入完成"
}

# =============================================================================
# 模块 2: lib_quota.sh
# =============================================================================
write_lib_quota() {
  cat > "${VLESS_LIB_DIR}/lib_quota.sh" << 'EOF_LQ'
#!/usr/bin/env bash
# lib_quota.sh — nftables 端口级双向配额库
# 统计目标：用户<->VPS (input tcp dport PORT + output tcp sport PORT)
# 不统计：VPS<->上游网站
# shellcheck disable=SC1091

source /usr/local/lib/vless/lib_common.sh

NFT_TABLE="inet vless_quota"
NFT_TABLE_NAME="vless_quota"
NFT_FAMILY="inet"

# ── 内部：从 nftables 读取计数器字节 ─────────────────────────────────────────
_nft_counter_bytes() {
  local cname="$1"
  nft list counter ${NFT_TABLE} "${cname}" 2>/dev/null \
    | grep -oP 'bytes \K[0-9]+' || echo "0"
}

_nft_ensure_table() {
  nft list table ${NFT_TABLE} &>/dev/null && return 0
  nft add table ${NFT_FAMILY} ${NFT_TABLE_NAME}
  # 基础链
  nft add chain ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_input \
    '{ type filter hook input priority -10; policy accept; }'
  nft add chain ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_output \
    '{ type filter hook output priority -10; policy accept; }'
}

# ── 读取某端口当前 live 字节 ──────────────────────────────────────────────────
pq_live_bytes() {
  local port="$1"
  local in_b out_b
  in_b=$(_nft_counter_bytes "cnt_in_${port}")
  out_b=$(_nft_counter_bytes "cnt_out_${port}")
  echo $(( in_b + out_b ))
}

# ── 重建单个端口的 nft 规则（counter + quota）────────────────────────────────
# 用于：初始建立 / pq_save_state 后重建
pq_rebuild_port_rules() {
  local port="$1" limit_bytes="$2"
  # 删除旧规则（如果有）
  pq_delete_port_rules "$port" 2>/dev/null || true

  _nft_ensure_table

  # 创建计数器
  nft add counter ${NFT_FAMILY} ${NFT_TABLE_NAME} "cnt_in_${port}"
  nft add counter ${NFT_FAMILY} ${NFT_TABLE_NAME} "cnt_out_${port}"

  if (( limit_bytes > 0 )); then
    # 创建 quota（over N bytes 触发 drop）
    nft add quota ${NFT_FAMILY} ${NFT_TABLE_NAME} "q_${port}" \
      "{ over ${limit_bytes} bytes }"

    # Input 规则：计数 + 配额 check
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_input \
      "tcp dport ${port} counter name cnt_in_${port}"
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_input \
      "tcp dport ${port} quota name \"q_${port}\" drop"

    # Output 规则：计数 + 配额 check
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_output \
      "tcp sport ${port} counter name cnt_out_${port}"
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_output \
      "tcp sport ${port} quota name \"q_${port}\" drop"
  else
    # 已超配额：直接 drop
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_input \
      "tcp dport ${port} counter name cnt_in_${port} drop"
    nft add rule ${NFT_FAMILY} ${NFT_TABLE_NAME} pq_output \
      "tcp sport ${port} counter name cnt_out_${port} drop"
  fi
}

# ── 删除某端口所有 nft 规则 ────────────────────────────────────────────────────
pq_delete_port_rules() {
  local port="$1"
  # 删除包含该端口的规则（通过 handle 匹配）
  local family="${NFT_FAMILY}" table="${NFT_TABLE_NAME}"

  for chain in pq_input pq_output; do
    # 找到含该端口的所有规则 handle
    local handles
    handles=$(nft -a list chain "${family}" "${table}" "${chain}" 2>/dev/null \
      | grep -E "dport ${port}|sport ${port}" \
      | grep -oP '# handle \K[0-9]+' || true)
    for h in $handles; do
      nft delete rule "${family}" "${table}" "${chain}" handle "$h" 2>/dev/null || true
    done
  done

  # 删除 counter 和 quota
  nft delete counter ${NFT_FAMILY} ${NFT_TABLE_NAME} "cnt_in_${port}"  2>/dev/null || true
  nft delete counter ${NFT_FAMILY} ${NFT_TABLE_NAME} "cnt_out_${port}" 2>/dev/null || true
  nft delete quota   ${NFT_FAMILY} ${NFT_TABLE_NAME} "q_${port}"       2>/dev/null || true
}

# ── 创建端口配额 ──────────────────────────────────────────────────────────────
pq_create() {
  local port="$1" limit_gib="$2"
  validate_port "$port" || return 1
  validate_gib  "$limit_gib" || return 1

  local limit_bytes
  limit_bytes=$(python3 -c "print(int(float('${limit_gib}') * 1024**3))")

  local metadir="${VLESS_QUOTA_DIR}/${port}"
  mkdir -p "$metadir"

  meta_write_all "${metadir}/meta" \
    "PORT=${port}" \
    "ORIGINAL_LIMIT_BYTES=${limit_bytes}" \
    "LIMIT_BYTES=${limit_bytes}" \
    "SAVED_USED_BYTES=0" \
    "CREATE_EPOCH=$(now_epoch)"

  pq_rebuild_port_rules "$port" "$limit_bytes"
  log_info "配额已创建: port=${port} limit=${limit_gib}GiB (${limit_bytes}B)"
}

# ── 删除端口配额 ──────────────────────────────────────────────────────────────
pq_delete() {
  local port="$1"
  local metadir="${VLESS_QUOTA_DIR}/${port}"
  pq_delete_port_rules "$port"
  rm -rf "$metadir"
  log_info "配额已删除: port=${port}"
}

# ── 查询配额状态（只读） ──────────────────────────────────────────────────────
pq_status() {
  local port="$1"
  local metadir="${VLESS_QUOTA_DIR}/${port}"
  [[ -f "${metadir}/meta" ]] || { echo "missing"; return; }

  local orig saved limit
  orig=$(meta_read "${metadir}/meta" ORIGINAL_LIMIT_BYTES)
  saved=$(meta_read "${metadir}/meta" SAVED_USED_BYTES)
  limit=$(meta_read "${metadir}/meta" LIMIT_BYTES)

  # live used = counter in + counter out（不触发保存）
  local live_bytes
  live_bytes=$(pq_live_bytes "$port")

  local total_used=$(( saved + live_bytes ))
  local left=$(( orig - total_used ))
  (( left < 0 )) && left=0

  local pct=0
  (( orig > 0 )) && pct=$(( total_used * 100 / orig ))

  echo "PORT=${port} ORIG=${orig} SAVED=${saved} LIVE=${live_bytes} USED=${total_used} LEFT=${left} PCT=${pct}"
}

# ── 保存状态（pq_save_state.sh 调用）────────────────────────────────────────
# 返回：更新后的 LIMIT_BYTES
pq_save_one_port() {
  local port="$1"
  local metadir="${VLESS_QUOTA_DIR}/${port}"
  [[ -f "${metadir}/meta" ]] || return 0

  local orig saved
  orig=$(meta_read "${metadir}/meta" ORIGINAL_LIMIT_BYTES)
  saved=$(meta_read "${metadir}/meta" SAVED_USED_BYTES)

  # 读取 live 计数
  local live_bytes
  live_bytes=$(pq_live_bytes "$port")

  local new_saved=$(( saved + live_bytes ))
  local new_limit=$(( orig - new_saved ))
  (( new_limit < 0 )) && new_limit=0

  # 更新 meta
  meta_write "${metadir}/meta" SAVED_USED_BYTES "$new_saved"
  meta_write "${metadir}/meta" LIMIT_BYTES       "$new_limit"

  # 立即重建 nft 规则（清零计数器，按新剩余额度设 quota）
  pq_rebuild_port_rules "$port" "$new_limit"

  log_to_file "${VLESS_LOG_DIR}/pq_save.log" \
    "port=${port} live=${live_bytes} new_saved=${new_saved} new_limit=${new_limit}"
}

# ── 开机恢复（按已保存 LIMIT_BYTES 重建 nft 规则）────────────────────────────
pq_restore_all() {
  _nft_ensure_table
  local port
  for port in $(list_managed_quota_ports); do
    local metadir="${VLESS_QUOTA_DIR}/${port}"
    [[ -f "${metadir}/meta" ]] || continue
    local limit
    limit=$(meta_read "${metadir}/meta" LIMIT_BYTES)
    pq_rebuild_port_rules "$port" "${limit:-0}"
    log_info "配额已恢复: port=${port} limit=${limit}B"
  done
}

# ── 检查配额是否已超（返回 0=正常 1=超额） ────────────────────────────────────
pq_is_exceeded() {
  local port="$1"
  local metadir="${VLESS_QUOTA_DIR}/${port}"
  [[ -f "${metadir}/meta" ]] || return 1
  local orig saved live total left
  orig=$(meta_read "${metadir}/meta" ORIGINAL_LIMIT_BYTES)
  saved=$(meta_read "${metadir}/meta" SAVED_USED_BYTES)
  live=$(pq_live_bytes "$port")
  total=$(( saved + live ))
  left=$(( orig - total ))
  (( left <= 0 )) && return 0 || return 1
}

# ── 周期性重置（仅限 >30 天的服务周期）──────────────────────────────────────
# 只处理 meta 存在 RESET_ENABLED=1 的端口
pq_reset_if_due() {
  local port="$1"
  local metadir="${VLESS_QUOTA_DIR}/${port}"
  [[ -f "${metadir}/meta" ]] || return 0

  local reset_enabled
  reset_enabled=$(meta_read "${metadir}/meta" RESET_ENABLED)
  [[ "$reset_enabled" == "1" ]] || return 0

  local last_reset orig
  last_reset=$(meta_read "${metadir}/meta" LAST_RESET_EPOCH)
  orig=$(meta_read "${metadir}/meta" ORIGINAL_LIMIT_BYTES)
  local now; now=$(now_epoch)

  # 满 30 天才重置
  if (( now - last_reset >= 2592000 )); then
    meta_write "${metadir}/meta" SAVED_USED_BYTES 0
    meta_write "${metadir}/meta" LIMIT_BYTES      "$orig"
    meta_write "${metadir}/meta" LAST_RESET_EPOCH "$now"
    pq_rebuild_port_rules "$port" "$orig"
    log_info "配额已自动重置: port=${port}"
    log_to_file "${VLESS_LOG_DIR}/pq_reset.log" "port=${port} reset at $(date)"
  fi
}
EOF_LQ
  chmod 644 "${VLESS_LIB_DIR}/lib_quota.sh"
  echo "✅ lib_quota.sh 写入完成"
}

# =============================================================================
# 模块 3: lib_iplimit.sh
# =============================================================================
write_lib_iplimit() {
  cat > "${VLESS_LIB_DIR}/lib_iplimit.sh" << 'EOF_LI'
#!/usr/bin/env bash
# lib_iplimit.sh — 临时节点源 IP 槽位限制库
# 实现：nftables 动态集合 + 只有 input 路径续期
# shellcheck disable=SC1091

source /usr/local/lib/vless/lib_common.sh

NFT_IL_FAMILY="inet"
NFT_IL_TABLE="vless_iplimit"
NFT_IL_CHAIN_IN="il_input"

_il_ensure_table() {
  nft list table ${NFT_IL_FAMILY} ${NFT_IL_TABLE} &>/dev/null && return 0
  nft add table ${NFT_IL_FAMILY} ${NFT_IL_TABLE}
  nft add chain ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} \
    '{ type filter hook input priority -8; policy accept; }'
}

# ── 创建 IP 限制（为某临时节点端口）────────────────────────────────────────
il_create() {
  local tag="$1" port="$2" ip_limit="$3" sticky_seconds="${4:-120}"
  validate_positive_int "IP_LIMIT" "$ip_limit"     || return 1
  validate_positive_int "IP_STICKY_SECONDS" "$sticky_seconds" || return 1
  validate_port "$port" || return 1

  _il_ensure_table

  local setname="allowed_${tag}"

  # 创建动态集合（有 size 上限，带 timeout，只 input 写入）
  nft add set ${NFT_IL_FAMILY} ${NFT_IL_TABLE} "${setname}" \
    "{ type ipv4_addr; flags timeout, dynamic; timeout ${sticky_seconds}s; size ${ip_limit}; }"

  # 规则 1：已在集合中的 IP → 刷新 timeout（续期）然后 accept
  nft add rule ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} \
    "tcp dport ${port} ip saddr @${setname} update @${setname} { ip saddr timeout ${sticky_seconds}s } accept"

  # 规则 2：不在集合中的 IP → 尝试加入（若集合未满则成功 + accept）
  nft add rule ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} \
    "tcp dport ${port} add @${setname} { ip saddr timeout ${sticky_seconds}s } accept"

  # 规则 3：仍到达这里 = 集合已满 → drop
  nft add rule ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} \
    "tcp dport ${port} drop"

  # 保存元数据
  local metadir="${VLESS_IPLIMIT_DIR}/${tag}"
  mkdir -p "$metadir"
  meta_write_all "${metadir}/meta" \
    "TAG=${tag}" \
    "PORT=${port}" \
    "IP_LIMIT=${ip_limit}" \
    "IP_STICKY_SECONDS=${sticky_seconds}" \
    "SET_NAME=${setname}" \
    "CREATE_EPOCH=$(now_epoch)"

  log_info "IP限制已创建: tag=${tag} port=${port} limit=${ip_limit} sticky=${sticky_seconds}s"
}

# ── 删除 IP 限制 ──────────────────────────────────────────────────────────────
il_delete() {
  local tag="$1"
  local metadir="${VLESS_IPLIMIT_DIR}/${tag}"
  [[ -f "${metadir}/meta" ]] || { rm -rf "$metadir"; return 0; }

  local port setname
  port=$(meta_read "${metadir}/meta" PORT)
  setname=$(meta_read "${metadir}/meta" SET_NAME)
  setname="${setname:-allowed_${tag}}"

  # 删除包含该端口的规则
  local h
  local handles
  handles=$(nft -a list chain ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} 2>/dev/null \
    | grep -E "(dport|sport) ${port}" \
    | grep -oP '# handle \K[0-9]+' || true)
  for h in $handles; do
    nft delete rule ${NFT_IL_FAMILY} ${NFT_IL_TABLE} ${NFT_IL_CHAIN_IN} handle "$h" 2>/dev/null || true
  done

  # 删除集合
  nft delete set ${NFT_IL_FAMILY} ${NFT_IL_TABLE} "${setname}" 2>/dev/null || true

  rm -rf "$metadir"
  log_info "IP限制已删除: tag=${tag}"
}

# ── 查询活动 IP 数（只读）────────────────────────────────────────────────────
il_active_count() {
  local tag="$1"
  local metadir="${VLESS_IPLIMIT_DIR}/${tag}"
  [[ -f "${metadir}/meta" ]] || { echo "0"; return; }
  local setname
  setname=$(meta_read "${metadir}/meta" SET_NAME)
  setname="${setname:-allowed_${tag}}"
  nft list set ${NFT_IL_FAMILY} ${NFT_IL_TABLE} "${setname}" 2>/dev/null \
    | grep -c 'expires' || echo "0"
}

# ── 开机恢复（重建已管理的 iplimit 规则）────────────────────────────────────
il_restore_all() {
  _il_ensure_table
  local tag
  for tag_dir in "${VLESS_IPLIMIT_DIR}"/*/; do
    [[ -d "$tag_dir" ]] || continue
    tag=$(basename "$tag_dir")
    [[ -f "${tag_dir}/meta" ]] || continue
    local port ip_limit sticky
    port=$(meta_read "${tag_dir}/meta" PORT)
    ip_limit=$(meta_read "${tag_dir}/meta" IP_LIMIT)
    sticky=$(meta_read "${tag_dir}/meta" IP_STICKY_SECONDS)
    il_create "$tag" "$port" "$ip_limit" "$sticky" && \
      log_info "IP限制已恢复: tag=${tag}" || \
      log_warn "IP限制恢复失败: tag=${tag}"
  done
}
EOF_LI
  chmod 644 "${VLESS_LIB_DIR}/lib_iplimit.sh"
  echo "✅ lib_iplimit.sh 写入完成"
}

# =============================================================================
# 模块 4: pq_save_state.sh
# =============================================================================
write_pq_save_state() {
  cat > "${VLESS_BIN_DIR}/pq_save_state.sh" << 'EOF_PSS'
#!/usr/bin/env bash
# pq_save_state.sh — 周期性保存配额状态 + 重建 nft 规则（每 5 分钟由 timer 调用）
# 也在关机前由 systemd 调用（保证正常重启不丢流量）
set -euo pipefail
source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh

LOGFILE="${VLESS_LOG_DIR}/pq_save.log"

main() {
  local port
  for port in $(list_managed_quota_ports); do
    [[ -f "${VLESS_QUOTA_DIR}/${port}/meta" ]] || continue
    pq_save_one_port "$port" || log_to_file "$LOGFILE" "WARN: save failed for port=${port}"
  done
  log_to_file "$LOGFILE" "--- pq_save_state run complete ---"
}

with_lock "${VLESS_LOCK_DIR}/pq_save.lock" 30 main
EOF_PSS
  chmod 755 "${VLESS_BIN_DIR}/pq_save_state.sh"
  echo "✅ pq_save_state.sh 写入完成"
}

# =============================================================================
# 模块 5: pq_restore.sh (开机恢复)
# =============================================================================
write_pq_restore() {
  cat > "${VLESS_BIN_DIR}/pq_restore.sh" << 'EOF_PR'
#!/usr/bin/env bash
# pq_restore.sh — 开机恢复：按已保存状态重建 nft 配额 + IP 限制规则
set -euo pipefail
source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh
source /usr/local/lib/vless/lib_iplimit.sh

log_info "=== pq_restore: 开机恢复配额和IP限制 ==="
pq_restore_all
# IP 限制恢复由 vless-gc 在确认节点存活后处理，避免恢复已过期节点的 iplimit
# il_restore_all  # 注：已过期节点的 iplimit 不应恢复，由 gc 处理

log_info "=== pq_restore: 完成 ==="
EOF_PR
  chmod 755 "${VLESS_BIN_DIR}/pq_restore.sh"
  echo "✅ pq_restore.sh 写入完成"
}

# =============================================================================
# 模块 6: pq_audit.sh
# =============================================================================
write_pq_audit() {
  cat > "${VLESS_BIN_DIR}/pq_audit.sh" << 'EOF_PA'
#!/usr/bin/env bash
# pq_audit.sh — 配额状态只读审计（严禁触发任何修改）
source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh

fmt_bytes() {
  local b="${1:-0}"
  if   (( b >= 1073741824 )); then printf "%.2fGiB" "$(echo "$b 1073741824" | awk '{printf "%.2f",$1/$2}')";
  elif (( b >= 1048576 ));    then printf "%.2fMiB" "$(echo "$b 1048576"    | awk '{printf "%.2f",$1/$2}')";
  elif (( b >= 1024 ));       then printf "%.2fKiB" "$(echo "$b 1024"       | awk '{printf "%.2f",$1/$2}')";
  else printf "%dB" "$b"; fi
}

echo "════════════════════════════════════════════════════════════════"
printf "%-10s %-10s %-10s %-10s %-6s %s\n" "PORT" "ORIG" "USED" "LEFT" "USE%" "STATUS"
echo "────────────────────────────────────────────────────────────────"

port_found=0
for port in $(list_managed_quota_ports | sort -n); do
  port_found=1
  metadir="${VLESS_QUOTA_DIR}/${port}"
  if [[ ! -f "${metadir}/meta" ]]; then
    printf "%-10s %-10s %-10s %-10s %-6s %s\n" "$port" "-" "-" "-" "-" "missing/stale"
    continue
  fi

  local_status=$(pq_status "$port")
  orig=$(echo "$local_status"  | grep -oP 'ORIG=\K[0-9]+' || echo "0")
  used=$(echo "$local_status"  | grep -oP 'USED=\K[0-9]+' || echo "0")
  left=$(echo "$local_status"  | grep -oP 'LEFT=\K[0-9]+' || echo "0")
  pct=$(echo "$local_status"   | grep -oP 'PCT=\K[0-9]+'  || echo "0")

  status="OK"
  (( left == 0 )) && status="EXCEEDED"
  nft list counter inet vless_quota "cnt_in_${port}" &>/dev/null || status="nft-missing"

  printf "%-10s %-10s %-10s %-10s %-6s %s\n" \
    "$port" "$(fmt_bytes $orig)" "$(fmt_bytes $used)" "$(fmt_bytes $left)" "${pct}%" "$status"
done

(( port_found == 0 )) && echo "(无受管配额端口)"
echo "════════════════════════════════════════════════════════════════"
EOF_PA
  chmod 755 "${VLESS_BIN_DIR}/pq_audit.sh"
  echo "✅ pq_audit.sh 写入完成"
}

# =============================================================================
# 模块 7: onekey_reality_ipv4.sh — 主节点安装
# =============================================================================
write_onekey() {
  cat > "/root/onekey_reality_ipv4.sh" << 'EOF_OK'
#!/usr/bin/env bash
# onekey_reality_ipv4.sh — VLESS Reality 主节点一键安装
set -Eeuo pipefail
trap 'echo "❌ FATAL ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR
umask 077

source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh

# ── 默认值 ────────────────────────────────────────────────────────────────────
MAIN_PORT="${MAIN_PORT:-443}"
CAMOUFLAGE_DOMAIN="${CAMOUFLAGE_DOMAIN:-www.apple.com}"
REALITY_DEST="${REALITY_DEST:-www.apple.com:443}"
REALITY_SNI="${REALITY_SNI:-www.apple.com}"
NODE_NAME="${NODE_NAME:-vless-reality-main}"

# ── 安装 Xray ─────────────────────────────────────────────────────────────────
install_xray() {
  echo "📥 安装/更新 Xray..."
  if [[ -f /usr/local/bin/xray ]]; then
    echo "ℹ Xray 已安装: $(/usr/local/bin/xray version 2>/dev/null | head -1)"
  fi
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
    @ Release 2>&1 | tail -5
  [[ -f /usr/local/bin/xray ]] || { echo "❌ Xray 安装失败"; exit 1; }
  echo "✅ Xray 版本: $(/usr/local/bin/xray version | head -1)"
}

# ── 让 xray.service 以 root 运行 ──────────────────────────────────────────────
configure_xray_service_as_root() {
  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/99-run-as-root.conf << 'DROPEOF'
[Service]
User=root
Group=root
DROPEOF
  systemctl daemon-reload
}

# ── 生成 Reality 密钥对 ──────────────────────────────────────────────────────
gen_reality_keys() {
  /usr/local/bin/xray x25519 2>/dev/null | awk '
    /Private key:/ {priv=$3}
    /Public key:/  {pub=$3}
    END {print priv, pub}'
}

# ── 写入主配置 ────────────────────────────────────────────────────────────────
write_main_config() {
  local uuid="$1" priv="$2" short_id="$3"

  mkdir -p "${XRAY_CONF_DIR}"
  cat > "${XRAY_CONF_DIR}/config.json" << CONFEOF
{
  "log": {
    "loglevel": "warning",
    "access": "${VLESS_LOG_DIR}/xray_access.log",
    "error":  "${VLESS_LOG_DIR}/xray_error.log"
  },
  "inbounds": [
    {
      "tag": "vless-in-main",
      "listen": "0.0.0.0",
      "port": ${MAIN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
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
          "privateKey": "${priv}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls","quic"]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct",  "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type":"field","outboundTag":"blocked","geoip":["private"]}
    ]
  }
}
CONFEOF
  chmod 600 "${XRAY_CONF_DIR}/config.json"
}

# ── 保存配置文件 ──────────────────────────────────────────────────────────────
save_env() {
  local pub_ip="$1" uuid="$2" pub_key="$3" short_id="$4"
  cat > "${VLESS_DEFAULT}" << ENVEOF
# VLESS Reality 主节点配置 — 由 onekey_reality_ipv4.sh 生成
PUBLIC_DOMAIN=${pub_ip}
CAMOUFLAGE_DOMAIN=${CAMOUFLAGE_DOMAIN}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
PORT=${MAIN_PORT}
NODE_NAME=${NODE_NAME}
UUID=${uuid}
PUBLIC_KEY=${pub_key}
SHORT_ID=${short_id}
ENVEOF
  chmod 600 "${VLESS_DEFAULT}"
}

# ── 生成订阅链接 ──────────────────────────────────────────────────────────────
gen_subscription() {
  local pub_ip="$1" uuid="$2" pub_key="$3" short_id="$4"
  local url="vless://${uuid}@${pub_ip}:${MAIN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#${NODE_NAME}"

  echo "$url" > /root/vless_reality_vision_url.txt
  echo "$url" | base64 -w 0 > /root/v2ray_subscription_base64.txt

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "✅ 主节点部署完成"
  echo "────────────────────────────────────────────────────────────"
  echo "节点名称 : ${NODE_NAME}"
  echo "服务器IP : ${pub_ip}"
  echo "端口     : ${MAIN_PORT}"
  echo "UUID     : ${uuid}"
  echo "PublicKey: ${pub_key}"
  echo "ShortId  : ${short_id}"
  echo "SNI      : ${REALITY_SNI}"
  echo "────────────────────────────────────────────────────────────"
  echo "订阅链接 :"
  echo "$url"
  echo "════════════════════════════════════════════════════════════"
  echo "已保存至:"
  echo "  /root/vless_reality_vision_url.txt"
  echo "  /root/v2ray_subscription_base64.txt"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  [[ "$(id -u)" -eq 0 ]] || { echo "❌ 需要 root"; exit 1; }
  local codename
  codename=$(grep -E "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [[ "$codename" == "bookworm" ]] || { echo "❌ 仅支持 Debian 12"; exit 1; }

  install_xray
  configure_xray_service_as_root

  echo "🔑 生成 Reality 密钥对..."
  read -r priv_key pub_key <<< "$(gen_reality_keys)"
  [[ -n "$priv_key" && -n "$pub_key" ]] || { echo "❌ 密钥生成失败"; exit 1; }

  local uuid short_id pub_ip
  uuid=$(/usr/local/bin/xray uuid)
  short_id=$(openssl rand -hex 8)

  echo "🌐 获取公网 IP..."
  pub_ip=$(get_public_ipv4) || { echo "❌ 无法获取公网 IP"; exit 1; }
  echo "   公网 IP: ${pub_ip}"

  write_main_config "$uuid" "$priv_key" "$short_id"
  save_env "$pub_ip" "$uuid" "$pub_key" "$short_id"

  echo "🚀 启动 xray.service..."
  systemctl enable --now xray.service
  sleep 2

  # 严格校验
  local ok=0
  for i in 1 2 3; do
    systemctl is-active --quiet xray.service && \
    wait_port_listening "$MAIN_PORT" 5 1 && { ok=1; break; }
    sleep 3
  done
  (( ok == 1 )) || { echo "❌ xray.service 启动失败或端口未监听"; systemctl status xray.service; exit 1; }

  gen_subscription "$pub_ip" "$uuid" "$pub_key" "$short_id"
}

main "$@"
EOF_OK
  chmod 755 "/root/onekey_reality_ipv4.sh"
  echo "✅ onekey_reality_ipv4.sh 写入完成"
}

# =============================================================================
# 模块 8: vless_mktemp.sh — 创建临时节点
# =============================================================================
write_vless_mktemp() {
  cat > "${VLESS_BIN_DIR}/vless_mktemp.sh" << 'EOF_MK'
#!/usr/bin/env bash
# vless_mktemp.sh — 创建临时 VLESS Reality 节点
# 用法: id="tmp001" IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh
set -Eeuo pipefail
trap 'echo "❌ FATAL ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR
umask 077

source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh
source /usr/local/lib/vless/lib_iplimit.sh

# ── 参数解析 ──────────────────────────────────────────────────────────────────
TAG="${id:-}"
D="${D:-}"
PQ_GIB="${PQ_GIB:-}"
IP_LIMIT="${IP_LIMIT:-}"
IP_STICKY_SECONDS="${IP_STICKY_SECONDS:-120}"
PORT_START="${PORT_START:-40000}"
PORT_END="${PORT_END:-49999}"
MAX_START_RETRIES="${MAX_START_RETRIES:-5}"
PBK="${PBK:-}"

# 读取主节点配置以继承 Reality 参数
load_main_config() {
  [[ -f "${VLESS_DEFAULT}" ]] || { log_error "主节点配置不存在: ${VLESS_DEFAULT}"; return 1; }
  source "${VLESS_DEFAULT}"
}

# ── 参数校验 ──────────────────────────────────────────────────────────────────
validate_params() {
  [[ -n "$TAG" ]]    || { log_error "必须设置 id=<TAG>"; exit 1; }
  [[ -n "$D"  ]]    || { log_error "必须设置 D=<秒数>"; exit 1; }
  validate_positive_int "D" "$D"
  [[ "$TAG" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "id 只能包含字母数字下划线连字符"; exit 1; }

  if [[ -n "$PQ_GIB" ]]; then
    validate_gib "$PQ_GIB" || exit 1
  fi
  if [[ -n "$IP_LIMIT" ]]; then
    validate_positive_int "IP_LIMIT" "$IP_LIMIT" || exit 1
    validate_positive_int "IP_STICKY_SECONDS" "$IP_STICKY_SECONDS" || exit 1
  fi
  validate_positive_int "PORT_START" "$PORT_START"
  validate_positive_int "PORT_END"   "$PORT_END"
  [[ "$PORT_END" -gt "$PORT_START" ]] || { log_error "PORT_END 必须大于 PORT_START"; exit 1; }
}

# ── 查找可用端口 ──────────────────────────────────────────────────────────────
find_free_port() {
  local p
  for (( p = PORT_START; p <= PORT_END; p++ )); do
    # 未被系统监听，且无已管理配额
    if ! is_port_listening "$p" && [[ ! -d "${VLESS_QUOTA_DIR}/${p}" ]]; then
      echo "$p"; return 0
    fi
  done
  log_error "端口范围 ${PORT_START}-${PORT_END} 内无可用端口"
  return 1
}

# ── 读取主节点 PBK（从订阅链接中提取）───────────────────────────────────────
get_pbk() {
  local pbk_out="${PBK:-}"
  if [[ -z "$pbk_out" ]] && [[ -f /root/vless_reality_vision_url.txt ]]; then
    pbk_out=$(grep -oP '&pbk=\K[^&]+' /root/vless_reality_vision_url.txt 2>/dev/null || true)
  fi
  if [[ -z "$pbk_out" ]] && [[ -f "${VLESS_DEFAULT}" ]]; then
    pbk_out=$(grep -E "^PUBLIC_KEY=" "${VLESS_DEFAULT}" 2>/dev/null | cut -d= -f2 || true)
  fi
  echo "$pbk_out"
}

# ── 读取主节点私钥 ────────────────────────────────────────────────────────────
get_private_key() {
  # 从当前 xray config.json 中读取 privateKey
  python3 -c "
import json, sys
try:
    with open('${XRAY_CONF_DIR}/config.json') as f:
        cfg = json.load(f)
    for inb in cfg.get('inbounds', []):
        rs = inb.get('streamSettings', {}).get('realitySettings', {})
        if rs.get('privateKey'):
            print(rs['privateKey']); sys.exit(0)
    sys.exit(1)
except Exception as e:
    sys.exit(1)
" || { log_error "无法从主节点 config.json 提取 privateKey"; return 1; }
}

# ── 写临时节点 xray 配置 ──────────────────────────────────────────────────────
write_tmp_xray_config() {
  local tag="$1" uuid="$2" port="$3" priv="$4" dest="$5" sni="$6" short_id="$7"
  local conf_dir="${XRAY_CONF_DIR}/tmp_${tag}"
  mkdir -p "$conf_dir"
  cat > "${conf_dir}/config.json" << TCONF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vless-in-${tag}",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${priv}",
          "shortIds": ["${short_id}"]
        }
      }
    }
  ],
  "outbounds": [
    {"tag": "direct",  "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ]
}
TCONF
  chmod 600 "${conf_dir}/config.json"
}

# ── 写 systemd instantiated unit ──────────────────────────────────────────────
write_tmp_systemd_unit() {
  local tag="$1" conf_dir="${XRAY_CONF_DIR}/tmp_${1}"
  # 使用 xray-tmp@ template unit，在 write_systemd_units 中已创建
  # 这里写入 drop-in，指定此 instance 的配置目录
  local dropin_dir="/etc/systemd/system/xray-tmp@${tag}.service.d"
  mkdir -p "$dropin_dir"
  cat > "${dropin_dir}/override.conf" << SYSEOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -confdir ${conf_dir}
SYSEOF
}

# ── 回滚函数 ──────────────────────────────────────────────────────────────────
rollback() {
  local tag="$1" port="${2:-}" reason="${3:-unknown}"
  log_warn "回滚: tag=${tag} reason=${reason}"
  systemctl stop  "xray-tmp@${tag}.service" 2>/dev/null || true
  systemctl disable "xray-tmp@${tag}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/xray-tmp@${tag}.service.d/override.conf" 2>/dev/null || true
  rmdir "/etc/systemd/system/xray-tmp@${tag}.service.d" 2>/dev/null || true
  rm -rf "${XRAY_CONF_DIR}/tmp_${tag}" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  if [[ -n "$port" ]]; then
    pq_delete    "$port" 2>/dev/null || true
  fi
  il_delete    "$tag"  2>/dev/null || true
  rm -rf "${VLESS_NODES_DIR}/${tag}" 2>/dev/null || true
  log_warn "回滚完成: tag=${tag}"
}

# ── 写节点元数据 ──────────────────────────────────────────────────────────────
write_node_meta() {
  local tag="$1" uuid="$2" port="$3" pub_ip="$4" expire="$5"
  local dest="$6" sni="$7" short_id="$8" pbk="$9"
  local metadir="${VLESS_NODES_DIR}/${tag}"
  mkdir -p "$metadir"

  local has_pq="${PQ_GIB:+1}"
  local has_il="${IP_LIMIT:+1}"

  meta_write_all "${metadir}/meta" \
    "TAG=${tag}" \
    "UUID=${uuid}" \
    "PORT=${port}" \
    "SERVER_ADDR=${pub_ip}" \
    "CREATE_EPOCH=$(now_epoch)" \
    "DURATION_SECONDS=${D}" \
    "EXPIRE_EPOCH=${expire}" \
    "REALITY_DEST=${dest}" \
    "REALITY_SNI=${sni}" \
    "SHORT_ID=${short_id}" \
    "PBK=${pbk}" \
    "PQ_GIB=${PQ_GIB:-}" \
    "IP_LIMIT=${IP_LIMIT:-}" \
    "IP_STICKY_SECONDS=${IP_STICKY_SECONDS}" \
    "RESET_ENABLED=0"

  # 若服务周期 > 30 天，启用自动重置
  if (( D > 2592000 )); then
    meta_write "${metadir}/meta" RESET_ENABLED 1
    if [[ -n "$PQ_GIB" ]]; then
      meta_write "${VLESS_QUOTA_DIR}/${port}/meta" RESET_ENABLED 1
      meta_write "${VLESS_QUOTA_DIR}/${port}/meta" LAST_RESET_EPOCH "$(now_epoch)"
    fi
  fi
}

# ── 生成订阅链接 ──────────────────────────────────────────────────────────────
gen_tmp_subscription() {
  local tag="$1" uuid="$2" port="$3" pub_ip="$4" pbk="$5" sni="$6" short_id="$7" expire="$8"
  local url="vless://${uuid}@${pub_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${short_id}&type=tcp&headerType=none#tmp-${tag}"

  local metadir="${VLESS_NODES_DIR}/${tag}"
  echo "$url" > "${metadir}/subscription_url.txt"
  echo "$url" | base64 -w 0 > "${metadir}/subscription_base64.txt"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "✅ 临时节点创建成功: ${tag}"
  echo "────────────────────────────────────────────────────────────"
  echo "UUID    : ${uuid}"
  echo "端口    : ${port}"
  echo "过期    : $(epoch_to_beijing "${expire}") (北京时间)"
  echo "TTL     : $(seconds_to_human $(( expire - $(now_epoch) )))"
  [[ -n "$PQ_GIB" ]] && echo "配额    : ${PQ_GIB} GiB"
  [[ -n "$IP_LIMIT" ]] && echo "IP限制  : ${IP_LIMIT} 个活动IP (续期:${IP_STICKY_SECONDS}s)"
  echo "────────────────────────────────────────────────────────────"
  echo "订阅链接: $url"
  echo "════════════════════════════════════════════════════════════"
  echo "已保存至: ${metadir}/"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  with_lock "${VLESS_LOCK_DIR}/vless_nodes.lock" 30 _create_node
}

_create_node() {
  validate_params
  load_main_config

  # 检查 TAG 是否已存在
  if [[ -d "${VLESS_NODES_DIR}/${TAG}" ]]; then
    log_error "节点 ${TAG} 已存在，请先清理或使用不同 id"
    exit 1
  fi

  local port
  port=$(find_free_port)
  log_info "使用端口: ${port}"

  local uuid priv_key pbk short_id pub_ip
  uuid=$(xray uuid)
  priv_key=$(get_private_key)
  pbk=$(get_pbk)
  short_id=$(openssl rand -hex 8)
  pub_ip=$(get_public_ipv4)

  [[ -n "$pbk" ]]     || { log_error "无法获取 PublicKey，请先安装主节点"; exit 1; }
  [[ -n "$priv_key" ]] || { log_error "无法获取主节点私钥"; exit 1; }
  [[ -n "$pub_ip" ]]  || { log_error "无法获取公网 IP"; exit 1; }

  local dest="${REALITY_DEST}"
  local sni="${REALITY_SNI}"
  local expire=$(( $(now_epoch) + D ))

  # ── 步骤 1: 写 xray 配置 ──────────────────────────────────────────────────
  write_tmp_xray_config "$TAG" "$uuid" "$port" "$priv_key" "$dest" "$sni" "$short_id"
  write_tmp_systemd_unit "$TAG"
  systemctl daemon-reload

  # ── 步骤 2: 启动 systemd unit ─────────────────────────────────────────────
  local unit="xray-tmp@${TAG}.service"
  systemctl enable --now "$unit" || { rollback "$TAG" "$port" "systemd enable/start failed"; exit 1; }

  wait_unit_active "$unit" 10 1 || { rollback "$TAG" "$port" "unit not active"; exit 1; }
  wait_port_listening "$port" 15 1 || { rollback "$TAG" "$port" "port not listening"; exit 1; }

  # ── 步骤 3: 创建配额（如果指定）─────────────────────────────────────────
  if [[ -n "$PQ_GIB" ]]; then
    pq_create "$port" "$PQ_GIB" || { rollback "$TAG" "$port" "pq_create failed"; exit 1; }
  fi

  # ── 步骤 4: 创建 IP 限制（如果指定）──────────────────────────────────────
  if [[ -n "$IP_LIMIT" ]]; then
    il_create "$TAG" "$port" "$IP_LIMIT" "$IP_STICKY_SECONDS" || {
      rollback "$TAG" "$port" "il_create failed"; exit 1
    }
  fi

  # ── 步骤 5: 写节点元数据 ──────────────────────────────────────────────────
  write_node_meta "$TAG" "$uuid" "$port" "$pub_ip" "$expire" \
    "$dest" "$sni" "$short_id" "$pbk"

  # ── 步骤 6: 验证完整性 ────────────────────────────────────────────────────
  systemctl is-active --quiet "$unit" || { rollback "$TAG" "$port" "post-create unit check failed"; exit 1; }
  is_port_listening "$port" || { rollback "$TAG" "$port" "post-create port check failed"; exit 1; }
  [[ -f "${VLESS_NODES_DIR}/${TAG}/meta" ]] || { rollback "$TAG" "$port" "meta missing"; exit 1; }

  gen_tmp_subscription "$TAG" "$uuid" "$port" "$pub_ip" "$pbk" "$sni" "$short_id" "$expire"

  # 注册到期清理定时器
  _schedule_expiry "$TAG" "$expire"
}

_schedule_expiry() {
  local tag="$1" expire="$2"
  local remaining=$(( expire - $(now_epoch) ))
  (( remaining <= 0 )) && { vless_cleanup_one.sh "$tag"; return; }

  # 使用 systemd-run 按绝对时间调度清理
  systemd-run --on-calendar="$(date -d "@${expire}" '+%Y-%m-%d %H:%M:%S')" \
    --unit="vless-expire-${tag}" \
    --description="Auto-expire vless tmp node ${tag}" \
    /usr/local/bin/vless_cleanup_one.sh "$tag" 2>/dev/null || \
    log_warn "systemd-run 调度失败，依赖 GC 兜底"
}
EOF_MK
  chmod 755 "${VLESS_BIN_DIR}/vless_mktemp.sh"
  echo "✅ vless_mktemp.sh 写入完成"
}

# =============================================================================
# 模块 9: vless_cleanup_one.sh — 清理单个节点
# =============================================================================
write_vless_cleanup_one() {
  cat > "${VLESS_BIN_DIR}/vless_cleanup_one.sh" << 'EOF_CO'
#!/usr/bin/env bash
# vless_cleanup_one.sh — 清理单个临时节点（幂等）
# 用法: vless_cleanup_one.sh <TAG>
set -euo pipefail

source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh
source /usr/local/lib/vless/lib_iplimit.sh

TAG="${1:-}"
[[ -n "$TAG" ]] || { echo "用法: $0 <TAG>"; exit 1; }

_do_cleanup() {
  log_info "清理节点: ${TAG}"

  local metadir="${VLESS_NODES_DIR}/${TAG}"
  local port=""

  # 读取端口（如有 meta）
  if [[ -f "${metadir}/meta" ]]; then
    port=$(meta_read "${metadir}/meta" PORT || echo "")
  fi

  # 1. 停止并禁用 systemd unit
  local unit="xray-tmp@${TAG}.service"
  systemctl stop    "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true

  # 2. 删除 systemd drop-in
  rm -f "/etc/systemd/system/xray-tmp@${TAG}.service.d/override.conf" 2>/dev/null || true
  rmdir "/etc/systemd/system/xray-tmp@${TAG}.service.d" 2>/dev/null || true

  # 3. 删除 xray 配置目录
  rm -rf "${XRAY_CONF_DIR}/tmp_${TAG}" 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true

  # 4. 删除端口配额
  if [[ -n "$port" ]]; then
    pq_delete "$port" 2>/dev/null || true
  fi

  # 5. 删除 IP 限制
  il_delete "$TAG" 2>/dev/null || true

  # 6. 删除节点元数据
  rm -rf "$metadir" 2>/dev/null || true

  # 7. 取消 expire 定时器（如果还在）
  systemctl stop    "vless-expire-${TAG}.service" 2>/dev/null || true
  systemctl disable "vless-expire-${TAG}.service" 2>/dev/null || true

  log_info "清理完成: ${TAG}"
  log_to_file "${VLESS_LOG_DIR}/gc.log" "cleanup: tag=${TAG} port=${port}"
}

# 根据是否已持有锁选择调用方式
if [[ "${VLESS_LOCK_HELD:-}" == "1" ]]; then
  _do_cleanup
else
  with_lock "${VLESS_LOCK_DIR}/vless_nodes.lock" 30 _do_cleanup
fi
EOF_CO
  chmod 755 "${VLESS_BIN_DIR}/vless_cleanup_one.sh"
  echo "✅ vless_cleanup_one.sh 写入完成"
}

# =============================================================================
# 模块 10: vless_gc.sh — GC 过期节点
# =============================================================================
write_vless_gc() {
  cat > "${VLESS_BIN_DIR}/vless_gc.sh" << 'EOF_GC'
#!/usr/bin/env bash
# vless_gc.sh — 定时 GC：清理已过期的临时节点（兜底机制）
# 只处理"当前仍存在且已过期"的节点，不复活已删除对象
set -euo pipefail

source /usr/local/lib/vless/lib_common.sh

LOGFILE="${VLESS_LOG_DIR}/gc.log"

_do_gc() {
  local now; now=$(now_epoch)
  local gc_count=0

  log_to_file "$LOGFILE" "=== GC start ==="

  for tag in $(list_managed_tags); do
    local metadir="${VLESS_NODES_DIR}/${tag}"
    [[ -f "${metadir}/meta" ]] || continue

    local expire
    expire=$(meta_read "${metadir}/meta" EXPIRE_EPOCH || echo "0")

    if (( now >= expire )); then
      log_to_file "$LOGFILE" "GC: expiring tag=${tag} expire=${expire} now=${now}"
      VLESS_LOCK_HELD=1 /usr/local/bin/vless_cleanup_one.sh "$tag" \
        >> "$LOGFILE" 2>&1 || true
      (( gc_count++ ))
    fi
  done

  log_to_file "$LOGFILE" "=== GC done: cleaned ${gc_count} nodes ==="
}

with_lock "${VLESS_LOCK_DIR}/vless_nodes.lock" 30 _do_gc
EOF_GC
  chmod 755 "${VLESS_BIN_DIR}/vless_gc.sh"
  echo "✅ vless_gc.sh 写入完成"
}

# =============================================================================
# 模块 11: vless_clear_all.sh
# =============================================================================
write_vless_clear_all() {
  cat > "${VLESS_BIN_DIR}/vless_clear_all.sh" << 'EOF_CA'
#!/usr/bin/env bash
# vless_clear_all.sh — 清理所有临时节点
set -euo pipefail
source /usr/local/lib/vless/lib_common.sh

echo "⚠️  将清理所有临时节点，按 Ctrl+C 取消..."
sleep 3

_do_clear_all() {
  for tag in $(list_managed_tags); do
    echo "清理: ${tag}"
    VLESS_LOCK_HELD=1 /usr/local/bin/vless_cleanup_one.sh "$tag" || true
  done
  echo "✅ 全部临时节点已清理"
}

with_lock "${VLESS_LOCK_DIR}/vless_nodes.lock" 60 _do_clear_all
EOF_CA
  chmod 755 "${VLESS_BIN_DIR}/vless_clear_all.sh"
  echo "✅ vless_clear_all.sh 写入完成"
}

# =============================================================================
# 模块 12: pq_reset.sh — 周期配额重置（>30天服务才触发）
# =============================================================================
write_pq_reset() {
  cat > "${VLESS_BIN_DIR}/pq_reset.sh" << 'EOF_RESET'
#!/usr/bin/env bash
# pq_reset.sh — 配额自动重置（每天检查一次，满 30 天 + RESET_ENABLED=1 才重置）
# 严格约束：只处理当前仍存在的端口，绝不复活已删除对象
set -euo pipefail
source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh

LOGFILE="${VLESS_LOG_DIR}/pq_reset.log"
log_to_file "$LOGFILE" "=== pq_reset check start ==="

for port in $(list_managed_quota_ports); do
  # 必须同时存在节点 meta，否则跳过（节点已删除但 quota meta 残留时）
  local_owner=""
  for tag in $(list_managed_tags); do
    local_port=$(meta_read "${VLESS_NODES_DIR}/${tag}/meta" PORT 2>/dev/null || echo "")
    if [[ "$local_port" == "$port" ]]; then
      local_owner="$tag"; break
    fi
  done

  if [[ -z "$local_owner" ]]; then
    # 也检查是否为主节点端口
    main_port=$(grep -E "^PORT=" "${VLESS_DEFAULT}" 2>/dev/null | cut -d= -f2 || echo "")
    [[ "$port" == "$main_port" ]] || {
      log_to_file "$LOGFILE" "SKIP: port=${port} no owner node (already deleted?)"
      continue
    }
  fi

  pq_reset_if_due "$port" || log_to_file "$LOGFILE" "WARN: reset check failed for port=${port}"
done

log_to_file "$LOGFILE" "=== pq_reset check done ==="
EOF_RESET
  chmod 755 "${VLESS_BIN_DIR}/pq_reset.sh"
  echo "✅ pq_reset.sh 写入完成"
}

# =============================================================================
# 模块 13: vless_audit.sh — 完整审计（只读）
# =============================================================================
write_vless_audit() {
  cat > "${VLESS_BIN_DIR}/vless_audit.sh" << 'EOF_AU'
#!/usr/bin/env bash
# vless_audit.sh — 只读审计（严禁触发任何修改/保存/清理）
source /usr/local/lib/vless/lib_common.sh
source /usr/local/lib/vless/lib_quota.sh
source /usr/local/lib/vless/lib_iplimit.sh

fmt_bytes() {
  local b="${1:-0}"
  if   (( b >= 1073741824 )); then printf "%.2fGiB" "$(echo "$b 1073741824" | awk '{printf "%.2f",$1/$2}')";
  elif (( b >= 1048576 ));    then printf "%.2fMiB" "$(echo "$b 1048576"    | awk '{printf "%.2f",$1/$2}')";
  elif (( b >= 1024 ));       then printf "%.2fKiB" "$(echo "$b 1024"       | awk '{printf "%.2f",$1/$2}')";
  else printf "%dB" "$b"; fi
}

now=$(now_epoch)

echo "══════════════════════════════════════════════════════════════════════════════"
echo "  VLESS 节点审计  $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S') (北京时间)"
echo "══════════════════════════════════════════════════════════════════════════════"

# ── 主节点 ────────────────────────────────────────────────────────────────────
echo ""
echo "▌ 主节点"
echo "────────────────────────────────────────────────────────────────────────────"

if [[ -f "${VLESS_DEFAULT}" ]]; then
  source "${VLESS_DEFAULT}"
  main_status=$(systemctl is-active xray.service 2>/dev/null || echo "inactive")
  main_listen="否"
  is_port_listening "${PORT:-}" && main_listen="是"
  echo "  节点名称 : ${NODE_NAME:-main}"
  echo "  systemd  : ${main_status}"
  echo "  端口     : ${PORT:-?}  监听: ${main_listen}"
  echo "  服务器   : ${PUBLIC_DOMAIN:-?}"

  # 主节点配额（如果存在）
  if [[ -d "${VLESS_QUOTA_DIR}/${PORT}" ]]; then
    qs=$(pq_status "${PORT}")
    orig=$(echo "$qs" | grep -oP 'ORIG=\K[0-9]+')
    used=$(echo "$qs" | grep -oP 'USED=\K[0-9]+')
    left=$(echo "$qs" | grep -oP 'LEFT=\K[0-9]+')
    pct=$(echo  "$qs" | grep -oP 'PCT=\K[0-9]+')
    echo "  配额     : LIMIT=$(fmt_bytes $orig) USED=$(fmt_bytes $used) LEFT=$(fmt_bytes $left) (${pct}%)"
  fi
else
  echo "  ⚠️  未找到主节点配置 ${VLESS_DEFAULT}"
fi

# ── 临时节点 ──────────────────────────────────────────────────────────────────
echo ""
echo "▌ 临时节点"
echo "────────────────────────────────────────────────────────────────────────────"

tmp_count=0
for tag in $(list_managed_tags | sort); do
  tmp_count=$(( tmp_count + 1 ))
  metadir="${VLESS_NODES_DIR}/${tag}"
  meta="${metadir}/meta"

  if [[ ! -f "$meta" ]]; then
    echo "  [${tag}]  ⚠️  meta 缺失 (missing/stale)"
    continue
  fi

  uuid=$(meta_read "$meta" UUID)
  port=$(meta_read "$meta" PORT)
  expire=$(meta_read "$meta" EXPIRE_EPOCH)
  pq_gib=$(meta_read "$meta" PQ_GIB)
  ip_limit=$(meta_read "$meta" IP_LIMIT)
  ip_sticky=$(meta_read "$meta" IP_STICKY_SECONDS)
  server=$(meta_read "$meta" SERVER_ADDR)

  unit="xray-tmp@${tag}.service"
  unit_status=$(systemctl is-active "$unit" 2>/dev/null || echo "inactive")
  listen="否"
  [[ -n "$port" ]] && is_port_listening "$port" && listen="是"

  ttl=$(( expire - now ))
  ttl_str=$(seconds_to_human "$ttl")
  expire_str=$(epoch_to_beijing "$expire")
  [[ "$ttl" -le 0 ]] && { ttl_str="已过期"; expire_str="已过期"; }

  echo ""
  echo "  ┌─ TAG: ${tag}"
  echo "  │  UUID     : ${uuid}"
  echo "  │  端口     : ${port:-?}  服务器: ${server:-?}"
  echo "  │  systemd  : ${unit_status}  监听: ${listen}"
  echo "  │  TTL      : ${ttl_str}"
  echo "  │  过期时间 : ${expire_str}"

  # 配额信息
  if [[ -n "$pq_gib" ]] && [[ "$pq_gib" != "" ]]; then
    if [[ -d "${VLESS_QUOTA_DIR}/${port}" ]]; then
      qs=$(pq_status "$port")
      orig=$(echo "$qs" | grep -oP 'ORIG=\K[0-9]+')
      used=$(echo "$qs" | grep -oP 'USED=\K[0-9]+')
      left=$(echo "$qs" | grep -oP 'LEFT=\K[0-9]+')
      pct=$(echo  "$qs" | grep -oP 'PCT=\K[0-9]+')
      echo "  │  配额     : LIMIT=$(fmt_bytes $orig) USED=$(fmt_bytes $used) LEFT=$(fmt_bytes $left) (${pct}%)"
    else
      echo "  │  配额     : ⚠️  missing/stale"
    fi
  else
    echo "  │  配额     : 无"
  fi

  # IP 限制信息
  if [[ -n "$ip_limit" ]] && [[ "$ip_limit" != "" ]]; then
    active_ips=$(il_active_count "$tag" 2>/dev/null || echo "?")
    echo "  │  IP限制   : ${ip_limit} 个槽位  活动: ${active_ips}  续期: ${ip_sticky}s"
  else
    echo "  │  IP限制   : 无"
  fi
  echo "  └─────────────────────────────────────────────────────────────────────"
done

(( tmp_count == 0 )) && echo "  (无临时节点)"

echo ""
echo "══════════════════════════════════════════════════════════════════════════════"
EOF_AU
  chmod 755 "${VLESS_BIN_DIR}/vless_audit.sh"
  echo "✅ vless_audit.sh 写入完成"
}

# =============================================================================
# 模块 14: systemd 单元
# =============================================================================
write_systemd_units() {
  echo "🔧 安装 systemd 单元..."

  # ── xray-tmp@ 模板单元 ────────────────────────────────────────────────────
  cat > /etc/systemd/system/xray-tmp@.service << 'EOF_ST'
[Unit]
Description=Xray Temporary Node %i
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/tmp_%i

[Install]
WantedBy=multi-user.target
EOF_ST

  # ── vless-gc.service + timer ──────────────────────────────────────────────
  cat > /etc/systemd/system/vless-gc.service << 'EOF_GCS'
[Unit]
Description=VLESS GC - Clean expired temp nodes
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/vless_gc.sh
StandardOutput=journal
StandardError=journal
EOF_GCS

  cat > /etc/systemd/system/vless-gc.timer << 'EOF_GCT'
[Unit]
Description=VLESS GC Timer (every 5 minutes)
After=network.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_GCT

  # ── pq-save-state.service + timer ─────────────────────────────────────────
  cat > /etc/systemd/system/pq-save-state.service << 'EOF_PSS2'
[Unit]
Description=VLESS Port Quota - Save State
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/pq_save_state.sh
StandardOutput=journal
StandardError=journal
EOF_PSS2

  cat > /etc/systemd/system/pq-save-state.timer << 'EOF_PSST'
[Unit]
Description=VLESS Port Quota Save State Timer (every 5 minutes)

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF_PSST

  # ── 关机前保存（ExecStop-like via StopPre on shutdown） ───────────────────
  cat > /etc/systemd/system/pq-save-on-shutdown.service << 'EOF_SHUTDOWN'
[Unit]
Description=VLESS Port Quota - Save before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/pq_save_state.sh
RemainAfterExit=yes
TimeoutStartSec=30s

[Install]
WantedBy=shutdown.target reboot.target halt.target
EOF_SHUTDOWN

  # ── 开机恢复 ─────────────────────────────────────────────────────────────
  cat > /etc/systemd/system/pq-restore.service << 'EOF_RESTORE'
[Unit]
Description=VLESS Port Quota - Restore on boot
After=network.target nftables.service
Before=xray.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/pq_restore.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_RESTORE

  # ── pq-reset.service + timer ──────────────────────────────────────────────
  cat > /etc/systemd/system/pq-reset.service << 'EOF_RESET2'
[Unit]
Description=VLESS Port Quota - Auto Reset Check

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/pq_reset.sh
StandardOutput=journal
StandardError=journal
EOF_RESET2

  cat > /etc/systemd/system/pq-reset.timer << 'EOF_RESETT'
[Unit]
Description=VLESS Port Quota Reset Check Timer (daily)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF_RESETT

  # ── nftables 持久化 ───────────────────────────────────────────────────────
  # 确保 /etc/nftables.conf 加载我们的规则文件
  if ! grep -q "include.*nftables.d" /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
  fi
  # 初始化空规则文件（开机恢复时由 pq_restore.sh 填充）
  touch /etc/nftables.d/vless_quota.nft
  touch /etc/nftables.d/vless_iplimit.nft

  systemctl daemon-reload
  systemctl enable --now vless-gc.timer
  systemctl enable --now pq-save-state.timer
  systemctl enable --now pq-reset.timer
  systemctl enable --now pq-restore.service
  systemctl enable pq-save-on-shutdown.service
  systemctl enable nftables.service

  echo "✅ systemd 单元安装完成"
}

# =============================================================================
# 模块 15: logrotate + journal 清理
# =============================================================================
write_logrotate() {
  cat > /etc/logrotate.d/vless << 'EOF_LR'
/var/log/vless/*.log {
  daily
  rotate 2
  compress
  delaycompress
  missingok
  notifempty
  create 640 root root
}
EOF_LR

  # journal 保留 2 天
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/vless-retention.conf << 'EOF_JR'
[Journal]
MaxRetentionSec=2day
SystemMaxUse=200M
EOF_JR
  systemctl restart systemd-journald 2>/dev/null || true
  echo "✅ logrotate + journal 配置完成"
}

# =============================================================================
# 模块 16: 路径符号链接（方便直接调用）
# =============================================================================
write_symlinks() {
  for cmd in vless_mktemp vless_audit vless_gc vless_clear_all \
             vless_cleanup_one pq_audit pq_save_state pq_restore pq_reset; do
    local src="${VLESS_BIN_DIR}/${cmd}.sh"
    local dst="/usr/local/bin/${cmd}"
    [[ -f "$src" ]] && ln -sf "$src" "$dst" && chmod 755 "$dst" || true
  done
  echo "✅ 符号链接创建完成"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  echo "═══════════════════════════════════════════════════════════════"
  echo "  VLESS Reality 一键部署 v2.0 — Debian 12 专用"
  echo "═══════════════════════════════════════════════════════════════"

  pre_check
  install_deps
  make_dirs

  echo ""
  echo "📝 写入模块脚本..."
  write_lib_common
  write_lib_quota
  write_lib_iplimit
  write_pq_save_state
  write_pq_restore
  write_pq_audit
  write_vless_audit
  write_onekey
  write_vless_mktemp
  write_vless_cleanup_one
  write_vless_gc
  write_vless_clear_all
  write_pq_reset
  write_symlinks

  echo ""
  echo "🔧 安装 systemd 单元..."
  write_systemd_units

  echo ""
  echo "📋 配置 logrotate..."
  write_logrotate

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "✅ 所有模块已部署！"
  echo ""
  echo "下一步：安装主节点"
  echo "  bash /root/onekey_reality_ipv4.sh"
  echo ""
  echo "创建临时节点（示例）："
  echo "  id='tmp001' IP_LIMIT=1 PQ_GIB=1 D=1200 vless_mktemp.sh"
  echo ""
  echo "查看审计："
  echo "  vless_audit.sh"
  echo "  pq_audit.sh"
  echo "═══════════════════════════════════════════════════════════════"

  # 询问是否立即安装主节点
  read -rp "是否现在安装主节点？[y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    bash /root/onekey_reality_ipv4.sh
  fi
}

main "$@"
