# 本地文件访问可以借助 MCP / Access client-local files through MCP

> 这里的 **MCP** 指 Model Context Protocol（不是 `mpc`）。
>
> **MCP** here means Model Context Protocol.

## 结论

当 DeepSeek Harness 运行在 PVE/Linux，而 Web 浏览器运行在 Windows 时，Harness 自带的 **Select Workspace Directory** 仍然只能选择 **Harness 主机上的目录**。但是，本地 Windows 文件并不一定只能通过 SMB 挂载；还可以把 Windows 端作为一个 **MCP 文件工具服务器**，让 PVE 上的 Harness 通过 MCP 调用它。

DeepSeek Harness 在测试版本 `47f943859bef60e4160492346772ded9b24f765a` 已实现 MCP Client，支持：

- `stdio`
- `streamable-http`

并把 MCP 服务器提供的 Tools 注册成 Harness 的模型工具。

因此远程文件访问可以有两条路线：

```text
方案 A：SMB / 网络挂载
Windows D:\project
      |
      v
PVE /mnt/windows/project
      |
      v
Harness Workspace
```

```text
方案 B：MCP 文件工具桥
Windows D:\project
      |
      v
Filesystem-capable MCP server @ Windows
      |
      | Streamable HTTP over trusted LAN / VPN
      v
DeepSeek Harness MCP Client @ PVE
      |
      v
Agent tools: mcp__<server>__<tool>
```

## 重要区别

MCP **不会把 Windows 目录直接变成 Harness 的原生 Workspace**。

也就是说：

- Workspace picker 仍然浏览 PVE 文件系统；
- Harness 自带 shell 的工作目录仍然在 PVE；
- Windows 文件通过 MCP 暴露后，是以 **MCP Tools** 的形式被 Agent 读取、写入、搜索或操作；
- 如果某项工作必须让本地 shell、git、编译器等直接把 Windows 工程当普通目录使用，SMB/SSHFS/同步或直接在 Windows 上运行 Harness 仍更合适。

## `stdio` 与远程 Windows 的关系

如果 MCP 配置使用：

```yaml
transport: stdio
```

那么 MCP 子进程是由 **Harness 所在主机**启动的。

因此：

```text
Harness @ PVE
  -> stdio MCP process @ PVE
  -> 看到的是 PVE 文件系统
```

它并不能因为浏览器在 Windows 就自动访问 `D:\project`。

要从 PVE 访问 Windows 本地文件，应在 Windows 上运行 MCP Server，并让 Harness 使用 `streamable-http` 连接它：

```text
PVE Harness
   |
   | streamable-http
   v
Windows MCP Server
   |
   v
D:\project
```

## Harness MCP 配置形态

上游当前 MCP Client 插件包为：

```text
@deepseek-ai/dsh-mcp-client
```

其远程配置形态类似：

```yaml
- id: mcp-windows-files
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: windows-files
    transport: streamable-http
    url: https://WINDOWS-LAN-IP:PORT/mcp
    headers:
      Authorization: !!js `Bearer ${process.env.WINDOWS_MCP_TOKEN}`
```

Agent 看到的工具名会采用：

```text
mcp__<serverName>__<toolName>
```

例如：

```text
mcp__windows-files__read_file
mcp__windows-files__write_file
```

具体工具名由实际 MCP Server 提供。

## 安全建议

远程文件 MCP 的风险不低于共享目录，因为它把本机文件操作能力交给 Agent。建议至少：

1. **只暴露明确的工程目录**，例如 `D:\RM3100`，不要暴露整个 `C:\` 或用户 Home。
2. 远程 MCP 使用认证 Token，不要匿名开放。
3. 只监听可信 LAN/VPN；不要直接暴露到 Internet。
4. 能用 HTTPS 就使用 HTTPS。
5. Windows 防火墙仅允许 PVE/Harness 主机 IP 访问 MCP 端口。
6. 优先选择支持路径沙箱、只读模式或细粒度写权限的 MCP 文件服务器。
7. 对删除、覆盖、执行命令等高风险操作保持额外限制。

## 什么时候选 MCP，什么时候选 SMB

| 需求 | 更适合 |
|---|---|
| Agent 读取/修改少量 Windows 本地文件 | MCP |
| 不想在 PVE 上长期挂载 Windows 共享 | MCP |
| 希望严格限制 Agent 只能调用特定文件工具 | MCP |
| Harness shell / git / compiler 必须直接操作工程目录 | SMB / SSHFS / 同步 |
| 大量文件扫描、构建、Git 操作 | SMB / 本地运行 Harness |
| Windows 电脑离线时仍要继续使用工程副本 | 同步到 PVE |

## English summary

When DeepSeek Harness runs on PVE/Linux and the browser runs on Windows, the built-in workspace picker still browses the **Harness host filesystem**. However, Windows-local files can also be exposed to the agent through an MCP filesystem/tool server running on Windows.

The tested Harness revision includes an MCP client with `stdio` and `streamable-http` transports. `stdio` starts the MCP process on the Harness host, so it still sees the PVE filesystem. To reach files on the Windows client, run a filesystem-capable MCP server on Windows and connect to it from Harness using `streamable-http` over a trusted LAN/VPN.

This does **not** turn `D:\project` into a native Harness workspace. It exposes Windows file operations as MCP tools. For shell, Git, compilers, build systems, or workloads that expect a normal filesystem path, SMB/network mounting or running Harness directly on Windows is usually more appropriate.

## Upstream references

- DeepSeek Harness: https://github.com/deepseek-ai/deepseek-harness
- Tested revision: `47f943859bef60e4160492346772ded9b24f765a`
- MCP client implementation note: `.agents/notes/implemented/feature/2026-07-07-mcp-client-plugin.md`
