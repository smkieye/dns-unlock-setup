#!/usr/bin/env bash
set -Eeuo pipefail

# Brute-force rollback / uninstall for dns-unlock-setup.
# Goals:
# - Remove installed dnsproxy program/config/service and DNS-unlock artifacts.
# - Keep all backup directories/files intact.
# - Restore Linux IPv4/IPv6 behavior to normal dual-stack defaults.
# - Set system DNS to 1.1.1.1 and 8.8.8.8; if the server has IPv6 connectivity,
#   also add IPv6 public DNS so AAAA resolution works normally.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok(){ printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err(){ printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }

need_root(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

confirm(){
  local ans
  printf "\n${YELLOW}本脚本将简单粗暴卸载 DNS 解锁相关程序/服务/配置，但保留所有备份目录。继续请输入 YES：${NC} " >/dev/tty
  read -r ans </dev/tty || true
  [[ "$ans" == "YES" ]] || { warn "已取消。"; exit 0; }
}

make_safety_backup(){
  SAFETY="/root/dns-unlock-brutal-rollback-safety-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SAFETY"
  info "先备份当前关键状态到：$SAFETY"
  cp -a /etc/dnsproxy "$SAFETY/dnsproxy" 2>/dev/null || true
  cp -a /etc/systemd/system/dnsproxy-doh.service "$SAFETY/dnsproxy-doh.service" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf "$SAFETY/resolved.conf" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf.d "$SAFETY/resolved.conf.d" 2>/dev/null || true
  cp -a /etc/resolv.conf "$SAFETY/resolv.conf" 2>/dev/null || true
  cp -a /etc/sysctl.conf "$SAFETY/sysctl.conf" 2>/dev/null || true
  cp -a /etc/sysctl.d "$SAFETY/sysctl.d" 2>/dev/null || true
  cp -a /etc/nftables.conf "$SAFETY/nftables.conf" 2>/dev/null || true
  cp -a /etc/sing-box/conf/00_dns_unlock.json "$SAFETY/00_dns_unlock.json" 2>/dev/null || true
  cp -a /etc/sing-box/conf/00_dns_unlock.json.disabled "$SAFETY/00_dns_unlock.json.disabled" 2>/dev/null || true
  nft list ruleset > "$SAFETY/nft-ruleset.txt" 2>/dev/null || true
}

has_ipv6_default_route(){
  ip -6 route show default 2>/dev/null | grep -q .
}

remove_dnsproxy(){
  info "停止并移除 dnsproxy-doh 服务、dnsproxy 程序和配置"
  systemctl stop dnsproxy-doh.service 2>/dev/null || true
  systemctl disable dnsproxy-doh.service 2>/dev/null || true
  rm -f /etc/systemd/system/dnsproxy-doh.service
  rm -f /etc/systemd/system/multi-user.target.wants/dnsproxy-doh.service
  rm -rf /etc/dnsproxy
  rm -f /usr/local/bin/dnsproxy
  systemctl daemon-reload || true
}

remove_resolved_unlock_dropins(){
  info "删除 DNS 解锁相关 systemd-resolved drop-in"
  rm -f \
    /etc/systemd/resolved.conf.d/10-gaidns-doh.conf \
    /etc/systemd/resolved.conf.d/10-dns-unlock.conf \
    /etc/systemd/resolved.conf.d/10-dns-unlock-setup.conf \
    /etc/systemd/resolved.conf.d/99-dns-unlock.conf 2>/dev/null || true
}

restore_ipv4_ipv6_defaults(){
  info "恢复 Linux IPv4/IPv6 默认行为：启用 IPv4/IPv6，不再禁用 IPv6/AAAA"

  # Runtime sysctl: enable IPv6 back immediately. Ignore unsupported keys.
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true

  # Remove common files/drop-ins created by DNS unlock scripts to disable IPv6.
  rm -f \
    /etc/sysctl.d/99-disable-ipv6.conf \
    /etc/sysctl.d/99-dns-unlock-ipv6.conf \
    /etc/sysctl.d/99-dns-unlock-disable-ipv6.conf \
    /etc/sysctl.d/10-disable-ipv6.conf 2>/dev/null || true

  # If /etc/sysctl.conf contains disable_ipv6 lines, comment them instead of deleting the file.
  if [[ -f /etc/sysctl.conf ]]; then
    sed -i -E 's/^([[:space:]]*net\.ipv6\.conf\..*\.disable_ipv6[[:space:]]*=.*)$/# dns-unlock rollback commented: \1/' /etc/sysctl.conf || true
  fi

  # Re-enable IPv6 via GRUB/sysctl common kernel parameters if our scripts added them.
  if [[ -f /etc/default/grub ]]; then
    sed -i -E 's/[[:space:]]*ipv6\.disable=1//g; s/[[:space:]]*net\.ipv6\.conf\.all\.disable_ipv6=1//g' /etc/default/grub || true
    if command -v update-grub >/dev/null 2>&1; then
      update-grub >/dev/null 2>&1 || true
    fi
  fi
}

configure_public_dns(){
  info "恢复系统 DNS 到公共 DNS：1.1.1.1、8.8.8.8；双栈服务器额外加入 IPv6 DNS"
  mkdir -p /etc/systemd/resolved.conf.d

  local dns_line="DNS=1.1.1.1 8.8.8.8"
  local fallback_line="FallbackDNS=1.0.0.1 8.8.4.4"
  if has_ipv6_default_route; then
    dns_line="DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888"
    fallback_line="FallbackDNS=1.0.0.1 8.8.4.4 2606:4700:4700::1001 2001:4860:4860::8844"
    ok "检测到 IPv6 默认路由，已加入 IPv6 DNS，AAAA 解析会恢复。"
  else
    warn "未检测到 IPv6 默认路由，仅配置 IPv4 DNS；系统仍允许 IPv6，未来有 IPv6 路由后可解析 AAAA。"
  fi

  cat > /etc/systemd/resolved.conf.d/99-public-dns.conf <<EOF
[Resolve]
$dns_line
$fallback_line
Domains=~.
DNSStubListener=yes
DNSSEC=no
DNSOverTLS=no
Cache=yes
EOF

  # Undo immutable resolv.conf if previous script set it.
  chattr -i /etc/resolv.conf 2>/dev/null || true

  # Prefer systemd-resolved stub on systemd systems.
  if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
    systemctl restart systemd-resolved.service 2>/dev/null || true
    ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  else
    # Fallback for non-systemd-resolved distributions.
    {
      echo 'nameserver 1.1.1.1'
      echo 'nameserver 8.8.8.8'
      if has_ipv6_default_route; then
        echo 'nameserver 2606:4700:4700::1111'
        echo 'nameserver 2001:4860:4860::8888'
      fi
    } > /etc/resolv.conf
  fi
}

remove_proxy_core_artifacts(){
  info "删除脚本新增的代理核心 DNS 残留文件；不删除任何备份目录"
  rm -f /etc/sing-box/conf/00_dns_unlock.json /etc/sing-box/conf/00_dns_unlock.json.disabled 2>/dev/null || true

  # Do NOT aggressively rewrite 03_route.json / 05_dns.json here: those files may belong to the user's panel.
  # The purpose is uninstalling installed artifacts and restoring system DNS/IPv6; backups are preserved for manual restore.
}

remove_quic_block(){
  info "删除 Disney/QUIC UDP 443 阻断规则"
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet disney_quic_block 2>/dev/null || true
  fi
  if [[ -f /etc/nftables.conf ]] && grep -q 'disney_quic_block' /etc/nftables.conf; then
    rm -f /etc/nftables.conf
    systemctl disable nftables.service >/dev/null 2>&1 || true
    systemctl stop nftables.service 2>/dev/null || true
  fi
}

restart_proxy_if_present(){
  if systemctl list-unit-files sing-box.service >/dev/null 2>&1; then
    if [[ -x /etc/sing-box/sing-box && -d /etc/sing-box/conf ]]; then
      if (cd /etc/sing-box && ./sing-box check -C /etc/sing-box/conf >/tmp/sing-box-rollback-check.log 2>&1); then
        systemctl restart sing-box.service 2>/dev/null || true
        ok "sing-box 配置检查通过并已重启。"
      else
        warn "sing-box 配置检查失败，未重启。日志：/tmp/sing-box-rollback-check.log"
      fi
    else
      systemctl restart sing-box.service 2>/dev/null || true
    fi
  fi
}

verify(){
  printf "\n${BLUE}=== 回滚后状态 ===${NC}\n"
  systemctl is-active dnsproxy-doh.service 2>/dev/null | sed 's/^/dnsproxy-doh: /' || echo 'dnsproxy-doh: not-found/inactive'
  systemctl is-active systemd-resolved.service 2>/dev/null | sed 's/^/systemd-resolved: /' || true
  systemctl is-active sing-box.service 2>/dev/null | sed 's/^/sing-box: /' || true

  echo
  echo '--- /etc/resolv.conf ---'
  ls -l /etc/resolv.conf 2>/dev/null || true
  sed -n '1,20p' /etc/resolv.conf 2>/dev/null || true

  echo
  echo '--- systemd-resolved DNS ---'
  resolvectl status 2>/dev/null | sed -n '1,60p' || true

  echo
  echo '--- IPv6 status ---'
  sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true

  echo
  echo '--- DNS smoke test ---'
  if command -v dig >/dev/null 2>&1; then
    echo 'A cloudflare.com:'; dig cloudflare.com A +short | sed -n '1,5p' || true
    echo 'AAAA cloudflare.com:'; dig cloudflare.com AAAA +short | sed -n '1,5p' || true
  else
    getent ahosts cloudflare.com | sed -n '1,8p' || true
  fi

  if command -v nft >/dev/null 2>&1 && nft list table inet disney_quic_block >/dev/null 2>&1; then
    warn "disney_quic_block 仍存在，请手动检查 nftables。"
  else
    ok "Disney QUIC 阻断表不存在。"
  fi

  printf "\n${GREEN}简单粗暴回滚完成。所有旧备份目录均未清理；本次安全备份：%s${NC}\n" "$SAFETY"
  warn "如之前曾手动改过 sing-box 的 03_route.json/05_dns.json，脚本不会强行猜测原始内容；需要时请从保留的备份目录手动恢复。"
}

main(){
  need_root
  echo '============================================================'
  echo ' DNS Unlock Setup 简单粗暴回滚/卸载脚本'
  echo '============================================================'
  confirm
  make_safety_backup
  remove_dnsproxy
  remove_resolved_unlock_dropins
  restore_ipv4_ipv6_defaults
  configure_public_dns
  remove_proxy_core_artifacts
  remove_quic_block
  restart_proxy_if_present
  verify
}

main "$@"
