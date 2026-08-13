# 计划：官方 Filesystem MCP + mcp-proxy + DSH

> 状态：**占坑 / Planned, not yet tested**
>
> 本页先记录计划中的实现路线和验证目标，后续有空再做实机配置与复核。当前不要把下面的命令或参数视为已经在本项目环境中验证通过。

## 目标

当 DeepSeek Harness 运行在 PVE/Linux，而实际工程文件位于 Windows 本地磁盘（例如 `D:\RM3100`）时，希望不通过 SMB 挂载，也能让 DSH Agent 读取、搜索和修改 Windows 本地工程文件。

计划采用：

```text
Windows D:\RM3100
      |
      v
官方 Filesystem MCP Server
      |
      | stdio
      v
mcp-proxy
      |
      | Streamable HTTP + authentication
      v
PVE / DeepSeek Harness
      |
      v
@deepseek-ai/dsh-mcp-client
```

## 候选组件

1. **Filesystem MCP Server**
   - 优先选择 Model Context Protocol 官方/参考 filesystem server。
   - 只允许访问明确工程目录，例如 `D:\RM3100`。
   - 不计划直接暴露整个 `C:\`、用户 Home 或所有磁盘。

2. **mcp-proxy**
   - 作为 Windows 端 stdio MCP 到远程 Streamable HTTP 的薄代理。
   - 负责把本地 filesystem MCP 暴露给 PVE 上的 Harness MCP Client。
   - 远程监听必须配合认证、Windows Firewall 和可信 LAN/VPN 使用。

3. **DeepSeek Harness MCP Client**
   - 使用 `@deepseek-ai/dsh-mcp-client`。
   - PVE 端使用 `streamable-http` 连接 Windows MCP endpoint。
   - Agent 最终通过 `mcp__<serverName>__<toolName>` 形式使用文件工具。

## 为什么选这条路线

相比一个同时负责文件系统访问、HTTP 服务和认证的大型第三方 MCP Server，这条方案把职责拆成两层：

```text
官方 Filesystem MCP -> 文件操作语义
mcp-proxy            -> 网络传输/远程桥接
```

预期优点：

- 文件操作层尽量使用官方实现；
- 网络代理层较薄，便于理解和替换；
- 可以严格限制公开目录；
- 不需要把 Windows 工程长期挂载到 PVE；
- 与 DSH 已实现的 Streamable HTTP MCP Client 方向一致。

## 与原生 Workspace 的关系

这条方案**不会**让 Windows `D:\RM3100` 出现在 DSH 的 **Select Workspace Directory** 中。

原生 Workspace 仍然属于 Harness 主机文件系统：

```text
Workspace / shell / git / compiler @ PVE
```

Windows 文件则通过 MCP tools 暴露：

```text
read / write / search / metadata ... @ Windows MCP
```

因此后续实测时需要明确区分：

- **MCP 文件工具访问成功**；
- **Windows 目录成为原生 DSH Workspace**。

前者是本方案目标，后者不是。

## 计划实测项目

后续配置时至少验证：

- [ ] Windows 上启动 filesystem MCP，并只允许一个测试目录；
- [ ] mcp-proxy 从 stdio 转成 Streamable HTTP；
- [ ] 远程 endpoint 有认证，不允许匿名访问；
- [ ] Windows Firewall 仅允许 PVE/Harness 主机 IP；
- [ ] PVE 上的 `@deepseek-ai/dsh-mcp-client` 能发现工具；
- [ ] DSH 能读取 Windows 文件；
- [ ] DSH 能创建/修改测试文件；
- [ ] 路径沙箱不能逃逸到允许目录之外；
- [ ] 大文件、二进制文件和中文路径行为；
- [ ] 网络断开/Windows 睡眠后的错误与恢复行为；
- [ ] 删除/覆盖操作的风险控制；
- [ ] 对比 SMB 方案在 Git、编译、大量小文件扫描场景下的性能与便利性。

## 计划中的 DSH 配置形态

最终目标大致如下；具体 URL、认证 Header 与代理参数待实测后填写：

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

## 安全边界

远程 filesystem MCP 本质上是在把 Windows 本地文件操作能力交给 Agent，因此最终方案至少应满足：

- 只暴露明确工程目录；
- 不匿名开放 MCP endpoint；
- 不直接暴露到 Internet；
- Windows Firewall 只允许指定 Harness 主机；
- 能使用 HTTPS/VPN 时优先使用；
- 删除、覆盖、移动等写操作需要重点验证；
- Token/密码不得硬编码进公开仓库。

## 待实测后补充

- Windows 一键启动脚本；
- mcp-proxy 确认可用的版本与参数；
- 官方 Filesystem MCP 确认可用的版本与参数；
- DSH `cordis.yml` 完整配置；
- systemd / Windows Task Scheduler 常驻方案；
- HTTPS/证书方案；
- 实测截图和工具列表；
- 读写/搜索/路径逃逸测试结果；
- MCP 与 SMB 的性能对比。

---

## English summary

**Status: planned, not yet tested.**

The intended architecture is:

```text
Windows project directory
  -> official/reference Filesystem MCP over stdio
  -> mcp-proxy
  -> authenticated Streamable HTTP over trusted LAN/VPN
  -> @deepseek-ai/dsh-mcp-client on PVE
```

The goal is to let DSH agents access Windows-local project files without mounting the directory as a native PVE filesystem. This does **not** make the Windows directory a native DSH workspace; it exposes file operations as MCP tools.

Actual commands, versions, authentication headers and production configuration will be added only after hands-on testing.

## References

- DeepSeek Harness: https://github.com/deepseek-ai/deepseek-harness
- Local-files MCP design note in this repository: `docs/mcp-local-files.md`
