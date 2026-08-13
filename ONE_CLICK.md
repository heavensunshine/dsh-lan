# 一键配置 / One-click setup

> 状态：**Draft / 尚未实机复核**。本页先把“局域网 DSH + Windows 文件 MCP”整合为一套可执行目标；后续实测后再把版本、参数和自动化脚本标记为稳定。

## 目标

一套配置同时覆盖：

1. PVE/Linux 上的 DeepSeek Harness 保持监听 `127.0.0.1:3080`；
2. Nginx 提供局域网 HTTPS、Basic Auth、WebSocket 反代；
3. Windows 上运行 Filesystem MCP，只开放指定工程目录；
4. `mcp-proxy` 把 Filesystem MCP 的 stdio 转成 Streamable HTTP；
5. Windows Firewall 只允许 PVE 主机访问 MCP 端口；
6. DSH 通过 `@deepseek-ai/dsh-mcp-client` 加载 Windows 文件工具。

```text
Windows browser
    |
    | HTTPS + Basic Auth
    v
Nginx @ PVE
    |
    v
DSH 127.0.0.1:3080
    |
    | Streamable HTTP + X-API-Key
    v
mcp-proxy @ Windows
    |
    | stdio
    v
Filesystem MCP
    |
    v
D:\project
```

## 为什么需要“两台机器各一条命令”

PVE 和 Windows 是两个独立操作系统，因此无法真正由一条本地命令同时修改两台机器。这里把“一键”定义为：

- **Windows 端一条 PowerShell 命令**：安装/配置 Filesystem MCP + mcp-proxy + 防火墙；
- **PVE 端一条 Bash 命令**：配置 Nginx/HTTPS/Basic Auth，并生成 DSH MCP overlay；
- 两端共享同一个 MCP API key。

## 计划中的 Windows 一键入口

目标调用形式：

```powershell
pwsh -File .\scripts\setup-windows-files-mcp.ps1 `
  -AllowedPath 'D:\RM3100' `
  -PveIp '192.168.50.3' `
  -Port 8082
```

脚本计划完成：

- 检查 Node/npm；
- 安装 `@modelcontextprotocol/server-filesystem`；
- 安装 `mcp-proxy`；
- 自动生成强随机 `X-API-Key`；
- Filesystem MCP 只允许 `-AllowedPath`；
- 创建启动脚本/计划任务；
- 创建 Windows Firewall 入站规则，仅允许 `-PveIp` 访问 `8082`；
- 输出 Windows LAN IP、MCP URL 和 API key，供 PVE 端使用。

计划中的代理命令基于当前 mcp-proxy CLI：

```text
mcp-proxy --port 8082 --apiKey <secret> -- <filesystem-server-command>
```

Streamable HTTP endpoint 为：

```text
http://WINDOWS_IP:8082/mcp
```

> 该 MCP hop 在第一版计划中使用 **trusted LAN/VPN + API key + Windows Firewall IP allowlist**。后续实测阶段再决定是否为 Windows MCP 单独增加 TLS。

## 计划中的 PVE 一键入口

目标调用形式：

```bash
sudo bash ./scripts/setup-pve.sh \
  --host-ip 192.168.50.3 \
  --lan-cidr 192.168.50.0/24 \
  --windows-mcp-ip 192.168.50.20 \
  --windows-mcp-port 8082 \
  --mcp-api-key '<Windows 脚本输出的 key>'
```

脚本计划完成：

- 安装/检查 Nginx、`apache2-utils`、OpenSSL；
- 保持 Harness 本体只监听 `127.0.0.1:3080`；
- 自动生成局域网本地 CA 和 PVE HTTPS 证书；
- 自动生成或设置 Nginx Basic Auth；
- Nginx 只允许指定 LAN CIDR；
- 配置 WebSocket reverse proxy；
- 生成 DSH MCP Cordis overlay；
- 可选创建 systemd 服务，让 DSH 开机启动；
- 输出需要导入 Windows 的 CA 证书路径。

## DSH MCP overlay

上游 DSH 的 MCP Client 支持 `streamable-http`。目标生成如下 overlay：

```yaml
- insert:
    - id: mcp-windows-files
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: windows-files
        transport: streamable-http
        url: http://192.168.50.20:8082/mcp
        headers:
          X-API-Key: '<generated-secret>'
        toolCallTimeoutMs: 60000
        failOnStartupError: false
        reconnect:
          enabled: true
          initialDelayMs: 500
          maxDelayMs: 30000
          maxAttempts: 10
```

启动时可使用：

```bash
npx @deepseek-ai/dsh web --patch /etc/dsh-lan/windows-files.cordis.yml
```

也可以在实测稳定后，把该 `insert` 合并到 `$DSH_HOME/cordis.patch.yml`。

## Nginx 目标配置

```nginx
server {
    listen 8081 ssl;
    server_name 192.168.50.3;

    ssl_certificate     /etc/dsh-lan/tls/dsh-lan.crt;
    ssl_certificate_key /etc/dsh-lan/tls/dsh-lan.key;

    allow 192.168.50.0/24;
    deny all;

    auth_basic "DeepSeek Harness";
    auth_basic_user_file /etc/dsh-lan/htpasswd;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;

        proxy_set_header Host 127.0.0.1:3080;
        proxy_set_header Origin "";
        proxy_set_header Authorization "";

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

## 不能自动完成的最后一步

浏览器所在 Windows 必须信任 PVE 一键脚本生成的本地 CA。计划保留一个明确的手动步骤：

```powershell
scp root@192.168.50.3:/etc/dsh-lan/tls/dsh-lan-ca.crt .
certutil -addstore -f ROOT .\dsh-lan-ca.crt
```

之后浏览器访问：

```text
https://192.168.50.3:8081
```

## 安全边界

- Harness 不直接监听 LAN；
- Nginx 是远程 Web UI 的认证边界；
- Windows Filesystem MCP 只开放明确工程目录；
- MCP endpoint 必须使用强随机 API key；
- Windows Firewall 只允许 PVE IP；
- Web UI 和 MCP endpoint 都不应暴露到公网；
- Basic Auth 不是细粒度多用户权限系统；
- MCP 文件工具并不会让 Windows 目录变成 DSH 原生 Workspace。

## 实测后再标记 Stable

- [ ] PVE 一键脚本
- [ ] Windows MCP 一键脚本
- [ ] Nginx HTTPS / Basic Auth
- [ ] 浏览器 secure-context
- [ ] Filesystem MCP read/write/search
- [ ] Windows Firewall PVE-only
- [ ] DSH MCP discovery
- [ ] 路径沙箱逃逸测试
- [ ] Windows 睡眠/断线恢复
- [ ] systemd / Scheduled Task 自启动

## 上游依据

- DSH MCP Client：`@deepseek-ai/dsh-mcp-client`
- DSH MCP transport：`stdio` / `streamable-http`
- DSH overlay 可通过 `dsh web --patch <path>` 加载
- Filesystem MCP：`@modelcontextprotocol/server-filesystem`
- mcp-proxy：stdio -> Streamable HTTP，支持 `--apiKey` / `X-API-Key`
