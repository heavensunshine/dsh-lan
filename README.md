# dsh-lan — 局域网版 DSH / DeepSeek Harness LAN Edition

> **非官方社区部署记录。** 本仓库不隶属于 DeepSeek，也不替代上游安全设计或官方文档。
>
> **Unofficial community deployment notes.** This repository is not affiliated with DeepSeek and does not replace upstream security design or official documentation.

**上游 / Upstream:** https://github.com/deepseek-ai/deepseek-harness

## 简介 / Introduction

**中文**

`dsh-lan` 记录把 DeepSeek Harness Web UI 安全地用于受信任局域网的实测流程：Harness 保持仅监听 `127.0.0.1`，由 Nginx 提供局域网 HTTPS 入口、Basic Auth、WebSocket 反向代理，并记录远程 Web 使用中的已知限制，包括浏览器 secure-context、`crypto.randomUUID()`、Host/Origin 信任边界，以及远程 Workspace 实际位于 Harness 主机文件系统而不是浏览器客户端文件系统。

**English**

`dsh-lan` documents a tested way to use the DeepSeek Harness Web UI on a trusted LAN: keep Harness bound to `127.0.0.1`, place Nginx in front for LAN HTTPS access, Basic Auth and WebSocket proxying, and document known remote-Web limitations such as browser secure-context requirements, `crypto.randomUUID()`, Host/Origin trust boundaries, and the fact that remote workspaces live on the Harness host filesystem rather than the browser client's filesystem.

## 快速入口 / Quick links

- **一键配置草案 / One-click setup draft:** [`ONE_CLICK.md`](ONE_CLICK.md)
- **Windows 本地文件通过 MCP:** [`docs/mcp-local-files.md`](docs/mcp-local-files.md)
- **Filesystem MCP + mcp-proxy 计划:** [`docs/official-filesystem-mcp-proxy-plan.md`](docs/official-filesystem-mcp-proxy-plan.md)
- **两种 LAN 安全模式与参考项目:** [`docs/deployment-modes-and-references.md`](docs/deployment-modes-and-references.md)

> 一键脚本目前仍属于 Draft / 未完成实机复核阶段。涉及 DSH、MCP proxy、Windows Firewall、证书和 systemd 的版本与参数，后续会按实际环境继续验证。

## 两种局域网模式 / Two LAN modes

参考现有社区实现后，本仓库明确区分两种不同的安全模型：

| 模式 | 网络入口 | 认证 | privileged RPC | 适合场景 |
|---|---|---|---|---|
| **Mode A：HTTPS reverse proxy** | Nginx → `127.0.0.1:3080` | Basic Auth | 可按可信反代策略获得更完整能力 | PVE/服务器长期运行、完整控制 |
| **Mode B：Direct LAN plugin** | DSH 直接监听 `0.0.0.0` | 通常无 | 保持上游 loopback-only 限制 | 手机临时访问、可信 Wi-Fi、状态查看 |

本仓库当前默认推荐 **Mode A**。Mode B 的优点是轻量，并可通过 `crypto.randomUUID()` polyfill 在普通 HTTP LAN 上工作，但没有登录认证时只适合完全可信的局域网。

完整比较见 [`docs/deployment-modes-and-references.md`](docs/deployment-modes-and-references.md)。

---

## 测试环境 / Tested environment

- DeepSeek Harness commit: `47f943859bef60e4160492346772ded9b24f765a`
- Host: Proxmox VE / Debian
- Browser client: Windows + Chromium/Edge
- Harness launch:

```bash
npx @deepseek-ai/dsh web
```

Expected output:

```text
dsh web: http://127.0.0.1:3080
```

The important point is that Harness itself stays on loopback.

---

# 中文说明

## 1. 推荐架构

```text
Windows / LAN Browser
        |
        | HTTPS + Basic Auth
        v
      Nginx
        |
        | localhost only
        v
127.0.0.1:3080
DeepSeek Harness
```

建议：

- **不要把 Harness 本体直接绑定到 `0.0.0.0`。**（除非明确选择 Direct-LAN / Phone 模式并接受相应安全边界。）
- **不要把本方案直接暴露到 Internet。**
- Nginx 入口只允许可信局域网，例如 `192.168.50.0/24`。
- 使用 HTTPS，而不是裸 HTTP。
- Basic Auth 只作为反向代理层访问控制；它不是 Harness 原生用户权限系统。

Harness 能驱动 agent、shell 和文件系统，因此拿到 Web UI 访问权限的人，应视为拿到了这台 Harness 主机上的高权限操作能力。

## 2. 安装 Nginx 与 Basic Auth

```bash
apt update
apt install -y nginx apache2-utils
```

创建用户，例如 `dsh`：

```bash
htpasswd -c /etc/nginx/.htpasswd dsh
```

## 3. 端口规划

实测环境中 `8080` 已经被另一个 DeepSeek API 反代占用，因此 Harness Web 使用 `8081`：

| Port | Purpose |
|---|---|
| `3080` | DeepSeek Harness，仅 `127.0.0.1` |
| `8080` | 已有 DeepSeek API / Anthropic 兼容代理 |
| `8081` | dsh-lan Nginx HTTPS + Basic Auth |
| `8006` | PVE Web 管理 |

如果你的 `8080` 没有被占用，可以自行调整。

检查冲突：

```bash
grep -R "listen .*8080" -n /etc/nginx
ss -lntp | grep -E ':3080|:8080|:8081'
```

## 4. Nginx 反向代理

示例：

```nginx
server {
    listen 8081 ssl;
    server_name 192.168.50.3;

    ssl_certificate     /etc/nginx/ssl/dsh.crt;
    ssl_certificate_key /etc/nginx/ssl/dsh.key;

    allow 192.168.50.0/24;
    deny all;

    auth_basic "DeepSeek Harness";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;

        # 让后端 Harness 看到 loopback authority。
        proxy_set_header Host 127.0.0.1:3080;
        proxy_set_header Origin "";

        # Basic Auth 只由 Nginx 消费，不继续传给 Harness。
        proxy_set_header Authorization "";

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # Harness 使用 WebSocket 下行通道。
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

启用配置后：

```bash
nginx -t && systemctl reload nginx
```

> **安全说明：** 上面把 `Host` 改写为 `127.0.0.1:3080`，目的是让通过 Nginx 完成认证的远程请求按 loopback 后端语义工作。这样做等于把 Nginx 变成真正的认证边界。**任何通过 Basic Auth 的用户都应视为拥有 localhost 等级的 Harness 能力。** 不要把这个入口开放给不可信网络。

## 5. 为什么必须 HTTPS

通过普通局域网 HTTP 访问：

```text
http://192.168.50.3:8081
```

在模型设置页曾实测出现：

```text
Loading the provider directory failed: crypto.randomUUID is not a function
```

原因是浏览器把普通 LAN HTTP origin 视为非安全上下文，部分 Web Crypto API 在这种上下文不可用。

当前测试版本中，`packages/client/connection/src/client/random-uuid.ts` 已经有使用 `crypto.getRandomValues()` 的 browser-safe UUID helper，但仍有其他浏览器路径可能依赖 `crypto.randomUUID()`。

因此推荐从根本上把远程 Web UI 放到 HTTPS 上，而不是逐个 patch 浏览器调用。

如果明确选择 **Direct-LAN / Phone mode**，社区项目已经证明也可以在 index 页面层注入基于 `crypto.getRandomValues()` 的 UUID polyfill；这种模式应当作为单独的低依赖方案，而不是替代 HTTPS + 认证的默认部署。

浏览器控制台可验证：

```js
window.isSecureContext
```

应得到：

```js
true
```

以及：

```js
typeof crypto.randomUUID
```

应得到：

```text
"function"
```

## 6. 局域网自签 CA 示例

```bash
mkdir -p /etc/nginx/ssl
cd /etc/nginx/ssl

openssl genrsa -out dsh-ca.key 4096
openssl req -x509 -new -nodes \
    -key dsh-ca.key \
    -sha256 \
    -days 3650 \
    -out dsh-ca.crt \
    -subj "/CN=DeepSeek Harness LAN CA"

openssl genrsa -out dsh.key 2048
openssl req -new \
    -key dsh.key \
    -out dsh.csr \
    -subj "/CN=192.168.50.3"

cat > dsh.ext <<'EOF'
subjectAltName = IP:192.168.50.3
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF

openssl x509 -req \
    -in dsh.csr \
    -CA dsh-ca.crt \
    -CAkey dsh-ca.key \
    -CAcreateserial \
    -out dsh.crt \
    -days 825 \
    -sha256 \
    -extfile dsh.ext

chmod 600 dsh.key dsh-ca.key
```

在 Windows 管理员 PowerShell 中信任 CA：

```powershell
certutil -addstore -f ROOT .\dsh-ca.crt
```

然后使用：

```text
https://192.168.50.3:8081
```

## 7. Workspace 的重要限制

远程浏览器中的 **Select Workspace Directory** 浏览的是：

```text
运行 DeepSeek Harness 的主机文件系统
```

例如 Harness 跑在 PVE 上，那么看到的是：

```text
/root
/mnt/pve/...
```

而不是浏览器所在 Windows 机器的：

```text
C:\Users\...
D:\project\...
```

这是 Host-side directory picker 的架构结果，不只是 UI 限制。

### 常见解决方案

如果想让 PVE 上的 Harness 操作 Windows 工程：

```text
Windows D:\project
      |
      | SMB / network share
      v
PVE /mnt/windows/project
      |
      v
DeepSeek Harness Workspace
```

或者使用 MCP 文件桥：

```text
Windows D:\project
      |
      v
Filesystem MCP + mcp-proxy
      |
      v
PVE DeepSeek Harness MCP Client
```

MCP 方案把文件能力作为 Agent tools 暴露，并不会把 Windows 路径变成 PVE 上的原生 Workspace。详见 [`docs/mcp-local-files.md`](docs/mcp-local-files.md)。

也可以直接在 Windows 本机运行 Harness，这样 Workspace 就是 Windows 文件系统。

---

# English

## 1. Recommended architecture

```text
Windows / LAN Browser
        |
        | HTTPS + Basic Auth
        v
      Nginx
        |
        | loopback
        v
127.0.0.1:3080
DeepSeek Harness
```

Recommendations:

- Keep Harness bound to `127.0.0.1` for the default full-control deployment.
- Do not expose this setup directly to the public Internet.
- Restrict Nginx to a trusted LAN subnet.
- Use HTTPS rather than plain LAN HTTP.
- Treat Basic Auth as a reverse-proxy access gate, not as a native Harness multi-user authorization system.

Because Harness can drive agents, shell commands and filesystem tools, anyone who can access the Web UI should be treated as a privileged operator of the Harness host.

## 2. Why HTTPS matters

A plain LAN origin such as:

```text
http://192.168.50.3:8081
```

can be a non-secure browser context. In the tested revision, this produced:

```text
Loading the provider directory failed: crypto.randomUUID is not a function
```

The tested tree already has a browser-safe UUID helper using `crypto.getRandomValues()` in one client path, but other browser paths may still rely on `crypto.randomUUID()`.

Using HTTPS makes the remote UI a secure context and avoids patching individual Web Crypto call sites. For an explicitly chosen direct-LAN/mobile mode, community projects also demonstrate an index-level UUID polyfill, but that mode has a different authentication and privilege model.

## 3. Workspace semantics

The remote **Select Workspace Directory** dialog browses the filesystem of the machine running DeepSeek Harness, not the filesystem of the browser client.

If Harness runs on PVE/Linux and the browser runs on Windows, a Windows path such as `D:\project` is not directly available to the remote Harness process.

Typical solutions are:

- mount the Windows project on the Harness host via SMB/network storage;
- expose selected Windows file operations through a filesystem MCP server;
- synchronize the project to the Harness host;
- or run Harness directly on Windows.

---

## 已知不足 / Known limitations

1. **官方远程认证层仍需完善 / Native remote authentication is still limited.**
   The tested Web carrier is designed primarily around loopback trust; this repository adds a reverse-proxy authentication boundary rather than changing Harness itself.

2. **HTTP secure-context 问题 / Plain HTTP secure-context issues.**
   Some browser APIs such as `crypto.randomUUID()` require a secure context. HTTPS should be treated as mandatory for the default remote LAN deployment; direct-LAN mode needs an explicit compatibility layer.

3. **Workspace 是 Host-side / Workspaces are host-side.**
   The browser cannot directly turn a client-local folder into a Harness-host workspace.

4. **Basic Auth 不是细粒度权限系统 / Basic Auth is not fine-grained authorization.**
   Every authenticated user effectively gets the capability surface exposed by this reverse proxy.

5. **反向代理 Header 改写是信任边界的一部分 / Header rewriting becomes part of the trust boundary.**
   If `Host` is rewritten to loopback, the proxy must only be reachable after strong authentication and from trusted networks.

6. **一键脚本尚未完整实机封板 / One-click scripts are still draft.**
   Versions, firewall behavior, MCP proxy arguments, upgrade/uninstall and multi-client testing still need hands-on validation.

---

## 借鉴的社区项目 / Related community projects

- **flupke91/dsh-phone-control** — https://github.com/flupke91/dsh-phone-control
  - phone/tablet oriented direct-LAN mode;
  - DSH plugin + Cordis patch;
  - index-level `crypto.randomUUID()` polyfill;
  - dynamic LAN-IP/trusted-host watcher;
  - explicit distinction between trust fence and authentication;
  - MIT licensed.

- **moxisuki/dsh-lan** — https://github.com/moxisuki/dsh-lan
  - compact direct-LAN overlay/plugin approach;
  - `0.0.0.0` binding through the composition seam;
  - `webServer.tapIndex()` polyfill;
  - `trustedHosts` guidance for DNS names;
  - explicitly documents host-side workspace semantics.

本仓库吸收的是架构和部署经验，不直接复制未明确授权的源码。更详细的比较、哪些设计适合本仓库以及后续 roadmap，见 [`docs/deployment-modes-and-references.md`](docs/deployment-modes-and-references.md)。

---

## 建议给上游的改进 / Suggested upstream improvements

- Document an official remote deployment pattern.
- Clearly require HTTPS for non-loopback browser access, or remove all secure-context-only browser dependencies where possible.
- Detect `window.isSecureContext === false` and show a clear diagnostic instead of surfacing `crypto.randomUUID is not a function`.
- Make the Workspace picker explicitly state that it browses the **Harness host** filesystem.
- Add a first-class authenticated remote-access mode instead of relying on a reverse proxy to become the security boundary.
- Consider an explicit low-privilege remote/mobile mode distinct from localhost-equivalent administration.

---

## Suggested repository topics

```text
deepseek-harness
dsh
deepseek
lan
self-hosted
nginx
https
reverse-proxy
basic-auth
proxmox
pve
remote-access
mcp
```

## License / 许可

MIT License. See [`LICENSE`](LICENSE).

本仓库当前主要包含部署文档、配置示例和自动化脚本，不重新分发 DeepSeek Harness 上游源码。
