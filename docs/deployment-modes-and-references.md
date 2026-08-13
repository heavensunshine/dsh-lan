# 局域网部署模式与相关项目 / LAN deployment modes and related projects

> 本文整理两个现有社区项目中值得借鉴的设计，并明确 `heavensunshine/dsh-lan` 与它们的定位差异。
>
> This note summarizes useful design ideas from two existing community projects and clarifies how `heavensunshine/dsh-lan` differs from them.

## 参考项目 / Related projects

### 1. flupke91/dsh-phone-control

https://github.com/flupke91/dsh-phone-control

该项目定位很清晰：让手机/平板在可信局域网中直接访问 DSH Web UI。它采用 **DSH plugin + Cordis patch**，直接把 WebServer 绑定到 `0.0.0.0`，并通过 `webServer.tapIndex()` 注入 `crypto.randomUUID()` polyfill。

几个值得借鉴的点：

- 不修改 DSH 安装文件，尽量只使用官方 plugin / patch seam；
- 将「手机访问」作为明确使用场景，而不是只描述技术方案；
- 对普通 HTTP LAN 下的 `crypto.randomUUID()` secure-context 问题给出部署级 workaround；
- 监控网卡变化，并动态维护 trusted-host 配置，适合 DHCP、热点、多网卡环境；
- 明确区分 `/api` trust fence 与真正的登录认证；
- 明确说明 `settings.*`、`credentials.*`、目录选择等 privileged method 在 direct-LAN 模式下仍保持 loopback-only；
- 提供安装、卸载、排障和设计文档，项目生命周期说明完整。

该项目使用 MIT License。

### 2. moxisuki/dsh-lan

https://github.com/moxisuki/dsh-lan

该项目更偏最小实现：

- `cordis.yml` 直接通过 overlay 把 WebServer 绑定到 `0.0.0.0`；
- host plugin 通过 `webServer.tapIndex()` 注入 `crypto.randomUUID()` polyfill；
- 保留 DSH 自身 `/api` browser-trust fence；
- 对 DNS name / alias 访问给出 `trustedHosts` 配置思路；
- 明确指出目录选择器浏览的是 **运行 dsh 的那台机器** 的文件系统。

在本次检查时，仓库根目录未看到 LICENSE 文件，因此这里仅借鉴公开文档中的架构思路，不复制其源码。

---

# 两种 LAN 模式必须分开看

参考上述两个项目后，`dsh-lan` 应明确把局域网访问分为两种不同安全模型，而不是把它们混成一个方案。

## Mode A — HTTPS reverse proxy / Full-control LAN

这是本仓库当前推荐的默认方案：

```text
LAN Browser
    |
    | HTTPS + Basic Auth
    v
  Nginx
    |
    | authenticated loopback proxy
    v
127.0.0.1:3080
DeepSeek Harness
```

特点：

- Harness 本体继续只监听 `127.0.0.1`；
- Nginx 是网络与认证边界；
- HTTPS 原生解决 browser secure-context 问题，不需要 UUID polyfill；
- Basic Auth 至少提供显式登录门槛；
- 如果 Nginx 把后端 `Host` 改写成 loopback authority，则通过认证的远程用户可能获得接近 localhost 的 Harness 能力；
- 因此必须把这类用户视为高权限操作者。

**适合：**

- PVE / 家庭服务器长期运行；
- 希望远程使用设置、凭据、Agent、Workspace 等更完整能力；
- 希望有 HTTPS 和密码；
- 固定服务器地址或可控的局域网环境。

## Mode B — Direct LAN plugin / Limited-control LAN

这是 `dsh-phone-control` 和 `moxisuki/dsh-lan` 所代表的方向：

```text
LAN Browser / Phone
        |
        | plain HTTP
        v
DSH WebServer @ 0.0.0.0:3080
        |
        +-- browser trust fence
        +-- randomUUID polyfill
```

特点：

- 少一层 Nginx，部署更轻；
- 通过 plugin / overlay 直接绑定 LAN；
- 普通 HTTP 需要 `crypto.randomUUID()` polyfill 或上游彻底消除 secure-context 依赖；
- 没有真正登录认证时，只能用于**完全可信的局域网**；
- DSH 自身的 loopback-only privileged methods 仍可继续阻止部分高权限 RPC；
- 很适合手机查看会话、继续聊天、监控 Agent 状态；
- DHCP / Wi-Fi / 热点切换时，动态 trusted-host 更新很有价值。

**适合：**

- 临时同 Wi-Fi 手机访问；
- 不需要完整 settings / credentials 管理；
- 愿意接受「可信 LAN 内无登录」的安全模型；
- 追求最小依赖和快速访问。

---

# 安全能力对比

| 能力 | Mode A: HTTPS reverse proxy | Mode B: Direct LAN plugin |
|---|---|---|
| Harness 监听 | `127.0.0.1` | `0.0.0.0` |
| HTTPS | 推荐/默认 | 通常无 |
| 登录门槛 | Basic Auth | 通常无 |
| `crypto.randomUUID()` | HTTPS 原生可用 | 需要 polyfill / upstream fix |
| browser trust fence | 由反代策略决定 | 保留 DSH 原生 fence |
| privileged loopback RPC | 可能经可信反代获得 | 仍通常 403 |
| 手机临时访问 | 可以 | 更轻量 |
| 多网卡/DHCP | 服务器模式通常较稳定 | 建议动态 netwatch |
| 公网暴露 | 不建议 | 严禁 |

## 关键结论

**两种模式没有绝对谁替代谁。**

- Mode A 更像「自托管 Web 服务」；
- Mode B 更像「可信局域网里的手机遥控入口」。

本仓库的一键脚本目前应继续以 **Mode A** 为主，因为它有 HTTPS 和显式认证；未来如果加入 direct-LAN plugin，应作为单独模式，不能默认为同等安全。

---

# 从两个项目补充到本仓库的内容

## 已吸收的设计原则

1. **不修改 DSH 安装文件**
   - 优先使用 Cordis patch、plugin、reverse proxy 等部署接缝。

2. **把 secure-context 问题作为部署条件而不是单点 bug**
   - HTTPS 模式：直接满足 secure context；
   - direct HTTP 模式：使用 polyfill 作为兼容层。

3. **明确权限降级与权限提升**
   - direct-LAN：部分 privileged RPC 403 是设计边界；
   - reverse-proxy：把 Host 改成 loopback 相当于把认证后的远端用户提升到更高信任级别。

4. **移动端 / 手机是第一类场景**
   - 后续 README 和测试应加入手机浏览器验证，而不是只测试桌面 Edge。

5. **多网卡与 DHCP 是真实问题**
   - 如果未来实现 direct-LAN 模式，应借鉴 netwatch 思路自动维护可访问 LAN authority；
   - PVE 固定地址 + Nginx 模式则通常不需要该机制。

6. **安装之外还要有卸载、更新和诊断**
   - 一键脚本后续应增加 `--remove` / `--status` / `--doctor` 或等价流程；
   - 应能检查端口冲突、证书、Nginx、DSH、MCP endpoint、WebSocket 和 firewall。

7. **DNS / hostname / alias 访问需要单独说明**
   - IP literal、DNS name、mDNS name 的 Host/Origin 行为不同；
   - direct-LAN 模式要考虑 `trustedHosts`；
   - HTTPS 模式要确保证书 SAN 与访问名称一致。

---

# 值得后续新增的功能 / Roadmap candidates

- [ ] **Direct-LAN / Phone mode**：作为可选第二模式，不取代 HTTPS reverse-proxy 默认方案；
- [ ] **Dynamic LAN-IP watcher**：仅用于 direct-LAN 模式；
- [ ] **`doctor` 自检命令**：检查端口、DSH、Nginx、TLS、WebSocket、MCP、Firewall；
- [ ] **一键卸载 / 回滚**：清理 systemd、Nginx site、证书、Firewall rule、Scheduled Task；
- [ ] **一键升级**：更新 DSH / MCP proxy 前先做版本和配置兼容检查；
- [ ] **手机端验收矩阵**：Android Chrome、iOS Safari、桌面 Edge/Chrome；
- [ ] **多网卡/热点场景**：明确哪个地址被发布、哪个 subnet 被允许；
- [ ] **Hostname + SAN 生成**：允许 `dsh.local` 等名称，而不只使用 IP 证书；
- [ ] **只读/低权限远程模式**：如果上游未来支持 capability-level auth，可比 Basic Auth 更细粒度；
- [ ] **MCP 文件访问 doctor**：检测 Windows Filesystem MCP endpoint、Token、路径沙箱和读写权限。

---

# 与文件 MCP 的关系

LAN Web UI 和 Windows 文件 MCP 是两个独立通道：

```text
Browser ---> HTTPS/Nginx ---> DSH Web UI @ PVE

DSH Agent ---> MCP Client ---> Windows Filesystem MCP ---> D:\project
```

因此：

- Web UI 远程访问成功，不代表 Windows 本地文件已可访问；
- MCP 文件工具可用，也不会让 Windows 路径自动成为 PVE 上的原生 Workspace；
- 一键配置需要分别验证 Web 通道与 MCP 通道。

详见：

- `ONE_CLICK.md`
- `docs/mcp-local-files.md`
- `docs/official-filesystem-mcp-proxy-plan.md`

---

## Attribution / 致谢

本页参考：

- https://github.com/flupke91/dsh-phone-control
- https://github.com/moxisuki/dsh-lan

只吸收公开文档和架构层面的经验；本仓库不复制第二个项目未明确授权的源码。若未来直接引入 MIT 项目的源代码片段，应保留对应版权与许可声明。
