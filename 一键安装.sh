#!/bin/bash

# ====================================================
# 全栈网络架构部署脚本 (Sing-box + Sub-Store + CF Tunnel)
# Role: Senior Network Security Engineer
# Version: 3.0 (Merged & Hardened)
# ====================================================

set -e

# --- 全局配色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 全局路径 ---
SUBSTORE_DIR="/opt/substore"
SB_CONFIG_DIR="/etc/sing-box"
CF_CONFIG_DIR="/etc/cloudflared"

# --- 日志函数 ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_succ() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}==>${NC} $1"; }

# --- 权限检查 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "必须使用 root 权限运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

# --- 依赖检测与安装 ---
install_dependencies() {
    log_step "系统环境初始化与依赖安装..."
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) SB_ARCH="amd64"; CF_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64"; CF_ARCH="arm64" ;;
        *) log_err "不支持的架构: $ARCH"; exit 1 ;;
    esac

    # 包管理器检测
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
        apt-get update -y
        apt-get install -y curl wget jq openssl qrencode ufw tar
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
        yum install -y epel-release
        yum install -y curl wget jq openssl qrencode firewalld tar
    else
        log_err "无法识别的操作系统，仅支持 Debian/Ubuntu/CentOS"
        exit 1
    fi

    # Docker 安装 (用于 Sub-Store)
    if ! command -v docker &> /dev/null; then
        log_info "正在安装 Docker..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    else
        log_succ "Docker 已安装"
    fi
}

# ====================================================
# 模块 A: Sing-box 核心网络层 (Reality + TUIC)
# ====================================================

install_singbox_core() {
    log_step "部署 Sing-box 核心服务..."

    # 获取最新版本
    LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
    VER="${LATEST_TAG#v}"
    SB_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VER}-linux-${SB_ARCH}.tar.gz"
    
    # 下载安装
    cd /tmp
    wget -O sb.tar.gz "$SB_URL"
    tar -xzf sb.tar.gz
    SB_EXT_DIR=$(tar -tzf sb.tar.gz | head -n 1 | cut -d/ -f1)
    install -m 755 "${SB_EXT_DIR}/sing-box" /usr/local/bin/sing-box
    rm -rf "${SB_EXT_DIR}" sb.tar.gz

    log_succ "Sing-box 二进制文件安装完成"
}

configure_singbox() {
    mkdir -p $SB_CONFIG_DIR
    
    # 交互式配置
    echo ""
    log_info "配置 Sing-box 参数:"
    read -rp "请输入 Reality 伪装域名 (默认: www.apple.com): " REALITY_DOMAIN
    REALITY_DOMAIN=${REALITY_DOMAIN:-www.apple.com}
    
    # 生成密钥
    log_info "生成密钥对..."
    sing-box generate reality-keypair > /tmp/sb_keys
    PRI_KEY=$(grep "PrivateKey" /tmp/sb_keys | awk '{print $2}')
    PUB_KEY=$(grep "PublicKey" /tmp/sb_keys | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)
    UUID_VLESS=$(cat /proc/sys/kernel/random/uuid)
    UUID_TUIC=$(cat /proc/sys/kernel/random/uuid)
    PASS_TUIC=$(openssl rand -base64 12)

    # 生成 TUIC 自签名证书
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout $SB_CONFIG_DIR/tuic.key -out $SB_CONFIG_DIR/tuic.crt \
    -subj "/CN=tuic.server" >/dev/null 2>&1

    # 写入配置 (Security Hardened)
    cat > $SB_CONFIG_DIR/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "$UUID_VLESS", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_DOMAIN", "server_port": 443 },
          "private_key": "$PRI_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [{ "uuid": "$UUID_TUIC", "password": "$PASS_TUIC" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$SB_CONFIG_DIR/tuic.crt",
        "key_path": "$SB_CONFIG_DIR/tuic.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
    
    # 创建 Systemd 服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $SB_CONFIG_DIR/config.json
Restart=always
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    
    # 保存凭证
    cat > $SB_CONFIG_DIR/credentials.txt <<EOF
[VLESS Reality]
IP: $(curl -s https://api.ip.sb)
Port: 443
UUID: $UUID_VLESS
SNI: $REALITY_DOMAIN
PBK: $PUB_KEY
SID: $SHORT_ID

[TUIC V5]
IP: $(curl -s https://api.ip.sb)
Port: 8443
UUID: $UUID_TUIC
Pass: $PASS_TUIC
EOF

    log_succ "Sing-box 配置完成！凭证已保存至 $SB_CONFIG_DIR/credentials.txt"
}

# ====================================================
# 模块 B: Sub-Store + Cloudflare Tunnel (应用层)
# ====================================================

install_substore_stack() {
    log_step "部署 Sub-Store 容器..."
    
    mkdir -p $SUBSTORE_DIR
    
    # 编写 Docker Compose (只监听本地 127.0.0.1，安全加固)
    cat > $SUBSTORE_DIR/docker-compose.yml <<EOF
version: '3.8'
services:
  sub-store:
    image: xream/sub-store:latest
    container_name: sub-store
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - ./data:/opt/app/data
    environment:
      - SUB_STORE_FRONTEND_BACKEND_PATH=/
EOF

    cd $SUBSTORE_DIR
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    log_succ "Sub-Store 正在后台运行 (端口 3001)"
}

setup_tunnel_interactive() {
    log_step "配置 Cloudflare Tunnel..."
    
    # 安装 Cloudflared
    if ! command -v cloudflared &> /dev/null; then
        log_info "下载 Cloudflared..."
        curl -L --output /tmp/cf.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
        dpkg -i /tmp/cf.deb || rpm -i /tmp/cf.deb
        rm /tmp/cf.deb
    fi

    # 登录流程
    if [ ! -f ~/.cloudflared/cert.pem ]; then
        log_warn "请点击终端显示的链接，在浏览器中登录 Cloudflare 授权："
        cloudflared tunnel login
    fi

    echo ""
    read -rp "请输入你要分配给 Sub-Store 的域名 (例如 sub.example.com): " CF_DOMAIN
    read -rp "为 Tunnel 命名 (例如 my-vps-tunnel): " TUNNEL_NAME
    
    # 创建隧道
    cloudflared tunnel create "$TUNNEL_NAME" || log_warn "Tunnel 可能已存在"
    TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
    
    if [ -z "$TUNNEL_ID" ]; then log_err "Tunnel ID 获取失败"; return; fi

    # 配置隧道映射
    mkdir -p $CF_CONFIG_DIR
    cat > $CF_CONFIG_DIR/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json
ingress:
  - hostname: $CF_DOMAIN
    service: http://127.0.0.1:3001
  - service: http_status:404
EOF

    # 路由 DNS
    log_info "正在向 Cloudflare 注册 DNS 记录..."
    cloudflared tunnel route dns "$TUNNEL_ID" "$CF_DOMAIN"

    # 安装并启动服务
    cloudflared service uninstall 2>/dev/null || true
    cloudflared --config $CF_CONFIG_DIR/config.yml service install
    systemctl restart cloudflared
    
    log_succ "Tunnel 部署完成！"
    log_info "Sub-Store 访问地址: https://$CF_DOMAIN"
}

# ====================================================
# 模块 C: 系统优化与防火墙
# ====================================================

system_tuning() {
    log_step "应用防火墙与 BBR 优化..."
    
    # 开放 Sing-box 端口，但 Sub-Store 不需要开放端口（走 Tunnel）
    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8443/udp
        echo "y" | ufw enable
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=8443/udp
        firewall-cmd --reload
    fi
    
    # 开启 BBR
    if ! grep -q "bbr" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        log_succ "BBR 已开启"
    fi
}

# ====================================================
# 主控菜单
# ====================================================

show_dashboard() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}   全栈网络架构师 - 综合部署工具 (v3.0)   ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "1. ${GREEN}一键全家桶安装${NC} (Sing-box + Sub-Store + Tunnel)"
    echo -e "2. 单独安装/重置 Sing-box (Reality/TUIC)"
    echo -e "3. 单独部署 Sub-Store 面板 (Docker)"
    echo -e "4. 配置 Cloudflare Tunnel (穿透)"
    echo -e "5. 查看连接凭证 (Credentials)"
    echo -e "6. 卸载/清理所有服务"
    echo -e "0. 退出"
    echo -e "${CYAN}====================================================${NC}"
    echo ""
}

main() {
    check_root
    while true; do
        show_dashboard
        read -rp "请选择操作 [0-6]: " choice
        case $choice in
            1)
                install_dependencies
                install_singbox_core
                configure_singbox
                install_substore_stack
                setup_tunnel_interactive
                system_tuning
                echo -e "\n${GREEN}🎉 全栈部署完成！请查看上方输出获取凭证。${NC}"
                read -rp "按回车键继续..."
                ;;
            2)
                install_dependencies
                install_singbox_core
                configure_singbox
                system_tuning
                read -rp "按回车键继续..."
                ;;
            3)
                install_dependencies
                install_substore_stack
                read -rp "按回车键继续..."
                ;;
            4)
                install_dependencies
                setup_tunnel_interactive
                read -rp "按回车键继续..."
                ;;
            5)
                if [ -f $SB_CONFIG_DIR/credentials.txt ]; then
                    cat $SB_CONFIG_DIR/credentials.txt
                else
                    log_err "未找到凭证文件，请先安装 Sing-box。"
                fi
                read -rp "按回车键继续..."
                ;;
            6)
                log_warn "正在清理..."
                systemctl stop sing-box cloudflared 2>/dev/null
                systemctl disable sing-box cloudflared 2>/dev/null
                rm -rf /usr/local/bin/sing-box /etc/sing-box /etc/cloudflared
                if [ -d "$SUBSTORE_DIR" ]; then
                    cd $SUBSTORE_DIR && docker compose down
                    rm -rf $SUBSTORE_DIR
                fi
                log_succ "清理完成"
                read -rp "按回车键继续..."
                ;;
            0) exit 0 ;;
            *) log_err "无效输入" ;;
        esac
    done
}

main