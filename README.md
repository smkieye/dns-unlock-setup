# DNS Unlock Setup

交互式 DNS 解锁一键脚本。适用于 Linux VPS / 代理节点，将 DNS 解锁服务固化到本地 `127.0.0.1:53`，并尽量自动配置系统 DNS 与常见代理核心。

## 功能

- 交互式选择上游 DNS：
  - DoH，例如 `https://xxx.example/dns-query`
  - 普通 DNS IP，例如 `X.X.X.X,Y.Y.Y.Y`
- 交互式选择解析 / 出站策略：
  - IPv4 only：屏蔽 AAAA / IPv6 解析，适合 Disney+ / Bamgrid 等场景
  - IPv6 only
  - Prefer IPv4
  - Prefer IPv6
  - Dual stack
- 自动安装 AdGuardTeam `dnsproxy`
- 本地监听 `127.0.0.1:53`，避免暴露开放递归 DNS
- systemd 服务持久化：`dnsproxy-doh.service`
- systemd-resolved 持久化配置
- 自动备份原配置到 `/root/dns-unlock-backup-时间戳/`
- 尝试自动配置常见代理核心：
  - sing-box
  - Xray
  - V2Ray
  - Clash / Mihomo
- IPv4 only 模式下：
  - `dnsproxy` 启用 `ipv6-disabled: true`
  - sing-box 设置 `strategy: ipv4_only`
  - 替换 sing-box 中的 `prefer_ipv6`
- 执行后自动验证 Netflix / Disney+ / Bamgrid 相关域名 A / AAAA 解析

## 一键执行

直接复制下面命令在任意新服务器执行：

```bash
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/smkieye/dns-unlock-setup/main/install.sh -o "$tmp" && sudo bash "$tmp"
```

如果你已经是 root：

```bash
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/smkieye/dns-unlock-setup/main/install.sh -o "$tmp" && bash "$tmp"
```

> 不推荐直接 `curl ... | bash`，因为这是交互式脚本，管道方式可能影响 `read` 读取用户输入。

## 推荐选择

如果目标是 Disney+ / Netflix / Bamgrid DNS 解锁，推荐：

- 上游 DNS 类型：DoH
- DoH 地址：填写你的 DNS 解锁服务商提供的地址，例如 `https://xxx.example/dns-query`
- Bootstrap DNS：`1.1.1.1:53,8.8.8.8:53`，小白直接回车即可
- 出站 / 解析策略：IPv4 only
- 配置系统 DNS：Y
- 自动配置代理核心：Y
- 自动重启代理核心：Y
- 持久禁用系统内核 IPv6：N
- 给 `/etc/resolv.conf` 加 `chattr +i`：N

## 回滚到安装前状态

如果想撤销本脚本造成的 DNS 解锁、sing-box DNS 修改、Disney/QUIC 相关修复，可以运行回滚脚本：

```bash
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/smkieye/dns-unlock-setup/main/rollback.sh -o "$tmp" && sudo bash "$tmp"
```

如果你已经是 root：

```bash
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/smkieye/dns-unlock-setup/main/rollback.sh -o "$tmp" && bash "$tmp"
```

回滚脚本会先备份当前状态到 `/root/dns-unlock-rollback-safety-时间戳/`，然后列出服务器上已有的 `/root/dns-unlock-backup-*`、`/root/dns-unlock-setup-backup-*`、`/root/dns-unlock-fix-backup-*`、`/root/disney-playback-fix-backup-*` 备份目录供选择。

小白建议：如果要回到最初状态，优先选择最早的 `dns-unlock-backup-*` 或 `dns-unlock-setup-backup-*`。

## 执行后验证

```bash
systemctl status dnsproxy-doh --no-pager

dig @127.0.0.1 netflix.com A +short
dig @127.0.0.1 disneyplus.com A +short
dig @127.0.0.1 disney.api.edge.bamgrid.com A +short
dig @127.0.0.1 disney.api.edge.bamgrid.com AAAA +short

dig netflix.com A +short
getent ahostsv4 netflix.com | head
```

如系统使用 systemd-resolved：

```bash
resolvectl query netflix.com
```

## 重启持久化验证

```bash
reboot
```

重启后重新登录：

```bash
systemctl is-enabled dnsproxy-doh
systemctl is-active dnsproxy-doh
systemctl is-active systemd-resolved

dig @127.0.0.1 disney.api.edge.bamgrid.com A +short
dig @127.0.0.1 disney.api.edge.bamgrid.com AAAA +short
dig netflix.com A +short
```

## 注意事项

- 默认只监听 `127.0.0.1:53`，不会把 DNS 服务暴露到公网。
- 自动修改代理核心配置前会备份，但复杂分流 DNS 建议手动检查备份和 diff。
- 如果 VPS 面板或云镜像会覆盖 `/etc/resolv.conf`，可在交互时选择 `chattr +i`，但默认不建议开启。
- 如果选择 IPv4 only，AAAA 查询通常应为空，这是为了避免部分流媒体服务因 IPv6 出口地区不一致而解锁失败。

## 许可证

MIT
