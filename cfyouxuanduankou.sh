#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo; echo "❌ 脚本执行失败：第 ${LINENO} 行附近出错。"; echo "可查看日志：journalctl -u nginx -u xray --no-pager -n 100";' ERR

# ==========================================================
# VLESS + WSS + Cloudflare 自定义端口脚本
#
# 原版本默认端口：
#   DOMAIN     = hy21.liucna.com
#   TLS_PORT   = 443
#   XRAY_PORT  = 10000
#   HTTP_PORT  = 80
#
# 换新 VPS / 新 IP / 新域名时，最少要改：
#   1. DOMAIN：必改，改成新域名
#   2. Cloudflare DNS：A 记录指向新 VPS 的 IP，并开启小黄云
#   3. VPS 防火墙 / 云安全组：放行 TLS_PORT，例如 443 或 8443
#
# 可选修改：
#   TLS_PORT  ：公网 TLS/WSS 端口，小黄云只能用 443/2053/2083/2087/2096/8443
#   XRAY_PORT ：Xray 本地端口，只监听 127.0.0.1，可随便换，别冲突即可
#   HTTP_PORT ：HTTP 占位端口，默认 80；如果 80 被占用，可设为 0 跳过
#
# 运行示例：
#   bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/jichang/refs/heads/main/cfyouxuanduankou.sh)
#
# 不交互运行示例：
#   DOMAIN="new.example.com" TLS_PORT=8443 XRAY_PORT=10010 HTTP_PORT=0 bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/jichang/refs/heads/main/cfyouxuanduankou.sh)
# ==========================================================

DEFAULT_DOMAIN="hy21.liucna.com"
DEFAULT_TLS_PORT="443"
DEFAULT_XRAY_PORT="10000"
DEFAULT_HTTP_PORT="80"

CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
CF_HTTP_PORTS="80 8080 8880 2052 2082 2086 2095"

# 默认严格检查 Cloudflare 小黄云端口。
# 如果你是灰云直连，或者不用 Cloudflare 小黄云，可以设置 CF_STRICT=0 跳过检查。
CF_STRICT="${CF_STRICT:-1}"

ask_value() {
    local var_name="$1"
    local default_value="$2"
    local prompt_text="$3"
    local current_value="${!var_name-}"

    if [ -n "${current_value}" ]; then
        return 0
    fi

    if [ -t 0 ]; then
        read -r -p "${prompt_text} [默认: ${default_value}]: " input_value || input_value=""
        printf -v "${var_name}" "%s" "${input_value:-$default_value}"
    else
        printf -v "${var_name}" "%s" "${default_value}"
    fi

    export "${var_name}"
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_port() {
    local port="$1"
    local name="$2"
    local allow_zero="${3:-0}"

    if ! is_number "${port}"; then
        echo "❌ ${name} 必须是数字，当前值：${port}"
        exit 1
    fi

    if [ "${allow_zero}" = "1" ] && [ "${port}" = "0" ]; then
        return 0
    fi

    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        echo "❌ ${name} 必须在 1-65535 之间，当前值：${port}"
        exit 1
    fi
}

contains_port() {
    local port="$1"
    shift
    local item
    for item in "$@"; do
        if [ "${port}" = "${item}" ]; then
            return 0
        fi
    done
    return 1
}

check_port_used_by_other_service() {
    local port="$1"
    local name="$2"

    local used
    used="$(ss -H -lntp "sport = :${port}" 2>/dev/null || true)"

    if [ -z "${used}" ]; then
        return 0
    fi

    if echo "${used}" | grep -qi 'nginx'; then
        echo "⚠️ ${name}=${port} 当前被 nginx 使用。"
        echo "   如果是旧的本脚本配置，后面会自动覆盖并重启 nginx。"
        return 0
    fi

    if echo "${used}" | grep -qi 'xray'; then
        echo "⚠️ ${name}=${port} 当前被 xray 使用。"
        echo "   如果是旧的本脚本配置，后面会自动重启 xray。"
        return 0
    fi

    echo
    echo "❌ ${name}=${port} 已被其它服务占用："
    echo "${used}"
    echo
    echo "请换一个端口后重新运行。"
    exit 1
}

echo "=================================================="
echo "VLESS + WSS + Cloudflare 自定义端口安装脚本"
echo "=================================================="
echo
echo "默认使用原脚本端口："
echo "  TLS_PORT=${DEFAULT_TLS_PORT}"
echo "  XRAY_PORT=${DEFAULT_XRAY_PORT}"
echo "  HTTP_PORT=${DEFAULT_HTTP_PORT}"
echo
echo "Cloudflare 小黄云 TLS/WSS 可用公网端口："
echo "  ${CF_HTTPS_PORTS}"
echo
echo "不要把 TLS_PORT 设置成这些："
echo "  80 8080 8880 2052 2082 2086 2095：这些是 HTTP 端口"
echo "  10000 10010 12345 5000 8081 8444 等随机端口：小黄云默认不转发"
echo
echo "换新 VPS / 新 IP / 新域名时："
echo "  DOMAIN 必改"
echo "  Cloudflare DNS 的 A 记录要指向新 VPS IP"
echo "  新 VPS 防火墙 / 安全组要放行 TLS_PORT"
echo "=================================================="
echo

ask_value DOMAIN "${DEFAULT_DOMAIN}" "请输入域名 DOMAIN"
ask_value TLS_PORT "${DEFAULT_TLS_PORT}" "请输入公网 TLS/WSS 端口 TLS_PORT"
ask_value XRAY_PORT "${DEFAULT_XRAY_PORT}" "请输入 Xray 本地端口 XRAY_PORT"
ask_value HTTP_PORT "${DEFAULT_HTTP_PORT}" "请输入 HTTP 占位端口 HTTP_PORT，填 0 表示不监听 HTTP"

DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
TLS_PORT="${TLS_PORT:-$DEFAULT_TLS_PORT}"
XRAY_PORT="${XRAY_PORT:-$DEFAULT_XRAY_PORT}"
HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"

validate_port "${TLS_PORT}" "TLS_PORT"
validate_port "${XRAY_PORT}" "XRAY_PORT"
validate_port "${HTTP_PORT}" "HTTP_PORT" "1"

read -r -a CF_HTTPS_PORT_ARRAY <<< "${CF_HTTPS_PORTS}"
read -r -a CF_HTTP_PORT_ARRAY <<< "${CF_HTTP_PORTS}"

if [ "${CF_STRICT}" = "1" ]; then
    if ! contains_port "${TLS_PORT}" "${CF_HTTPS_PORT_ARRAY[@]}"; then
        echo
        echo "❌ TLS_PORT=${TLS_PORT} 不是 Cloudflare 小黄云 HTTPS/WSS 支持端口。"
        echo
        echo "小黄云 TLS/WSS 只能选："
        echo "  ${CF_HTTPS_PORTS}"
        echo
        echo "不能用作本脚本 TLS_PORT 的常见端口："
        echo "  80 8080 8880 2052 2082 2086 2095：这些是 HTTP 端口"
        echo "  10000 10010 12345 5000 8081 8444 等随机端口：小黄云默认不转发"
        echo
        echo "如果你是灰云直连，可以这样跳过检查："
        echo "  CF_STRICT=0 TLS_PORT=${TLS_PORT} bash <(curl -fsSL 脚本地址)"
        exit 1
    fi

    if [ "${HTTP_PORT}" != "0" ] && ! contains_port "${HTTP_PORT}" "${CF_HTTP_PORT_ARRAY[@]}"; then
        echo
        echo "⚠️ HTTP_PORT=${HTTP_PORT} 不是 Cloudflare 小黄云 HTTP 支持端口。"
        echo "HTTP 支持端口是：${CF_HTTP_PORTS}"
        echo "本脚本主要走 TLS_PORT=${TLS_PORT}，HTTP_PORT 只是占位端口。"
        echo "如果不需要 HTTP，建议 HTTP_PORT=0。"
        echo
    fi
fi

if [ "${TLS_PORT}" = "${XRAY_PORT}" ]; then
    echo "❌ TLS_PORT 和 XRAY_PORT 不能相同。"
    exit 1
fi

if [ "${HTTP_PORT}" != "0" ] && [ "${HTTP_PORT}" = "${TLS_PORT}" ]; then
    echo "❌ HTTP_PORT 和 TLS_PORT 不能相同。"
    exit 1
fi

if [ "${HTTP_PORT}" != "0" ] && [ "${HTTP_PORT}" = "${XRAY_PORT}" ]; then
    echo "❌ HTTP_PORT 和 XRAY_PORT 不能相同。"
    exit 1
fi

if [ "${EUID}" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行。"
    echo "例如：sudo -i 后再执行脚本。"
    exit 1
fi

echo
echo "更新软件源并安装依赖..."
apt update
apt install -y curl wget unzip openssl nginx ca-certificates python3 iproute2

UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
WSPATH="${WSPATH:-/$(openssl rand -hex 8)}"

echo
echo "=================================================="
echo "最终配置："
echo "DOMAIN=${DOMAIN}"
echo "TLS_PORT=${TLS_PORT}"
echo "XRAY_PORT=${XRAY_PORT}"
echo "HTTP_PORT=${HTTP_PORT}"
echo "UUID=${UUID}"
echo "WSPATH=${WSPATH}"
echo "=================================================="
echo

echo "停止可能冲突的旧服务..."
systemctl disable --now hysteria-server 2>/dev/null || true
systemctl disable --now hy2 2>/dev/null || true
systemctl disable --now xray 2>/dev/null || true

check_port_used_by_other_service "${TLS_PORT}" "TLS_PORT"
check_port_used_by_other_service "${XRAY_PORT}" "XRAY_PORT"

if [ "${HTTP_PORT}" != "0" ]; then
    check_port_used_by_other_service "${HTTP_PORT}" "HTTP_PORT"
fi

echo
echo "修复 Oracle/Ubuntu 默认 iptables：放行需要的 TCP 端口，避免被 REJECT 拦截..."

DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent

allow_tcp_port_before_reject() {
    local port="$1"

    while iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
    done

    local reject_line
    reject_line="$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"

    if [ -n "$reject_line" ]; then
        iptables -I INPUT "$reject_line" -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
        echo "已在 REJECT 前放行 TCP ${port}"
    else
        iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
        echo "未发现 REJECT，已追加放行 TCP ${port}"
    fi
}

if [ "${HTTP_PORT}" != "0" ]; then
    allow_tcp_port_before_reject "${HTTP_PORT}"
fi

allow_tcp_port_before_reject "${TLS_PORT}"

netfilter-persistent save
systemctl enable netfilter-persistent

echo
echo "当前 INPUT 规则："
iptables -L INPUT -n -v --line-numbers

echo
echo "安装 Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF_XRAY
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws-local",
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "email": "cf-wss"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WSPATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF_XRAY

mkdir -p /etc/ssl/xray

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout /etc/ssl/xray/${DOMAIN}.key \
  -out /etc/ssl/xray/${DOMAIN}.crt \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN}"

chmod 600 /etc/ssl/xray/${DOMAIN}.key

mkdir -p /etc/cloudflare
curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
  -o /etc/cloudflare/authenticated_origin_pull_ca.pem

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

{
if [ "${HTTP_PORT}" != "0" ]; then
cat <<EOF_NGINX_HTTP
server {
    listen ${HTTP_PORT};
    server_name ${DOMAIN};
    return 444;
}

EOF_NGINX_HTTP
fi

cat <<EOF_NGINX_HTTPS
server {
    listen ${TLS_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/ssl/xray/${DOMAIN}.crt;
    ssl_certificate_key /etc/ssl/xray/${DOMAIN}.key;

    ssl_client_certificate /etc/cloudflare/authenticated_origin_pull_ca.pem;
    ssl_verify_client on;
    ssl_verify_depth 1;

    location ${WSPATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        return 404;
    }
}
EOF_NGINX_HTTPS
} > /etc/nginx/sites-available/xray-wss.conf

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/xray-wss.conf /etc/nginx/sites-enabled/xray-wss.conf

echo
echo "检查 nginx 配置..."
nginx -t

systemctl enable --now nginx
systemctl restart nginx

systemctl enable --now xray
systemctl restart xray

python3 - <<EOF_PY | tee /root/cf-wss-vless-link.txt
import urllib.parse

domain = "${DOMAIN}"
uuid = "${UUID}"
path = "${WSPATH}"
tls_port = "${TLS_PORT}"
xray_port = "${XRAY_PORT}"
http_port = "${HTTP_PORT}"

print("==================================================")
print("VLESS + WSS + Cloudflare 链接：")
print(f"vless://{uuid}@{domain}:{tls_port}?encryption=none&security=tls&sni={domain}&type=ws&host={domain}&path={urllib.parse.quote(path, safe='')}#cf-wss-{domain}-{tls_port}")
print("==================================================")
print("DOMAIN:", domain)
print("TLS_PORT:", tls_port)
print("XRAY_PORT:", xray_port)
print("HTTP_PORT:", http_port)
print("UUID:", uuid)
print("WSPATH:", path)
print("保存位置: /root/cf-wss-vless-link.txt")
print("==================================================")
print("Cloudflare 小黄云 TLS/WSS 可用端口：443, 2053, 2083, 2087, 2096, 8443")
print("其它随机端口走小黄云会不通；灰云直连或 Spectrum 另说。")
print("==================================================")
EOF_PY

echo
echo "检查监听："
if [ "${HTTP_PORT}" != "0" ]; then
    ss -lntup | grep -E ":(${HTTP_PORT}|${TLS_PORT}|${XRAY_PORT})\\b" || true
else
    ss -lntup | grep -E ":(${TLS_PORT}|${XRAY_PORT})\\b" || true
fi

echo
echo "Xray 状态："
systemctl status xray --no-pager -l | sed -n '1,20p'

echo
echo "Nginx 状态："
systemctl status nginx --no-pager -l | sed -n '1,20p'

echo
echo "=================================================="
echo "✅ 安装完成"
echo "链接已保存到：/root/cf-wss-vless-link.txt"
echo
echo "换新 VPS / 新 IP / 新域名时，请记住："
echo "1. DOMAIN 必改成新域名。"
echo "2. Cloudflare DNS 的 A 记录必须指向新 VPS IP。"
echo "3. DNS 记录需要开启小黄云。"
echo "4. 新 VPS 的云防火墙 / 安全组要放行 TLS_PORT=${TLS_PORT}。"
echo "5. 如果你继续使用本脚本的 ssl_verify_client on，Cloudflare 后台需要开启 Authenticated Origin Pulls。"
echo "6. 每次运行默认会生成新的 UUID 和 WSPATH，客户端要导入本次输出的新链接。"
echo
echo "Cloudflare 小黄云 TLS/WSS 可用端口："
echo "  443 2053 2083 2087 2096 8443"
echo "=================================================="
