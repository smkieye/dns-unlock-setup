#!/usr/bin/env bash
set -euo pipefail

# DNS Unlock / Disney playback fix rollback script
# Safe default: create a current-state backup, then restore selected previous backup,
# remove dnsproxy/systemd-resolved unlock drop-ins, and remove Disney QUIC block.

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

pause_confirm(){
  local ans
  printf "\n${YELLOW}即将回滚 DNS 解锁/Disney 修复相关配置。继续吗？输入 YES 继续：${NC} " >/dev/tty
  read -r ans </dev/tty || true
  [[ "$ans" == "YES" ]] || { warn "已取消。"; exit 0; }
}

make_safety_backup(){
  SAFETY="/root/dns-unlock-rollback-safety-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SAFETY"
  info "先备份当前状态到：$SAFETY"
  cp -a /etc/sing-box "$SAFETY/sing-box" 2>/dev/null || true
  cp -a /etc/dnsproxy "$SAFETY/dnsproxy" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf "$SAFETY/resolved.conf" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf.d "$SAFETY/resolved.conf.d" 2>/dev/null || true
  cp -a /etc/systemd/system/dnsproxy-doh.service "$SAFETY/dnsproxy-doh.service" 2>/dev/null || true
  cp -a /etc/nftables.conf "$SAFETY/nftables.conf" 2>/dev/null || true
  nft list ruleset > "$SAFETY/nft-ruleset.txt" 2>/dev/null || true
}

find_backups(){
  mapfile -t BACKUPS < <(
    for d in \
      /root/dns-unlock-backup-* \
      /root/dns-unlock-setup-backup-* \
      /root/dns-unlock-fix-backup-* \
      /root/disney-playback-fix-backup-*; do
      [[ -d "$d" ]] && echo "$d"
    done | sort
  )
}

describe_backup(){
  local d="$1"; local marks=()
  [[ -d "$d/sing-box" || -d "$d/sing-box-conf" ]] && marks+=("sing-box")
  [[ -d "$d/dnsproxy" ]] && marks+=("dnsproxy")
  [[ -f "$d/resolved.conf" || -d "$d/resolved.conf.d" ]] && marks+=("resolved")
  [[ -f "$d/nftables.conf" || -f "$d/nft-ruleset.before" || -f "$d/nft-ruleset.txt" ]] && marks+=("nft")
  [[ ${#marks[@]} -eq 0 ]] && printf "未知内容" || printf "%s" "${marks[*]}"
}

choose_backup(){
  find_backups
  SELECTED_BACKUP=""
  if [[ ${#BACKUPS[@]} -eq 0 ]]; then
    warn "未找到 /root/dns-unlock* 或 /root/disney-playback* 备份目录。将执行“尽力撤销”模式。"
    return 0
  fi

  printf "\n${BLUE}找到以下备份目录：${NC}\n" >/dev/tty
  local i=1
  for d in "${BACKUPS[@]}"; do
    printf "  %2d) %s  [%s]\n" "$i" "$d" "$(describe_backup "$d")" >/dev/tty
    ((i++))
  done
  printf "   0) 不从备份恢复，只撤销 DNS 解锁/QUIC 阻断改动\n" >/dev/tty

  printf "\n${YELLOW}建议：如果要回到最初状态，选择最早的 dns-unlock-backup / dns-unlock-setup-backup。${NC}\n" >/dev/tty
  printf "请选择备份编号 [默认 1]: " >/dev/tty
  local ans
  read -r ans </dev/tty || true
  ans="${ans:-1}"
  if [[ "$ans" == "0" ]]; then
    SELECTED_BACKUP=""
    return 0
  fi
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || (( ans < 1 || ans > ${#BACKUPS[@]} )); then
    err "无效编号：$ans"
    exit 1
  fi
  SELECTED_BACKUP="${BACKUPS[$((ans-1))]}"
  ok "将从备份恢复：$SELECTED_BACKUP"
}

restore_path(){
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    info "恢复 $dst <- $src"
    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

restore_from_backup(){
  local b="$1"
  [[ -n "$b" ]] || return 0

  # sing-box: some backups store full /etc/sing-box, others only conf.
  if [[ -d "$b/sing-box" ]]; then
    restore_path "$b/sing-box" /etc/sing-box
  elif [[ -d "$b/sing-box-conf" ]]; then
    restore_path "$b/sing-box-conf" /etc/sing-box/conf
  fi

  # Other proxy cores, if present in backup.
  [[ -d "$b/xray" ]] && restore_path "$b/xray" /etc/xray
  [[ -d "$b/v2ray" ]] && restore_path "$b/v2ray" /etc/v2ray
  [[ -d "$b/mihomo" ]] && restore_path "$b/mihomo" /etc/mihomo
  [[ -d "$b/clash" ]] && restore_path "$b/clash" /etc/clash

  [[ -d "$b/dnsproxy" ]] && restore_path "$b/dnsproxy" /etc/dnsproxy
  [[ -f "$b/resolved.conf" ]] && restore_path "$b/resolved.conf" /etc/systemd/resolved.conf
  [[ -d "$b/resolved.conf.d" ]] && restore_path "$b/resolved.conf.d" /etc/systemd/resolved.conf.d
  [[ -f "$b/nftables.conf" ]] && restore_path "$b/nftables.conf" /etc/nftables.conf
}

remove_unlock_artifacts(){
  info "撤销 DNS 解锁脚本常见残留配置"

  # Stop/disable dnsproxy-doh installed by the unlock script.
  systemctl stop dnsproxy-doh.service 2>/dev/null || true
  systemctl disable dnsproxy-doh.service 2>/dev/null || true
  rm -f /etc/systemd/system/dnsproxy-doh.service
  systemctl daemon-reload || true

  # Remove common systemd-resolved drop-ins added by our scripts.
  rm -f \
    /etc/systemd/resolved.conf.d/10-gaidns-doh.conf \
    /etc/systemd/resolved.conf.d/10-dns-unlock.conf \
    /etc/systemd/resolved.conf.d/10-dns-unlock-setup.conf \
    /etc/systemd/resolved.conf.d/99-dns-unlock.conf 2>/dev/null || true

  # Remove the extra early sing-box DNS file created by older one-click versions.
  rm -f /etc/sing-box/conf/00_dns_unlock.json /etc/sing-box/conf/00_dns_unlock.json.disabled 2>/dev/null || true

  # Runtime remove Disney QUIC block table without flushing Docker/fail2ban rules.
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet disney_quic_block 2>/dev/null || true
  fi

  # If nftables.conf is exactly/mostly our Disney block and no backup restored it, move it aside.
  if [[ -f /etc/nftables.conf ]] && grep -q 'disney_quic_block' /etc/nftables.conf; then
    mv /etc/nftables.conf "/etc/nftables.conf.removed-by-dns-rollback-$(date +%Y%m%d-%H%M%S)"
    warn "已移除包含 disney_quic_block 的 /etc/nftables.conf；如果你原本有自定义 nftables，请从安全备份恢复。"
  fi
}

restart_and_verify(){
  info "重启/验证服务"
  systemctl restart systemd-resolved 2>/dev/null || true

  if [[ -x /etc/sing-box/sing-box && -d /etc/sing-box/conf ]]; then
    if (cd /etc/sing-box && ./sing-box check -C /etc/sing-box/conf >/tmp/sing-box-rollback-check.log 2>&1); then
      ok "sing-box 配置检查通过"
      systemctl restart sing-box 2>/dev/null || true
    else
      warn "sing-box 配置检查失败，未主动重启 sing-box。日志：/tmp/sing-box-rollback-check.log"
    fi
  elif command -v sing-box >/dev/null 2>&1 && [[ -d /etc/sing-box/conf ]]; then
    if sing-box check -C /etc/sing-box/conf >/tmp/sing-box-rollback-check.log 2>&1; then
      ok "sing-box 配置检查通过"
      systemctl restart sing-box 2>/dev/null || true
    else
      warn "sing-box 配置检查失败，未主动重启 sing-box。日志：/tmp/sing-box-rollback-check.log"
    fi
  fi

  printf "\n${BLUE}当前状态：${NC}\n"
  systemctl is-active sing-box 2>/dev/null | sed 's/^/sing-box: /' || true
  systemctl is-active dnsproxy-doh 2>/dev/null | sed 's/^/dnsproxy-doh: /' || true
  systemctl is-active systemd-resolved 2>/dev/null | sed 's/^/systemd-resolved: /' || true
  systemctl is-enabled nftables 2>/dev/null | sed 's/^/nftables enabled: /' || true
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | sed -n '1,35p' || true
  fi
  if command -v nft >/dev/null 2>&1; then
    if nft list table inet disney_quic_block >/dev/null 2>&1; then
      warn "disney_quic_block 仍存在，请手动检查 nftables。"
    else
      ok "Disney UDP/443 阻断表已不存在"
    fi
  fi
  printf "\n${GREEN}回滚流程完成。当前状态安全备份：%s${NC}\n" "$SAFETY"
}

main(){
  need_root
  echo "============================================================"
  echo " DNS Unlock / Disney Playback Fix 回滚脚本"
  echo "============================================================"
  warn "该脚本会恢复备份并撤销 dnsproxy-doh、systemd-resolved 解锁 drop-in、Disney QUIC 阻断等改动。"
  pause_confirm
  make_safety_backup
  choose_backup
  restore_from_backup "$SELECTED_BACKUP"
  remove_unlock_artifacts
  restart_and_verify
}

main "$@"
