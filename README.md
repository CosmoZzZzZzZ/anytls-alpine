# AnyTLS Manager for Alpine Linux

[English](#english) | [中文](#中文)

An interactive AnyTLS installation and management script designed for Alpine Linux and OpenRC, with selectable IPv4 or IPv6 listening modes.

> This repository is an Alpine/OpenRC community installer. The AnyTLS implementation is provided by the official [`anytls/anytls-go`](https://github.com/anytls/anytls-go) project.

---

## English

### Features

- Installs the latest official AnyTLS server release.
- Supports Alpine Linux with the `apk` package manager.
- Uses OpenRC and `supervise-daemon` instead of systemd.
- Supports `amd64` and `arm64`.
- Selectable IPv4 or IPv6 listening mode.
- Generates a random port and password.
- Displays a client import URI automatically.
- Supports reinstall, update, status, logs, port changes, password changes, network-mode changes, and uninstall.
- Preserves the existing configuration by default during reinstall.
- Restores the previous binary if an AnyTLS update fails to start.
- Does not disable the system firewall.

### Requirements

- Alpine Linux with OpenRC running as the service manager.
- Root access.
- `amd64` or `arm64` architecture.
- A public inbound IPv4 address, or a globally reachable IPv6 address.
- An AnyTLS-compatible client.

This script is intended for a normal Alpine VPS or virtual machine. A minimal Docker container normally does not run OpenRC as PID 1, so the service-management part of the script will refuse to continue in that environment.

### Quick installation

Run the following command as `root`:

```sh
apk add --no-cache bash curl ca-certificates && \
bash <(curl -fsSL 'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh')
```

For a safer inspect-before-running workflow:

```sh
curl -fsSL \
  'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh' \
  -o /tmp/anytls-alpine.sh

less /tmp/anytls-alpine.sh
bash /tmp/anytls-alpine.sh
```

### Installation configuration

Select the following menu entry:

```text
1. Install/Reinstall AnyTLS
```

The installer will ask for a network mode:

```text
1. IPv4 — listen on 0.0.0.0
2. IPv6 — listen on [::]
```

#### IPv4 mode

Choose IPv4 only when the server has an inbound-reachable public IPv4 address or the provider has configured IPv4 port forwarding.

An IPv4 address returned by an external IP-check service may be only a shared outbound NAT address. It does not guarantee that inbound IPv4 connections can reach the server.

Example client URI:

```text
anytls://PASSWORD@203.0.113.10:46666/?insecure=1#AnyTLS-Alpine
```

#### IPv6 mode

Choose IPv6 when the server has a globally reachable IPv6 address. The client network must also support IPv6.

The script listens on `[::]` and automatically places the IPv6 address inside square brackets in the client URI:

```text
anytls://PASSWORD@[2001:db8::1234]:46666/?insecure=1#AnyTLS-Alpine
```

Check the server's public IPv6 address with:

```sh
curl -6fsS https://api64.ipify.org
echo
```

Check locally assigned global IPv6 addresses with:

```sh
ip -6 address show scope global
```

If the provider uses IPv6 NAT instead of assigning a directly reachable global IPv6 address, configure the required port mapping in the provider control panel.

#### Port selection

Enter a TCP port from `1` to `65535`, or press Enter/wait 15 seconds to generate a random port. Make sure the chosen TCP port is allowed by both:

- The VPS provider's security group or firewall.
- The firewall inside Alpine Linux.

The script deliberately does not disable your firewall.

#### Password and TLS

The script generates a random password. The reference AnyTLS server generates a self-signed TLS certificate at runtime, so the client must enable one of the following equivalent settings:

```text
Allow insecure: enabled
Skip certificate verification: true
```

Keep the generated password private. It is stored in `/etc/conf.d/anytls` with file mode `0600`.

### Switching between IPv4 and IPv6

Run the manager again:

```sh
bash <(curl -fsSL 'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh')
```

Then select:

```text
6. Change IPv4/IPv6 mode
```

Choose the new mode. The current port and password will be preserved. The service will be restarted automatically, and the new client URI will be displayed.

### Menu

| Number | Action |
|---:|---|
| 1 | Install or reinstall AnyTLS |
| 2 | Update the AnyTLS server binary |
| 3 | Show the client configuration and import URI |
| 4 | Change the listening port |
| 5 | Generate and apply a new password |
| 6 | Change IPv4/IPv6 mode |
| 7 | Show the OpenRC service status |
| 8 | Show recent logs |
| 9 | Uninstall AnyTLS |
| 0 | Exit |

### Command-line actions

After downloading the script, actions can also be called directly:

```sh
bash anytls-alpine.sh install
bash anytls-alpine.sh update
bash anytls-alpine.sh config
bash anytls-alpine.sh status
bash anytls-alpine.sh logs
bash anytls-alpine.sh port
bash anytls-alpine.sh password
bash anytls-alpine.sh network
bash anytls-alpine.sh uninstall
```

### Service management

```sh
# Status
rc-service anytls status

# Restart
rc-service anytls restart

# Stop
rc-service anytls stop

# Start
rc-service anytls start

# Verify the listening port
ss -lntp

# Recent logs
tail -n 100 /var/log/anytls.log
tail -n 100 /var/log/anytls.err
```

### Files

| Path | Purpose |
|---|---|
| `/etc/AnyTLS/server` | AnyTLS server binary |
| `/etc/AnyTLS/version` | Installed AnyTLS version |
| `/etc/AnyTLS/config.yaml` | Human-readable configuration metadata |
| `/etc/conf.d/anytls` | OpenRC port, password, and network-mode configuration |
| `/etc/init.d/anytls` | OpenRC service definition |
| `/var/log/anytls.log` | Standard output log |
| `/var/log/anytls.err` | Error log |

### Troubleshooting

#### The displayed IPv4 address is outbound-only

If the provider says that IPv4 is outbound-only, select IPv6 mode. A shared IPv4 egress address cannot normally receive incoming AnyTLS connections.

#### The service is not listening

```sh
rc-service anytls status
tail -n 100 /var/log/anytls.err
ss -lntp
```

IPv4 mode should listen on `0.0.0.0:PORT`. IPv6 mode should listen on `[::]:PORT`; depending on the `ss` version, it may be displayed as `*:PORT`.

#### The service is running but the client cannot connect

Check all of the following:

1. The client is using the address family selected during installation.
2. The client network supports IPv6 when IPv6 mode is selected.
3. The TCP port is allowed by the provider security group.
4. The TCP port is allowed by the Alpine firewall.
5. Any required NAT port mapping has been configured.
6. The client has enabled skip-certificate-verification/insecure mode.

#### OpenRC is not running

If `/run/openrc/softlevel` is missing, OpenRC is not managing the current system. This is common in Docker containers. Use a container-native foreground process or another supervisor instead of this script's OpenRC service installation.

### Updating and uninstalling

Run the manager and select option `2` to update the AnyTLS binary. The script downloads the latest official release and restores the previous binary if the new version fails to start.

Select option `9` to stop the service and remove the binary, configuration, OpenRC service, and logs.

### Security notes

- Review remote scripts before piping them into Bash.
- Do not publish `/etc/conf.d/anytls`; it contains the server password.
- Restrict the listening port with provider and local firewall rules when appropriate.
- The generated client URI contains the password and should be treated as a secret.
- `insecure=1` disables certificate verification. Anyone who obtains the password and URI can use the service.

---

## 中文

### 功能

- 自动下载并安装 AnyTLS 官方最新服务端。
- 使用 Alpine Linux 的 `apk` 包管理器。
- 使用 OpenRC 和 `supervise-daemon`，不依赖 systemd。
- 支持 `amd64` 和 `arm64`。
- 安装时可以选择 IPv4 或 IPv6 监听模式。
- 自动生成随机端口和密码。
- 自动显示客户端导入链接。
- 支持重装、更新、查看配置、查看状态、查看日志、更改端口、更改密码、更改网络模式及卸载。
- 重装时默认保留现有配置。
- 更新后的 AnyTLS 如果无法启动，会恢复旧版二进制文件。
- 不会自动关闭系统防火墙。

### 系统要求

- 使用 OpenRC 作为服务管理器的 Alpine Linux。
- `root` 权限。
- `amd64` 或 `arm64` 架构。
- 可从公网连入的 IPv4，或者全局可达的 IPv6 地址。
- 支持 AnyTLS 的客户端。

脚本适用于正常运行 OpenRC 的 Alpine VPS 或虚拟机。精简 Docker 容器通常没有让 OpenRC 作为 PID 1 运行，因此脚本会拒绝在这种环境中安装 OpenRC 服务。

### 一键安装

使用 `root` 执行：

```sh
apk add --no-cache bash curl ca-certificates && \
bash <(curl -fsSL 'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh')
```

如果希望先检查脚本再执行：

```sh
curl -fsSL \
  'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh' \
  -o /tmp/anytls-alpine.sh

less /tmp/anytls-alpine.sh
bash /tmp/anytls-alpine.sh
```

### 安装配置方法

进入脚本后选择：

```text
1. 安装/重装 AnyTLS
```

脚本会要求选择网络模式：

```text
1. IPv4——监听 0.0.0.0
2. IPv6——监听 [::]
```

#### IPv4 模式

只有服务器拥有可从公网连入的 IPv4，或者服务商已经提供 IPv4 端口映射时，才应选择 IPv4。

外部 IP 查询网站显示的 IPv4 可能只是多人共享的 NAT 出口地址，并不代表外部连接可以通过该地址进入服务器。

IPv4 客户端链接示例：

```text
anytls://密码@203.0.113.10:46666/?insecure=1#AnyTLS-Alpine
```

#### IPv6 模式

服务器具有全局可达的 IPv6 地址时选择 IPv6。客户端所在网络也必须支持 IPv6。

脚本会监听 `[::]`，并自动在导入链接中给 IPv6 地址加上方括号：

```text
anytls://密码@[2001:db8::1234]:46666/?insecure=1#AnyTLS-Alpine
```

查询服务器公网 IPv6：

```sh
curl -6fsS https://api64.ipify.org
echo
```

查询系统分配到的全局 IPv6 地址：

```sh
ip -6 address show scope global
```

如果服务商提供的是 IPv6 NAT，而不是直接分配全局可达 IPv6，需要在服务商控制面板配置相应端口映射。

#### 端口配置

输入 `1` 到 `65535` 的 TCP 端口；也可以直接按回车或等待 15 秒，由脚本随机生成端口。

必须同时在以下位置允许所选 TCP 端口：

- VPS 服务商的安全组或防火墙。
- Alpine Linux 系统内部的防火墙。

脚本不会直接关闭整个防火墙。

#### 密码与 TLS

脚本会生成随机密码。AnyTLS 参考服务端会在运行时生成自签名 TLS 证书，因此客户端必须启用以下同类设置之一：

```text
允许不安全：启用
跳过证书验证：true
```

请勿公开生成的密码。密码保存在 `/etc/conf.d/anytls`，文件权限为 `0600`。

### 切换 IPv4/IPv6

再次运行管理脚本：

```sh
bash <(curl -fsSL 'https://raw.githubusercontent.com/CosmoZzZzZzZ/anytls-alpine/refs/heads/main/anytls-alpine.sh')
```

选择：

```text
6. 更改 IPv4/IPv6 模式
```

选择新的网络模式即可。当前端口和密码会保持不变，服务会自动重启并显示新的客户端导入链接。

### 菜单说明

| 编号 | 功能 |
|---:|---|
| 1 | 安装或重装 AnyTLS |
| 2 | 更新 AnyTLS 服务端二进制文件 |
| 3 | 查看客户端配置和导入链接 |
| 4 | 更改监听端口 |
| 5 | 随机生成并更换密码 |
| 6 | 切换 IPv4/IPv6 模式 |
| 7 | 查看 OpenRC 服务状态 |
| 8 | 查看最近日志 |
| 9 | 卸载 AnyTLS |
| 0 | 退出 |

### 命令行操作

下载脚本后，也可以直接指定操作：

```sh
bash anytls-alpine.sh install
bash anytls-alpine.sh update
bash anytls-alpine.sh config
bash anytls-alpine.sh status
bash anytls-alpine.sh logs
bash anytls-alpine.sh port
bash anytls-alpine.sh password
bash anytls-alpine.sh network
bash anytls-alpine.sh uninstall
```

### 服务管理

```sh
# 查看状态
rc-service anytls status

# 重启服务
rc-service anytls restart

# 停止服务
rc-service anytls stop

# 启动服务
rc-service anytls start

# 查看监听端口
ss -lntp

# 查看最近日志
tail -n 100 /var/log/anytls.log
tail -n 100 /var/log/anytls.err
```

### 文件位置

| 路径 | 用途 |
|---|---|
| `/etc/AnyTLS/server` | AnyTLS 服务端二进制文件 |
| `/etc/AnyTLS/version` | 已安装的 AnyTLS 版本 |
| `/etc/AnyTLS/config.yaml` | 便于阅读的配置记录 |
| `/etc/conf.d/anytls` | OpenRC 使用的端口、密码及网络模式配置 |
| `/etc/init.d/anytls` | OpenRC 服务定义 |
| `/var/log/anytls.log` | 标准输出日志 |
| `/var/log/anytls.err` | 错误日志 |

### 故障排查

#### 显示的 IPv4 只是出口地址

如果服务商注明 IPv4 仅供出站使用，请选择 IPv6 模式。共享的 IPv4 NAT 出口地址通常无法接收 AnyTLS 入站连接。

#### 服务没有监听端口

```sh
rc-service anytls status
tail -n 100 /var/log/anytls.err
ss -lntp
```

IPv4 模式应监听 `0.0.0.0:端口`。IPv6 模式应监听 `[::]:端口`；部分 `ss` 版本可能显示为 `*:端口`。

#### 服务运行中但客户端无法连接

依次检查：

1. 客户端使用的地址类型是否与安装时选择的一致。
2. 选择 IPv6 时，客户端网络是否支持 IPv6。
3. 服务商安全组是否允许相应 TCP 端口。
4. Alpine 防火墙是否允许相应 TCP 端口。
5. 如果使用 NAT，是否已经设置端口映射。
6. 客户端是否启用了跳过证书验证/允许不安全。

#### OpenRC 没有运行

如果系统中不存在 `/run/openrc/softlevel`，说明 OpenRC 当前没有管理该系统。这种情况常见于 Docker 容器。请改用容器前台进程或其他进程管理器，而不是使用本脚本的 OpenRC 服务安装功能。

### 更新与卸载

运行管理脚本并选择 `2` 可以更新 AnyTLS。脚本会下载官方最新版本；如果新版本无法启动，会恢复旧版二进制文件。

选择 `9` 可以停止服务，并删除程序、配置、OpenRC 服务及日志。

### 安全说明

- 使用管道直接执行远程脚本前，建议先下载并检查内容。
- 不要公开 `/etc/conf.d/anytls`，其中包含服务密码。
- 根据实际需要通过服务商安全组及本机防火墙限制监听端口。
- 客户端导入链接内含密码，应视为敏感信息。
- `insecure=1` 表示不验证服务器证书；任何获得密码和链接的人都可能使用该服务。

