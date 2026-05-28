#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# CF VLESS + WSS + Nginx + Xray 交互向导版
# 目标：Debian 12 新 VPS，root 登录后直接运行，按提示操作。
# 原则：预检查先行。预检查没通过前，不写入服务、不写 Xray 配置、不写 Nginx 配置。
# ==========================================================

SERVICE_NAME="xray-cf-wss"
BASE_DIR="/usr/local/etc/${SERVICE_NAME}"
XRAY_CONFIG="${BASE_DIR}/config.json"
SYSTEMD_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
SSL_DIR="/etc/ssl/${SERVICE_NAME}"
CF_AOP_CERT="/etc/cloudflare/authenticated_origin_pull_ca.pem"
LINK_DIR="/root"

CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
CF_HTTP_PORTS="80 8080 8880 2052 2082 2086 2095"

# 默认值：新 VPS 优先 443；如果端口被占用，交互界面会自动推荐其它可用端口。
DEFAULT_XRAY_PORT="10000"
DEFAULT_HTTP_PORT="0"
DEFAULT_ENABLE_AOP="1"
DEFAULT_OPEN_FIREWALL="1"
DEFAULT_CF_STRICT="1"

ACTION="${ACTION:-}"
DOMAIN="${DOMAIN:-}"
TLS_PORT="${TLS_PORT:-}"
XRAY_PORT="${XRAY_PORT:-}"
HTTP_PORT="${HTTP_PORT:-}"
UUID="${UUID:-}"
WSPATH="${WSPATH:-}"
ENABLE_AOP="${ENABLE_AOP:-}"
OPEN_FIREWALL="${OPEN_FIREWALL:-}"
CF_STRICT="${CF_STRICT:-}"
ALLOW_DUPLICATE_DOMAIN="${ALLOW_DUPLICATE_DOMAIN:-0}"

CREATED_BY_FILE="${BASE_DIR}/created-by-this-script.txt"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }
line() { printf '%s\n' "============================================================"; }

err_trap() {
    local line_no="$1"
    echo
    red "❌ 脚本执行失败：第 ${line_no} 行附近出错。"
    echo "排查命令："
    echo "  nginx -t"
    echo "  journalctl -u nginx -u ${SERVICE_NAME} --no-pager -n 120"
    echo "  ss -lntup"
}
trap 'err_trap ${LINENO}' ERR

is_root() { [ "${EUID}" -eq 0 ]; }
is_tty() { [ -t 0 ]; }
is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$needle" = "$item" ] && return 0
    done
    return 1
}

sanitize_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

get_public_ip() {
    curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true
}

port_in_range() {
    local port="$1"
    is_number "$port" || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

tcp_owner() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp "sport = :${port}" 2>/dev/null || true
    else
        return 0
    fi
}

port_is_free() {
    local port="$1"
    [ -z "$(tcp_owner "$port")" ]
}

port_owner_is_nginx() {
    local port="$1"
    local used
    used="$(tcp_owner "$port")"
    [ -n "$used" ] && echo "$used" | grep -qi 'nginx'
}

port_owner_is_this_service() {
    local port="$1"
    local used
    used="$(tcp_owner "$port")"
    [ -n "$used" ] && echo "$used" | grep -qi "${SERVICE_NAME}\|xray"
}

first_free_cf_https_port() {
    local p
    for p in $CF_HTTPS_PORTS; do
        if port_is_free "$p" || port_owner_is_nginx "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "443"
}

first_free_local_port() {
    local p
    for p in 10000 10001 10002 10003 11000 12000 20000; do
        if port_is_free "$p" || port_owner_is_this_service "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "10000"
}

ask_text() {
    local var_name="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local current="${!var_name-}"

    [ -n "$current" ] && return 0

    if is_tty; then
        local input=""
        if [ -n "$default_value" ]; then
            read -r -p "${prompt} [默认: ${default_value}]: " input || input=""
            printf -v "$var_name" '%s' "${input:-$default_value}"
        else
            read -r -p "${prompt}: " input || input=""
            printf -v "$var_name" '%s' "$input"
        fi
    else
        printf -v "$var_name" '%s' "$default_value"
    fi
    export "$var_name"
}

ask_yes_no() {
    local var_name="$1"
    local prompt="$2"
    local default_value="$3" # 1 yes, 0 no
    local current="${!var_name-}"
    [ -n "$current" ] && return 0

    local hint="Y/n"
    [ "$default_value" = "0" ] && hint="y/N"

    if is_tty; then
        local input=""
        read -r -p "${prompt} [${hint}]: " input || input=""
        input="${input:-}"
        case "$input" in
            y|Y|yes|YES|Yes) printf -v "$var_name" '1' ;;
            n|N|no|NO|No) printf -v "$var_name" '0' ;;
            *) printf -v "$var_name" '%s' "$default_value" ;;
        esac
    else
        printf -v "$var_name" '%s' "$default_value"
    fi
    export "$var_name"
}

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    fi
}

generate_wspath() {
    if command -v openssl >/dev/null 2>&1; then
        echo "/$(openssl rand -hex 8)"
    else
        echo "/$(date +%s%N | sha256sum | cut -c1-16)"
    fi
}

validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        red "❌ DOMAIN 不能为空。"
        return 1
    fi
    if echo "$domain" | grep -qE '[[:space:]/:]'; then
        red "❌ DOMAIN 不要带 http://、https://、斜杠、空格或端口。"
        echo "正确示例：cf1.example.com"
        return 1
    fi
    if ! echo "$domain" | grep -qE '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
        red "❌ DOMAIN 看起来不像完整域名。"
        echo "正确示例：cf1.example.com"
        return 1
    fi
}

validate_wspath() {
    local path="$1"
    if [ -z "$path" ]; then
        red "❌ WSPATH 不能为空。"
        return 1
    fi
    if [[ "$path" != /* ]]; then
        red "❌ WSPATH 必须以 / 开头，例如 /abc123。"
        return 1
    fi
    if echo "$path" | grep -qE '[[:space:]]'; then
        red "❌ WSPATH 不能包含空格。"
        return 1
    fi
}

validate_uuid_basic() {
    local id="$1"
    if ! echo "$id" | grep -qE '^[0-9a-fA-F-]{32,36}$'; then
        red "❌ UUID 格式看起来不对。"
        echo "正确示例：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        return 1
    fi
}

nginx_listen_ports_from_config() {
    command -v nginx >/dev/null 2>&1 || return 0
    nginx -T 2>/dev/null \
        | sed 's/#.*//' \
        | awk '
            /^[[:space:]]*listen[[:space:]]+/ {
                for (i=2; i<=NF; i++) {
                    gsub(";", "", $i)
                    if ($i ~ /^[0-9]+$/) print $i
                    if ($i ~ /^\[::\]:[0-9]+$/) { sub(/^\[::\]:/, "", $i); print $i }
                    if ($i ~ /^[0-9.]+:[0-9]+$/) { sub(/^.*:/, "", $i); print $i }
                }
            }
        ' | sort -n | uniq
}

nginx_has_domain() {
    local domain="$1"
    command -v nginx >/dev/null 2>&1 || return 1
    nginx -T 2>/dev/null | sed 's/#.*//' | grep -Eq "server_name[[:space:]].*(^|[[:space:]])${domain}([[:space:];]|$)"
}

show_current_ports() {
    line
    blue "当前常见端口占用："
    if command -v ss >/dev/null 2>&1; then
        ss -lntup | grep -E ':(80|443|2053|2083|2087|2096|8443|10000|10001|10002)\b' || echo "未发现常见端口占用。"
    else
        yellow "未找到 ss 命令，暂时无法显示端口占用。安装阶段会安装 iproute2。"
    fi
}

print_cloudflare_tips() {
    cat <<EOF_TIPS

Cloudflare 小黄云 HTTPS/WSS 可用端口：
  ${CF_HTTPS_PORTS}

不能乱填的端口示例：
  20000 / 10000 / 12345 / 5000 / 8081 / 8444
原因：Cloudflare 小黄云默认不会转发这些 HTTPS/WSS 端口。

如果 443 被 Caddy、Nginx、Apache 占用：
  推荐 TLS_PORT=2053，HTTP_PORT=0

客户端里要填的是 TLS_PORT，不是 XRAY_PORT。
XRAY_PORT 只给服务器本机 Nginx 转发使用。
EOF_TIPS
}

collect_inputs_interactive() {
    line
    blue "CF VLESS + WSS 一键向导"
    echo "适合：Debian 12 新 VPS，root 用户，Cloudflare 小黄云。"
    echo "你只需要按提示输入，不需要懂代码。"
    line
    show_current_ports
    print_cloudflare_tips
    line

    if [ -z "$ACTION" ]; then
        echo "请选择操作："
        echo "  1) 只预检查，不写入任何配置"
        echo "  2) 正式安装：先预检查，通过后再写入配置"
        echo "  3) 卸载本脚本创建的 CF 节点配置"
        echo "  0) 退出"
        local choice=""
        if is_tty; then
            read -r -p "请输入数字 [默认: 1]: " choice || choice=""
        fi
        choice="${choice:-1}"
        case "$choice" in
            1) ACTION="precheck" ;;
            2) ACTION="install" ;;
            3) ACTION="uninstall" ;;
            0) echo "已退出。"; exit 0 ;;
            *) red "❌ 选择无效。"; exit 1 ;;
        esac
        export ACTION
    fi

    if [ "$ACTION" = "uninstall" ]; then
        return 0
    fi

    local suggest_tls suggest_xray
    suggest_tls="$(first_free_cf_https_port)"
    suggest_xray="$(first_free_local_port)"

    echo
    blue "请填写节点信息："
    ask_text DOMAIN "请输入节点域名 DOMAIN，不要带 https://，例如 cf1.example.com" ""
    ask_text TLS_PORT "请输入公网 TLS/WSS 端口 TLS_PORT" "$suggest_tls"
    ask_text XRAY_PORT "请输入 Xray 本地端口 XRAY_PORT，客户端不要填这个" "${suggest_xray:-$DEFAULT_XRAY_PORT}"
    ask_text HTTP_PORT "请输入 HTTP 占位端口 HTTP_PORT，建议填 0 表示不监听 HTTP" "$DEFAULT_HTTP_PORT"

    ask_text UUID "请输入 UUID；留空自动生成。换 VPS 想保持客户端不变时，填旧 UUID" ""
    [ -z "$UUID" ] && UUID="$(generate_uuid)" && export UUID

    ask_text WSPATH "请输入 WebSocket 路径 WSPATH；留空自动生成。换 VPS 想保持客户端不变时，填旧路径" ""
    [ -z "$WSPATH" ] && WSPATH="$(generate_wspath)" && export WSPATH

    ask_yes_no ENABLE_AOP "是否启用 Cloudflare Authenticated Origin Pulls 源站校验？推荐开启" "$DEFAULT_ENABLE_AOP"
    ask_yes_no OPEN_FIREWALL "是否尝试自动放行需要的 TCP 端口？推荐开启" "$DEFAULT_OPEN_FIREWALL"
    ask_yes_no CF_STRICT "是否强制检查 Cloudflare 小黄云端口？推荐开启" "$DEFAULT_CF_STRICT"

    line
    blue "你填写的最终配置："
    echo "操作 ACTION       = ${ACTION}"
    echo "域名 DOMAIN       = ${DOMAIN}"
    echo "公网端口 TLS_PORT = ${TLS_PORT}"
    echo "本地端口 XRAY_PORT= ${XRAY_PORT}"
    echo "HTTP_PORT         = ${HTTP_PORT}"
    echo "UUID              = ${UUID}"
    echo "WSPATH            = ${WSPATH}"
    echo "AOP 源站校验      = ${ENABLE_AOP}"
    echo "自动放行防火墙    = ${OPEN_FIREWALL}"
    echo "Cloudflare端口校验= ${CF_STRICT}"
    line

    if [ "$ACTION" = "install" ] && is_tty; then
        local ok=""
        read -r -p "确认正式安装？预检查通过后才会写入配置 [y/N]: " ok || ok=""
        case "$ok" in
            y|Y|yes|YES|Yes) ;;
            *) echo "已取消安装。"; exit 0 ;;
        esac
    fi
}

precheck() {
    local errors=0
    line
    blue "开始预检查：预检查失败不会写入任何配置。"

    if ! is_root; then
        red "❌ 请使用 root 用户运行。Debian 12 新 VPS 登录 root 后直接运行即可。"
        errors=$((errors+1))
    fi

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "系统：${PRETTY_NAME:-unknown}"
        if [ "${ID:-}" != "debian" ]; then
            yellow "⚠️ 当前不是 Debian。脚本主要按 Debian 12 设计，Ubuntu 通常也能用，但不保证。"
        elif [ "${VERSION_ID:-}" != "12" ]; then
            yellow "⚠️ 当前 Debian 版本不是 12。脚本主要按 Debian 12 设计。"
        fi
    fi

    validate_domain "$DOMAIN" || errors=$((errors+1))

    if ! port_in_range "$TLS_PORT"; then
        red "❌ TLS_PORT 必须是 1-65535 的数字。当前：${TLS_PORT}"
        errors=$((errors+1))
    fi
    if ! port_in_range "$XRAY_PORT"; then
        red "❌ XRAY_PORT 必须是 1-65535 的数字。当前：${XRAY_PORT}"
        errors=$((errors+1))
    fi
    if [ "$HTTP_PORT" != "0" ] && ! port_in_range "$HTTP_PORT"; then
        red "❌ HTTP_PORT 必须是 0 或 1-65535 的数字。当前：${HTTP_PORT}"
        errors=$((errors+1))
    fi

    if [ "$CF_STRICT" = "1" ] && port_in_range "$TLS_PORT"; then
        # shellcheck disable=SC2086
        if ! in_list "$TLS_PORT" $CF_HTTPS_PORTS; then
            red "❌ TLS_PORT=${TLS_PORT} 不是 Cloudflare 小黄云 HTTPS/WSS 支持端口。"
            echo "可用端口：${CF_HTTPS_PORTS}"
            echo "例如：443 被占用时，请填 2053。"
            errors=$((errors+1))
        fi
    fi

    if [ "$TLS_PORT" = "$XRAY_PORT" ]; then
        red "❌ TLS_PORT 和 XRAY_PORT 不能相同。"
        errors=$((errors+1))
    fi
    if [ "$HTTP_PORT" != "0" ] && [ "$HTTP_PORT" = "$TLS_PORT" ]; then
        red "❌ HTTP_PORT 和 TLS_PORT 不能相同。"
        errors=$((errors+1))
    fi
    if [ "$HTTP_PORT" != "0" ] && [ "$HTTP_PORT" = "$XRAY_PORT" ]; then
        red "❌ HTTP_PORT 和 XRAY_PORT 不能相同。"
        errors=$((errors+1))
    fi

    validate_uuid_basic "$UUID" || errors=$((errors+1))
    validate_wspath "$WSPATH" || errors=$((errors+1))

    if command -v ss >/dev/null 2>&1; then
        local used
        used="$(tcp_owner "$TLS_PORT")"
        if [ -n "$used" ] && ! echo "$used" | grep -qi 'nginx'; then
            red "❌ TLS_PORT=${TLS_PORT} 已被非 Nginx 服务占用，不能继续。"
            echo "$used"
            echo "处理办法：不停止原服务时，请换 Cloudflare 支持端口，例如 2053。"
            errors=$((errors+1))
        fi

        used="$(tcp_owner "$XRAY_PORT")"
        if [ -n "$used" ] && ! echo "$used" | grep -qi "${SERVICE_NAME}\|xray"; then
            red "❌ XRAY_PORT=${XRAY_PORT} 已被其它服务占用。"
            echo "$used"
            echo "处理办法：换一个本地端口，例如 10001。"
            errors=$((errors+1))
        fi

        if [ "$HTTP_PORT" != "0" ]; then
            used="$(tcp_owner "$HTTP_PORT")"
            if [ -n "$used" ] && ! echo "$used" | grep -qi 'nginx'; then
                red "❌ HTTP_PORT=${HTTP_PORT} 已被非 Nginx 服务占用。"
                echo "$used"
                echo "处理办法：建议 HTTP_PORT=0。"
                errors=$((errors+1))
            fi
        fi
    else
        yellow "⚠️ 未找到 ss，跳过端口占用预检查。"
    fi

    if command -v nginx >/dev/null 2>&1; then
        if ! nginx -t >/tmp/${SERVICE_NAME}-nginx-test.log 2>&1; then
            red "❌ 当前系统已有 Nginx，但 nginx -t 不通过。"
            cat /tmp/${SERVICE_NAME}-nginx-test.log
            errors=$((errors+1))
        else
            green "✅ 当前 Nginx 配置语法通过。"
        fi

        if [ "$ALLOW_DUPLICATE_DOMAIN" != "1" ] && nginx_has_domain "$DOMAIN"; then
            red "❌ 当前 Nginx 配置里已经存在 server_name ${DOMAIN}。"
            echo "为避免抢占原网站，请换一个新子域名，或确认后使用 ALLOW_DUPLICATE_DOMAIN=1。"
            errors=$((errors+1))
        fi

        local p used
        while read -r p; do
            [ -z "$p" ] && continue
            used="$(tcp_owner "$p")"
            if [ -n "$used" ] && ! echo "$used" | grep -qi 'nginx'; then
                red "❌ Nginx 已启用配置里存在 listen ${p}，但该端口被非 Nginx 服务占用。"
                echo "$used"
                echo "这会导致 systemctl start nginx 失败。"
                echo "常见例子：/etc/nginx/sites-enabled/default 监听 80，但 80 被 Caddy 占用。"
                echo "处理办法：先移走冲突的 Nginx 默认站点，或停用占用端口的服务。"
                errors=$((errors+1))
            fi
        done < <(nginx_listen_ports_from_config)
    else
        yellow "ℹ️ 当前未安装 Nginx。正式安装时会安装 Nginx。"
    fi

    if [ "$errors" -eq 0 ]; then
        green "✅ 预检查通过。现在正式安装才会开始写入配置。"
        return 0
    else
        red "❌ 预检查未通过，共发现 ${errors} 个问题。没有写入任何配置。"
        return 1
    fi
}

install_xray_if_needed() {
    if command -v xray >/dev/null 2>&1; then
        green "✅ 已检测到 xray：$(command -v xray)"
        return 0
    fi

    yellow "未检测到 xray，开始安装 Xray 核心。"
    echo "说明：这是正式安装阶段，预检查已经通过，现在才会写入系统。"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if command -v xray >/dev/null 2>&1; then
        green "✅ Xray 安装完成。"
    else
        red "❌ Xray 安装后仍找不到 xray 命令。"
        exit 1
    fi
}

open_firewall_ports() {
    [ "$OPEN_FIREWALL" = "1" ] || return 0

    yellow "尝试自动放行 TCP 端口：${TLS_PORT}${HTTP_PORT:+ 和 ${HTTP_PORT}}"

    if command -v iptables >/dev/null 2>&1; then
        allow_one() {
            local port="$1"
            [ "$port" = "0" ] && return 0
            while iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT || true
            done
            local reject_line
            reject_line="$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"
            if [ -n "$reject_line" ]; then
                iptables -I INPUT "$reject_line" -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
            else
                iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
            fi
            echo "已放行 TCP ${port}"
        }
        allow_one "$TLS_PORT"
        if [ "$HTTP_PORT" != "0" ]; then
            allow_one "$HTTP_PORT"
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save || true
            systemctl enable netfilter-persistent >/dev/null 2>&1 || true
        fi
    else
        yellow "⚠️ 未找到 iptables，跳过自动防火墙放行。请在云厂商安全组放行 TCP ${TLS_PORT}。"
    fi
}

write_configs_and_start() {
    local safe_domain safe_id nginx_conf nginx_link cert key link_file env_file
    safe_domain="$(sanitize_name "$DOMAIN")"
    safe_id="${safe_domain}-${TLS_PORT}"
    nginx_conf="${NGINX_AVAILABLE_DIR}/${SERVICE_NAME}-${safe_id}.conf"
    nginx_link="${NGINX_ENABLED_DIR}/${SERVICE_NAME}-${safe_id}.conf"
    cert="${SSL_DIR}/${safe_id}.crt"
    key="${SSL_DIR}/${safe_id}.key"
    link_file="${LINK_DIR}/cf-wss-vless-${safe_id}.txt"
    env_file="${LINK_DIR}/cf-wss-vless-${safe_id}.env"

    mkdir -p "$BASE_DIR" "$SSL_DIR" /etc/cloudflare "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR"

    cat > "$XRAY_CONFIG" <<EOF_XRAY
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ws-local",
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "email": "cf-wss" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WSPATH}" }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF_XRAY

    if xray run -test -config "$XRAY_CONFIG" >/tmp/${SERVICE_NAME}-xray-test.log 2>&1; then
        green "✅ Xray 配置测试通过。"
    else
        red "❌ Xray 配置测试失败："
        cat /tmp/${SERVICE_NAME}-xray-test.log
        exit 1
    fi

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$key" \
      -out "$cert" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=DNS:${DOMAIN}"
    chmod 600 "$key"

    if [ "$ENABLE_AOP" = "1" ]; then
        curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
          -o "$CF_AOP_CERT"
    fi

    {
        if [ "$HTTP_PORT" != "0" ]; then
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

    ssl_certificate ${cert};
    ssl_certificate_key ${key};

EOF_NGINX_HTTPS

        if [ "$ENABLE_AOP" = "1" ]; then
            cat <<EOF_NGINX_AOP
    ssl_client_certificate ${CF_AOP_CERT};
    ssl_verify_client on;
    ssl_verify_depth 1;

EOF_NGINX_AOP
        else
            cat <<EOF_NGINX_NOAOP
    # 未启用 Authenticated Origin Pulls。
    # 若要只允许 Cloudflare 回源访问，建议重新运行并开启 AOP。

EOF_NGINX_NOAOP
        fi

        cat <<EOF_NGINX_REST
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
EOF_NGINX_REST
    } > "$nginx_conf"

    ln -sf "$nginx_conf" "$nginx_link"

    # Debian 新装 Nginx 可能自带 default 站点。若 HTTP_PORT=0，本脚本不需要 80，禁用 default 可减少冲突。
    if [ -L /etc/nginx/sites-enabled/default ]; then
        mkdir -p /root/nginx-disabled-backup
        mv /etc/nginx/sites-enabled/default "/root/nginx-disabled-backup/default.$(date +%F-%H%M%S)"
        yellow "已备份并禁用 Nginx 默认站点软链接，避免占用 80。"
    fi

    nginx -t

    cat > "$SYSTEMD_SERVICE" <<EOF_SERVICE
[Unit]
Description=Xray CF WSS Independent Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$(command -v xray) run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    cat > "$CREATED_BY_FILE" <<EOF_CREATED
Created by cfduankou wizard script.
DOMAIN=${DOMAIN}
TLS_PORT=${TLS_PORT}
XRAY_PORT=${XRAY_PORT}
HTTP_PORT=${HTTP_PORT}
NGINX_CONF=${nginx_conf}
SYSTEMD_SERVICE=${SYSTEMD_SERVICE}
EOF_CREATED

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi

    python3 - <<EOF_PY | tee "$link_file"
import urllib.parse

domain = "${DOMAIN}"
uuid = "${UUID}"
path = "${WSPATH}"
port = "${TLS_PORT}"
print("==================================================")
print("VLESS + WSS + Cloudflare 链接：")
print(f"vless://{uuid}@{domain}:{port}?encryption=none&security=tls&sni={domain}&type=ws&host={domain}&path={urllib.parse.quote(path, safe='')}#cf-wss-{domain}-{port}")
print("==================================================")
print("DOMAIN:", domain)
print("TLS_PORT:", port)
print("XRAY_PORT:", "${XRAY_PORT}")
print("HTTP_PORT:", "${HTTP_PORT}")
print("UUID:", uuid)
print("WSPATH:", path)
print("保存位置:", "${link_file}")
EOF_PY

    cat > "$env_file" <<EOF_ENV
DOMAIN='${DOMAIN}'
TLS_PORT='${TLS_PORT}'
XRAY_PORT='${XRAY_PORT}'
HTTP_PORT='${HTTP_PORT}'
UUID='${UUID}'
WSPATH='${WSPATH}'
EOF_ENV
    chmod 600 "$env_file"

    line
    green "✅ 安装完成。"
    echo "链接文件：${link_file}"
    echo "参数备份：${env_file}"
    echo
    echo "检查命令："
    echo "  systemctl status ${SERVICE_NAME} --no-pager -l"
    echo "  systemctl status nginx --no-pager -l"
    echo "  ss -lntup | grep -E ':(${TLS_PORT}|${XRAY_PORT})\\b'"
    line
}

install_now() {
    precheck

    line
    blue "开始正式安装。预检查已通过，现在才会写入系统。"

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip openssl nginx ca-certificates python3 iproute2 iptables netfilter-persistent

    install_xray_if_needed
    open_firewall_ports
    write_configs_and_start
}

uninstall_now() {
    line
    yellow "将只卸载本脚本创建的 ${SERVICE_NAME} 相关配置，不会删除 Caddy/Jellyfin/SimpleCloud/Hysteria。"
    if is_tty; then
        local ok=""
        read -r -p "确认卸载？[y/N]: " ok || ok=""
        case "$ok" in y|Y|yes|YES|Yes) ;; *) echo "已取消。"; exit 0 ;; esac
    fi

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

    rm -f /etc/nginx/sites-enabled/${SERVICE_NAME}-*.conf
    rm -f /etc/nginx/sites-available/${SERVICE_NAME}-*.conf

    if command -v nginx >/dev/null 2>&1; then
        nginx -t && { systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true; }
    fi

    rm -rf "$BASE_DIR" "$SSL_DIR"
    green "✅ 已卸载本脚本创建的 CF 节点配置。"
}

main() {
    collect_inputs_interactive

    case "$ACTION" in
        precheck|PRECHECK_ONLY|check)
            precheck
            ;;
        install|"")
            install_now
            ;;
        uninstall|remove)
            uninstall_now
            ;;
        *)
            red "❌ 未知 ACTION：${ACTION}"
            exit 1
            ;;
    esac
}

main "$@"
