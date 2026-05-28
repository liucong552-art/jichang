#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# VLESS + WSS + Cloudflare 预检优先 / 尽量无垃圾版
#
# 目标：
#   1. 不停止、不禁用原机 hysteria-server / hy2 / xray / caddy 等服务
#   2. 写入任何持久配置前，先完整预检查
#   3. 预检查失败时不写 service、不写 Xray 配置、不写 Nginx 配置
#   4. 写入阶段如果失败，尽量回滚本脚本改动
#   5. 支持 PRECHECK_ONLY=1 只检查不安装
#
# 推荐先只检查：
#   DOMAIN="node.example.com" TLS_PORT=2053 XRAY_PORT=10000 HTTP_PORT=0 PRECHECK_ONLY=1 bash cfduankou-preflight-clean.sh
#
# 检查通过后安装：
#   DOMAIN="node.example.com" TLS_PORT=2053 XRAY_PORT=10000 HTTP_PORT=0 bash cfduankou-preflight-clean.sh
#
# 卸载本脚本创建的配置：
#   ACTION=uninstall DOMAIN="node.example.com" TLS_PORT=2053 bash cfduankou-preflight-clean.sh
# ==========================================================

trap 'on_error ${LINENO}' ERR

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

ACTION="${ACTION:-install}"                 # install / uninstall
PRECHECK_ONLY="${PRECHECK_ONLY:-0}"         # 1=只预检查，不写任何持久文件
CF_STRICT="${CF_STRICT:-1}"                 # 1=强制 Cloudflare 小黄云 HTTPS 端口校验
ENABLE_AOP="${ENABLE_AOP:-1}"               # 1=启用 Authenticated Origin Pulls
AUTO_FIREWALL="${AUTO_FIREWALL:-0}"         # 默认 0，避免失败后留下防火墙规则；需要自动放行可设 1
ALLOW_DUPLICATE_DOMAIN="${ALLOW_DUPLICATE_DOMAIN:-0}"
ALLOW_NGINX_DEFAULT_CONFLICT="${ALLOW_NGINX_DEFAULT_CONFLICT:-0}" # 不建议开。1=忽略已有 Nginx listen 端口被其它服务占用
NO_GARBAGE_MODE="${NO_GARBAGE_MODE:-1}"     # 1=缺依赖直接退出，不自动 apt 安装
INSTALL_XRAY_IF_MISSING="${INSTALL_XRAY_IF_MISSING:-0}" # 默认 0，避免安装器产生额外默认 xray 服务

ROLLBACK_ACTIVE=0
ROLLBACK_DIR=""
ROLLBACK_MANIFEST=""
WAS_SERVICE_ACTIVE=0
WAS_NGINX_ACTIVE=0
XRAY_BIN=""

say() { printf '%s\n' "$*"; }

on_error() {
    local line="${1:-unknown}"
    echo
    echo "❌ 脚本执行失败：第 ${line} 行附近出错。"
    if [ "${ROLLBACK_ACTIVE}" = "1" ]; then
        rollback_changes || true
    fi
    echo
    echo "排查建议："
    echo "  1) nginx -t"
    echo "  2) journalctl -u nginx -u ${SERVICE_NAME} --no-pager -n 120"
    echo "  3) ss -lntup"
    exit 1
}

ask_value() {
    local var_name="$1"
    local default_value="$2"
    local prompt_text="$3"
    local current_value="${!var_name-}"

    if [ -n "${current_value}" ]; then
        return 0
    fi

    if [ -t 0 ]; then
        local input_value=""
        read -r -p "${prompt_text} [默认: ${default_value}]: " input_value || input_value=""
        printf -v "${var_name}" "%s" "${input_value:-$default_value}"
    else
        printf -v "${var_name}" "%s" "${default_value}"
    fi

    export "${var_name}"
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

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
        echo "如果你确认无误，可以继续；否则请改成类似 node.example.com。"
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

safe_name() {
    echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
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

print_cf_port_error() {
    local port="$1"
    cat <<EOF

❌ TLS_PORT=${port} 不是 Cloudflare 小黄云 HTTPS/WSS 支持端口。

小黄云 TLS/WSS 只能选：
  ${CF_HTTPS_PORTS}

不能乱改成：
  80 8080 8880 2052 2082 2086 2095：这些是 HTTP 端口，不是 HTTPS/WSS 端口
  10000 10010 12345 20000 5000 8081 8444：小黄云默认不转发

如果你是灰云直连，才可以这样跳过检查：
  CF_STRICT=0 TLS_PORT=${port} bash $0

EOF
}

print_important_notes() {
    cat <<EOF

==================================================
哪些参数不要乱改
==================================================
DOMAIN：必须是纯域名，不要带 https://、端口或路径。
TLS_PORT：客户端连接的公网 TLS/WSS 端口；小黄云只能用：${CF_HTTPS_PORTS}
XRAY_PORT：Xray 本机端口，只监听 127.0.0.1；客户端不要填这个端口。
HTTP_PORT：HTTP 占位端口；有 Caddy/宝塔/其它站点时建议设为 0。
UUID：改了客户端也要改；换 VPS 想客户端不变，就传旧 UUID。
WSPATH：改了客户端也要改；必须以 / 开头，不建议用 /。
ENABLE_AOP=1：Cloudflare 后台必须开启 Authenticated Origin Pulls。
AUTO_FIREWALL：默认 0，不自动写防火墙，避免失败后留下规则。
PRECHECK_ONLY=1：只检查，不创建目录、不写配置、不启用服务。
==================================================

EOF
}

need_command() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        MISSING_COMMANDS+=("${cmd}:${pkg}")
    fi
}

check_required_commands_no_write() {
    MISSING_COMMANDS=()
    need_command awk awk
    need_command sed sed
    need_command grep grep
    need_command ss iproute2
    need_command openssl openssl
    need_command python3 python3
    need_command systemctl systemd
    need_command nginx nginx

    if [ "${ENABLE_AOP}" = "1" ]; then
        need_command curl curl
    fi

    if [ "${AUTO_FIREWALL}" = "1" ]; then
        need_command iptables iptables
    fi

    if [ "${#MISSING_COMMANDS[@]}" -gt 0 ]; then
        echo
        echo "❌ 预检查失败：缺少必要命令。为了避免产生垃圾，本脚本默认不会自动 apt 安装。"
        echo
        echo "缺少："
        local item
        for item in "${MISSING_COMMANDS[@]}"; do
            echo "  - ${item%%:*}  建议安装包：${item##*:}"
        done
        echo
        echo "你可以手动安装后重跑，例如："
        echo "  apt update && apt install -y nginx iproute2 openssl python3 curl"
        echo
        exit 1
    fi
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

check_xray_no_write() {
    if XRAY_BIN="$(get_xray_bin 2>/dev/null)"; then
        return 0
    fi

    if [ "${INSTALL_XRAY_IF_MISSING}" = "1" ] && [ "${NO_GARBAGE_MODE}" != "1" ]; then
        echo "⚠️ 预检查：未发现 xray，但你允许后续自动安装。"
        return 0
    fi

    echo
    echo "❌ 预检查失败：未发现 xray 二进制。"
    echo "为了避免产生额外默认服务/配置，当前默认不自动安装 Xray。"
    echo
    echo "建议先手动安装 Xray，或你确认可以接受安装器产生改动时再运行："
    echo "  NO_GARBAGE_MODE=0 INSTALL_XRAY_IF_MISSING=1 DOMAIN=... TLS_PORT=... XRAY_PORT=... HTTP_PORT=0 bash $0"
    echo
    exit 1
}

get_tcp_owner() {
    local port="$1"
    ss -H -lntp "sport = :${port}" 2>/dev/null || true
}

fail_if_port_used_by_non_nginx() {
    local port="$1"
    local name="$2"
    local allow_nginx="${3:-0}"
    local used

    used="$(get_tcp_owner "${port}")"
    if [ -z "${used}" ]; then
        echo "✅ ${name}=${port} 当前未被 TCP 服务占用。"
        return 0
    fi

    if [ "${allow_nginx}" = "1" ] && echo "${used}" | grep -qi 'nginx'; then
        echo "✅ ${name}=${port} 当前由 Nginx 监听，可共用同一个 Nginx 端口。"
        return 0
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && echo "${used}" | grep -qi 'xray'; then
        echo "✅ ${name}=${port} 当前可能由本脚本服务 ${SERVICE_NAME} 使用，允许升级/重跑。"
        return 0
    fi

    echo
    echo "❌ 预检查失败：${name}=${port} 已被其它服务占用。"
    echo "占用信息："
    echo "${used}"
    echo
    echo "处理建议："
    echo "  - 不想停止原服务：换本脚本端口。"
    echo "  - 如果冲突的是 TLS_PORT：可换 ${CF_HTTPS_PORTS} 中未占用的端口，比如 2053。"
    echo "  - 如果冲突的是 XRAY_PORT：换成本机端口，比如 20000 / 30000。"
    echo "  - 如果冲突的是 HTTP_PORT=80：设置 HTTP_PORT=0。"
    echo
    exit 1
}

get_nginx_enabled_listen_ports() {
    nginx -T 2>/dev/null \
        | sed 's/#.*//' \
        | awk '
            /^[[:space:]]*listen[[:space:]]+/ {
                line=$0
                sub(/^[[:space:]]*listen[[:space:]]+/, "", line)
                gsub(";", "", line)
                split(line, a, /[[:space:]]+/)
                token=a[1]
                if (token ~ /^[0-9]+$/) {
                    print token
                } else if (token ~ /^\[::\]:[0-9]+$/) {
                    sub(/^\[::\]:/, "", token)
                    print token
                } else if (token ~ /^[0-9.]+:[0-9]+$/) {
                    sub(/^.*:/, "", token)
                    print token
                } else if (token ~ /^\*:[0-9]+$/) {
                    sub(/^\*:/, "", token)
                    print token
                }
            }
        ' | sort -n | uniq
}

preflight_nginx_current_config() {
    echo
    echo "预检查：Nginx 当前配置..."

    if ! nginx -t >/tmp/cf-wss-nginx-test.log 2>&1; then
        echo "❌ 预检查失败：当前 Nginx 配置本身就不通过 nginx -t。"
        cat /tmp/cf-wss-nginx-test.log
        rm -f /tmp/cf-wss-nginx-test.log
        exit 1
    fi
    rm -f /tmp/cf-wss-nginx-test.log
    echo "✅ 当前 Nginx 配置语法正常。"

    if [ "${ALLOW_NGINX_DEFAULT_CONFLICT}" = "1" ]; then
        echo "⚠️ ALLOW_NGINX_DEFAULT_CONFLICT=1，跳过 Nginx 已启用 listen 端口冲突扫描。"
        return 0
    fi

    echo "预检查：扫描当前 Nginx 已启用配置中的 listen 端口..."
    local port used bad=0
    while read -r port; do
        [ -z "${port}" ] && continue
        used="$(get_tcp_owner "${port}")"
        if [ -n "${used}" ] && ! echo "${used}" | grep -qi 'nginx'; then
            echo
            echo "❌ 预检查失败：当前 Nginx 配置里存在 listen ${port}，但该端口已被非 Nginx 服务占用。"
            echo "占用信息："
            echo "${used}"
            echo
            echo "这会导致 systemctl start nginx 失败，即使本脚本自己没有监听该端口。"
            echo
            echo "常见处理："
            echo "  1) 如果是默认站点监听 80，可先备份式禁用："
            echo "     mkdir -p /root/nginx-disabled-backup"
            echo "     mv /etc/nginx/sites-enabled/default /root/nginx-disabled-backup/default.\$(date +%F-%H%M%S)"
            echo
            echo "  2) 如果 80/443 被 Caddy 占用，且你不想停 Caddy："
            echo "     使用 TLS_PORT=2053 HTTP_PORT=0"
            echo
            bad=1
        fi
    done < <(get_nginx_enabled_listen_ports)

    if [ "${bad}" = "1" ]; then
        exit 1
    fi

    echo "✅ 当前 Nginx 已启用 listen 端口未发现非 Nginx 占用冲突。"
}

check_duplicate_nginx_domain() {
    local domain="$1"
    local self_conf="$2"

    if [ "${ALLOW_DUPLICATE_DOMAIN}" = "1" ]; then
        echo "⚠️ ALLOW_DUPLICATE_DOMAIN=1，跳过重复 server_name 拦截。"
        return 0
    fi

    local matches
    matches="$(grep -RIlE "server_name[[:space:]]+([^;[:space:]]+[[:space:]]+)*${domain}([[:space:];]|$)" \
        /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
        | grep -vF "${self_conf}" || true)"

    if [ -n "${matches}" ]; then
        echo
        echo "❌ 预检查失败：Nginx 里已经存在相同域名配置：${domain}"
        echo "${matches}"
        echo
        echo "为避免抢占原站点，本脚本不继续写入。"
        echo "处理方法："
        echo "  1) 换一个新的子域名，例如 node2.example.com"
        echo "  2) 或确认要共存后使用：ALLOW_DUPLICATE_DOMAIN=1"
        echo
        exit 1
    fi

    echo "✅ 未发现重复 server_name：${domain}"
}

load_state_if_exists() {
    if [ -f "${STATE_FILE}" ]; then
        echo "检测到旧状态文件，将默认复用 UUID / WSPATH：${STATE_FILE}"
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
    fi
}

resolve_and_validate_config() {
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
        echo "TLS_PORT 是公网端口，XRAY_PORT 是 127.0.0.1 本地端口。"
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
}

print_final_config() {
    cat <<EOF

==================================================
最终配置
==================================================
DOMAIN=${DOMAIN}
TLS_PORT=${TLS_PORT}      # 客户端连接端口
XRAY_PORT=${XRAY_PORT}    # 本机 127.0.0.1 端口，客户端不要填
HTTP_PORT=${HTTP_PORT}    # 0 表示不监听 HTTP
UUID=${UUID}
WSPATH=${WSPATH}
SERVICE=${SERVICE_NAME}
PRECHECK_ONLY=${PRECHECK_ONLY}
NO_GARBAGE_MODE=${NO_GARBAGE_MODE}
ENABLE_AOP=${ENABLE_AOP}
CF_STRICT=${CF_STRICT}
AUTO_FIREWALL=${AUTO_FIREWALL}
==================================================

EOF
}

run_preflight() {
    echo
    echo "=================================================="
    echo "开始预检查：此阶段不写入任何持久配置"
    echo "=================================================="

    if [ "${EUID}" -ne 0 ]; then
        echo "❌ 请使用 root 用户运行。"
        echo "例如：sudo -i 后再执行脚本。"
        exit 1
    fi

    check_required_commands_no_write
    check_xray_no_write

    preflight_nginx_current_config

    echo
    echo "预检查：目标端口占用..."
    fail_if_port_used_by_non_nginx "${TLS_PORT}" "TLS_PORT" "1"
    fail_if_port_used_by_non_nginx "${XRAY_PORT}" "XRAY_PORT" "0"
    if [ "${HTTP_PORT}" != "0" ]; then
        fail_if_port_used_by_non_nginx "${HTTP_PORT}" "HTTP_PORT" "1"
    fi

    check_duplicate_nginx_domain "${DOMAIN}" "${NGINX_CONFIG}"

    echo
    echo "✅ 预检查通过：目前未发现会导致安装失败的本机问题。"
    echo "说明：DNS 解析、Cloudflare 面板设置、云厂商安全组属于外部环境，脚本无法 100% 代替你确认。"
}

backup_path() {
    local path="$1"
    mkdir -p "$(dirname "${ROLLBACK_MANIFEST}")"
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        mkdir -p "${ROLLBACK_DIR}$(dirname "${path}")"
        cp -a "${path}" "${ROLLBACK_DIR}${path}"
        echo "restore|${path}" >> "${ROLLBACK_MANIFEST}"
    else
        echo "remove|${path}" >> "${ROLLBACK_MANIFEST}"
    fi
}

start_rollback_window() {
    ROLLBACK_DIR="$(mktemp -d /tmp/cf-wss-rollback.XXXXXX)"
    ROLLBACK_MANIFEST="${ROLLBACK_DIR}/manifest"
    : > "${ROLLBACK_MANIFEST}"

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        WAS_SERVICE_ACTIVE=1
    else
        WAS_SERVICE_ACTIVE=0
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        WAS_NGINX_ACTIVE=1
    else
        WAS_NGINX_ACTIVE=0
    fi

    backup_path "${SERVICE_FILE}"
    backup_path "${CONFIG_DIR}"
    backup_path "${SSL_DIR}"
    backup_path "${NGINX_CONFIG}"
    backup_path "${NGINX_LINK}"
    backup_path "${LINK_FILE}"
    backup_path "${STATE_FILE}"

    ROLLBACK_ACTIVE=1
}

rollback_changes() {
    echo
    echo "开始回滚本脚本本次写入的内容..."

    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

    if [ -n "${ROLLBACK_MANIFEST}" ] && [ -f "${ROLLBACK_MANIFEST}" ]; then
        tac "${ROLLBACK_MANIFEST}" | while IFS='|' read -r action path; do
            [ -z "${action}" ] && continue
            case "${action}" in
                remove)
                    rm -rf "${path}" 2>/dev/null || true
                    ;;
                restore)
                    rm -rf "${path}" 2>/dev/null || true
                    mkdir -p "$(dirname "${path}")"
                    cp -a "${ROLLBACK_DIR}${path}" "${path}" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    systemctl daemon-reload 2>/dev/null || true

    if [ "${WAS_SERVICE_ACTIVE}" = "1" ]; then
        systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    else
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi

    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1 && [ "${WAS_NGINX_ACTIVE}" = "1" ]; then
            systemctl reload nginx 2>/dev/null || true
        fi
    fi

    echo "✅ 回滚完成。"
}

install_xray_if_allowed() {
    if XRAY_BIN="$(get_xray_bin 2>/dev/null)"; then
        return 0
    fi

    if [ "${INSTALL_XRAY_IF_MISSING}" = "1" ] && [ "${NO_GARBAGE_MODE}" != "1" ]; then
        echo
        echo "⚠️ 未发现 xray，开始安装 Xray。"
        echo "注意：官方安装器可能会创建默认 xray.service；本脚本自己的服务仍是 ${SERVICE_NAME}。"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        XRAY_BIN="$(get_xray_bin)"
        return 0
    fi

    echo "❌ 未发现 xray，且当前不允许自动安装。"
    exit 1
}

allow_tcp_port_before_reject() {
    local port="$1"

    if [ "${AUTO_FIREWALL}" != "1" ]; then
        echo "ℹ️ AUTO_FIREWALL=0，跳过自动放行 TCP ${port}。请在云防火墙/系统防火墙手动放行。"
        return 0
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "⚠️ 没有 iptables，跳过系统防火墙设置。请手动放行 TCP ${port}。"
        return 0
    fi

    while iptables -C INPUT -p tcp --dport "${port}" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "${port}" -m conntrack --ctstate NEW -j ACCEPT
    done

    local reject_line
    reject_line="$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"

    if [ -n "${reject_line}" ]; then
        iptables -I INPUT "${reject_line}" -p tcp --dport "${port}" -m conntrack --ctstate NEW -j ACCEPT
        echo "已在 REJECT 前放行 TCP ${port}"
    else
        iptables -A INPUT -p tcp --dport "${port}" -m conntrack --ctstate NEW -j ACCEPT
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
SERVICE_NAME='${SERVICE_NAME}'
EOF
    chmod 600 "${STATE_FILE}"
}

write_configs_and_start() {
    install_xray_if_allowed
    start_rollback_window

    echo
    echo "写入配置前再次确认目标端口没有新冲突..."
    fail_if_port_used_by_non_nginx "${TLS_PORT}" "TLS_PORT" "1"
    fail_if_port_used_by_non_nginx "${XRAY_PORT}" "XRAY_PORT" "0"
    if [ "${HTTP_PORT}" != "0" ]; then
        fail_if_port_used_by_non_nginx "${HTTP_PORT}" "HTTP_PORT" "1"
    fi

    echo
    echo "创建目录..."
    mkdir -p "${CONFIG_DIR}" "${SSL_DIR}" /etc/cloudflare "${BASE_NGINX_AVAILABLE}" "${BASE_NGINX_ENABLED}"

    echo "写入 Xray 配置：${XRAY_CONFIG}"
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

    echo "生成源站自签证书..."
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "${SSL_KEY}" \
      -out "${SSL_CERT}" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
    chmod 600 "${SSL_KEY}"

    if [ "${ENABLE_AOP}" = "1" ]; then
        echo "下载 Cloudflare Authenticated Origin Pulls CA..."
        tmp_ca="$(mktemp /tmp/cf-aop-ca.XXXXXX)"
        curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem -o "${tmp_ca}"
        mv "${tmp_ca}" "${AOP_CA_FILE}"
        chmod 644 "${AOP_CA_FILE}"
    fi

    echo "写入 Nginx 站点配置：${NGINX_CONFIG}"
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

    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
EOF_NGINX_HTTPS

        if [ "${ENABLE_AOP}" = "1" ]; then
            cat <<EOF_NGINX_AOP

    ssl_client_certificate ${AOP_CA_FILE};
    ssl_verify_client on;
    ssl_verify_depth 1;
EOF_NGINX_AOP
        else
            cat <<EOF_NGINX_NO_AOP

    # ENABLE_AOP=0：未启用 Cloudflare Authenticated Origin Pulls 校验
    ssl_verify_client off;
EOF_NGINX_NO_AOP
        fi

        cat <<EOF_NGINX_LOCATION

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
EOF_NGINX_LOCATION
    } > "${NGINX_CONFIG}"

    ln -sf "${NGINX_CONFIG}" "${NGINX_LINK}"

    echo "写入 systemd 独立服务：${SERVICE_FILE}"
    cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=Xray CF WSS isolated service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    echo "检查 Nginx 新配置..."
    nginx -t

    echo "启动 / 重载服务..."
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"

    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi

    echo "服务启动后检查监听..."
    ss -lntup | grep -E ":(${TLS_PORT}|${XRAY_PORT})\b" || true

    echo "写入链接和状态文件..."
    write_state_file

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
print("TLS_PORT:", tls_port, "  # 客户端连接这个端口")
print("XRAY_PORT:", xray_port, " # 服务器本地端口，客户端不要填")
print("HTTP_PORT:", http_port)
print("UUID:", uuid)
print("WSPATH:", path)
print("保存位置: ${LINK_FILE}")
print("状态文件: ${STATE_FILE}")
print("==================================================")
EOF_PY

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

    ROLLBACK_ACTIVE=0
    rm -rf "${ROLLBACK_DIR}" 2>/dev/null || true

    echo
    echo "=================================================="
    echo "✅ 安装完成"
    echo "链接已保存到：${LINK_FILE}"
    echo "=================================================="
    echo "Cloudflare 需要确认："
    echo "1. DNS A 记录指向当前 VPS IP，并开启小黄云。"
    echo "2. SSL/TLS 模式建议 Full。"
    echo "3. ENABLE_AOP=1 时，Cloudflare 后台必须开启 Authenticated Origin Pulls。"
    echo "4. 云厂商安全组放行 TCP ${TLS_PORT}。"
    echo "5. 客户端端口填 TLS_PORT=${TLS_PORT}，不要填 XRAY_PORT=${XRAY_PORT}。"
    echo "=================================================="
}

uninstall_self() {
    if [ "${EUID}" -ne 0 ]; then
        echo "❌ 请使用 root 用户运行。"
        exit 1
    fi

    DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
    TLS_PORT="${TLS_PORT:-$DEFAULT_TLS_PORT}"
    SAFE_DOMAIN="$(safe_name "${DOMAIN}")"
    CONFIG_DIR="${BASE_CONFIG_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    SSL_DIR="${BASE_SSL_DIR}/${SAFE_DOMAIN}-${TLS_PORT}"
    NGINX_CONFIG="${BASE_NGINX_AVAILABLE}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    NGINX_LINK="${BASE_NGINX_ENABLED}/${SERVICE_NAME}-${SAFE_DOMAIN}-${TLS_PORT}.conf"
    LINK_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.txt"
    STATE_FILE="${LINK_DIR}/cf-wss-vless-${SAFE_DOMAIN}-${TLS_PORT}.env"

    echo "=================================================="
    echo "卸载本脚本创建的配置"
    echo "DOMAIN=${DOMAIN}"
    echo "TLS_PORT=${TLS_PORT}"
    echo "=================================================="
    echo "不会删除原机 hysteria / hy2 / caddy / docker / 普通 xray 服务。"

    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload || true

    rm -f "${NGINX_LINK}" "${NGINX_CONFIG}"
    rm -rf "${CONFIG_DIR}" "${SSL_DIR}"
    rm -f "${LINK_FILE}" "${STATE_FILE}"

    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx 2>/dev/null || true
    fi

    echo "✅ 已卸载本脚本创建的配置。"
}

main_install() {
    echo "=================================================="
    echo "VLESS + WSS + Cloudflare 预检优先 / 尽量无垃圾版"
    echo "=================================================="
    echo "本脚本不会停止原机 hysteria-server / hy2 / xray / caddy。"
    echo "本脚本创建独立服务：${SERVICE_NAME}"
    echo "=================================================="

    print_important_notes
    resolve_and_validate_config
    print_final_config
    run_preflight

    if [ "${PRECHECK_ONLY}" = "1" ] || [ "${ACTION}" = "precheck" ]; then
        echo
        echo "✅ PRECHECK_ONLY=1：只检查，不写入任何持久文件。"
        echo "检查通过后可去掉 PRECHECK_ONLY=1 再运行安装。"
        exit 0
    fi

    write_configs_and_start
}

case "${ACTION}" in
    install)
        main_install
        ;;
    precheck)
        PRECHECK_ONLY=1
        main_install
        ;;
    uninstall)
        uninstall_self
        ;;
    *)
        echo "❌ ACTION 只支持 install / precheck / uninstall，当前：${ACTION}"
        exit 1
        ;;
esac
