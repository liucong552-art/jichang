DOMAIN="hy21.liucna.com"

set -Eeuo pipefail

UUID="$(cat /proc/sys/kernel/random/uuid)"
WSPATH="/$(openssl rand -hex 8)"

echo "DOMAIN=${DOMAIN}"
echo "UUID=${UUID}"
echo "WSPATH=${WSPATH}"

systemctl disable --now hysteria-server 2>/dev/null || true
systemctl disable --now hy2 2>/dev/null || true
systemctl disable --now xray 2>/dev/null || true

apt update
apt install -y curl wget unzip openssl nginx ca-certificates python3

echo
echo "修复 Oracle/Ubuntu 默认 iptables：放行 TCP 80/443，避免被 REJECT 拦截..."

DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent

allow_tcp_port_before_reject() {
    local port="$1"

    # 删除已有的同类规则，避免重复；如果之前加在 REJECT 后面，也会被清掉重插
    while iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
    done

    # 找到第一条 REJECT 规则
    local reject_line
    reject_line="$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"{print $1; exit}')"

    if [ -n "$reject_line" ]; then
        iptables -I INPUT "$reject_line" -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
        echo "已在 REJECT 前放行 TCP $port"
    else
        iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
        echo "未发现 REJECT，已追加放行 TCP $port"
    fi
}

allow_tcp_port_before_reject 80
allow_tcp_port_before_reject 443

netfilter-persistent save
systemctl enable netfilter-persistent

echo "当前 INPUT 规则："
iptables -L INPUT -n -v --line-numbers

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
      "port": 10000,
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

cat > /etc/nginx/sites-available/xray-wss.conf <<EOF_NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 444;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/ssl/xray/${DOMAIN}.crt;
    ssl_certificate_key /etc/ssl/xray/${DOMAIN}.key;

    ssl_client_certificate /etc/cloudflare/authenticated_origin_pull_ca.pem;
    ssl_verify_client on;
    ssl_verify_depth 1;

    location ${WSPATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
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
EOF_NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/xray-wss.conf /etc/nginx/sites-enabled/xray-wss.conf

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
print("==================================================")
print("VLESS + WSS + Cloudflare 链接：")
print(f"vless://{uuid}@{domain}:443?encryption=none&security=tls&sni={domain}&type=ws&host={domain}&path={urllib.parse.quote(path, safe='')}#cf-wss-${DOMAIN}")
print("==================================================")
print("DOMAIN:", domain)
print("UUID:", uuid)
print("WSPATH:", path)
print("保存位置: /root/cf-wss-vless-link.txt")
EOF_PY

echo
echo "检查监听："
ss -lntup | grep -E ':443|:10000' || true

echo
echo "Xray 状态："
systemctl status xray --no-pager -l | sed -n '1,20p'

echo
echo "Nginx 状态："
systemctl status nginx --no-pager -l | sed -n '1,20p'
