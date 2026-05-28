#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo; echo "❌ 脚本执行失败：第 ${LINENO} 行附近出错。"; echo "排查建议："; echo "  1) nginx -t"; echo "  2) journalctl -u nginx -u xray-cf-wss --no-pager -n 120"; echo "  3) ss -lntup";' ERR

# ==========================================================
# VLESS + WSS + Cloudflare 安全增强版
#
# 主要优化：
#   1. 不停止、不禁用原机已有 hysteria-server / hy2 / xray 服务
#   2. 使用独立 systemd 服务：xray-cf-wss
#   3. 使用独立配置目录：/usr/local/etc/xray-cf-wss
#   4. 使用独立 Nginx 站点文件，不删除 default，不覆盖其它站点
#   5. TLS_PORT 提前校验：小黄云只允许 443/2053/2083/2087/2096/8443
#   6. 端口冲突提前提示，不安装到一半才失败
#   7. 默认复用上次 UUID / WSPATH，避免重复运行后客户端失效
#
# 默认交互运行：
#   bash cf-wss-safe.sh
#
# 推荐非交互运行：
#   DOMAIN="node.example.com" TLS_PORT=443 XRAY_PORT=10000 HTTP_PORT=0 bash cf-wss-safe.sh
#
# 固定客户端信息，换 VPS 时很好用：
#   DOMAIN="node.example.com" UUID="旧UUID" WSPATH="/旧路径" bash cf-wss-safe.sh
#
# 卸载本脚本创建的服务和配置：
#   ACTION=uninstall DOMAIN="node.example.com" TLS_PORT=443 bash cf-wss-safe.sh
# ==========================================================

DEFAULT_DOMAIN="hy21.liucna.com"
DEFAULT_TLS_PORT="443"
DEFAULT_XRAY_PORT="10000"
DEFAULT_HTTP_PORT="80"

CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
CF_HTTP_PORTS="80 8080 8880 2052 2082 2086 2095"

SERVICE_NAME="xray-cf-wss"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

BASE_CONFIG_DIR="/usr/local/etc/xray-cf-wss"
BASE_SSL_DIR="/etc/ssl/xray-cf-wss"
BASE_NGINX_AVAILABLE="/etc/nginx/sites-available"
BASE_NGINX_ENABLED="/etc/nginx/sites-enabled"

LINK_DIR="/root"
AOP_CA_FILE="/etc/cloudflare/authenticated_origin_pull_ca.pem"

# 行为开关
ACTION="${ACTION:-install}"                 # install / uninstall
CF_STRICT="${CF_STRICT:-1}"                 # 1=强制小黄云 HTTPS 端口校验；0=灰云直连等场景跳过
ENABLE_AOP="${ENABLE_AOP:-1}"               # 1=启用 Cloudflare Authenticated Origin Pulls；0=不校验 Cloudflare 客户端证书
AUTO_FIREWALL="${AUTO_FIREWALL:-1}"         # 1=自动写入 iptables 放行端口；0=不改防火墙
INSTALL_XRAY_IF_MISSING="${INSTALL_XRAY_IF_MISSING:-1}" # 1=缺少 xray 二进制时自动安装
ALLOW_DUPLICATE_DOMAIN="${ALLOW_DUPLICATE_DOMAIN:-0}"   # 1=允许 Nginx 中存在重复 server_name

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

validate_domain() {
    local domain="$1"

    if [ -z "${domain}" ]; then
        echo "❌ DOMAIN 不能为空。"
        exit 1
    fi

    if echo "${domain}" | grep -qE '[[:space:]/:]'; then
        echo "❌ DOMAIN 不要带 http://、https://、斜杠、空格或端口。"
        echo "✅ 正确示例：node.example.com"
        echo "❌ 错误示例：https://node.example.com:443/"
        exit 1
    fi

    if ! echo "${domain}" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; then
        echo "⚠️ DOMAIN 看起来不像标准域名：${domain}"
        echo "   如果你确认无误，可以继续；否则请改成类似 node.example.com"
    fi
}

validate_uuid() {
    local uuid="$1"

    if ! echo "${uuid}" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        echo "❌ UUID 格式不正确：${uuid}"
        echo "✅ 正确示例：$(cat /proc/sys/kernel/random/uuid)"
        exit 1
    fi
}

validate_wspath() {
    local path="$1"

    if [ -z "${path}" ]; then
        echo "❌ WSPATH 不能为空。"
        exit 1
    fi

    if [[ "${path}" != /* ]]; then
        echo "❌ WSPATH 必须以 / 开头，例如 /abc123"
        exit 1
    fi

    if echo "${path}" | grep -qE '[[:space:]]'; then
        echo "❌ WSPATH 不能包含空格。"
        exit 1
    fi

    if [ "${path}" = "/" ]; then
        echo "❌ WSPATH 不建议设置成 /，太明显，也容易和网站根路径冲突。"
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

print_important_notes() {
    cat <<EOF

==================================================
⚠️ 这些参数不要乱改
==================================================
1. DOMAIN
   - 必须是你 Cloudflare 里的域名，例如 node.example.com
   - 不要写 http:// 或 https://
   - 换新 VPS 但域名不变：只改 Cloudflare A 记录 IP
   - 换新域名：这里必须改成新域名，客户端链接也要换

2. TLS_PORT
   - 这是客户端连接的公网 TLS/WSS 端口
   - 如果 DNS 开小黄云，只能用：
     ${CF_HTTPS_PORTS}
   - 不能用 20000、10000、12345 这类随机端口；小黄云默认不会转发
   - 如果你填 TLS_PORT=20000，本脚本会在安装前直接失败并告诉你可用端口

3. XRAY_PORT
   - 这是 Xray 只监听 127.0.0.1 的本地端口
   - 客户端不要填这个端口
   - 只要不和本机其它服务冲突即可，例如 10000 / 20000 / 30000

4. HTTP_PORT
   - 只是 HTTP 占位端口
   - 如果 80 被宝塔、Caddy、已有 Nginx 站点占用，可以设成 0
   - 设成 0 表示不监听 HTTP

5. UUID 和 WSPATH
   - 客户端链接里的 UUID 和 path 必须和服务器一致
   - 想换 VPS 后客户端不变，就手动传入旧 UUID 和旧 WSPATH
   - 不传时，本脚本会优先复用上次保存的值；没有旧值才随机生成

6. 原机服务
   - 本脚本不会停止 hysteria-server / hy2 / xray
   - 本脚本新建独立服务：${SERVICE_NAME}
   - 如果端口被原服务占用，本脚本会退出并提示你换端口
==================================================

EOF
}

print_cf_port_error() {
    local bad_port="$1"

    cat <<EOF

❌ TLS_PORT=${bad_port} 不能用于 Cloudflare 小黄云的 HTTPS/WSS 代理。

Cloudflare 小黄云 HTTPS/WSS 只支持这些公网端口：
  ${CF_HTTPS_PORTS}

这些是 HTTP 端口，不能作为本脚本的 TLS_PORT：
  ${CF_HTTP_PORTS}

常见错误：
  TLS_PORT=20000   ❌ 小黄云不会转发
  TLS_PORT=10000   ❌ 这是本地 Xray 端口，不是公网 TLS 端口
  TLS_PORT=443     ✅ 推荐
  TLS_PORT=2053    ✅ 可用
  TLS_PORT=8443    ✅ 可用

正确示例：
  DOMAIN="${DOMAIN:-node.example.com}" TLS_PORT=443 XRAY_PORT=10000 HTTP_PORT=0 bash $0
  DOMAIN="${DOMAIN:-node.example.com}" TLS_PORT=2053 XRAY_PORT=10000 HTTP_PORT=0 bash $0

如果你不是小黄云，而是灰云直连，可跳过这个检查：
  CF_STRICT=0 DOMAIN="${DOMAIN:-node.example.com}" TLS_PORT=${bad_port} bash $0

EOF
}

safe_name() {
    echo "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
        return 0
    fi

    if [ -x /usr/local/bin/xray ]; then
        echo "/usr/local/bin/xray"
        return 0
    fi

    if [ -x /usr/bin/xray ]; then
        echo "/usr/bin/xray"
        return 0
    fi

    return 1
}

install_xray_if_needed() {
    if get_xray_bin >/dev/null 2>&1; then
        XRAY_BIN="$(get_xray_bin)"
        return 0
    fi

    if [ "${INSTALL_XRAY_IF_MISSING}" != "1" ]; then
        echo "❌ 没找到 xray 二进制文件。"
        echo "   你设置了 INSTALL_XRAY_IF_MISSING=0，所以不会自动安装。"
        exit 1
    fi

    echo
    echo "⚠️ 未发现 xray 二进制，开始安装 Xray。"
    echo "   本脚本不会停止已有服务，但安装器可能会创建默认 xray.service。"
    echo "   本脚本实际使用的仍是独立服务：${SERVICE_NAME}"
    echo

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    XRAY_BIN="$(get_xray_bin)"
    if [ -z "${XRAY_BIN}" ]; then
        echo "❌ Xray 安装后仍未找到 xray 二进制。"
        exit 1
    fi
}

check_command() {
    local cmd="$1"
    local pkg="$2"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("${pkg}")
    fi
}

install_dependencies() {
    echo
    echo "检查依赖..."

    MISSING_PACKAGES=()
    check_command curl curl
    check_command wget wget
    check_command unzip unzip
    check_command openssl openssl
    check_command nginx nginx
    check_command python3 python3
    check_command ss iproute2

    if [ "${AUTO_FIREWALL}" = "1" ]; then
        check_command iptables iptables
    fi

    if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
        echo "需要安装依赖：${MISSING_PACKAGES[*]}"
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y "${MISSING_PACKAGES[@]}" ca-certificates
    else
        echo "依赖已满足。"
    fi

    if [ "${AUTO_FIREWALL}" = "1" ]; then
        DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent
    fi
}

port_used_by_non_nginx() {
    local port="$1"
    local name="$2"
    local allow_nginx="${3:-0}"

    if ! command -v ss >/dev/null 2>&1; then
        echo "⚠️ 当前系统没有 ss 命令，跳过 ${name}=${port} 的端口占用预检查。"
        return 0
    fi

    local used
    used="$(ss -H -lntp "sport = :${port}" 2>/dev/null || true)"

    if [ -z "${used}" ]; then
        return 0
    fi

    if [ "${allow_nginx}" = "1" ] && echo "${used}" | grep -qi 'nginx'; then
        echo "ℹ️ ${name}=${port} 当前由 nginx 监听，这是正常的；本脚本会添加独立 server 块，不会删除其它站点。"
        return 0
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        if echo "${used}" | grep -qi 'xray'; then
            echo "ℹ️ ${name}=${port} 当前可能由本脚本服务 ${SERVICE_NAME} 使用，允许继续升级/重载。"
            return 0
        fi
    fi

    echo
    echo "❌ ${name}=${port} 已被其它服务占用："
    echo "${used}"
    echo
    echo "处理方法："
    echo "  - 如果这是你的原机服务，请不要关它，改本脚本端口即可。"
    echo "  - 如果冲突的是 TLS_PORT，请换成 Cloudflare HTTPS 支持端口：${CF_HTTPS_PORTS}"
    echo "  - 如果冲突的是 XRAY_PORT，请换一个本地端口，例如 20000 / 30000"
    echo "  - 如果冲突的是 HTTP_PORT=80，可以设置 HTTP_PORT=0"
    exit 1
}

check_duplicate_nginx_domain() {
    local domain="$1"
    local tls_port="$2"
    local self_conf="$3"

    if [ "${ALLOW_DUPLICATE_DOMAIN}" = "1" ]; then
        return 0
    fi

    local matches
    matches="$(grep -RIlE "server_name[[:space:]]+([^;[:space:]]+[[:space:]]+)*${domain}([[:space:];]|$)" /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | grep -vF "${self_conf}" || true)"

    if [ -n "${matches}" ]; then
        echo
        echo "❌ Nginx 里已经存在相同域名的配置：${domain}"
        echo "${matches}"
        echo
        echo "为避免覆盖或抢占原站点，本脚本已停止。"
        echo "处理方法："
        echo "  1) 换一个新的子域名，例如 node2.example.com"
        echo "  2) 或确认你要共存后使用：ALLOW_DUPLICATE_DOMAIN=1"
        echo "  3) 或手动整理 Nginx 配置后再运行"
        exit 1
    fi
}

allow_tcp_port_before_reject() {
    local port="$1"

    if [ "${AUTO_FIREWALL}" != "1" ]; then
        echo "ℹ️ AUTO_FIREWALL=0，跳过自动放行 TCP ${port}。请你在云防火墙和系统防火墙手动放行。"
        return 0
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "⚠️ 没有 iptables，跳过系统防火墙设置。请手动放行 TCP ${port}。"
        return 0
    fi

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

write_state_file() {
    cat > "${STATE_FILE}" <<EOF
DOMAIN='${DOMAIN}'
TLS_PORT='${TLS_PORT}'
XRAY_PORT='${XRAY_PORT}'
HTTP_PORT='${HTTP_PORT}'
UUID='${UUID}'
WSPATH='${WSPATH}'
ENABLE_AOP='${ENABLE_AOP}'
EOF

    chmod 600 "${STATE_FILE}"
}

load_state_if_exists() {
    if [ -f "${STATE_FILE}" ]; then
        # 只读取简单 key=value，不直接 source，避免状态文件被意外写入命令
        local old_uuid old_wspath
        old_uuid="$(grep -E "^UUID='" "${STATE_FILE}" 2>/dev/null | sed -E "s/^UUID='(.*)'$/\1/" || true)"
        old_wspath="$(grep -E "^WSPATH='" "${STATE_FILE}" 2>/dev/null | sed -E "s/^WSPATH='(.*)'$/\1/" || true)"

        if [ -z "${UUID:-}" ] && [ -n "${old_uuid}" ]; then
            UUID="${old_uuid}"
            echo "ℹ️ 复用上次 UUID：${UUID}"
        fi

        if [ -z "${WSPATH:-}" ] && [ -n "${old_wspath}" ]; then
            WSPATH="${old_wspath}"
            echo "ℹ️ 复用上次 WSPATH：${WSPATH}"
        fi
    fi
}

uninstall_self() {
    ask_value DOMAIN "${DEFAULT_DOMAIN}" "请输入要卸载配置对应的域名 DOMAIN"
    ask_value TLS_PORT "${DEFAULT_TLS_PORT}" "请输入要卸载配置对应的 TLS_PORT"

    DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
    TLS_PORT="${TLS_PORT:-$DEFAULT_TLS_PORT}"
    SAFE_DOMAIN="$(safe_name "${DOMAIN}")"

    NGINX_CONFIG="${BASE_NGINX_AVAILABLE}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    NGINX_LINK="${BASE_NGINX_ENABLED}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    CONFIG_DIR="${BASE_CONFIG_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    SSL_DIR="${BASE_SSL_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    LINK_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.txt"
    STATE_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.env"

    echo
    echo "将卸载本脚本创建的以下内容："
    echo "  systemd 服务：${SERVICE_NAME}"
    echo "  Nginx 配置：${NGINX_CONFIG}"
    echo "  Xray 配置目录：${CONFIG_DIR}"
    echo "  SSL 目录：${SSL_DIR}"
    echo "  链接文件：${LINK_FILE}"
    echo "  状态文件：${STATE_FILE}"
    echo

    if [ -t 0 ]; then
        read -r -p "确认卸载？输入 yes 继续: " confirm
        if [ "${confirm}" != "yes" ]; then
            echo "已取消。"
            exit 0
        fi
    fi

    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload

    rm -f "${NGINX_LINK}" "${NGINX_CONFIG}"
    rm -rf "${CONFIG_DIR}" "${SSL_DIR}"
    rm -f "${LINK_FILE}" "${STATE_FILE}"

    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx || true
    fi

    echo "✅ 已卸载本脚本创建的配置。原机其它服务未处理、未停止。"
}

main_install() {
    if [ "${EUID}" -ne 0 ]; then
        echo "❌ 请使用 root 用户运行。"
        echo "例如：sudo -i 后再执行脚本。"
        exit 1
    fi

    echo "=================================================="
    echo "VLESS + WSS + Cloudflare 安全增强版"
    echo "=================================================="
    echo "本脚本不会停止原机 hysteria-server / hy2 / xray。"
    echo "本脚本会创建独立服务：${SERVICE_NAME}"
    echo "=================================================="

    print_important_notes

    ask_value DOMAIN "${DEFAULT_DOMAIN}" "请输入域名 DOMAIN"
    ask_value TLS_PORT "${DEFAULT_TLS_PORT}" "请输入公网 TLS/WSS 端口 TLS_PORT"
    ask_value XRAY_PORT "${DEFAULT_XRAY_PORT}" "请输入 Xray 本地端口 XRAY_PORT"
    ask_value HTTP_PORT "${DEFAULT_HTTP_PORT}" "请输入 HTTP 占位端口 HTTP_PORT，填 0 表示不监听 HTTP"

    DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
    TLS_PORT="${TLS_PORT:-$DEFAULT_TLS_PORT}"
    XRAY_PORT="${XRAY_PORT:-$DEFAULT_XRAY_PORT}"
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"

    validate_domain "${DOMAIN}"
    validate_port "${TLS_PORT}" "TLS_PORT"
    validate_port "${XRAY_PORT}" "XRAY_PORT"
    validate_port "${HTTP_PORT}" "HTTP_PORT" "1"

    read -r -a CF_HTTPS_PORT_ARRAY <<< "${CF_HTTPS_PORTS}"
    read -r -a CF_HTTP_PORT_ARRAY <<< "${CF_HTTP_PORTS}"

    if [ "${CF_STRICT}" = "1" ] && ! contains_port "${TLS_PORT}" "${CF_HTTPS_PORT_ARRAY[@]}"; then
        print_cf_port_error "${TLS_PORT}"
        exit 1
    fi

    if [ "${CF_STRICT}" = "1" ] && [ "${HTTP_PORT}" != "0" ] && ! contains_port "${HTTP_PORT}" "${CF_HTTP_PORT_ARRAY[@]}"; then
        echo
        echo "⚠️ HTTP_PORT=${HTTP_PORT} 不是 Cloudflare 小黄云 HTTP 支持端口。"
        echo "HTTP 支持端口：${CF_HTTP_PORTS}"
        echo "HTTP_PORT 只是占位端口，不需要时建议 HTTP_PORT=0。"
        echo
    fi

    if [ "${TLS_PORT}" = "${XRAY_PORT}" ]; then
        echo "❌ TLS_PORT 和 XRAY_PORT 不能相同。"
        echo "   TLS_PORT 是公网端口，XRAY_PORT 是 127.0.0.1 本地端口。"
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

    SAFE_DOMAIN="$(safe_name "${DOMAIN}")"

    CONFIG_DIR="${BASE_CONFIG_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    XRAY_CONFIG="${CONFIG_DIR}/config.json"
    SSL_DIR="${BASE_SSL_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    SSL_CERT="${SSL_DIR}/origin.crt"
    SSL_KEY="${SSL_DIR}/origin.key"
    NGINX_CONFIG="${BASE_NGINX_AVAILABLE}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    NGINX_LINK="${BASE_NGINX_ENABLED}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    LINK_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.txt"
    STATE_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.env"

    load_state_if_exists

    UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
    WSPATH="${WSPATH:-/$(openssl rand -hex 8)}"

    validate_uuid "${UUID}"
    validate_wspath "${WSPATH}"

    echo
    echo "=================================================="
    echo "最终配置"
    echo "=================================================="
    echo "DOMAIN=${DOMAIN}"
    echo "TLS_PORT=${TLS_PORT}      # 客户端连接端口"
    echo "XRAY_PORT=${XRAY_PORT}    # 本机 127.0.0.1 端口，客户端不要填"
    echo "HTTP_PORT=${HTTP_PORT}    # 0 表示不监听 HTTP"
    echo "UUID=${UUID}"
    echo "WSPATH=${WSPATH}"
    echo "SERVICE=${SERVICE_NAME}"
    echo "ENABLE_AOP=${ENABLE_AOP}"
    echo "CF_STRICT=${CF_STRICT}"
    echo "AUTO_FIREWALL=${AUTO_FIREWALL}"
    echo "=================================================="

    echo
    echo "预检查端口占用..."
    port_used_by_non_nginx "${TLS_PORT}" "TLS_PORT" "1"
    port_used_by_non_nginx "${XRAY_PORT}" "XRAY_PORT" "0"

    if [ "${HTTP_PORT}" != "0" ]; then
        port_used_by_non_nginx "${HTTP_PORT}" "HTTP_PORT" "1"
    fi

    install_dependencies
    install_xray_if_needed

    mkdir -p "${CONFIG_DIR}" "${SSL_DIR}" /etc/cloudflare "${BASE_NGINX_AVAILABLE}" "${BASE_NGINX_ENABLED}"

    check_duplicate_nginx_domain "${DOMAIN}" "${TLS_PORT}" "${NGINX_CONFIG}"

    echo
    echo "放行系统防火墙端口..."
    if [ "${HTTP_PORT}" != "0" ]; then
        allow_tcp_port_before_reject "${HTTP_PORT}"
    fi
    allow_tcp_port_before_reject "${TLS_PORT}"

    if [ "${AUTO_FIREWALL}" = "1" ] && command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save || true
        systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    fi

    echo
    echo "写入 Xray 独立配置：${XRAY_CONFIG}"
    if [ -f "${XRAY_CONFIG}" ]; then
        cp -a "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "${XRAY_CONFIG}" <<EOF_XRAY
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

    echo
    echo "生成源站自签 TLS 证书：${SSL_CERT}"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "${SSL_KEY}" \
      -out "${SSL_CERT}" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=DNS:${DOMAIN}"

    chmod 600 "${SSL_KEY}"

    if [ "${ENABLE_AOP}" = "1" ]; then
        echo
        echo "下载 Cloudflare Authenticated Origin Pulls CA..."
        curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
          -o "${AOP_CA_FILE}"
    fi

    echo
    echo "写入独立 Nginx 站点：${NGINX_CONFIG}"
    if [ -f "${NGINX_CONFIG}" ]; then
        cp -a "${NGINX_CONFIG}" "${NGINX_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    {
    if [ "${HTTP_PORT}" != "0" ]; then
cat <<EOF_NGINX_HTTP
server {
    listen ${HTTP_PORT};
    server_name ${DOMAIN};

    # HTTP 只占位，不提供内容。
    return 444;
}

EOF_NGINX_HTTP
    fi

cat <<EOF_NGINX_HTTPS
server {
    listen ${TLS_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

EOF_NGINX_HTTPS

    if [ "${ENABLE_AOP}" = "1" ]; then
cat <<EOF_NGINX_AOP
    # 需要在 Cloudflare 后台开启 Authenticated Origin Pulls。
    ssl_client_certificate ${AOP_CA_FILE};
    ssl_verify_client on;
    ssl_verify_depth 1;

EOF_NGINX_AOP
    else
cat <<EOF_NGINX_NO_AOP
    # ENABLE_AOP=0：不校验 Cloudflare 客户端证书。
    # 如果你走小黄云，仍然建议开启 Authenticated Origin Pulls。
    ssl_verify_client off;

EOF_NGINX_NO_AOP
    fi

cat <<EOF_NGINX_PROXY
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
EOF_NGINX_PROXY
    } > "${NGINX_CONFIG}"

    ln -sf "${NGINX_CONFIG}" "${NGINX_LINK}"

    echo
    echo "写入 systemd 独立服务：${SERVICE_FILE}"
    cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=Xray CF WSS independent service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    echo
    echo "检查 nginx 配置..."
    nginx -t

    echo
    echo "启动 / 重载服务..."
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"

    # 不重启 nginx，优先 reload，减少对原站点影响
    systemctl enable --now nginx
    systemctl reload nginx

    write_state_file

    echo
    echo "生成客户端链接：${LINK_FILE}"
    python3 - <<EOF_PY | tee "${LINK_FILE}"
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
print("TLS_PORT:", tls_port, "(客户端填写这个端口)")
print("XRAY_PORT:", xray_port, "(本地端口，客户端不要填)")
print("HTTP_PORT:", http_port)
print("UUID:", uuid)
print("WSPATH:", path)
print("保存位置: ${LINK_FILE}")
print("状态文件: ${STATE_FILE}")
print("==================================================")
print("Cloudflare 小黄云 HTTPS/WSS 可用端口：443, 2053, 2083, 2087, 2096, 8443")
print("如果设置 TLS_PORT=20000，小黄云默认不会转发，会连接失败。")
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
    echo "服务状态："
    systemctl status "${SERVICE_NAME}" --no-pager -l | sed -n '1,20p'
    systemctl status nginx --no-pager -l | sed -n '1,15p'

    cat <<EOF_DONE

==================================================
✅ 安装完成

客户端链接：
  ${LINK_FILE}

状态文件：
  ${STATE_FILE}

Cloudflare 侧还需要确认：
1. DNS A 记录：${DOMAIN} -> 当前 VPS IP
2. DNS 代理状态：小黄云开启
3. SSL/TLS 模式：建议 Full
4. 如果 ENABLE_AOP=1：Cloudflare 后台必须开启 Authenticated Origin Pulls
5. 云厂商安全组：放行 TCP ${TLS_PORT}
6. 如果 HTTP_PORT=${HTTP_PORT} 且不是 0，也放行 TCP ${HTTP_PORT}

换新 VPS：
- 域名不变：Cloudflare A 记录改新 IP，然后在新 VPS 运行本脚本
- 想客户端不变：传入旧 UUID 和旧 WSPATH
- 换新域名：DOMAIN 改成新域名，Cloudflare 也添加新 DNS 记录

本脚本没有停止原机 hysteria-server / hy2 / xray。
本脚本自己的服务名是：${SERVICE_NAME}
==================================================

EOF_DONE
}

case "${ACTION}" in
    install)
        main_install
        ;;
    uninstall)
        uninstall_self
        ;;
    *)
        echo "❌ ACTION 只支持 install 或 uninstall，当前：${ACTION}"
        exit 1
        ;;
esac
