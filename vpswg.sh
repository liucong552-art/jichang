cat >/root/setup_wg_nat_vps_v4.sh <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# WG-NAT（VPS 侧增量）：为“标记(mark)流量”提供 WireGuard 出口（经 NAT 机 MASQUERADE 出网）
# 用法（默认参数即可）：
#   bash /root/setup_wg_nat_vps_v4.sh
# 然后拿到输出的 VPS_WG_PUB，去 NAT 机执行：
#   bash /root/nat1.sh add <name> <VPS域名或IP> <VPS_WG_ADDR/32> '<VPS_WG_PUB>'
# 再回到 VPS 执行：
#   /usr/local/sbin/wg_nat_set_peer.sh '<NAT_WG_PUB>'
#
# 可覆盖参数：
WG_IF="${WG_IF:-wg-nat}"
WG_PORT="${WG_PORT:-51820}"
WG_ADDR="${WG_ADDR:-10.66.66.1/24}"
MARK_RAW="${MARK:-2333}"          # 2333 / 0x91d 都行
TABLE_ID="${TABLE_ID:-100}"

need_root(){ [[ ${EUID:-0} -eq 0 ]] || { echo "❌ 请用 root 运行"; exit 1; }; }

ts(){ date +%F_%H%M%S; }
backup_if_exists(){
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak.$(ts)"
    echo "✅ 备份：$f -> ${f}.bak.$(ts)"
  fi
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
    echo "❌ MARK 格式不合法：$1（应为 2333 或 0x91d）" >&2
    exit 1
  fi
}

need_root
export DEBIAN_FRONTEND=noninteractive

MARK_DEC="$(norm_mark "$MARK_RAW")"

echo "==> 安装依赖（wireguard-tools / iproute2 / iptables / curl / python3 / openssl）..."
apt-get update -y >/dev/null
apt-get install -y wireguard-tools iproute2 iptables curl python3 openssl >/dev/null

install -d -m 700 /etc/wireguard
install -d -m 755 /usr/local/sbin

echo "==> 生成 VPS WireGuard 密钥（${WG_IF}）..."
umask 077
if [[ ! -f "/etc/wireguard/${WG_IF}.key" ]]; then
  wg genkey | tee "/etc/wireguard/${WG_IF}.key" | wg pubkey >"/etc/wireguard/${WG_IF}.pub"
fi
VPS_PRIV="$(cat "/etc/wireguard/${WG_IF}.key")"
VPS_PUB="$(cat "/etc/wireguard/${WG_IF}.pub")"

echo "==> 写入 wg-quick 配置（先写一个“无 Peer”占位，方便先把服务跑起来）..."
backup_if_exists "/etc/wireguard/${WG_IF}.conf"
cat >"/etc/wireguard/${WG_IF}.conf" <<CFG
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIV}
Table = off

# 放宽 rp_filter：避免策略路由/回程被丢
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true

# 策略路由：只有打了 fwmark 的流量才走 table ${TABLE_ID} -> wg-nat
PostUp = ip rule add fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostUp = ip route replace default dev %i table ${TABLE_ID}

PostDown = ip rule del fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostDown = ip route del default dev %i table ${TABLE_ID} 2>/dev/null || true
CFG
chmod 600 "/etc/wireguard/${WG_IF}.conf"

echo "==> 放行 UDP/${WG_PORT}（若你没有防火墙，此步无害；如有云安全组仍需在面板放行）..."
iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "${WG_PORT}" -j ACCEPT || true

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  echo "❌ wg-quick@${WG_IF} 启动失败，日志如下：" >&2
  systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
  journalctl -u "wg-quick@${WG_IF}" --no-pager -n 120 >&2 || true
  exit 1
fi

backup_if_exists /usr/local/sbin/wg_nat_set_peer.sh
cat >/usr/local/sbin/wg_nat_set_peer.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

WG_IF="${WG_IF:-wg-nat}"
WG_PORT="${WG_PORT:-51820}"
WG_ADDR="${WG_ADDR:-10.66.66.1/24}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"

need_root(){ [[ ${EUID:-0} -eq 0 ]] || { echo "❌ 请用 root 运行"; exit 1; }; }
norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then raw="${raw#0x}"; echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then echo "$raw"
  else echo "❌ MARK 格式不合法：$1" >&2; exit 1
  fi
}

need_root

NAT_PUB="${1:-}"
[[ -n "$NAT_PUB" ]] || { echo "用法: wg_nat_set_peer.sh <NAT_PUBLIC_KEY>"; exit 1; }

NAT_PUB="${NAT_PUB//[[:space:]]/}"
NAT_PUB="${NAT_PUB//\"/}"
NAT_PUB="${NAT_PUB#<}"; NAT_PUB="${NAT_PUB%>}"

if ! [[ "$NAT_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "⚠️ 警告：NAT_PUB 看起来不像标准 WG 公钥（仍继续写入）。值：$NAT_PUB" >&2
fi

[[ -f "/etc/wireguard/${WG_IF}.key" ]] || { echo "❌ 缺少 /etc/wireguard/${WG_IF}.key，请先跑 VPS 增量脚本"; exit 1; }

MARK_DEC="$(norm_mark "$MARK_RAW")"
VPS_PRIV="$(cat "/etc/wireguard/${WG_IF}.key")"

cat >"/etc/wireguard/${WG_IF}.conf" <<CFG
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIV}
Table = off

PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true

PostUp = ip rule add fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostUp = ip route replace default dev %i table ${TABLE_ID}

PostDown = ip rule del fwmark ${MARK_DEC} lookup ${TABLE_ID} 2>/dev/null || true
PostDown = ip route del default dev %i table ${TABLE_ID} 2>/dev/null || true

[Peer]
PublicKey = ${NAT_PUB}
AllowedIPs = 0.0.0.0/0
CFG

chmod 600 "/etc/wireguard/${WG_IF}.conf"
iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "${WG_PORT}" -j ACCEPT || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  echo "❌ wg-quick@${WG_IF} 启动失败，日志如下：" >&2
  systemctl --no-pager --full status "wg-quick@${WG_IF}" >&2 || true
  journalctl -u "wg-quick@${WG_IF}" --no-pager -n 120 >&2 || true
  exit 1
fi

echo "✅ 已回填 NAT 公钥并启动 ${WG_IF}"
SH
chmod +x /usr/local/sbin/wg_nat_set_peer.sh

backup_if_exists /usr/local/sbin/wg_nat_healthcheck.sh
cat >/usr/local/sbin/wg_nat_healthcheck.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

WG_IF="${WG_IF:-wg-nat}"
MARK_RAW="${MARK:-2333}"
TABLE_ID="${TABLE_ID:-100}"
HANDSHAKE_MAX="${HANDSHAKE_MAX:-180}"

fail(){ echo "❌ $*" >&2; exit 1; }
need_root(){ [[ ${EUID:-0} -eq 0 ]] || fail "请用 root 运行"; }

norm_mark(){
  local raw="${1,,}"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" =~ ^0x[0-9a-f]+$ ]]; then raw="${raw#0x}"; echo "$((16#$raw))"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then echo "$raw"
  else fail "MARK 格式不合法：$1"
  fi
}

need_root
MARK_DEC="$(norm_mark "$MARK_RAW")"
MARK_HEX="$(printf '0x%x' "$MARK_DEC")"

ip link show dev "$WG_IF" >/dev/null 2>&1 || fail "接口 $WG_IF 不存在/未启动：systemctl restart wg-quick@${WG_IF}"

echo "---- route test (mark=${MARK_DEC}) ----"
RG="$(ip route get 1.1.1.1 mark "$MARK_DEC" 2>/dev/null || true)"
echo "${RG:-<empty>}"
grep -qE "\bdev ${WG_IF}\b" <<<"$RG" || { echo "---- ip rule ----" >&2; ip rule show >&2 || true; fail "策略路由未走 ${WG_IF}（mark=${MARK_DEC}）"; }

echo "---- ip rule (fwmark -> table) ----"
if ip rule | grep -qE "fwmark (${MARK_HEX}|${MARK_DEC}).*lookup ${TABLE_ID}"; then
  echo "OK: ip rule 存在"
else
  echo "⚠️ 未找到 ip rule（可能 wg-quick 没跑 PostUp）"
fi

echo "---- wg show ----"
wg show "$WG_IF" || true

PEERS="$(wg show "$WG_IF" peers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${PEERS:-0}" == "0" ]]; then
  fail "wg-nat 尚未配置 peer：先执行 wg_nat_set_peer.sh <NAT_PUBLIC_KEY>"
fi

echo "---- handshake check ----"
HS="$(wg show "$WG_IF" latest-handshakes | awk 'NF>=2{print $2}' | sort -nr | head -n1 || true)"
[[ -n "$HS" ]] || fail "读不到握手时间（peer 未配置？）"
(( HS > 0 )) || fail "从未握手（latest-handshakes=0）。去 NAT 机检查 wg-exit 是否已启动 + PersistentKeepalive"

NOW="$(date +%s)"
AGE="$((NOW - HS))"
(( AGE <= HANDSHAKE_MAX )) || fail "握手过旧：${AGE}s（> ${HANDSHAKE_MAX}s）。去 NAT 机重启 wg-exit/检查 UDP 51820"

echo "---- curl exit ip (via ${WG_IF}) ----"
for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com"; do
  ip="$(curl -4fsS --connect-timeout 3 --max-time 8 --interface "${WG_IF}" "$url" 2>/dev/null | tr -d ' \r\n' || true)"
  if [[ -n "$ip" ]]; then
    echo "OK EXIT_IP=${ip}"
    exit 0
  fi
done

fail "出网测试失败（curl --interface ${WG_IF} 没拿到出口 IP）。优先检查：1) VPS 云安全组/防火墙 UDP 51820 2) NAT 机 ip_forward+MASQUERADE 3) 公钥/endpoint"
SH
chmod +x /usr/local/sbin/wg_nat_healthcheck.sh

echo
echo "✅ VPS 端 WG-NAT 增量部署完成（不会动你的主 Xray 配置/服务）。"
echo "==================== VPS WG 公钥 ===================="
echo "${VPS_PUB}"
echo "======================================================"
echo
echo "下一步：去 NAT 机执行新版命令："
echo "bash /root/nat1.sh add <name> <VPS域名或IP> <VPS_WG_ADDR/32> '${VPS_PUB}'"
echo
echo "示例（第1台 VPS）："
echo "bash /root/nat1.sh add vps1 your-domain.example.com 10.66.66.1/32 '${VPS_PUB}'"
echo
echo "示例（第2台 VPS）："
echo "bash /root/nat1.sh add vps2 your-domain.example.com 10.66.66.3/32 '${VPS_PUB}'"
echo
echo "然后回到本机执行："
echo "/usr/local/sbin/wg_nat_set_peer.sh '<NAT_WG_PUB>'"
EOF2

chmod +x /root/setup_wg_nat_vps_v4.sh
bash /root/setup_wg_nat_vps_v4.sh
