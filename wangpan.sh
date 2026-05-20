#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# 安全版 SimpleCloud + Jellyfin + Caddy Docker
#
# 默认域名：
#   文件管理：https://hy2.liucna.com
#   Jellyfin：https://video.hy2.liucna.com
#
# 推荐运行方式：
#   CLOUD_DOMAIN="wangpan.liucna.com" VIDEO_DOMAIN="video.liucna.com" bash <(curl -fsSL https://raw.githubusercontent.com/liucong552-art/jichang/refs/heads/main/wangpan.sh)
#
# 说明：
#   - SimpleCloud 只监听 127.0.0.1:8080
#   - Jellyfin 只监听 127.0.0.1:8096
#   - Caddy Docker 对外监听 80/443，自动 HTTPS
#   - 公网不开放 8080/8096
#   - 数据保存在 /data/cloud，不会因为重跑脚本被删除
# ==================================================

CLOUD_DOMAIN="${CLOUD_DOMAIN:-hy2.liucna.com}"
VIDEO_DOMAIN="${VIDEO_DOMAIN:-video.hy2.liucna.com}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
SSH_PORT="${SSH_PORT:-22}"

SCRIPT_URL="https://raw.githubusercontent.com/liucong552-art/jichang/refs/heads/main/wangpan.sh"

echo "=================================================="
echo " 安全版 SimpleCloud + Jellyfin + Caddy Docker"
echo "=================================================="
echo "文件管理域名: ${CLOUD_DOMAIN}"
echo "视频域名:     ${VIDEO_DOMAIN}"
echo "时区:         ${TIMEZONE}"
echo "SSH端口:      ${SSH_PORT}"
echo "=================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：请使用 root 用户执行。"
  exit 1
fi

echo "=== 0. 检查系统 ==="
cat /etc/os-release || true
df -h /

echo "=== 1. 安装基础工具 ==="
apt-get update
apt-get install -y ca-certificates curl gnupg openssl ufw python3 apt-transport-https

echo "=== 2. 获取服务器公网 IP ==="
SERVER_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo "当前服务器公网 IP: ${SERVER_IP}"
echo
echo "请确认 DNS 已解析："
echo "${CLOUD_DOMAIN}  ->  ${SERVER_IP}"
echo "${VIDEO_DOMAIN}  ->  ${SERVER_IP}"
echo

echo "=== 3. 安装 Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
  done

  install -m 0755 -d /etc/apt/keyrings

  . /etc/os-release
  OS_ID="$ID"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

  if [ -z "$OS_CODENAME" ]; then
    echo "错误：无法识别系统版本代号。"
    exit 1
  fi

  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker

echo "=== 4. 清理可能失败的 Caddy apt 源，避免 NO_PUBKEY 报错 ==="
rm -f /etc/apt/sources.list.d/caddy-stable.list
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
systemctl disable --now caddy 2>/dev/null || true

echo "=== 5. 创建数据目录 ==="
mkdir -p /opt/simplecloud
mkdir -p /opt/mycloud/jellyfin/config
mkdir -p /opt/mycloud/jellyfin/cache
mkdir -p /opt/mycloud/caddy/data
mkdir -p /opt/mycloud/caddy/config

mkdir -p /data/cloud/media
mkdir -p /data/cloud/files
mkdir -p /data/cloud/photos
mkdir -p /data/cloud/backup

chmod -R 775 /data/cloud

echo "=== 6. 生成或保留 SimpleCloud 登录信息 ==="
if [ -f /opt/simplecloud/config.env ]; then
  # shellcheck disable=SC1091
  . /opt/simplecloud/config.env
  CLOUD_USER="${CLOUD_USER:-admin}"
  CLOUD_PASS="${CLOUD_PASS:-$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)}"
else
  CLOUD_USER="admin"
  CLOUD_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)"
fi

cat > /opt/simplecloud/config.env <<ENV
CLOUD_USER=${CLOUD_USER}
CLOUD_PASS=${CLOUD_PASS}
CLOUD_ROOT=/data/cloud
ENV

chmod 600 /opt/simplecloud/config.env

echo "=== 7. 写入 SimpleCloud 程序 ==="
cat > /opt/simplecloud/simplecloud.py <<'PY'
#!/usr/bin/env python3
import os
import html
import base64
import shutil
import urllib.parse
import cgi
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = os.environ.get("CLOUD_ROOT", "/data/cloud")
USER = os.environ.get("CLOUD_USER", "admin")
PASS = os.environ.get("CLOUD_PASS", "admin")

def safe_path(url_path):
    decoded = urllib.parse.unquote(url_path)
    rel = decoded.lstrip("/")
    full = os.path.abspath(os.path.join(ROOT, rel))
    root = os.path.abspath(ROOT)
    if not (full == root or full.startswith(root + os.sep)):
        raise ValueError("bad path")
    return full, rel

def human_size(n):
    try:
        n = float(n)
    except Exception:
        return "-"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def auth_ok(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(h.split(" ", 1)[1]).decode()
            u, p = raw.split(":", 1)
            return u == USER and p == PASS
        except Exception:
            return False

    def require_auth(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="SimpleCloud"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.auth_ok():
            return self.require_auth()

        try:
            parsed = urllib.parse.urlparse(self.path)
            full, rel = safe_path(parsed.path)
        except Exception:
            self.send_error(403)
            return

        if os.path.isfile(full):
            size = os.path.getsize(full)
            name = os.path.basename(full)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(name))
            self.end_headers()
            with open(full, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            return

        if not os.path.isdir(full):
            self.send_error(404)
            return

        current = "/" + rel if rel else "/"
        parent_rel = "/".join(rel.split("/")[:-1]) if rel else ""
        parent_href = "/" + urllib.parse.quote(parent_rel) if parent_rel else "/"

        rows = []

        if rel:
            rows.append(f'''
<tr>
<td>📁</td>
<td><a href="{html.escape(parent_href)}">.. 返回上级</a></td>
<td></td>
<td></td>
</tr>
''')

        try:
            names = sorted(os.listdir(full), key=lambda x: (not os.path.isdir(os.path.join(full, x)), x.lower()))
        except Exception:
            names = []

        for name in names:
            path = os.path.join(full, name)
            href = "/" + urllib.parse.quote((rel + "/" + name).strip("/"))
            esc = html.escape(name)

            if os.path.isdir(path):
                rows.append(f'''
<tr>
<td>📁</td>
<td><a href="{href}">{esc}/</a></td>
<td>-</td>
<td>
<form method="post" style="display:inline" onsubmit="return confirm('确定删除文件夹 {esc} ?')">
<input type="hidden" name="action" value="delete">
<input type="hidden" name="target" value="{esc}">
<button class="danger">删除</button>
</form>
</td>
</tr>
''')
            else:
                size = human_size(os.path.getsize(path))
                rows.append(f'''
<tr>
<td>📄</td>
<td><a href="{href}">{esc}</a></td>
<td>{size}</td>
<td>
<a class="btn" href="{href}">下载</a>
<form method="post" style="display:inline" onsubmit="return confirm('确定删除 {esc} ?')">
<input type="hidden" name="action" value="delete">
<input type="hidden" name="target" value="{esc}">
<button class="danger">删除</button>
</form>
</td>
</tr>
''')

        body = f'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>SimpleCloud</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body {{
  font-family: Arial, "Microsoft YaHei", sans-serif;
  margin: 0;
  background: #f5f6f8;
  color: #222;
}}
.header {{
  background: #202124;
  color: white;
  padding: 16px 24px;
}}
.container {{
  max-width: 1100px;
  margin: 24px auto;
  padding: 0 16px;
}}
.card {{
  background: white;
  border-radius: 14px;
  padding: 20px;
  box-shadow: 0 4px 18px rgba(0,0,0,.08);
  margin-bottom: 18px;
}}
.path {{
  color: #555;
  word-break: break-all;
}}
.grid {{
  display: grid;
  gap: 12px;
  grid-template-columns: 1fr;
}}
input[type=file], input[type=text] {{
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 8px;
}}
button, .btn {{
  background: #1677ff;
  color: white;
  border: none;
  padding: 8px 12px;
  border-radius: 8px;
  cursor: pointer;
  text-decoration: none;
  display: inline-block;
}}
button:hover, .btn:hover {{
  opacity: .9;
}}
.danger {{
  background: #d93025;
}}
table {{
  width: 100%;
  border-collapse: collapse;
  margin-top: 12px;
}}
td, th {{
  border-bottom: 1px solid #eee;
  padding: 10px;
  text-align: left;
}}
.progress-wrap {{
  display: none;
  margin-top: 12px;
}}
progress {{
  width: 100%;
  height: 22px;
}}
.note {{
  color: #666;
  font-size: 14px;
  line-height: 1.7;
}}
.quick a {{
  margin-right: 8px;
  margin-bottom: 8px;
}}
</style>
</head>
<body>
<div class="header">
  <h2>SimpleCloud 私有网盘</h2>
</div>

<div class="container">

<div class="card">
  <p class="path">当前位置：<b>{html.escape(current)}</b></p>
  <div class="quick">
    <a class="btn" href="/media">media 视频目录</a>
    <a class="btn" href="/files">files 普通文件</a>
    <a class="btn" href="/photos">photos 照片</a>
    <a class="btn" href="/backup">backup 备份</a>
  </div>
</div>

<div class="card">
  <h3>上传文件到当前目录</h3>
  <div class="grid">
    <input id="fileInput" type="file" multiple>
    <button onclick="uploadFiles()">开始上传</button>
  </div>
  <div class="progress-wrap" id="progressWrap">
    <p id="uploadText">准备上传...</p>
    <progress id="progressBar" value="0" max="100"></progress>
  </div>
  <p class="note">
    视频请上传到 <b>/media</b>。上传完成后去 Jellyfin 扫描媒体库。
    大文件上传时不要关闭浏览器，不要让电脑睡眠。
  </p>
</div>

<div class="card">
  <h3>新建文件夹</h3>
  <form method="post">
    <input type="hidden" name="action" value="mkdir">
    <input type="text" name="dirname" placeholder="文件夹名称">
    <button type="submit">新建</button>
  </form>
</div>

<div class="card">
  <h3>文件列表</h3>
  <table>
    <tr>
      <th></th>
      <th>名称</th>
      <th>大小</th>
      <th>操作</th>
    </tr>
    {''.join(rows)}
  </table>
</div>

</div>

<script>
function uploadFiles() {{
  const input = document.getElementById('fileInput');
  const files = input.files;
  if (!files.length) {{
    alert('请选择文件');
    return;
  }}

  const wrap = document.getElementById('progressWrap');
  const bar = document.getElementById('progressBar');
  const text = document.getElementById('uploadText');

  wrap.style.display = 'block';

  let index = 0;

  function uploadOne() {{
    if (index >= files.length) {{
      text.innerText = '全部上传完成，页面即将刷新...';
      setTimeout(() => location.reload(), 1000);
      return;
    }}

    const file = files[index];
    const form = new FormData();
    form.append('file', file);

    const xhr = new XMLHttpRequest();
    xhr.open('POST', window.location.pathname, true);

    xhr.upload.onprogress = function(e) {{
      if (e.lengthComputable) {{
        const percent = Math.round((e.loaded / e.total) * 100);
        bar.value = percent;
        text.innerText = '正在上传 ' + (index + 1) + '/' + files.length + '：' + file.name + '，' + percent + '%';
      }}
    }};

    xhr.onload = function() {{
      if (xhr.status >= 200 && xhr.status < 400) {{
        index++;
        bar.value = 0;
        uploadOne();
      }} else {{
        alert('上传失败：' + file.name + '，HTTP ' + xhr.status);
      }}
    }};

    xhr.onerror = function() {{
      alert('上传失败：' + file.name);
    }};

    xhr.send(form);
  }}

  uploadOne();
}}
</script>
</body>
</html>
'''
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if not self.auth_ok():
            return self.require_auth()

        try:
            parsed = urllib.parse.urlparse(self.path)
            full, rel = safe_path(parsed.path)
        except Exception:
            self.send_error(403)
            return

        if not os.path.isdir(full):
            self.send_error(404)
            return

        ctype = self.headers.get("Content-Type", "")

        if ctype.startswith("multipart/form-data"):
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={
                    "REQUEST_METHOD": "POST",
                    "CONTENT_TYPE": ctype,
                }
            )

            files = []
            if "file" in form:
                item = form["file"]
                files = item if isinstance(item, list) else [item]

            for item in files:
                if not getattr(item, "filename", ""):
                    continue
                filename = os.path.basename(item.filename)
                dest = os.path.join(full, filename)
                with open(dest, "wb") as out:
                    shutil.copyfileobj(item.file, out)
                os.chmod(dest, 0o664)

        else:
            length = int(self.headers.get("Content-Length", "0"))
            data = self.rfile.read(length).decode("utf-8", errors="ignore")
            params = urllib.parse.parse_qs(data)
            action = params.get("action", [""])[0]

            if action == "delete":
                target = os.path.basename(params.get("target", [""])[0])
                dest = os.path.join(full, target)
                if os.path.isfile(dest):
                    os.remove(dest)
                elif os.path.isdir(dest):
                    shutil.rmtree(dest)

            elif action == "mkdir":
                dirname = os.path.basename(params.get("dirname", [""])[0].strip())
                if dirname:
                    os.makedirs(os.path.join(full, dirname), exist_ok=True)
                    os.chmod(os.path.join(full, dirname), 0o775)

        self.send_response(303)
        self.send_header("Location", self.path)
        self.send_header("Content-Length", "0")
        self.end_headers()

if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 8080), Handler)
    print("SimpleCloud listening on 127.0.0.1:8080")
    server.serve_forever()
PY

chmod +x /opt/simplecloud/simplecloud.py

echo "=== 8. 创建 SimpleCloud systemd 服务 ==="
cat > /etc/systemd/system/simplecloud.service <<'SERVICE'
[Unit]
Description=SimpleCloud Web File Manager
After=network.target

[Service]
Type=simple
EnvironmentFile=/opt/simplecloud/config.env
ExecStart=/usr/bin/python3 /opt/simplecloud/simplecloud.py
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now simplecloud
systemctl restart simplecloud

echo "=== 9. 安装 / 重建 Jellyfin 容器，只监听本机 127.0.0.1:8096 ==="
docker rm -f mycloud-jellyfin 2>/dev/null || true

docker run -d \
  --name mycloud-jellyfin \
  --restart unless-stopped \
  -p 127.0.0.1:8096:8096 \
  -e TZ="${TIMEZONE}" \
  -u 1000:1000 \
  -v /opt/mycloud/jellyfin/config:/config \
  -v /opt/mycloud/jellyfin/cache:/cache \
  -v /data/cloud/media:/media \
  jellyfin/jellyfin:latest

echo "=== 10. 写入 Caddyfile ==="
cat > /opt/mycloud/caddy/Caddyfile <<CADDY
${CLOUD_DOMAIN} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:8080
}

${VIDEO_DOMAIN} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:8096
}
CADDY

echo "=== 11. 安装 / 重建 Caddy Docker，只开放 80/443 ==="
docker rm -f mycloud-caddy 2>/dev/null || true

docker run -d \
  --name mycloud-caddy \
  --restart unless-stopped \
  --network host \
  -v /opt/mycloud/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /opt/mycloud/caddy/data:/data \
  -v /opt/mycloud/caddy/config:/config \
  caddy:2-alpine

echo "=== 12. 防火墙：只开放 SSH / HTTP / HTTPS，关闭原始端口 ==="
ufw allow "${SSH_PORT}/tcp" || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

ufw delete allow 8080/tcp 2>/dev/null || true
ufw delete allow 8096/tcp 2>/dev/null || true
ufw deny 8080/tcp || true
ufw deny 8096/tcp || true

ufw --force enable

echo "=== 13. 保存登录信息 ==="
cat > /root/mycloud-info.txt <<INFO
==============================
安全版 SimpleCloud + Jellyfin
==============================

文件管理地址：
https://${CLOUD_DOMAIN}

文件管理用户名：
${CLOUD_USER}

文件管理密码：
${CLOUD_PASS}

Jellyfin 地址：
https://${VIDEO_DOMAIN}

目录说明：
/media  上传视频到这里，Jellyfin 扫描这个目录
/files  普通文件、文档、压缩包
/photos 照片
/backup 备份

VPS 真实目录：
/data/cloud/media
/data/cloud/files
/data/cloud/photos
/data/cloud/backup

Jellyfin 添加媒体库：
内容类型：家庭视频和照片
文件夹路径：/media

公网开放端口：
${SSH_PORT} / 80 / 443

本机内部端口：
127.0.0.1:8080  SimpleCloud
127.0.0.1:8096  Jellyfin

Caddy：
Docker 容器 mycloud-caddy，host 网络模式，负责 HTTPS 自动证书和反向代理。

常用命令：
cat /root/mycloud-info.txt
systemctl status simplecloud --no-pager
journalctl -u simplecloud -f
docker logs mycloud-caddy --tail=100
docker logs mycloud-jellyfin --tail=100
docker restart mycloud-caddy
docker restart mycloud-jellyfin
ufw status
df -h
du -sh /data/cloud/media
INFO

echo
echo "=== 安装完成 ==="
cat /root/mycloud-info.txt

echo
echo "=== 服务状态 ==="
systemctl status simplecloud --no-pager -l | tail -n 15 || true
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ufw status

echo
echo "=== Caddy 日志最近 50 行 ==="
docker logs mycloud-caddy --tail=50 || true

echo
echo "=== 提示 ==="
echo "如果 HTTPS 暂时打不开，请确认 DNS 已经解析到当前 IP：${SERVER_IP}"
echo "文件管理：https://${CLOUD_DOMAIN}"
echo "Jellyfin：https://${VIDEO_DOMAIN}"
