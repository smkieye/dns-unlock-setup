#!/usr/bin/env bash
# Interactive DNS unlock setup script
# Supports DoH or plain DNS upstreams, IPv4/IPv6 DNS strategy, systemd persistence,
# and best-effort proxy-core DNS wiring for sing-box / Xray / V2Ray / Clash / Mihomo.
set -Eeuo pipefail

SCRIPT_VERSION="2026-05-14"
SERVICE_NAME="dnsproxy-doh"
DNSPROXY_BIN="/usr/local/bin/dnsproxy"
DNSPROXY_DIR="/etc/dnsproxy"
DNSPROXY_CONF="${DNSPROXY_DIR}/dnsproxy-doh.yaml"
RESOLVED_DROPIN_DIR="/etc/systemd/resolved.conf.d"
RESOLVED_DROPIN="${RESOLVED_DROPIN_DIR}/10-dns-unlock.conf"
LOCAL_DNS_IP="127.0.0.1"
LOCAL_DNS_PORT="53"
BACKUP_DIR=""
UPSTREAMS=()
BOOTSTRAPS=("1.1.1.1:53" "8.8.8.8:53")
DNS_MODE="doh"
IP_MODE="ipv4_only"
CONFIGURE_SYSTEM_DNS="yes"
CONFIGURE_PROXY_CORE="yes"
RESTART_PROXY_CORE="yes"
DISABLE_KERNEL_IPV6="no"
MAKE_RESOLVCONF_IMMUTABLE="no"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log() { printf "%b\n" "${GREEN}[+]${NC} $*"; }
warn() { printf "%b\n" "${YELLOW}[!]${NC} $*" >&2; }
err() { printf "%b\n" "${RED}[-]${NC} $*" >&2; }
info() { printf "%b\n" "${BLUE}[i]${NC} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

confirm() {
  local prompt="$1" default="${2:-Y}" ans
  local hint="[Y/n]"; [[ "$default" =~ ^[Nn]$ ]] && hint="[y/N]"
  read -r -p "$prompt $hint: " ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans || true
    printf '%s' "${ans:-$default}"
  else
    read -r -p "$prompt: " ans || true
    printf '%s' "$ans"
  fi
}

choose() {
  local prompt="$1"; shift
  local options=("$@") i choice tty="/dev/tty"
  # choose() is usually called inside command substitution, e.g. x="$(choose ...)".
  # Therefore menu text must not be printed to stdout, otherwise it is captured
  # into the variable and the user only sees the bare read prompt.
  if [[ -r "$tty" && -w "$tty" ]]; then
    printf '%s\n' "$prompt" > "$tty"
    for i in "${!options[@]}"; do printf '  %s) %s\n' "$((i+1))" "${options[$i]}" > "$tty"; done
    while true; do
      read -r -p "请选择 [1-${#options[@]}]: " choice < "$tty" > "$tty" || true
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
        printf '%s' "${options[$((choice-1))]}"
        return 0
      fi
      printf "%b\n" "${YELLOW}[!]${NC} 输入无效，请重试。" > "$tty"
    done
  else
    printf '%s\n' "$prompt" >&2
    for i in "${!options[@]}"; do printf '  %s) %s\n' "$((i+1))" "${options[$i]}" >&2; done
    while true; do
      read -r -p "请选择 [1-${#options[@]}]: " choice || true
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
        printf '%s' "${options[$((choice-1))]}"
        return 0
      fi
      warn "输入无效，请重试。"
    done
  fi
}

split_csv() {
  local s="$1" item
  IFS=',' read -ra _items <<< "$s"
  for item in "${_items[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

install_packages() {
  log "安装依赖 curl/tar/ca-certificates/dnsutils/jq/python3..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates tar gzip dnsutils jq python3 iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates tar gzip bind-utils jq python3 iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates tar gzip bind-utils jq python3 iproute
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates tar gzip bind-tools jq python3 iproute2
  else
    warn "未识别包管理器；请确保 curl/tar/ca-certificates/dig/jq/python3 已安装。"
  fi
}

arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    armv7l|armv7*) echo "linux-armv7" ;;
    armv6l|armv6*) echo "linux-armv6" ;;
    i386|i686) echo "linux-386" ;;
    *) err "暂不支持架构：$arch"; exit 1 ;;
  esac
}

install_dnsproxy() {
  if [[ -x "$DNSPROXY_BIN" ]]; then
    log "dnsproxy 已存在：$($DNSPROXY_BIN --version 2>/dev/null | head -n1 || echo $DNSPROXY_BIN)"
    return 0
  fi
  log "下载并安装 AdGuardTeam dnsproxy..."
  local asset tmp url api
  asset="$(arch_asset)"
  tmp="$(mktemp -d)"
  api="https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest"
  url="$(curl -fsSL "$api" | jq -r --arg asset "$asset" '.assets[] | select(.name | test("dnsproxy-"+$asset+"-.*\\.tar\\.gz")) | .browser_download_url' | head -n1)"
  if [[ -z "$url" || "$url" == "null" ]]; then
    err "无法从 GitHub release 找到 dnsproxy ${asset} 资源。"
    exit 1
  fi
  curl -fL "$url" -o "$tmp/dnsproxy.tar.gz"
  tar -xzf "$tmp/dnsproxy.tar.gz" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name dnsproxy -perm /111 | head -n1)"
  [[ -n "$bin" ]] || { err "压缩包中未找到 dnsproxy 可执行文件。"; exit 1; }
  install -m 0755 "$bin" "$DNSPROXY_BIN"
  rm -rf "$tmp"
  log "dnsproxy 安装完成：$($DNSPROXY_BIN --version 2>/dev/null | head -n1 || true)"
}

backup_files() {
  BACKUP_DIR="/root/dns-unlock-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for p in \
    /etc/dnsproxy \
    /etc/systemd/resolved.conf \
    /etc/systemd/resolved.conf.d \
    /etc/resolv.conf \
    /etc/sing-box \
    /usr/local/etc/sing-box \
    /etc/xray \
    /usr/local/etc/xray \
    /etc/v2ray \
    /usr/local/etc/v2ray \
    /etc/mihomo \
    /etc/clash; do
    if [[ -e "$p" || -L "$p" ]]; then
      local dest
      dest="$BACKUP_DIR$(echo "$p" | sed 's#/#_#g')"
      cp -a "$p" "$dest" 2>/dev/null || warn "备份失败：$p"
    fi
  done
  log "备份目录：$BACKUP_DIR"
}

normalize_upstream() {
  local raw="$1"
  raw="$(echo "$raw" | xargs)"
  [[ -z "$raw" ]] && return 0
  if [[ "$DNS_MODE" == "doh" ]]; then
    if [[ ! "$raw" =~ ^https:// ]]; then
      warn "DoH 地址通常应以 https:// 开头：$raw"
    fi
    printf '%s\n' "$raw"
  else
    # dnsproxy accepts normal upstream forms such as X.X.X.X:53, tcp://X.X.X.X:53, udp://X.X.X.X:53
    if [[ "$raw" =~ ^[0-9a-fA-F:.]+$ ]]; then
      printf '%s:53\n' "$raw"
    else
      printf '%s\n' "$raw"
    fi
  fi
}

write_dnsproxy_config() {
  mkdir -p "$DNSPROXY_DIR"
  local ipv6_disabled="false"
  [[ "$IP_MODE" == "ipv4_only" ]] && ipv6_disabled="true"
  {
    echo "listen-addrs:"
    echo "- ${LOCAL_DNS_IP}"
    echo "listen-ports:"
    echo "- ${LOCAL_DNS_PORT}"
    echo "upstream:"
    for u in "${UPSTREAMS[@]}"; do echo "- ${u}"; done
    echo "bootstrap:"
    for b in "${BOOTSTRAPS[@]}"; do echo "- ${b}"; done
    echo "cache: true"
    echo "cache-optimistic: true"
    echo "ipv6-disabled: ${ipv6_disabled}"
  } > "$DNSPROXY_CONF"
  chmod 0644 "$DNSPROXY_CONF"
  log "已写入 dnsproxy 配置：$DNSPROXY_CONF"
}

write_dnsproxy_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=dnsproxy local DNS unlock resolver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DNSPROXY_BIN} --config-path=${DNSPROXY_CONF}
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service"
  log "已启用 systemd 服务：${SERVICE_NAME}.service"
}

configure_system_resolved() {
  [[ "$CONFIGURE_SYSTEM_DNS" == "yes" ]] || return 0
  mkdir -p "$RESOLVED_DROPIN_DIR"
  cat > "$RESOLVED_DROPIN" <<EOF
[Resolve]
DNS=${LOCAL_DNS_IP}
Domains=~.
DNSStubListener=yes
DNSSEC=no
DNSOverTLS=no
Cache=yes
EOF
  log "已写入 systemd-resolved drop-in：$RESOLVED_DROPIN"

  if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl enable systemd-resolved.service || true
  fi

  # Fix static/immutable resolv.conf that bypasses systemd-resolved.
  if command -v lsattr >/dev/null 2>&1 && lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    warn "/etc/resolv.conf 有 immutable 属性，先 chattr -i"
    chattr -i /etc/resolv.conf || true
  fi

  if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    log "/etc/resolv.conf 已指向 systemd-resolved stub"
  else
    cat > /etc/resolv.conf <<EOF
nameserver ${LOCAL_DNS_IP}
options edns0 trust-ad
EOF
    log "/etc/resolv.conf 已写入本地 DNS：${LOCAL_DNS_IP}"
  fi

  if [[ "$MAKE_RESOLVCONF_IMMUTABLE" == "yes" ]] && command -v chattr >/dev/null 2>&1; then
    chattr +i /etc/resolv.conf || warn "chattr +i /etc/resolv.conf 失败，已跳过。"
  fi
}

configure_kernel_ipv6() {
  if [[ "$DISABLE_KERNEL_IPV6" != "yes" ]]; then return 0; fi
  cat > /etc/sysctl.d/99-disable-ipv6-dns-unlock.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null || warn "应用 sysctl 失败，请手动检查 /etc/sysctl.d/99-disable-ipv6-dns-unlock.conf"
  log "已持久禁用系统 IPv6（可删除 /etc/sysctl.d/99-disable-ipv6-dns-unlock.conf 恢复）。"
}

singbox_strategy() {
  case "$IP_MODE" in
    ipv4_only) echo "ipv4_only" ;;
    ipv6_only) echo "ipv6_only" ;;
    prefer_ipv4) echo "prefer_ipv4" ;;
    prefer_ipv6) echo "prefer_ipv6" ;;
    *) echo "" ;;
  esac
}

patch_json_dns() {
  local file="$1" core="$2" strategy="$3"
  python3 - "$file" "$core" "$strategy" "$LOCAL_DNS_IP" "$LOCAL_DNS_PORT" <<'PY'
import json, sys, os
path, core, strategy, ip, port = sys.argv[1:6]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    print(f"SKIP {path}: JSON parse failed: {e}")
    sys.exit(0)
if not isinstance(data, dict):
    print(f"SKIP {path}: root is not object")
    sys.exit(0)
if core == 'sing-box':
    dns = data.get('dns') if isinstance(data.get('dns'), dict) else {}
    servers = dns.get('servers') if isinstance(dns.get('servers'), list) else []
    tag = 'dns-unlock-local'
    found = False
    for s in servers:
        if isinstance(s, dict) and (s.get('tag') == tag or s.get('address') == ip or s.get('server') == ip):
            s.clear(); s.update({'type': 'udp', 'tag': tag, 'server': ip, 'server_port': int(port)})
            found = True
    if not found:
        servers.insert(0, {'type': 'udp', 'tag': tag, 'server': ip, 'server_port': int(port)})
    dns['servers'] = servers
    dns['final'] = tag
    if strategy:
        dns['strategy'] = strategy
    data['dns'] = dns
    # Replace route-specific prefer_ipv6 when IPv4-only was requested.
    if strategy == 'ipv4_only':
        def walk(x):
            if isinstance(x, dict):
                for k,v in list(x.items()):
                    if k == 'strategy' and v == 'prefer_ipv6':
                        x[k] = 'ipv4_only'
                    else:
                        walk(v)
            elif isinstance(x, list):
                for i in x: walk(i)
        walk(data.get('route', data))
else:
    dns = data.get('dns') if isinstance(data.get('dns'), dict) else {}
    dns['servers'] = [ip]
    data['dns'] = dns
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f"PATCHED {path}")
PY
}

find_service_config_paths() {
  local svc="$1"
  systemctl cat "$svc" 2>/dev/null | sed -nE 's/.*(-c|-C|-config)[ =]([^ ]+).*/\2/p' | tr -d '"' || true
}

patch_singbox() {
  local strategy paths=() p
  strategy="$(singbox_strategy)"
  while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < <(find_service_config_paths sing-box.service)
  for p in /etc/sing-box/config.json /usr/local/etc/sing-box/config.json /etc/sing-box/conf /usr/local/etc/sing-box/conf; do
    [[ -e "$p" ]] && paths+=("$p")
  done
  # Deduplicate
  mapfile -t paths < <(printf '%s\n' "${paths[@]}" | awk '!seen[$0]++')
  [[ ${#paths[@]} -eq 0 ]] && return 0
  log "检测到 sing-box 配置，尝试写入 DNS 策略：$strategy"
  for p in "${paths[@]}"; do
    if [[ -d "$p" ]]; then
      local dnsfile="$p/00_dns_unlock.json"
      cat > "$dnsfile" <<EOF
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-unlock-local",
        "server": "${LOCAL_DNS_IP}",
        "server_port": ${LOCAL_DNS_PORT}
      }
    ],
    "final": "dns-unlock-local"$( [[ -n "$strategy" ]] && printf ',\n    "strategy": "%s"' "$strategy" )
  }
}
EOF
      log "已写入 sing-box 多文件 DNS：$dnsfile"
      if [[ "$strategy" == "ipv4_only" ]]; then
        grep -RIl 'prefer_ipv6' "$p" 2>/dev/null | while read -r f; do
          python3 - "$f" <<'PY'
import sys, pathlib
p=pathlib.Path(sys.argv[1])
s=p.read_text(errors='ignore')
ns=s.replace('"prefer_ipv6"','"ipv4_only"')
if ns!=s:
    p.write_text(ns)
    print(f"replaced prefer_ipv6 in {p}")
PY
        done
      fi
    elif [[ -f "$p" && "$p" == *.json ]]; then
      patch_json_dns "$p" "sing-box" "$strategy"
    fi
  done
  if command -v sing-box >/dev/null 2>&1; then
    for p in "${paths[@]}"; do
      if [[ -d "$p" ]]; then sing-box check -C "$p" || warn "sing-box check -C $p 未通过，请查看输出。"; fi
      if [[ -f "$p" ]]; then sing-box check -c "$p" || warn "sing-box check -c $p 未通过，请查看输出。"; fi
    done
  fi
}

patch_xray_v2ray() {
  local files=()
  for p in /etc/xray/config.json /usr/local/etc/xray/config.json /etc/v2ray/config.json /usr/local/etc/v2ray/config.json; do
    [[ -f "$p" ]] && files+=("$p")
  done
  [[ ${#files[@]} -eq 0 ]] && return 0
  log "检测到 Xray/V2Ray JSON 配置，写入 dns.servers=127.0.0.1"
  for f in "${files[@]}"; do patch_json_dns "$f" "xray" ""; done
  command -v xray >/dev/null 2>&1 && for f in "${files[@]}"; do [[ "$f" == *xray* ]] && xray run -test -config "$f" || true; done
  command -v v2ray >/dev/null 2>&1 && for f in "${files[@]}"; do [[ "$f" == *v2ray* ]] && v2ray test -config "$f" || true; done
}

patch_yaml_dns_simple() {
  local file="$1"
  python3 - "$file" "$LOCAL_DNS_IP" "$LOCAL_DNS_PORT" <<'PY'
import sys, pathlib, re
path=pathlib.Path(sys.argv[1]); ip=sys.argv[2]; port=sys.argv[3]
s=path.read_text(errors='ignore')
block=f"""
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  nameserver:
    - {ip}:{port}
  fallback: []
""".lstrip()
if re.search(r'(?m)^dns:\n(?:^[ \t].*\n?)*', s):
    s2=re.sub(r'(?m)^dns:\n(?:^[ \t].*\n?)*', block, s, count=1)
else:
    s2=s.rstrip()+"\n\n"+block
path.write_text(s2)
print(f"PATCHED {path}")
PY
}

patch_clash_mihomo() {
  local files=()
  for p in /etc/mihomo/config.yaml /etc/mihomo/config.yml /etc/clash/config.yaml /etc/clash/config.yml; do
    [[ -f "$p" ]] && files+=("$p")
  done
  [[ ${#files[@]} -eq 0 ]] && return 0
  warn "检测到 Clash/Mihomo YAML。将以简单 DNS 块覆盖原 dns: 块；复杂分流 DNS 如需保留请用备份恢复后手工合并。"
  for f in "${files[@]}"; do patch_yaml_dns_simple "$f"; done
}

configure_proxy_cores() {
  [[ "$CONFIGURE_PROXY_CORE" == "yes" ]] || return 0
  patch_singbox
  patch_xray_v2ray
  patch_clash_mihomo
}

restart_services() {
  log "重启 dnsproxy/systemd-resolved..."
  systemctl restart "$SERVICE_NAME.service"
  if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl restart systemd-resolved.service || warn "systemd-resolved 重启失败，请检查 systemctl status systemd-resolved"
  fi
  if [[ "$RESTART_PROXY_CORE" == "yes" ]]; then
    for svc in sing-box xray v2ray mihomo clash; do
      if systemctl list-units --type=service --all "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
        systemctl restart "${svc}.service" || warn "重启 ${svc}.service 失败，请检查配置。"
      fi
    done
  fi
}

verify() {
  log "验证服务状态..."
  systemctl --no-pager --full status "$SERVICE_NAME.service" | sed -n '1,18p' || true
  echo
  info "/etc/resolv.conf:"
  ls -l /etc/resolv.conf || true
  cat /etc/resolv.conf || true
  echo
  info "监听端口 53:"
  ss -lntup 2>/dev/null | grep -E '(:53\b|:53\s)' || true
  echo
  local domains=("netflix.com" "disneyplus.com" "disney.api.edge.bamgrid.com" "bamgrid.com")
  for d in "${domains[@]}"; do
    echo "== ${d} A @127.0.0.1 =="
    dig @127.0.0.1 "$d" A +short +time=3 +tries=1 || true
    echo "== ${d} AAAA @127.0.0.1 =="
    dig @127.0.0.1 "$d" AAAA +short +time=3 +tries=1 || true
  done
  echo
  info "默认解析路径测试："
  dig netflix.com A +short +time=3 +tries=1 || true
  getent ahostsv4 netflix.com | head || true
}

interactive_config() {
  echo "============================================================"
  echo " DNS 解锁交互式一键配置脚本 v${SCRIPT_VERSION}"
  echo "============================================================"
  echo "说明：默认采用本地 dnsproxy 监听 127.0.0.1:53，再把系统和代理核心指向它。"
  echo

  local mode_label
  mode_label="$(choose "上游 DNS 类型" "DoH（https://xxx.example/dns-query 或服务商 DoH）" "普通 DNS IP/地址（如 X.X.X.X 或 X.X.X.X:53）")"
  [[ "$mode_label" == DoH* ]] && DNS_MODE="doh" || DNS_MODE="plain"

  local upstream_input default_upstream
  default_upstream=""
  echo
  if [[ "$DNS_MODE" == "doh" ]]; then
    info "上游 DNS = 你的解锁服务商给的 DoH 地址。示例格式：https://xxx.example/dns-query"
    info "请填写你自己的服务商地址；公开项目不会内置任何私人 DoH 地址。"
  else
    info "上游 DNS = 你的解锁 DNS 服务器 IP。示例格式：X.X.X.X 或 X.X.X.X,Y.Y.Y.Y，多个用英文逗号分隔。"
    warn "注意：这里不要填写项目示例占位符；要填你的 DNS 解锁服务商提供的真实 DNS IP。"
  fi
  upstream_input="$(ask "请输入上游 DNS")"
  mapfile -t UPSTREAMS < <(while read -r u; do normalize_upstream "$u"; done < <(split_csv "$upstream_input"))
  if [[ ${#UPSTREAMS[@]} -eq 0 ]]; then err "未输入有效上游 DNS。"; exit 1; fi

  local bootstrap_input
  echo
  info "Bootstrap DNS 是什么？"
  echo "  - 作用：只用于 dnsproxy 启动时解析 DoH 域名，例如把 xxx.example 解析成 IP。"
  echo "  - 如果你选择的是 DoH：建议直接回车使用默认 1.1.1.1:53,8.8.8.8:53。"
  echo "  - 如果你选择的是普通 DNS IP：这个选项基本不会影响解锁，也建议直接回车。"
  echo "  - 小白建议：不要改，直接回车。"
  bootstrap_input="$(ask "Bootstrap DNS（小白直接回车；多个用英文逗号分隔）" "1.1.1.1:53,8.8.8.8:53")"
  mapfile -t BOOTSTRAPS < <(split_csv "$bootstrap_input")

  echo
  info "下面选择解析/出站策略。小白建议：解锁流媒体优先选 1）IPv4 only，最稳。"
  local ip_label
  ip_label="$(choose "出站 / 解析策略" \
    "IPv4 only：只返回 IPv4，屏蔽 IPv6/AAAA；推荐 Disney+/Netflix/Bamgrid 解锁" \
    "IPv6 only：只返回 IPv6；除非你的解锁服务明确要求 IPv6，否则不要选" \
    "Prefer IPv4：IPv4/IPv6 都保留，但优先 IPv4；适合想保留双栈的人" \
    "Prefer IPv6：IPv4/IPv6 都保留，但优先 IPv6；不推荐流媒体解锁小白使用" \
    "Dual stack：不指定偏好，保持双栈；可能因 IPv6 地区不一致导致解锁失败")"
  case "$ip_label" in
    IPv4*) IP_MODE="ipv4_only" ;;
    IPv6*) IP_MODE="ipv6_only" ;;
    Prefer\ IPv4*) IP_MODE="prefer_ipv4" ;;
    Prefer\ IPv6*) IP_MODE="prefer_ipv6" ;;
    Dual*) IP_MODE="dual" ;;
  esac

  echo
  info "接下来几个 Yes/No 问题的小白推荐：一路回车即可。"
  echo "  - 配置系统 DNS：建议 Y，让系统默认也走解锁 DNS。"
  echo "  - 自动配置代理核心：建议 Y，脚本会检测 sing-box/Xray/V2Ray/Clash/Mihomo；没装就自动跳过。"
  echo "  - 重启代理核心：建议 Y，让配置立即生效。"
  CONFIGURE_SYSTEM_DNS=$(confirm "是否配置系统 DNS 指向 127.0.0.1:53 并持久化？小白建议直接回车" Y && echo yes || echo no)
  CONFIGURE_PROXY_CORE=$(confirm "是否自动尝试配置已安装的代理核心？小白建议直接回车" Y && echo yes || echo no)
  RESTART_PROXY_CORE=$(confirm "配置后是否自动重启检测到的代理核心服务？小白建议直接回车" Y && echo yes || echo no)

  if [[ "$IP_MODE" == "ipv4_only" ]]; then
    echo
    info "内核 IPv6 开关说明：通常不需要关系统 IPv6；脚本已经会屏蔽 DNS 的 IPv6/AAAA 解析。小白建议选 N，直接回车。"
    DISABLE_KERNEL_IPV6=$(confirm "是否同时持久禁用系统内核 IPv6？" N && echo yes || echo no)
  fi
  echo
  info "resolv.conf 锁定说明：chattr +i 会把 /etc/resolv.conf 锁住，防止面板覆盖，但也可能影响系统/面板以后改 DNS。小白建议选 N，直接回车。"
  MAKE_RESOLVCONF_IMMUTABLE=$(confirm "是否给 /etc/resolv.conf 加 chattr +i 防止面板覆盖？" N && echo yes || echo no)

  echo
  info "即将应用配置："
  printf '  上游类型: %s\n' "$DNS_MODE"
  printf '  上游 DNS:\n'; printf '    - %s\n' "${UPSTREAMS[@]}"
  printf '  Bootstrap:\n'; printf '    - %s\n' "${BOOTSTRAPS[@]}"
  printf '  IP 策略: %s\n' "$IP_MODE"
  printf '  配置系统 DNS: %s\n' "$CONFIGURE_SYSTEM_DNS"
  printf '  配置代理核心: %s\n' "$CONFIGURE_PROXY_CORE"
  printf '  重启代理核心: %s\n' "$RESTART_PROXY_CORE"
  printf '  禁用内核 IPv6: %s\n' "$DISABLE_KERNEL_IPV6"
  printf '  resolv.conf immutable: %s\n' "$MAKE_RESOLVCONF_IMMUTABLE"
  echo
  confirm "确认开始？" Y || { warn "已取消。"; exit 0; }
}

main() {
  need_root
  interactive_config
  install_packages
  backup_files
  install_dnsproxy
  write_dnsproxy_config
  write_dnsproxy_service
  configure_system_resolved
  configure_kernel_ipv6
  configure_proxy_cores
  restart_services
  verify
  echo
  log "完成。备份目录：$BACKUP_DIR"
  warn "建议执行一次真实 reboot 后重新运行以下验证："
  echo "  systemctl is-active ${SERVICE_NAME} systemd-resolved"
  echo "  dig @127.0.0.1 disney.api.edge.bamgrid.com A +short"
  echo "  dig @127.0.0.1 disney.api.edge.bamgrid.com AAAA +short"
  echo "  resolvectl query netflix.com  # 如系统使用 systemd-resolved"
}

main "$@"
