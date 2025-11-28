#!/usr/bin/env bash
# VLESS-REALITY + TUIC 一键安装脚本（修复版 v3）

set -uo pipefail

############## 通用函数 ##############

log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR ]\033[0m $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
}

############## 清理旧配置 ##############

clean_old_install() {
  log "开始清理旧的 sing-box 配置和数据..."
  
  # 停止服务
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    log "停止 sing-box 服务..."
    systemctl stop sing-box
  fi
  
  # 禁用服务
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    log "禁用 sing-box 服务..."
    systemctl disable sing-box
  fi
  
  # 删除服务文件
  if [ -f /etc/systemd/system/sing-box.service ]; then
    log "删除 systemd 服务文件..."
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
  fi
  
  # 备份并删除配置目录
  if [ -d /etc/sing-box ]; then
    local backup_name="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    log "备份旧配置到: $backup_name"
    tar -czf "$backup_name" /etc/sing-box/ 2>/dev/null || true
    log "删除旧配置目录..."
    rm -rf /etc/sing-box
  fi
  
  # 清理临时文件
  if [ -d /tmp/sb-reality ]; then
    rm -rf /tmp/sb-reality
  fi
  rm -f /tmp/sing-box-config-*.json 2>/dev/null || true
  rm -f /tmp/sb.tar.gz 2>/dev/null || true
  
  log "✅ 清理完成！旧配置已备份到 /root/"
  echo
}

show_menu() {
  echo "========================================"
  echo "   Sing-box VPN 一键安装脚本"
  echo "========================================"
  echo "1. 全新安装（推荐）"
  echo "2. 清理旧配置后重新安装"
  echo "3. 仅清理配置（不安装）"
  echo "4. 卸载 sing-box"
  echo "5. 查看当前配置"
  echo "0. 退出"
  echo "========================================"
  echo
}

uninstall_singbox() {
  log "开始卸载 sing-box..."
  
  # 停止并禁用服务
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  
  # 删除服务文件
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  
  # 备份配置
  if [ -d /etc/sing-box ]; then
    local backup_name="/root/sing-box-final-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$backup_name" /etc/sing-box/ 2>/dev/null || true
    log "配置已备份到: $backup_name"
  fi
  
  # 删除文件
  rm -rf /etc/sing-box
  rm -f /usr/local/bin/sing-box
  rm -rf /tmp/sb-reality
  rm -f /tmp/sing-box-config-*.json 2>/dev/null || true
  
  log "✅ sing-box 已完全卸载！"
  log "配置备份保存在 /root/ 目录下"
}

show_current_config() {
  if [ ! -f /etc/sing-box/config.json ]; then
    warn "未找到配置文件 /etc/sing-box/config.json"
    return
  fi
  
  echo "========================================"
  echo "当前配置信息："
  echo "========================================"
  
  if [ -f /etc/sing-box/share-links.txt ]; then
    cat /etc/sing-box/share-links.txt
  else
    warn "未找到分享链接文件"
  fi
  
  echo
  echo "服务状态："
  systemctl status sing-box --no-pager -l | head -n 10
  echo "========================================"
}

############## 安装基础依赖 ##############

install_base() {
  if command -v apt-get >/dev/null 2>&1; then
    log "检测到 Debian/Ubuntu 系统，安装依赖..."
    apt-get update -y
    apt-get install -y curl wget jq openssl qrencode
  elif command -v yum >/dev/null 2>&1; then
    log "检测到 CentOS/RHEL 系统，安装依赖..."
    yum install -y epel-release
    yum install -y curl wget jq openssl qrencode
  else
    err "无法识别的系统（非 apt / yum），请手动安装 curl、wget、jq、openssl。"
    exit 1
  fi
}

############## 安装最新 sing-box ##############

install_sing_box() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    *)
      err "不支持的 CPU 架构: $ARCH"
      exit 1
      ;;
  esac

  log "检测并安装最新 sing-box ..."

  # 用 GitHub API 获取最新 tag
  local LATEST_TAG
  LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
  if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
    err "获取 sing-box 最新版本号失败，请稍后重试。"
    exit 1
  fi

  local VER
  VER="${LATEST_TAG#v}"

  local SB_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz"
  log "下载并安装 sing-box ${LATEST_TAG} (${SB_ARCH}) ..."
  cd /tmp
  wget -O sb.tar.gz "$SB_URL"
  tar -xzf sb.tar.gz

  local SB_DIR
  SB_DIR=$(tar -tzf sb.tar.gz | head -n 1 | cut -d/ -f1)
  install -m 755 "${SB_DIR}/sing-box" /usr/local/bin/sing-box

  rm -rf "${SB_DIR}" sb.tar.gz

  log "sing-box 安装完成: $(sing-box version)"
}

############## Reality 域名测试与选择 ##############

GIST_URL="https://gist.githubusercontent.com/cj3343/8d38d603440ea50105319d7c09909faf/raw/47e05fcfdece890d1480f462afadc0baffcbb120/domain-list.txt"

download_domain_list() {
  mkdir -p /tmp/sb-reality
  local FILE="/tmp/sb-reality/domain-list.txt"

  if curl -fsSL "$GIST_URL" -o "$FILE"; then
    log "已从 Gist 拉取 Reality 域名池：$FILE"
  else
    warn "从 Gist 拉取域名池失败，使用内置备用列表。"
    cat > "$FILE" <<EOF
apple.com
www.apple.com
nvidia.com
www.nvidia.com
www.microsoft.com
www.spotify.com
www.tesla.com
s3.amazonaws.com
awsstatic.com
www.whatsapp.com
www.netflix.com
www.google.com
www.cloudflare.com
EOF
  fi
}

test_domains_latency() {
  local FILE="/tmp/sb-reality/domain-list.txt"
  [ -f "$FILE" ] || download_domain_list

  log "开始测试 Reality 目标域名延迟（openssl + 443）..."

  local best_domain=""
  local best_ms=999999

  while read -r d; do
    [ -z "$d" ] && continue
    local t1 t2 cost
    t1=$(date +%s%3N)
    if timeout 1 openssl s_client -connect "$d:443" -servername "$d" </dev/null >/dev/null 2>&1; then
      t2=$(date +%s%3N)
      cost=$((t2 - t1))
      printf "  %-30s %4s ms\n" "$d" "$cost"
      if [ "$cost" -lt "$best_ms" ]; then
        best_ms="$cost"
        best_domain="$d"
      fi
    else
      printf "  %-30s timeout\n" "$d"
    fi
  done < <(shuf "$FILE" | head -n 12)

  if [ -z "$best_domain" ]; then
    warn "所有测试域名均超时，请手动输入一个能 443 访问的大站域名。"
  else
    log "✅ 当前测速最优域名：$best_domain (${best_ms} ms)"
  fi

  REALITY_BEST_DOMAIN="$best_domain"
  REALITY_BEST_MS="$best_ms"
}

choose_reality_domain() {
  download_domain_list
  test_domains_latency

  while true; do
    if [ -n "${REALITY_BEST_DOMAIN:-}" ]; then
      echo
      echo "[INFO] 当前测速最优：${REALITY_BEST_DOMAIN} (${REALITY_BEST_MS} ms)"
      read -rp "Reality 伪装域名 [回车用当前最优 / 输入 r 重新测速 / 输入自定义域名]：" input
      case "$input" in
        "")
          REALITY_DOMAIN="$REALITY_BEST_DOMAIN"
          break
          ;;
        r|R)
          test_domains_latency
          ;;
        *)
          REALITY_DOMAIN="$input"
          break
          ;;
      esac
    else
      read -rp "Reality 伪装域名（例如 www.apple.com / nvidia.com）：" input
      if [ -n "$input" ]; then
        REALITY_DOMAIN="$input"
        break
      fi
    fi
  done

  log "✅ 最终使用的 Reality 伪装域名：$REALITY_DOMAIN"
}

############## 生成 Reality 密钥 / UUID 等 ##############

generate_reality_keys() {
  mkdir -p /etc/sing-box
  cd /etc/sing-box

  log "生成 Reality 密钥对..."
  sing-box generate reality-keypair > /etc/sing-box/reality.txt

  REALITY_PRIVATE=$(grep -i "PrivateKey" /etc/sing-box/reality.txt | awk '{print $2}')
  REALITY_PUBLIC=$(grep -i "PublicKey"  /etc/sing-box/reality.txt | awk '{print $2}')

  if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
    err "解析 Reality 密钥失败，请检查 /etc/sing-box/reality.txt"
    exit 1
  fi

  SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)

  log "Reality 私钥: $REALITY_PRIVATE"
  log "Reality 公钥: $REALITY_PUBLIC"
  log "Reality Short ID: $SHORT_ID"
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

############## 写入 sing-box 配置（完全重写，符合最新格式）##############

write_config() {
  local VLESS_PORT="$1"
  local TUIC_PORT="$2"
  local VLESS_UUID="$3"
  local TUIC_UUID="$4"
  local TUIC_PASS="$5"

  mkdir -p /etc/sing-box

  if [ -f /etc/sing-box/config.json ]; then
    cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak-$(date +%s)"
    warn "已备份旧 config.json"
  fi

  # 先写入临时文件
  local TMP_CONFIG="/tmp/sing-box-config-$$.json"
  
  cat > "$TMP_CONFIG" <<'EOFCONFIG'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "address": "tls://1.1.1.1"
      }
    ]
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": VLESS_PORT_PLACEHOLDER,
      "users": [
        {
          "uuid": "VLESS_UUID_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_DOMAIN_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_DOMAIN_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PRIVATE_PLACEHOLDER",
          "short_id": ["SHORT_ID_PLACEHOLDER"]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": TUIC_PORT_PLACEHOLDER,
      "users": [
        {
          "uuid": "TUIC_UUID_PLACEHOLDER",
          "password": "TUIC_PASS_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "REALITY_DOMAIN_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_DOMAIN_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PRIVATE_PLACEHOLDER",
          "short_id": ["SHORT_ID_PLACEHOLDER"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "protocol": ["bittorrent"],
        "outbound": "block"
      }
    ],
    "final": "direct"
  }
}
EOFCONFIG

  # 替换占位符
  sed -i "s/VLESS_PORT_PLACEHOLDER/${VLESS_PORT}/g" "$TMP_CONFIG"
  sed -i "s/TUIC_PORT_PLACEHOLDER/${TUIC_PORT}/g" "$TMP_CONFIG"
  sed -i "s/VLESS_UUID_PLACEHOLDER/${VLESS_UUID}/g" "$TMP_CONFIG"
  sed -i "s/TUIC_UUID_PLACEHOLDER/${TUIC_UUID}/g" "$TMP_CONFIG"
  sed -i "s/TUIC_PASS_PLACEHOLDER/${TUIC_PASS}/g" "$TMP_CONFIG"
  sed -i "s/REALITY_DOMAIN_PLACEHOLDER/${REALITY_DOMAIN}/g" "$TMP_CONFIG"
  sed -i "s|REALITY_PRIVATE_PLACEHOLDER|${REALITY_PRIVATE}|g" "$TMP_CONFIG"
  sed -i "s/SHORT_ID_PLACEHOLDER/${SHORT_ID}/g" "$TMP_CONFIG"

  log "配置已生成到临时文件: $TMP_CONFIG"
  log "开始检查 JSON 合法性..."
  
  if ! sing-box check -c "$TMP_CONFIG"; then
    err "配置检查失败！"
    err "临时配置文件保存在: $TMP_CONFIG"
    err "请检查后手动复制到 /etc/sing-box/config.json"
    exit 1
  fi
  
  log "配置合法 ✅"
  
  # 移动到正式位置
  mv "$TMP_CONFIG" /etc/sing-box/config.json
  log "配置已保存到 /etc/sing-box/config.json"
}

############## systemd 服务 ##############

setup_systemd() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box

  sleep 2
  log "Sing-box 服务状态："
  systemctl --no-pager -l status sing-box | sed -n '1,15p'
}

############## IP 检测 ##############

detect_ipv4() {
  local ip cand
  ip=$(curl -4s --max-time 5 https://api.ip.sb 2>/dev/null || true)
  cand=$(echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  if [ -z "$cand" ]; then
    ip=$(curl -4s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    cand=$(echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  fi
  if [ -z "$cand" ]; then
    ip=$(curl -4s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null || true)
    cand=$(echo "$ip" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  fi
  echo "$cand"
}

############## 生成分享链接 & 二维码 ##############

gen_share_links() {
  local VLESS_PORT="$1"
  local TUIC_PORT="$2"
  local VLESS_UUID="$3"
  local TUIC_UUID="$4"
  local TUIC_PASS="$5"

  echo
  local SERVER_IP
  read -rp "服务器公网 IPv4 [回车自动检测]：" SERVER_IP
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(detect_ipv4)
  fi
  if [ -z "$SERVER_IP" ]; then
    err "自动检测 IP 失败，请重新运行脚本中的链接生成部分或手动写 IP。"
    return
  fi

  local VLESS_URL="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#VLESS-REALITY"
  local TUIC_URL="tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=quic&alpn=h3&sni=${REALITY_DOMAIN}&allow_insecure=0#TUIC-REALITY"

  mkdir -p /etc/sing-box
  cat > /etc/sing-box/share-links.txt <<EOF
VLESS-REALITY:
${VLESS_URL}

TUIC-REALITY:
${TUIC_URL}
EOF

  echo
  echo "================= 分享链接（已保存到 /etc/sing-box/share-links.txt） ================="
  echo "VLESS-REALITY:"
  echo "$VLESS_URL"
  echo
  echo "TUIC-REALITY:"
  echo "$TUIC_URL"
  echo "==============================================================================="

  if command -v qrencode >/dev/null 2>&1; then
    echo
    log "生成二维码（终端显示）..."
    echo
    echo "【VLESS-REALITY 二维码】"
    echo "$VLESS_URL" | qrencode -t ANSIUTF8
    echo
    echo "【TUIC-REALITY 二维码】"
    echo "$TUIC_URL" | qrencode -t ANSIUTF8
    echo
    log "也可生成 PNG 文件："
    echo "$VLESS_URL" | qrencode -o /etc/sing-box/vless.png
    echo "$TUIC_URL"  | qrencode -o /etc/sing-box/tuic.png
    log "PNG 文件保存在：/etc/sing-box/vless.png, /etc/sing-box/tuic.png"
  else
    warn "未安装 qrencode，已跳过二维码生成。"
  fi
}

############## 主流程 ##############

setup_firewall() {
  log "配置防火墙规则..."
  
  if command -v ufw >/dev/null 2>&1; then
    # 允许 SSH（当前连接的端口）
    ufw allow 22/tcp 2>/dev/null || true
    
    # 允许 VPN 端口
    ufw allow "$1"/tcp  # VLESS
    ufw allow "$2"/udp  # TUIC
    
    # 启用防火墙（如果未启用）
    echo "y" | ufw enable 2>/dev/null || true
    ufw status
    
    log "✅ 防火墙已配置"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    # CentOS/RHEL 使用 firewalld
    firewall-cmd --permanent --add-port="$1"/tcp
    firewall-cmd --permanent --add-port="$2"/udp
    firewall-cmd --reload
    log "✅ 防火墙已配置"
  else
    warn "未检测到 ufw 或 firewalld，请手动配置防火墙开放端口 $1(TCP) 和 $2(UDP)"
  fi
}

do_install() {
  need_cmd curl
  need_cmd wget
  need_cmd jq

  install_base
  install_sing_box
  choose_reality_domain
  generate_reality_keys

  echo
  read -rp "VLESS Reality 端口 [默认: 443]：" VLESS_PORT
  VLESS_PORT=${VLESS_PORT:-443}
  read -rp "TUIC 端口 [默认: 8443]：" TUIC_PORT
  TUIC_PORT=${TUIC_PORT:-8443}
  log "✅ VLESS 端口: ${VLESS_PORT}"
  log "✅ TUIC  端口: ${TUIC_PORT}"

  local VLESS_UUID TUIC_UUID TUIC_PASS
  VLESS_UUID=$(generate_uuid)
  TUIC_UUID=$(generate_uuid)
  TUIC_PASS=$(generate_uuid)

  write_config "$VLESS_PORT" "$TUIC_PORT" "$VLESS_UUID" "$TUIC_UUID" "$TUIC_PASS"
  setup_firewall "$VLESS_PORT" "$TUIC_PORT"
  setup_systemd
  gen_share_links "$VLESS_PORT" "$TUIC_PORT" "$VLESS_UUID" "$TUIC_UUID" "$TUIC_PASS"

  echo
  log "🎉 全部完成！"
  echo
  echo "============== 🔐 安全建议 =============="
  echo "1. 定期更新系统：apt update && apt upgrade"
  echo "2. 修改 SSH 端口并禁用密码登录（只用密钥）"
  echo "3. 定期检查流量使用：可用 vnstat 监控"
  echo "4. 不要分享链接给不信任的人"
  echo "5. 定期更改 UUID：重新运行本脚本即可"
  echo "6. 监控服务状态：systemctl status sing-box"
  echo "========================================"
  echo
  echo "============== 📱 客户端导入 =============="
  echo "1）安卓 NekoBox / v2rayNG：扫码或粘贴链接"
  echo "2）iOS Shadowrocket：扫码导入"
  echo "3）Mac/Win sing-box / v2rayN：新建节点粘贴链接"
  echo "4）二维码已在上方显示，也可在 /etc/sing-box/ 下载 PNG"
  echo "=========================================="
}

main() {
  # 显示菜单
  while true; do
    show_menu
    read -rp "请选择操作 [0-5]: " choice
    
    case "$choice" in
      1)
        log "开始全新安装..."
        do_install
        break
        ;;
      2)
        clean_old_install
        log "开始重新安装..."
        do_install
        break
        ;;
      3)
        clean_old_install
        log "清理完成！"
        break
        ;;
      4)
        uninstall_singbox
        break
        ;;
      5)
        show_current_config
        echo
        read -rp "按回车键继续..."
        ;;
      0)
        log "退出脚本"
        exit 0
        ;;
      *)
        err "无效选择，请重新输入"
        echo
        ;;
    esac
  done
}

main "$@"
