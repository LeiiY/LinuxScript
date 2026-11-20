#!/usr/bin/env bash
#
# forward_443.sh
# 1) 端口转发：将本机 <本地端口> 的 TCP/UDP 流量转发到 <远程IP>:<远程端口> (iptables DNAT)，支持多条
# 2) 防火墙：默认拒绝所有入站，允许所有出站；可手动放行端口
#
# 用法 (需 root):
#   sudo bash forward_443.sh <本地端口> <远程IP> <远程端口>   添加/更新一条转发 (首次使用自动完成安装)
#   sudo bash forward_443.sh 443 1.1.1.1 443          示例：本机 443 -> 1.1.1.1:443
#   sudo bash forward_443.sh del <本地端口>                   删除某条转发
#   sudo bash forward_443.sh install            # 安装：启用转发 + 防火墙 + 开机自启
#   sudo bash forward_443.sh uninstall          # 卸载：移除全部规则并恢复默认放行
#   sudo bash forward_443.sh status             # 查看状态
#   sudo bash forward_443.sh allow tcp 8080     # 放行入站 TCP 端口
#   sudo bash forward_443.sh allow udp 53       # 放行入站 UDP 端口
#   sudo bash forward_443.sh allow tcp 8000-8100  # 也支持端口范围
#   sudo bash forward_443.sh deny  tcp 8080     # 撤销之前的放行
#   sudo bash forward_443.sh list               # 列出转发规则与已放行端口
#
# 说明：
#   - 每条转发同时覆盖 TCP 和 UDP；同一本地端口再次添加会覆盖旧目标。
#   - 远程地址可填 IPv4，也可填域名 (添加时解析一次，保存的是解析出的 IP)。
#   - 入站默认 DROP；已建立连接的回包、本地回环、ICMP(ping) 会放行；出站全部放行。
#   - 安装时会自动检测并放行当前 SSH 端口，避免把自己锁在门外。
#     如需关闭：deny tcp <ssh端口>（请确认有其它登录方式）。
#   - 转发走 FORWARD 链(DNAT)，不经过 INPUT，因此不受入站默认拒绝影响。
#   - 为避免把自己锁死，禁止把本地 SSH 端口作为转发的本地端口。
#   - 转发记录在 /etc/forward443/forwards.conf，放行端口记录在 /etc/forward443/ports.conf，
#     开机由 systemd 服务重新应用。
#
set -euo pipefail

SERVICE_NAME="forward443"

SCRIPT_PATH="/usr/local/sbin/${SERVICE_NAME}.sh"
STATE_DIR="/etc/${SERVICE_NAME}"
PORTS_FILE="${STATE_DIR}/ports.conf"
FORWARDS_FILE="${STATE_DIR}/forwards.conf"   # 每行: <本地端口> <远程IP> <远程端口>
INSTALLED_MARK="${STATE_DIR}/.installed"
SYSCTL_FILE="/etc/sysctl.d/99-${SERVICE_NAME}.conf"

# 自定义链名（便于幂等重建与干净卸载）
IN_CHAIN="FW443_IN"
FWD_CHAIN="FW443_FWD"
PRE_CHAIN="FW443_PRE"
OUT_CHAIN="FW443_OUT"
POST_CHAIN="FW443_POST"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 权限运行 (例如: sudo bash $0 ${1:-install})" >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 依赖 / 内核

install_deps() {
  if need_cmd iptables; then
    return
  fi
  if need_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables
  elif need_cmd dnf; then
    dnf install -y iptables
  elif need_cmd yum; then
    yum install -y iptables
  else
    echo "未识别的包管理器，请手动安装 iptables。" >&2
    exit 1
  fi
}

enable_ip_forward() {
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  echo "net.ipv4.ip_forward = 1" > "$SYSCTL_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

# ---------------------------------------------------------------- 状态文件

ensure_state() {
  mkdir -p "$STATE_DIR"
  touch "$PORTS_FILE" "$FORWARDS_FILE"
}

# 校验单个端口 (1-65535)
valid_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# 校验 IPv4
valid_ipv4() {
  local ip="${1:-}" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
}

# 把 IP 或域名解析为 IPv4，输出 IP
resolve_ipv4() {
  local host="${1:-}" ip
  if valid_ipv4 "$host"; then
    echo "$host"
    return 0
  fi
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -n "$ip" ]] && valid_ipv4 "$ip"; then
    echo "$ip"
    return 0
  fi
  return 1
}

# 规范化并校验 "proto port"，输出 "proto port"（范围统一为 a:b）
normalize_entry() {
  local proto="${1:-}" port="${2:-}"
  proto="${proto,,}"
  if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
    echo "协议必须是 tcp 或 udp" >&2
    return 1
  fi
  port="${port//-/:}"
  if [[ "$port" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[3]:-}"
    if (( a < 1 || a > 65535 )) || { [[ -n "$b" ]] && { (( b < 1 || b > 65535 || b < a )); }; }; then
      echo "端口超出范围 (1-65535) 或范围起止顺序错误" >&2
      return 1
    fi
  else
    echo "端口格式无效: ${2:-}  (示例: 8080 或 8000-8100)" >&2
    return 1
  fi
  echo "$proto $port"
}

detect_ssh_ports() {
  {
    if need_cmd ss; then
      ss -tlnpH 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    fi
    if [[ -r /etc/ssh/sshd_config ]]; then
      awk 'tolower($1)=="port" {print $2}' /etc/ssh/sshd_config
    fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

# ---------------------------------------------------------------- 防火墙核心

# 为 iptables / ip6tables 重建入站规则
apply_filter() {
  local ipt="$1" v6="$2"

  $ipt -N "$IN_CHAIN" 2>/dev/null || true
  $ipt -F "$IN_CHAIN"
  $ipt -C INPUT -j "$IN_CHAIN" 2>/dev/null || $ipt -I INPUT 1 -j "$IN_CHAIN"

  $ipt -A "$IN_CHAIN" -i lo -j ACCEPT
  $ipt -A "$IN_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  if [[ "$v6" == "1" ]]; then
    # IPv6 邻居发现等依赖 ICMPv6，必须放行
    $ipt -A "$IN_CHAIN" -p ipv6-icmp -j ACCEPT
  else
    $ipt -A "$IN_CHAIN" -p icmp --icmp-type echo-request -j ACCEPT
  fi

  local proto port _rest
  while read -r proto port _rest; do
    if [[ -z "${proto:-}" || "$proto" == \#* ]]; then
      continue
    fi
    $ipt -A "$IN_CHAIN" -p "$proto" --dport "$port" -j ACCEPT
  done < "$PORTS_FILE"

  # 默认策略：入站/转发拒绝，出站放行
  $ipt -P INPUT DROP
  $ipt -P FORWARD DROP
  $ipt -P OUTPUT ACCEPT
}

# IPv4 转发相关规则 (nat + FORWARD)，按 forwards.conf 逐条生成
apply_forward() {
  ensure_state

  # --- nat 表：重建自定义链 ---
  local c
  for c in "$PRE_CHAIN" "$OUT_CHAIN" "$POST_CHAIN"; do
    iptables -t nat -N "$c" 2>/dev/null || true
    iptables -t nat -F "$c"
  done
  iptables -t nat -C PREROUTING  -j "$PRE_CHAIN"  2>/dev/null || iptables -t nat -I PREROUTING 1  -j "$PRE_CHAIN"
  iptables -t nat -C OUTPUT      -j "$OUT_CHAIN"  2>/dev/null || iptables -t nat -I OUTPUT 1      -j "$OUT_CHAIN"
  iptables -t nat -C POSTROUTING -j "$POST_CHAIN" 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j "$POST_CHAIN"

  # --- FORWARD 链：重建自定义链 ---
  iptables -N "$FWD_CHAIN" 2>/dev/null || true
  iptables -F "$FWD_CHAIN"
  iptables -C FORWARD -j "$FWD_CHAIN" 2>/dev/null || iptables -I FORWARD 1 -j "$FWD_CHAIN"
  iptables -A "$FWD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  local lport rip rport _rest p
  while read -r lport rip rport _rest; do
    if [[ -z "${lport:-}" || "$lport" == \#* ]]; then
      continue
    fi
    for p in tcp udp; do
      # 外部访问本机 lport -> 远程
      iptables -t nat -A "$PRE_CHAIN" -p "$p" --dport "$lport" \
        -j DNAT --to-destination "${rip}:${rport}"
      # 本机自身访问 127.0.0.1:lport -> 远程 (可选)
      iptables -t nat -A "$OUT_CHAIN" -p "$p" -o lo --dport "$lport" \
        -j DNAT --to-destination "${rip}:${rport}"
      # 回包源地址伪装
      iptables -t nat -A "$POST_CHAIN" -p "$p" -d "$rip" --dport "$rport" -j MASQUERADE
      # 放行转发流量
      iptables -A "$FWD_CHAIN" -p "$p" -d "$rip" --dport "$rport" -j ACCEPT
    done
  done < "$FORWARDS_FILE"
}

apply_firewall() {
  ensure_state
  apply_filter iptables 0
  apply_forward
  if need_cmd ip6tables; then
    apply_filter ip6tables 1 || echo "警告: IPv6 规则应用失败，已跳过。" >&2
  fi
}

# 删除某工具下的自定义链及其跳转
remove_chain() {
  local ipt="$1" table="$2" parent="$3" chain="$4"
  while $ipt -t "$table" -D "$parent" -j "$chain" 2>/dev/null; do :; done
  $ipt -t "$table" -F "$chain" 2>/dev/null || true
  $ipt -t "$table" -X "$chain" 2>/dev/null || true
}

remove_firewall() {
  remove_chain iptables nat PREROUTING  "$PRE_CHAIN"
  remove_chain iptables nat OUTPUT      "$OUT_CHAIN"
  remove_chain iptables nat POSTROUTING "$POST_CHAIN"
  remove_chain iptables filter FORWARD  "$FWD_CHAIN"
  remove_chain iptables filter INPUT    "$IN_CHAIN"
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  if need_cmd ip6tables; then
    remove_chain ip6tables filter INPUT "$IN_CHAIN"
    ip6tables -P INPUT ACCEPT 2>/dev/null || true
    ip6tables -P FORWARD ACCEPT 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- 转发管理

# 添加/更新转发: do_add <本地端口> <远程IP或域名> <远程端口>
do_add() {
  local lport="${1:-}" rhost="${2:-}" rport="${3:-}" rip sp tmp

  if ! valid_port "$lport"; then
    echo "本地端口无效: ${lport} (范围 1-65535)" >&2
    exit 1
  fi
  if ! valid_port "$rport"; then
    echo "远程端口无效: ${rport} (范围 1-65535)" >&2
    exit 1
  fi
  lport=$((10#$lport))
  rport=$((10#$rport))

  if ! rip=$(resolve_ipv4 "$rhost"); then
    echo "无法解析远程地址为 IPv4: ${rhost}" >&2
    exit 1
  fi

  # 防止把 SSH 端口转走导致失联
  for sp in $(detect_ssh_ports); do
    if [[ "$sp" == "$lport" ]]; then
      echo "拒绝：本地端口 ${lport} 是当前 SSH 端口，转发会导致无法登录。" >&2
      exit 1
    fi
  done

  ensure_state
  tmp=$(mktemp)
  # 同一本地端口只保留最新目标
  awk -v p="$lport" '$1 != p' "$FORWARDS_FILE" > "$tmp" || true
  echo "${lport} ${rip} ${rport}" >> "$tmp"
  cat "$tmp" > "$FORWARDS_FILE"
  rm -f "$tmp"

  if [[ ! -f "$INSTALLED_MARK" ]]; then
    do_install            # 首次使用：完整安装 (内部会应用规则)
  else
    install_deps
    enable_ip_forward
    apply_firewall
    sync_script
  fi

  echo "已添加转发: 本机 ${lport}/tcp,udp -> ${rip}:${rport}"
  if [[ "$rhost" != "$rip" ]]; then
    echo "(域名 ${rhost} 已解析为 ${rip}，域名变更后需重新执行本命令更新)"
  fi
}

# 删除转发: do_del <本地端口>
do_del() {
  local lport="${1:-}" tmp
  if ! valid_port "$lport"; then
    echo "本地端口无效: ${lport}" >&2
    exit 1
  fi
  lport=$((10#$lport))
  ensure_state
  if ! awk -v p="$lport" '$1 == p {f=1} END{exit !f}' "$FORWARDS_FILE"; then
    echo "未找到本地端口 ${lport} 的转发规则"
    exit 0
  fi
  tmp=$(mktemp)
  awk -v p="$lport" '$1 != p' "$FORWARDS_FILE" > "$tmp" || true
  cat "$tmp" > "$FORWARDS_FILE"
  rm -f "$tmp"
  apply_firewall
  echo "已删除转发: 本机 ${lport}"
}

# ---------------------------------------------------------------- 手动放行 / 撤销

do_allow() {
  local entry
  entry=$(normalize_entry "${1:-}" "${2:-}") || exit 1
  ensure_state
  if grep -qxF "$entry" "$PORTS_FILE"; then
    echo "已存在放行规则: $entry"
  else
    echo "$entry" >> "$PORTS_FILE"
  fi
  apply_firewall
  echo "已放行入站: ${entry% *}/${entry#* }"
}

do_deny() {
  local entry tmp
  entry=$(normalize_entry "${1:-}" "${2:-}") || exit 1
  ensure_state
  if ! grep -qxF "$entry" "$PORTS_FILE"; then
    echo "未找到放行规则: $entry"
    exit 0
  fi
  tmp=$(mktemp)
  grep -vxF "$entry" "$PORTS_FILE" > "$tmp" || true
  cat "$tmp" > "$PORTS_FILE"
  rm -f "$tmp"
  apply_firewall
  echo "已撤销放行: ${entry% *}/${entry#* }"
}

list_forwards() {
  echo "== 端口转发 (tcp+udp) =="
  if grep -qvE '^\s*(#|$)' "$FORWARDS_FILE"; then
    printf '%-10s    %s\n' "本地端口" "目标"
    grep -vE '^\s*(#|$)' "$FORWARDS_FILE" | sort -n | \
      awk '{printf "%-10s -> %s:%s\n", $1, $2, $3}'
  else
    echo "(无)"
  fi
}

do_list() {
  ensure_state
  list_forwards
  echo
  echo "== 已手动放行的入站端口 (默认其余全部拒绝) =="
  if grep -qvE '^\s*(#|$)' "$PORTS_FILE"; then
    grep -vE '^\s*(#|$)' "$PORTS_FILE" | sort -k1,1 -k2,2n
  else
    echo "(无)"
  fi
}

# ---------------------------------------------------------------- 安装 / 卸载

# 把当前脚本同步到 /usr/local/sbin，供开机服务调用
sync_script() {
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}")
  mkdir -p "$(dirname "$SCRIPT_PATH")"
  if [[ "$self" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")" ]]; then
    install -m 0755 "$self" "$SCRIPT_PATH"
  fi
}

setup_service() {
  sync_script

  if ! need_cmd systemctl; then
    echo "未检测到 systemd：规则当前已生效，但重启后需手动执行: $SCRIPT_PATH apply" >&2
    return
  fi

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Port forwarding (tcp+udp, see ${FORWARDS_FILE}) and inbound firewall
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
  echo "已配置开机自启动服务: ${SERVICE_NAME}.service"
}

do_install() {
  install_deps
  enable_ip_forward
  ensure_state

  # 自动放行 SSH 端口，防止锁死
  local sp entry
  for sp in $(detect_ssh_ports); do
    entry="tcp $sp"
    if ! grep -qxF "$entry" "$PORTS_FILE"; then
      echo "$entry" >> "$PORTS_FILE"
    fi
    echo "检测到 SSH 端口 ${sp}，已自动放行 (tcp)。"
  done

  apply_firewall
  setup_service
  touch "$INSTALLED_MARK"
  echo "防火墙已启用: 入站默认拒绝，出站全部允许。"
  echo "添加转发示例: bash $0 443 1.1.1.1 443"
  echo "手动放行示例: bash $0 allow tcp 8080"
}

do_apply() {
  enable_ip_forward
  apply_firewall
}

do_uninstall() {
  remove_firewall
  if need_cmd systemctl; then
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
  fi
  rm -f "$SYSCTL_FILE"
  rm -rf "$STATE_DIR"
  rm -f "$SCRIPT_PATH"
  echo "转发规则、防火墙规则及自启动服务已卸载，默认策略已恢复为全部放行。"
}

do_status() {
  ensure_state
  echo "== IP Forward =="
  sysctl net.ipv4.ip_forward || true
  echo
  do_list
  echo
  echo "== INPUT 链 (默认策略 + 放行规则) =="
  iptables -L INPUT -n -v
  iptables -L "$IN_CHAIN" -n -v 2>/dev/null || echo "未安装 ${IN_CHAIN} 链"
  echo
  echo "== NAT 表规则 =="
  iptables -t nat -L -n -v
  echo
  echo "== FORWARD 链 =="
  iptables -L FORWARD -n -v
  if need_cmd ip6tables; then
    echo
    echo "== IPv6 INPUT 链 =="
    ip6tables -L INPUT -n -v 2>/dev/null || true
  fi
  echo
  echo "== systemd 服务状态 =="
  systemctl status "${SERVICE_NAME}.service" --no-pager 2>/dev/null || echo "未安装该服务"
}

usage() {
  cat <<EOF
用法:
  $0 <本地端口> <远程IP> <远程端口>   添加/更新一条转发 (tcp+udp)
      例: $0 443 1.1.1.1 443
  $0 del <本地端口>                   删除一条转发

  $0 install                  安装并启用默认拒绝入站防火墙
  $0 uninstall                卸载并恢复默认放行
  $0 status                   查看状态
  $0 allow <tcp|udp> <端口>   放行入站端口 (支持 8000-8100 范围)
  $0 deny  <tcp|udp> <端口>   撤销放行
  $0 list                     列出转发规则与已放行端口
EOF
}

case "${1:-}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  apply)     do_apply ;;
  allow)
    [[ $# -eq 3 ]] || { usage; exit 1; }
    do_allow "$2" "$3"
    ;;
  deny)
    [[ $# -eq 3 ]] || { usage; exit 1; }
    do_deny "$2" "$3"
    ;;
  del|delete|remove)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    do_del "$2"
    ;;
  list)      do_list ;;
  *)
    if [[ $# -eq 3 && "$1" =~ ^[0-9]+$ ]]; then
      do_add "$1" "$2" "$3"
    else
      usage
      exit 1
    fi
    ;;
esac
