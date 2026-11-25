# LinuxScript

一个基于 iptables 的 Linux 端口转发脚本：把本机的某个端口转发到远程 `IP:端口`，**同时转发 TCP 和 UDP**，并附带"默认拒绝入站"的简易防火墙。

## 特性

- 一条命令添加转发：`本地端口 → 远程IP:远程端口`
- 每条转发同时覆盖 **TCP + UDP**
- 支持添加多条转发，同一本地端口再次添加会覆盖旧目标
- 远程地址可填 IPv4，也可填域名（添加时解析一次）
- 内核 DNAT 转发，性能高，不依赖用户态代理进程
- 防火墙：入站默认拒绝、出站全部放行，可手动放行端口 / 端口范围
- 安装时自动检测并放行当前 SSH 端口，避免把自己锁在门外
- 规则写入配置文件，由 systemd 服务在开机时自动恢复
- 自定义 iptables 链，不污染已有规则，卸载干净

## 环境要求

- Linux（Debian / Ubuntu / CentOS / RHEL 等，需要 `bash`）
- root 权限
- `iptables`（缺失时脚本会尝试用 apt / dnf / yum 安装）
- systemd（可选，没有则重启后需手动执行 `apply`）

## 快速开始

### 1. 下载

```bash
curl -fsSL -o forward_port.sh \
  https://raw.githubusercontent.com/LeiiY/LinuxScript/main/forward_port.sh
```

或使用 wget：

```bash
wget -O forward_port.sh \
  https://raw.githubusercontent.com/LeiiY/LinuxScript/main/forward_port.sh
```

> 请先下载为文件再执行，不要使用 `curl ... | bash`。脚本需要把自己复制到 `/usr/local/sbin/` 以配置开机自启，管道方式下无法完成。

### 2. 添加转发

```bash
sudo bash forward_port.sh <本地端口> <远程IP> <远程端口>
```

示例：把本机 443 转发到 `1.1.1.1:443`

```bash
sudo bash forward_port.sh 443 1.1.1.1 443
```

首次执行会自动完成：安装依赖、开启内核转发、放行 SSH 端口、启用防火墙、配置开机自启。

## 命令一览

| 命令 | 说明 |
|---|---|
| `bash forward_port.sh <本地端口> <远程IP> <远程端口>` | 添加 / 更新一条转发（TCP+UDP） |
| `bash forward_port.sh del <本地端口>` | 删除一条转发 |
| `bash forward_port.sh list` | 列出转发规则和已放行端口 |
| `bash forward_port.sh status` | 查看内核转发、iptables 规则和服务状态 |
| `bash forward_port.sh allow <tcp\|udp> <端口>` | 放行入站端口，支持范围如 `8000-8100` |
| `bash forward_port.sh deny <tcp\|udp> <端口>` | 撤销放行 |
| `bash forward_port.sh install` | 仅安装防火墙和开机自启（不添加转发） |
| `bash forward_port.sh uninstall` | 卸载全部规则、服务和配置，恢复默认放行 |

以上命令均需 root 权限。

## 使用示例

```bash
# 多条转发
sudo bash forward_port.sh 443  1.1.1.1 443
sudo bash forward_port.sh 8443 1.2.3.4 443

# 使用域名（添加时解析为 IP 并保存）
sudo bash forward_port.sh 9000 example.com 9000

# 删除某条转发
sudo bash forward_port.sh del 8443

# 放行入站端口
sudo bash forward_port.sh allow tcp 8080
sudo bash forward_port.sh allow udp 53
sudo bash forward_port.sh allow tcp 8000-8100

# 撤销放行
sudo bash forward_port.sh deny tcp 8080

# 查看当前状态
sudo bash forward_port.sh list
sudo bash forward_port.sh status
```

## 工作原理

对每条转发，脚本会为 TCP 和 UDP 各生成以下 iptables 规则（以 `443 → 1.1.1.1:443` 为例）：

| 表 / 链 | 作用 |
|---|---|
| `nat` / `PREROUTING` | 外部访问本机 443 时，DNAT 到 `1.1.1.1:443` |
| `nat` / `OUTPUT` | 本机自己访问 `127.0.0.1:443` 时同样转发 |
| `nat` / `POSTROUTING` | `MASQUERADE`，让回包能原路返回 |
| `filter` / `FORWARD` | 放行去往目标地址的转发流量 |

所有规则都放在脚本自建的链里，主链仅插入一条跳转：

| 链名 | 用途 |
|---|---|
| `FW443_PRE` / `FW443_OUT` / `FW443_POST` | nat 表的 DNAT 与 MASQUERADE |
| `FW443_FWD` | 转发放行 |
| `FW443_IN` | 入站放行（lo、已建立连接、ICMP、手动放行端口） |

流量路径：

```
客户端 → 本机:本地端口 → [PREROUTING: DNAT] → [FORWARD] → [POSTROUTING: MASQUERADE] → 远程IP:远程端口
```

转发流量走 FORWARD 链，不经过 INPUT，因此不受"入站默认拒绝"影响。

## 防火墙策略

- `INPUT`：默认 `DROP`
  - 放行：本地回环、已建立 / 相关连接、ICMP ping、手动放行的端口
  - IPv6 额外放行 ICMPv6（邻居发现需要）
- `FORWARD`：默认 `DROP`，仅放行脚本添加的转发目标和已建立连接
- `OUTPUT`：全部放行

安装时会自动检测 sshd 的监听端口和 `/etc/ssh/sshd_config` 中的 `Port`，并放行对应 TCP 端口。如需关闭 SSH 放行：`deny tcp <ssh端口>`，请先确认有 VNC 或控制台等其它登录方式。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/etc/forward443/forwards.conf` | 转发记录，每行 `本地端口 远程IP 远程端口` |
| `/etc/forward443/ports.conf` | 手动放行的入站端口，每行 `协议 端口` |
| `/usr/local/sbin/forward443.sh` | 安装后的脚本副本，供开机服务调用 |
| `/etc/systemd/system/forward443.service` | 开机自启服务（oneshot，执行 `apply`） |
| `/etc/sysctl.d/99-forward443.conf` | 持久化 `net.ipv4.ip_forward = 1` |

## 验证转发是否生效

```bash
# 查看转发记录
sudo bash forward_port.sh list

# 查看规则和命中计数（packets 增长说明有流量）
sudo iptables -t nat -L FW443_PRE -n -v
sudo iptables -L FW443_FWD -n -v

# 确认内核转发已开启（应为 1）
sysctl net.ipv4.ip_forward

# 查看连接跟踪（需安装 conntrack 工具）
sudo conntrack -L -p tcp --dport 443
sudo conntrack -L -p udp --dport 443
```

## 卸载

```bash
sudo bash forward_port.sh uninstall
```

卸载会移除所有自定义链、systemd 服务、sysctl 配置和 `/etc/forward443` 目录，并把 `INPUT / FORWARD / OUTPUT` 默认策略恢复为 `ACCEPT`。

## 注意事项

- **云服务器安全组**：阿里云、腾讯云等需要在安全组中放行本地端口的入方向，TCP 和 UDP 要分别配置。
- **SSH 端口不能作为转发的本地端口**：脚本会拒绝，避免转走后无法登录。
- **目标端看到的来源 IP 是本机**：因为使用了 `MASQUERADE`，目标服务无法获取真实客户端 IP。
- **域名只在添加时解析一次**：保存的是解析出的 IP，目标 IP 变化后需重新执行添加命令。
- **仅支持 IPv4 转发目标**：IPv6 只配置了入站防火墙规则，没有 IPv6 转发。
- **UDP 会话超时**：iptables 用 conntrack 跟踪 UDP，长时间无流量的会话会被清理，之后会自动重新建立。
- **与其它防火墙共存**：如果机器上同时有 Docker、ufw、firewalld，它们也会修改 iptables 或 FORWARD 默认策略，可能与本脚本冲突，建议只保留一套防火墙管理方式。
- **不要和 nftables / nginx 中转同时转发同一端口**：DNAT 在 PREROUTING 阶段先改写数据包，其它程序会收不到流量。
- **建议先在测试机验证**：脚本会修改防火墙默认策略，操作前请确认有备用登录方式。

## 常见问题

**转发配置了但连不上？**

1. 确认云安全组已放行本地端口（TCP/UDP）
2. 确认 `sysctl net.ipv4.ip_forward` 输出为 `1`
3. 查看 `iptables -t nat -L FW443_PRE -n -v` 的计数是否增长
4. 确认目标服务器本身开放了对应端口，且没有只允许特定来源 IP

**重启后规则丢失？**

确认服务已启用：`systemctl status forward443.service`。没有 systemd 的系统需要在开机脚本中手动执行 `/usr/local/sbin/forward443.sh apply`。

**如何只转发 TCP 或只转发 UDP？**

当前每条转发固定为 TCP+UDP，没有协议选项。需要区分时可修改脚本 `apply_forward` 中的 `for p in tcp udp` 循环。

## 免责声明

本脚本会修改系统防火墙的默认策略和内核转发设置，请在了解其行为后使用，并确保有备用的服务器登录方式。因使用本脚本造成的任何后果由使用者自行承担。
