#!/usr/bin/env bash
# VLESS WS TLS / VLESS TCP REALITY Vision. Xray-core pinned to v26.2.2.
# References: mack-a/v2ray-agent (workflow), XTLS/Xray-core (configuration).
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION=v26.2.2
MODE=ws
BASE=/etc/vls
CONF=$BASE/config.json
ACME=$BASE/letsencrypt
BIN=/usr/local/lib/vls/xray
MANAGER=/usr/local/sbin/vls
SERVICE=vls.service
WORK=''
ROLLBACK=''
WAS_ACTIVE=0

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

select_mode() {
    MODE=$1
    case $MODE in
        ws) BASE=/etc/vls; SERVICE=vls.service ;;
        reality) BASE=/etc/vless-reality; SERVICE=vless-reality.service ;;
        *) die '未知协议类型。' ;;
    esac
    CONF=$BASE/config.json
    ACME=$BASE/letsencrypt
}

choose_node() {
    local choice
    if [[ -f /etc/vls/config.json && -f /etc/vless-reality/config.json ]]; then
        read -r -p '管理哪个节点？1. WS TLS  2. REALITY：' choice
        case $choice in 1) select_mode ws ;; 2) select_mode reality ;; *) die '无效选项。' ;; esac
    elif [[ -f /etc/vless-reality/config.json ]]; then
        select_mode reality
    else
        select_mode ws
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n $ROLLBACK ]]; then
        say '操作未完成，正在恢复原配置。' >&2
        if [[ $ROLLBACK == NEW ]]; then
            systemctl stop "$SERVICE" || true
            rm -f -- "$CONF"
        else
            cp -- "$ROLLBACK" "$CONF" || rc=1
            if (( WAS_ACTIVE )); then
                systemctl restart "$SERVICE" || rc=1
            else
                systemctl stop "$SERVICE" || rc=1
            fi
            say "备份保留在：$ROLLBACK" >&2
        fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    if (( rc )); then
        say '操作失败。请检查上方报错；安装过程中已下载的文件及证书会保留，便于重试。' >&2
    fi
    exit "$rc"
}

valid_domain() {
    local label
    local -a labels
    [[ ${#1} -le 253 && $1 == *.* && $1 != *..* && $1 != *. ]] || return 1
    [[ ! $1 =~ ^[0-9.]+$ ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 )) || return 1
    [[ $MODE == reality ]] || (( 10#$1 != 80 ))
}

ask_domain() {
    local input
    while true; do
        read -r -p "${DOMAIN_PROMPT:-域名}${DOMAIN:+ [$DOMAIN]}：" input
        input=${input:-${DOMAIN:-}}
        input=${input,,}
        if valid_domain "$input"; then DOMAIN=$input; return; fi
        say '请输入完整域名，例如 node.example.com，不含 https://、端口、路径或通配符。中文域名请使用 Punycode。'
    done
}

valid_address() {
    if [[ $1 =~ ^[0-9.]+$ ]]; then
        python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
    else
        valid_domain "$1"
    fi
}

ask_address() {
    local input
    while true; do
        read -r -p "本服务器公网 IPv4 或连接域名${ADDRESS:+ [$ADDRESS]}：" input
        input=${input:-${ADDRESS:-}}
        input=${input,,}
        if valid_address "$input"; then ADDRESS=$input; return; fi
        say '请输入有效 IPv4 或完整域名，不含协议、端口或路径。'
    done
}

check_reality_target() {
    say "检查 REALITY 目标 $DOMAIN:443 的证书、TLS 1.3 和 HTTP/2。"
    python3 - "$DOMAIN" <<'PY'
import socket, ssl, sys
ctx = ssl.create_default_context()
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(['h2'])
try:
    with socket.create_connection((sys.argv[1], 443), timeout=8) as raw:
        with ctx.wrap_socket(raw, server_hostname=sys.argv[1]) as conn:
            if conn.version() != 'TLSv1.3' or conn.selected_alpn_protocol() != 'h2':
                raise RuntimeError('目标需支持 TLS 1.3 和 HTTP/2')
except (OSError, RuntimeError) as exc:
    print(f'目标检查失败：{exc}', file=sys.stderr)
    sys.exit(1)
PY
}

reality_public_key() {
    local keys
    keys=$("$BIN" x25519 -i "$PRIVATE_KEY")
    PUBLIC_KEY=$(awk '/^(Password|PublicKey|Public key):/ {print $NF; exit}' <<< "$keys")
    [[ $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || die '无法从 REALITY 私钥推导公钥。'
}

ask_port() {
    local input
    while true; do
        read -r -p "节点 TCP 端口 [${PORT:-443}]：" input
        input=${input:-${PORT:-443}}
        if valid_port "$input"; then PORT=$((10#$input)); return; fi
        say '请输入 1–65535；80 留给证书验证，不能作为节点端口。'
    done
}

port_free() {
    local listeners
    listeners=$(ss -H -ltn "sport = :$1")
    [[ -z $listeners ]] || die "TCP $1 已被占用。请另选端口或自行处理占用服务；脚本不会停止其他服务。"
}

load_config() {
    [[ -s $CONF ]] || die '尚未安装所选协议，请先安装。'
    PORT=$(jq -er '.inbounds[0].port' "$CONF")
    UUID=$(jq -er '.inbounds[0].settings.clients[0].id' "$CONF")
    if [[ $MODE == reality ]]; then
        DOMAIN=$(jq -er '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONF")
        PRIVATE_KEY=$(jq -er '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONF")
        SHORT_ID=$(jq -er '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONF")
        ADDRESS=$(jq -er '._manager.address' "$CONF")
        reality_public_key
    else
        DOMAIN=$(jq -er '.inbounds[0].streamSettings.tlsSettings.serverName' "$CONF")
        WS_PATH=$(jq -er '.inbounds[0].streamSettings.wsSettings.path' "$CONF")
    fi
    if ! valid_domain "$DOMAIN" || ! valid_port "$PORT"; then
        die '已保存的域名或端口无效。'
    fi
}

dependencies() {
    local -a packages=(ca-certificates curl unzip jq openssl iproute2 python3)
    if [[ $MODE == ws ]]; then packages+=(certbot); fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${packages[@]}"
}

download_core() {
    local asset hash actual
    if [[ -x $BIN ]]; then
        [[ $("$BIN" version) == 'Xray 26.2.2 '* ]] || die '已有共享核心不是 v26.2.2，请先检查。'
        return
    fi
    case $(uname -m) in
        x86_64) asset=Xray-linux-64.zip
            hash=e281a2628e5d5beeec5e31b804b3f269ee70cd7f5d56aa92cccd1f8cb6d36365 ;;
        aarch64|arm64) asset=Xray-linux-arm64-v8a.zip
            hash=4afed4f00b75452b565c692746a1b4e36b6cfa6142660588dd7934bd1d200577 ;;
        *) die '仅支持 x86_64 和 ARM64。' ;;
    esac
    say "下载 Xray-core $VERSION，并校验官方 SHA-256。"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 20 --max-time 600 \
        "https://github.com/XTLS/Xray-core/releases/download/$VERSION/$asset" -o "$WORK/core.zip"
    actual=$(sha256sum "$WORK/core.zip")
    [[ ${actual%% *} == "$hash" ]] || die 'Xray 安装包 SHA-256 不匹配。'
    unzip -q "$WORK/core.zip" xray -d "$WORK/core"
    chmod 700 "$WORK/core/xray"
    [[ $("$WORK/core/xray" version) == 'Xray 26.2.2 '* ]] || die 'Xray 版本不匹配。'
    install -d -m 755 "$(dirname "$BIN")"
    install -m 755 "$WORK/core/xray" "$BIN"
}

certbot_cmd() {
    certbot --config /dev/null --config-dir "$ACME" \
        --work-dir /var/lib/vls/acme --logs-dir /var/log/vls/acme "$@"
}

issue_cert() {
    port_free 80
    say "为 $DOMAIN 申请或复用 Let's Encrypt 证书。"
    say '请确保域名 A/AAAA 记录指向本机；公网 TCP 80 可访问；Cloudflare 请使用仅 DNS。'
    getent ahosts "$DOMAIN" >/dev/null || die "无法解析 $DOMAIN，请先设置 DNS。"
    certbot_cmd certonly --standalone --preferred-challenges http --http-01-port 80 \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --server https://acme-v02.api.letsencrypt.org/directory \
        --cert-name "$DOMAIN" -d "$DOMAIN" --keep-until-expiring
    openssl x509 -in "$ACME/live/$DOMAIN/fullchain.pem" -noout -checkend 0
}

render_config() {
    if [[ $MODE == reality ]]; then
        jq -n --arg domain "$DOMAIN" --argjson port "$PORT" \
            --arg uuid "$UUID" --arg key "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg address "$ADDRESS" '
        {_manager:{address:$address},log:{loglevel:"warning"},
         inbounds:[{tag:"vless-reality",listen:"0.0.0.0",port:$port,protocol:"vless",
           settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
           streamSettings:{network:"raw",security:"reality",
             realitySettings:{show:false,target:($domain+":443"),xver:0,
               serverNames:[$domain],privateKey:$key,shortIds:[$sid]}}}],
         outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$1"
        return
    fi
    jq -n --arg domain "$DOMAIN" --argjson port "$PORT" \
        --arg uuid "$UUID" --arg path "$WS_PATH" --arg cert "$ACME/live/$DOMAIN" '
    {log:{loglevel:"warning"},
     inbounds:[{tag:"vls-tls",listen:"0.0.0.0",port:$port,protocol:"vless",
       settings:{clients:[{id:$uuid}],decryption:"none"},
       streamSettings:{network:"ws",security:"tls",
         tlsSettings:{serverName:$domain,minVersion:"1.2",alpn:["http/1.1"],
           certificates:[{certificateFile:($cert+"/fullchain.pem"),keyFile:($cert+"/privkey.pem")}]},
         wsSettings:{path:$path}}}],
     outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$1"
}

# Verify a real TLS handshake (including hostname and trust), then WS upgrade.
healthcheck() {
    if [[ $MODE == reality ]]; then reality_healthcheck; return; fi
    python3 - "$CONF" <<'PY'
import base64, hashlib, json, os, socket, ssl, sys, time
c = json.load(open(sys.argv[1]))['inbounds'][0]
s = c['streamSettings']
domain = s['tlsSettings']['serverName']
context = ssl.create_default_context()
context.set_alpn_protocols(['http/1.1'])
for attempt in range(10):
    try:
        with socket.create_connection(('127.0.0.1', c['port']), timeout=3) as raw:
            with context.wrap_socket(raw, server_hostname=domain) as conn:
                key = base64.b64encode(os.urandom(16)).decode()
                req = (f"GET {s['wsSettings']['path']} HTTP/1.1\r\nHost: {domain}\r\n"
                       f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
                conn.sendall(req.encode())
                data = b''
                while b'\r\n\r\n' not in data and len(data) < 16384:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                expected = base64.b64encode(hashlib.sha1(
                    (key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                if data.startswith(b'HTTP/1.1 101 ') and expected in data:
                    sys.exit(0)
                raise RuntimeError('WebSocket upgrade did not return a valid 101 response')
    except (OSError, RuntimeError) as exc:
        error = exc
        time.sleep(0.5)
print(f'本机 TLS/WS 检查失败：{error}', file=sys.stderr)
sys.exit(1)
PY
}


# Test authenticated REALITY traffic through a temporary loopback-only Xray client.
reality_healthcheck() {
    python3 - "$CONF" "$BIN" <<'PY'
import http.client, http.server, json, os, socket, subprocess, sys, tempfile, threading, time
config_path, binary = sys.argv[1:]
node = json.load(open(config_path))['inbounds'][0]
reality = node['streamSettings']['realitySettings']
keys = subprocess.check_output([binary, 'x25519', '-i', reality['privateKey']], text=True)
public = next(line.split()[-1] for line in keys.splitlines()
              if line.startswith(('Password:', 'PublicKey:', 'Public key:')))
token = os.urandom(16).hex().encode()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(token)))
        self.end_headers()
        self.wfile.write(token)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
proc = None
try:
    with tempfile.TemporaryDirectory(prefix='vless-reality-check-') as folder:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            proxy_port = sock.getsockname()[1]
        client = {
            'log': {'loglevel': 'warning'},
            'inbounds': [{'listen': '127.0.0.1', 'port': proxy_port, 'protocol': 'http'}],
            'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{
                'address': '127.0.0.1', 'port': node['port'],
                'users': [{'id': node['settings']['clients'][0]['id'],
                           'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]},
                'streamSettings': {'network': 'raw', 'security': 'reality',
                    'realitySettings': {'serverName': reality['serverNames'][0],
                        'fingerprint': 'chrome', 'password': public,
                        'shortId': reality['shortIds'][0]}}}]}
        path = os.path.join(folder, 'client.json')
        with open(path, 'w') as f:
            json.dump(client, f)
        with open(os.path.join(folder, 'client.log'), 'w+') as log:
            proc = subprocess.Popen([binary, 'run', '-config', path], stdout=log, stderr=log)
            try:
                for attempt in range(5):
                    connection = http.client.HTTPConnection('127.0.0.1', proxy_port, timeout=5)
                    try:
                        if proc.poll() is not None:
                            raise RuntimeError('临时验证客户端退出')
                        connection.request('GET', f'http://127.0.0.1:{server.server_port}/check')
                        response = connection.getresponse()
                        if response.status == 200 and response.read() == token:
                            break
                        raise RuntimeError('代理未返回预期内容')
                    except (OSError, http.client.HTTPException, RuntimeError) as exc:
                        error = exc
                        if attempt == 4:
                            raise RuntimeError(f'REALITY 验证失败：{error}')
                        time.sleep(.5)
                    finally:
                        connection.close()
            finally:
                proc.terminate()
                proc.wait(timeout=10)
finally:
    server.shutdown()
    server.server_close()
PY
}

write_units() {
    cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=VLESS $MODE (Xray-core $VERSION)
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=root
ExecStart=$BIN run -config $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/$SERVICE"
    if [[ $MODE == reality ]]; then systemctl daemon-reload; return; fi
    cat > /etc/systemd/system/vls-renew.service <<EOF
[Unit]
Description=Renew the active VLESS WS TLS certificate
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$MANAGER --renew
EOF
    cat > /etc/systemd/system/vls-renew.timer <<'EOF'
[Unit]
Description=Check VLESS WS TLS certificate twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/vls{,-renew}.service /etc/systemd/system/vls-renew.timer
    systemctl daemon-reload
}

apply_config() {
    local candidate=$WORK/config.json backup
    render_config "$candidate"
    "$BIN" run -test -config "$candidate"
    WAS_ACTIVE=0
    if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=1; fi
    if [[ -f $CONF ]]; then
        install -d -m 700 "$BASE/backups"
        backup=$(mktemp "$BASE/backups/config.XXXXXXXX.json")
        cp -p -- "$CONF" "$backup"
        ROLLBACK=$backup
    else
        ROLLBACK=NEW
    fi
    install -m 600 "$candidate" "$BASE/config.next"
    mv -f -- "$BASE/config.next" "$CONF"
    systemctl restart "$SERVICE"
    healthcheck
    systemctl is-active --quiet "$SERVICE"
    ROLLBACK=''
    if [[ $MODE == reality ]]; then
        say '配置已生效，本机 REALITY 身份验证与代理数据传输检查通过。'
    else
        say '配置已生效，本机 TLS 与 WebSocket 握手检查通过。'
    fi
    say '公网连通性仍取决于 DNS、防火墙及云安全组。'
}

show_link() {
    load_config
    if [[ $MODE == reality ]]; then
        printf '\n协议：VLESS + TCP + REALITY + Vision\n核心：%s\n连接地址：%s\n端口：%s\n目标域名/SNI：%s\nUUID：%s\n公钥：%s\nShort ID：%s\n' \
            "$VERSION" "$ADDRESS" "$PORT" "$DOMAIN" "$UUID" "$PUBLIC_KEY" "$SHORT_ID"
        printf '\n导入链接（含凭据，请妥善保管）：\nvless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#VLESS-REALITY\n\n' \
            "$UUID" "$ADDRESS" "$PORT" "$DOMAIN" "$PUBLIC_KEY" "$SHORT_ID"
        return
    fi
    local encoded
    encoded=$(jq -nr --arg path "$WS_PATH" '$path|@uri')
    printf '\n协议：VLESS + WS + TLS\n核心：%s\n域名：%s\n端口：%s\nUUID：%s\nWS 路径：%s\n' \
        "$VERSION" "$DOMAIN" "$PORT" "$UUID" "$WS_PATH"
    printf '\n导入链接（含凭据，请妥善保管）：\nvless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s&alpn=http%%2F1.1#vls-TLS\n\n' \
        "$UUID" "$DOMAIN" "$PORT" "$DOMAIN" "$DOMAIN" "$encoded"
}

install_node() {
    [[ ! -f $CONF ]] || die '已经安装。请使用修改端口或域名菜单。'
    say '请提前将域名 A 记录指向本机 IPv4，并放行 TCP 80 及节点端口。'
    say '此精简版节点监听 IPv4；不要设置指向本机的 AAAA 节点记录。'
    say "继续安装将使用 Let's Encrypt 服务并接受其服务条款：https://letsencrypt.org/repository/"
    local answer
    read -r -p '继续安装？[y/N]：' answer
    [[ $answer == y || $answer == Y ]] || return 0
    DOMAIN=''; DOMAIN_PROMPT=域名; PORT=443
    ask_domain
    ask_port
    dependencies
    port_free "$PORT"
    port_free 80
    install -d -m 700 "$BASE"
    download_core
    issue_cert
    UUID=$("$BIN" uuid)
    WS_PATH=/$(openssl rand -hex 12)
    if [[ $(readlink -f -- "${BASH_SOURCE[0]}") != "$MANAGER" ]]; then
        install -m 700 -- "${BASH_SOURCE[0]}" "$MANAGER"
    fi
    write_units
    apply_config
    systemctl enable "$SERVICE"
    systemctl enable --now vls-renew.timer
    show_link
    say '以后运行 sudo vls 打开菜单。请长期保持公网 TCP 80 可达且空闲，以便续期。'
}

install_reality() {
    [[ ! -f $CONF ]] || die 'REALITY 已经安装。请使用修改菜单。'
    say '安装 VLESS + TCP + REALITY + Vision，不申请证书，不要求 TCP 80 空闲。'
    say '连接地址是本服务器公网 IPv4 或解析到本机的域名。'
    say '目标域名是支持 TLS 1.3、HTTP/2 的网站；不需要归你所有，也不要解析到本节点。'
    dependencies
    ADDRESS=''; DOMAIN=''; DOMAIN_PROMPT='REALITY 目标域名/SNI'; PORT=443
    ask_address
    ask_port
    ask_domain
    port_free "$PORT"
    check_reality_target
    install -d -m 700 "$BASE"
    download_core
    local keys
    keys=$("$BIN" x25519)
    PRIVATE_KEY=$(awk '/^PrivateKey:/ {print $2}' <<< "$keys")
    [[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || die '生成 REALITY 私钥失败。'
    reality_public_key
    SHORT_ID=$(openssl rand -hex 8)
    UUID=$("$BIN" uuid)
    if [[ $(readlink -f -- "${BASH_SOURCE[0]}") != "$MANAGER" ]]; then
        install -m 700 -- "${BASH_SOURCE[0]}" "$MANAGER"
    fi
    write_units
    apply_config
    systemctl enable "$SERVICE"
    show_link
    say '以后运行 sudo vls 打开菜单。请放行节点 TCP 端口。'
}

change_port() {
    load_config
    local old=$PORT
    ask_port
    [[ $PORT != "$old" ]] || { say '端口未变化。'; return; }
    port_free "$PORT"
    apply_config
    show_link
    say "请放行新的 TCP $PORT 端口，并在客户端重新导入链接。"
}

change_domain() {
    load_config
    local old=$DOMAIN
    DOMAIN_PROMPT=域名
    if [[ $MODE == reality ]]; then DOMAIN_PROMPT='REALITY 目标域名/SNI'; fi
    ask_domain
    [[ $DOMAIN != "$old" ]] || { say '域名未变化。'; return; }
    if [[ $MODE == reality ]]; then check_reality_target; else issue_cert; fi
    apply_config
    show_link
    say '请在客户端重新导入链接。'
    if [[ $MODE == ws ]]; then say '旧证书保留，但定时任务只续期当前域名。'; fi
}

change_address() {
    [[ $MODE == reality ]] || die 'WS TLS 的连接地址随域名变化，请使用修改域名菜单。'
    load_config
    ask_address
    apply_config
    show_link
}

renew_cert() {
    if [[ $MODE == reality ]]; then say 'REALITY 无需申请或续期证书。'; return; fi
    load_config
    certbot_cmd renew --cert-name "$DOMAIN" --non-interactive \
        --deploy-hook "systemctl try-restart $SERVICE"
}

main() {
    [[ $EUID -eq 0 ]] || die '请以 root 运行，例如 sudo bash vls.sh。'
    [[ -d /run/systemd/system ]] || die '需要以 systemd 启动的 Debian/Ubuntu 服务器。'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ $ID == debian || $ID == ubuntu ]] || die '此精简版仅支持 Debian/Ubuntu。'
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    exec 9>/run/lock/vls.lock
    WORK=$(mktemp -d /tmp/vls.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ ${1:-} == --renew ]]; then
        flock -w 5 9 || die '另一个管理任务正在运行，本次续期检查未执行。'
        renew_cert
        return
    fi
    [[ $# -eq 0 ]] || die '仅支持交互运行或 --renew。'
    local choice
    while true; do
        printf '\n=== VLESS WS TLS / REALITY | Xray-core %s ===\n' "$VERSION"
        printf '1. 安装 VLESS WS TLS\n2. 安装 VLESS REALITY（TCP + Vision）\n3. 修改端口\n4. 修改域名 / REALITY 目标域名\n5. 查看节点链接\n6. 查看运行状态\n7. 重启服务\n8. 检查 WS TLS 证书续期\n9. 查看最近日志\n10. 修改 REALITY 连接地址\n0. 退出\n'
        read -r -p '请选择：' choice
        # Do not hold the lock while an idle menu waits for user input.
        flock -w 5 9 || die '另一个管理或续期任务正在运行，请稍后再试。'
        case $choice in
            1) select_mode ws; install_node ;;
            2) select_mode reality; install_reality ;;
            3) choose_node; change_port ;;
            4) choose_node; change_domain ;;
            5) choose_node; show_link ;;
            6) choose_node; systemctl --no-pager --full status "$SERVICE" || true ;;
            7) choose_node; load_config; "$BIN" run -test -config "$CONF"; systemctl restart "$SERVICE"; healthcheck ;;
            8) select_mode ws; renew_cert ;;
            9) choose_node; journalctl -u "$SERVICE" -n 60 --no-pager ;;
            10) select_mode reality; change_address ;;
            0) return ;;
            *) say '无效选项。' ;;
        esac
        flock -u 9
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
