#!/bin/bash

# Sub-Store + Cloudflare Tunnel 管理脚本
# 版本: 2.0
# 功能: 安装、卸载、状态查看、完整清理

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置常量
SUBSTORE_DIR="/opt/substore"
CF_CONFIG_DIR="/etc/cloudflared"
CF_CONFIG_FILE="$CF_CONFIG_DIR/config.yml"
TUNNEL_NAME="substore-tunnel"

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}==>${NC} $1"
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
================================================
   Sub-Store + Cloudflare Tunnel 管理脚本
                  v2.0
================================================
EOF
    echo -e "${NC}"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统架构
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armhf" ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "系统架构: $ARCH"
}

# 显示主菜单
show_menu() {
    echo ""
    echo "请选择操作："
    echo ""
    echo "  ${GREEN}1)${NC} 全新安装"
    echo "  ${CYAN}2)${NC} 查看状态"
    echo "  ${CYAN}3)${NC} 重启服务"
    echo "  ${CYAN}4)${NC} 查看日志"
    echo "  ${YELLOW}5)${NC} 重新配置"
    echo "  ${RED}6)${NC} 完全卸载"
    echo "  ${BLUE}0)${NC} 退出"
    echo ""
    read -p "请输入选项 [0-6]: " choice
    echo ""
}

# 检查组件安装状态
check_docker_installed() {
    command -v docker &> /dev/null
}

check_cloudflared_installed() {
    command -v cloudflared &> /dev/null
}

check_substore_running() {
    [ -d "$SUBSTORE_DIR" ] && docker ps 2>/dev/null | grep -q sub-store
}

check_tunnel_running() {
    systemctl is-active --quiet cloudflared 2>/dev/null
}

# 安装 Docker
install_docker() {
    log_step "检查 Docker 状态..."

    if check_docker_installed; then
        log_success "Docker 已安装: $(docker --version)"
        if ! systemctl is-active --quiet docker; then
            log_info "启动 Docker 服务..."
            systemctl start docker
            systemctl enable docker
        fi
        return 0
    fi

    log_info "开始安装 Docker..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl start docker
    systemctl enable docker

    log_success "Docker 安装完成！"
}

# 部署 Sub-Store
setup_substore() {
    log_step "配置 Sub-Store..."

    if [ -d "$SUBSTORE_DIR" ]; then
        log_warning "Sub-Store 已存在"
        read -p "是否重新部署? (y/n): " redeploy
        if [[ $redeploy != "y" ]]; then
            log_info "保留现有配置"
            return 0
        fi
        cd $SUBSTORE_DIR && docker compose down 2>/dev/null || true
    fi

    mkdir -p $SUBSTORE_DIR

    cat > $SUBSTORE_DIR/docker-compose.yml <<'EOF'
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
    networks:
      - substore-network

networks:
  substore-network:
    driver: bridge
EOF

    log_info "启动 Sub-Store..."
    cd $SUBSTORE_DIR
    docker compose pull
    docker compose up -d
    sleep 5

    if docker ps | grep -q sub-store; then
        log_success "Sub-Store 启动成功！"
    else
        log_error "Sub-Store 启动失败"
        docker compose logs
        exit 1
    fi
}

# 安装 cloudflared
install_cloudflared() {
    log_step "检查 cloudflared..."

    if check_cloudflared_installed; then
        log_success "cloudflared 已安装"
        return 0
    fi

    log_info "安装 cloudflared..."
    case $ARCH in
        amd64) DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" ;;
        arm64) DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" ;;
        armhf) DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb" ;;
    esac

    curl -L --output /tmp/cloudflared.deb $DEB_URL
    dpkg -i /tmp/cloudflared.deb
    rm /tmp/cloudflared.deb

    log_success "cloudflared 安装完成！"
}

# 清理 Tunnel 配置
cleanup_tunnel_config() {
    log_info "清理现有 Tunnel 配置..."

    systemctl stop cloudflared 2>/dev/null || true
    cloudflared service uninstall 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared.service
    rm -rf /etc/systemd/system/cloudflared.service.d
    systemctl daemon-reload

    log_success "配置已清理"
}

# 配置 Cloudflare Tunnel
setup_cloudflare_tunnel() {
    log_step "配置 Cloudflare Tunnel..."

    # 检查登录状态
    if [ ! -f ~/.cloudflared/cert.pem ]; then
        echo ""
        log_warning "需要登录 Cloudflare"
        echo "按 Enter 后将打开浏览器进行授权..."
        read -p "按 Enter 继续..."

        cloudflared tunnel login

        if [ ! -f ~/.cloudflared/cert.pem ]; then
            log_error "登录失败"
            exit 1
        fi
        log_success "登录成功！"
    fi

    # 输入 Tunnel 名称
    echo ""
    read -p "Tunnel 名称 [默认: $TUNNEL_NAME]: " input_name
    TUNNEL_NAME=${input_name:-$TUNNEL_NAME}

    # 处理已存在的 Tunnel
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        log_warning "Tunnel '$TUNNEL_NAME' 已存在"
        echo ""
        echo "选项："
        echo "  1) 删除并重新创建（推荐）"
        echo "  2) 使用现有 Tunnel"
        echo "  3) 取消"
        read -p "请选择 [1-3]: " opt

        case $opt in
            1)
                OLD_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
                log_info "删除旧 Tunnel..."
                cloudflared tunnel delete $OLD_ID 2>/dev/null || true
                rm -f ~/.cloudflared/$OLD_ID.json 2>/dev/null || true
                TUNNEL_ID=""
                ;;
            2)
                TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
                if [ ! -f ~/.cloudflared/$TUNNEL_ID.json ]; then
                    log_error "凭证文件丢失，必须重新创建"
                    exit 1
                fi
                ;;
            *)
                log_info "已取消"
                exit 0
                ;;
        esac
    fi

    # 创建新 Tunnel
    if [ -z "$TUNNEL_ID" ]; then
        log_info "创建 Tunnel: $TUNNEL_NAME"
        cloudflared tunnel create $TUNNEL_NAME
        TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')

        if [ -z "$TUNNEL_ID" ]; then
            log_error "创建失败"
            exit 1
        fi
        log_success "Tunnel 创建成功！"
        log_info "Tunnel ID: $TUNNEL_ID"
    fi

    # 验证凭证文件
    CREDENTIALS_FILE="$HOME/.cloudflared/$TUNNEL_ID.json"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        log_error "凭证文件不存在: $CREDENTIALS_FILE"
        exit 1
    fi

    # 输入域名
    echo ""
    read -p "域名 (例如: sub.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        log_error "域名不能为空"
        exit 1
    fi

    # 创建配置文件
    mkdir -p $CF_CONFIG_DIR
    cat > $CF_CONFIG_FILE <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS_FILE

ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:3001
  - service: http_status:404
EOF

    log_success "配置文件已创建"

    # 配置 DNS
    log_info "配置 DNS..."
    if cloudflared tunnel route dns $TUNNEL_ID $DOMAIN 2>&1 | grep -q "already exists"; then
        echo ""
        log_warning "DNS 记录已存在，需要手动处理："
        echo ""
        echo "${YELLOW}请按以下步骤操作：${NC}"
        echo "1. 访问: ${CYAN}https://dash.cloudflare.com${NC}"
        echo "2. 选择域名 $(echo $DOMAIN | rev | cut -d. -f1-2 | rev)"
        echo "3. 进入 ${CYAN}DNS -> Records${NC}"
        echo "4. ${RED}删除${NC}现有的 ${CYAN}$(echo $DOMAIN | cut -d. -f1)${NC} 记录"
        echo "5. ${GREEN}添加${NC}新的 CNAME 记录："
        echo "   - 类型: ${GREEN}CNAME${NC}"
        echo "   - 名称: ${GREEN}$(echo $DOMAIN | cut -d. -f1)${NC}"
        echo "   - 目标: ${GREEN}$TUNNEL_ID.cfargotunnel.com${NC}"
        echo "   - 代理: ${GREEN}开启${NC}（橙色云朵）"
        echo ""
        read -p "完成后按 Enter 继续..."
    else
        log_success "DNS 配置成功！"
    fi

    # 清理并重新安装服务
    cleanup_tunnel_config

    log_info "安装服务..."
    cloudflared --config $CF_CONFIG_FILE service install
    systemctl start cloudflared
    systemctl enable cloudflared

    sleep 3

    if systemctl is-active --quiet cloudflared; then
        log_success "服务启动成功！"
    else
        log_error "服务启动失败"
        journalctl -u cloudflared -n 20 --no-pager
        exit 1
    fi

    # 显示完成信息
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}             部署完成！${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo -e "访问地址: ${CYAN}https://$DOMAIN${NC}"
    echo ""
    echo "首次访问配置："
    echo "  后端地址: ${CYAN}https://$DOMAIN${NC}"
    echo ""
    echo "提示："
    echo "  - DNS 生效可能需要 1-2 分钟"
    echo "  - 流量经 Cloudflare 加密保护"
    echo "  - 无需开放任何防火墙端口"
    echo ""
}

# 查看状态
show_status() {
    show_banner
    echo "系统状态"
    echo "========================================"
    echo ""

    echo -n "Docker: "
    if check_docker_installed; then
        if systemctl is-active --quiet docker; then
            echo -e "${GREEN}运行中${NC}"
        else
            echo -e "${YELLOW}已安装但未运行${NC}"
        fi
    else
        echo -e "${RED}未安装${NC}"
    fi

    echo -n "Sub-Store: "
    if check_substore_running; then
        echo -e "${GREEN}运行中${NC}"
        docker ps --filter name=sub-store --format "  └─ {{.Names}}: {{.Status}}"
    else
        [ -d "$SUBSTORE_DIR" ] && echo -e "${YELLOW}已配置但未运行${NC}" || echo -e "${RED}未部署${NC}"
    fi

    echo -n "Cloudflare Tunnel: "
    if check_cloudflared_installed; then
        if check_tunnel_running; then
            echo -e "${GREEN}运行中${NC}"
            if [ -f "$CF_CONFIG_FILE" ]; then
                TUNNEL_ID=$(grep "^tunnel:" $CF_CONFIG_FILE | awk '{print $2}')
                DOMAIN=$(grep "hostname:" $CF_CONFIG_FILE | awk '{print $3}')
                echo "  └─ ID: $TUNNEL_ID"
                echo "  └─ 域名: ${CYAN}https://$DOMAIN${NC}"
            fi
        else
            echo -e "${RED}未运行${NC}"
        fi
    else
        echo -e "${RED}未安装${NC}"
    fi

    echo ""
}

# 重启服务
restart_services() {
    show_banner
    log_step "重启服务..."
    echo ""

    if [ -d "$SUBSTORE_DIR" ]; then
        log_info "重启 Sub-Store..."
        cd $SUBSTORE_DIR && docker compose restart
        log_success "Sub-Store 已重启"
    fi

    if check_cloudflared_installed; then
        log_info "重启 Cloudflare Tunnel..."
        systemctl restart cloudflared
        log_success "Cloudflare Tunnel 已重启"
    fi

    echo ""
    read -p "按 Enter 返回..."
}

# 查看日志
show_logs() {
    show_banner
    echo "日志选项"
    echo "========================================"
    echo ""
    echo "  1) Sub-Store 日志"
    echo "  2) Cloudflare Tunnel 日志"
    echo "  0) 返回"
    echo ""
    read -p "请选择 [0-2]: " log_opt
    echo ""

    case $log_opt in
        1)
            if [ -d "$SUBSTORE_DIR" ]; then
                log_info "Sub-Store 日志 (Ctrl+C 退出)"
                echo ""
                cd $SUBSTORE_DIR && docker compose logs -f
            else
                log_error "Sub-Store 未部署"
            fi
            ;;
        2)
            if check_cloudflared_installed; then
                log_info "Cloudflare Tunnel 日志 (Ctrl+C 退出)"
                echo ""
                journalctl -u cloudflared -f
            else
                log_error "cloudflared 未安装"
            fi
            ;;
    esac

    echo ""
    read -p "按 Enter 返回..."
}

# 重新配置
reconfigure() {
    show_banner
    echo "重新配置向导"
    echo "========================================"
    echo ""
    echo "  1) 仅重新配置 Cloudflare Tunnel"
    echo "  2) 重新部署 Sub-Store"
    echo "  3) 全部重新配置"
    echo "  0) 返回"
    echo ""
    read -p "请选择 [0-3]: " reconf_opt
    echo ""

    case $reconf_opt in
        1)
            cleanup_tunnel_config
            setup_cloudflare_tunnel
            ;;
        2)
            if [ -d "$SUBSTORE_DIR" ]; then
                cd $SUBSTORE_DIR && docker compose down
            fi
            setup_substore
            ;;
        3)
            if [ -d "$SUBSTORE_DIR" ]; then
                cd $SUBSTORE_DIR && docker compose down
            fi
            cleanup_tunnel_config
            setup_substore
            setup_cloudflare_tunnel
            ;;
    esac

    echo ""
    read -p "按 Enter 返回..."
}

# 完全卸载
uninstall_all() {
    show_banner
    echo -e "${RED}警告：完全卸载${NC}"
    echo "========================================"
    echo ""
    echo "将会删除："
    echo "  - Cloudflare Tunnel 服务和配置"
    echo "  - Sub-Store 容器"
    echo "  - 所有配置文件"
    echo ""
    echo -e "${YELLOW}注意：${NC}"
    echo "  - Docker 和 cloudflared 程序不会被卸载"
    echo "  - 可选择保留 Sub-Store 数据"
    echo ""
    read -p "确认卸载？输入 YES 继续: " confirm

    if [ "$confirm" != "YES" ]; then
        log_info "已取消"
        return
    fi

    echo ""
    log_step "开始卸载..."
    echo ""

    # 停止并删除 cloudflared
    if check_cloudflared_installed; then
        log_info "停止 Cloudflare Tunnel..."
        systemctl stop cloudflared 2>/dev/null || true
        cloudflared service uninstall 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared.service
        rm -rf /etc/systemd/system/cloudflared.service.d
        systemctl daemon-reload

        # 获取域名信息
        if [ -f "$CF_CONFIG_FILE" ]; then
            DOMAIN=$(grep "hostname:" $CF_CONFIG_FILE | awk '{print $3}')
            TUNNEL_ID=$(grep "^tunnel:" $CF_CONFIG_FILE | awk '{print $2}')
        fi

        # 询问是否删除 Tunnel
        if cloudflared tunnel list 2>/dev/null | grep -v "^ID" | grep -q "[a-z0-9]"; then
            echo ""
            cloudflared tunnel list
            echo ""
            read -p "是否删除 Cloudflare Tunnel? (y/n): " del_tunnel
            if [[ $del_tunnel == "y" ]]; then
                while read line; do
                    [[ $line =~ ^ID ]] && continue
                    [[ -z $line ]] && continue
                    tid=$(echo $line | awk '{print $1}')
                    tname=$(echo $line | awk '{print $2}')
                    log_info "删除 Tunnel: $tname"
                    cloudflared tunnel delete $tid 2>/dev/null || true
                done < <(cloudflared tunnel list 2>/dev/null)
            fi
        fi

        # 删除配置
        rm -rf $CF_CONFIG_DIR
        rm -f ~/.cloudflared/*.json 2>/dev/null || true
        log_success "Cloudflare Tunnel 已清理"
    fi

    # 停止并删除 Sub-Store
    if [ -d "$SUBSTORE_DIR" ]; then
        log_info "停止 Sub-Store..."
        cd $SUBSTORE_DIR && docker compose down 2>/dev/null || true

        echo ""
        read -p "是否删除 Sub-Store 数据? (y/n): " del_data
        if [[ $del_data == "y" ]]; then
            rm -rf $SUBSTORE_DIR
            log_success "Sub-Store 数据已删除"
        else
            log_info "数据保留在: $SUBSTORE_DIR"
        fi
    fi

    # 提醒删除 DNS
    if [ ! -z "$DOMAIN" ]; then
        echo ""
        echo -e "${YELLOW}================================================${NC}"
        echo -e "${YELLOW}重要：请手动删除 Cloudflare DNS 记录${NC}"
        echo -e "${YELLOW}================================================${NC}"
        echo ""
        echo "1. 访问: ${CYAN}https://dash.cloudflare.com${NC}"
        echo "2. 选择域名: $(echo $DOMAIN | rev | cut -d. -f1-2 | rev)"
        echo "3. 进入: ${CYAN}DNS -> Records${NC}"
        echo "4. 删除记录: ${CYAN}$DOMAIN${NC}"
        echo "   (CNAME 类型，指向 *.cfargotunnel.com)"
        echo ""
    fi

    echo ""
    log_success "卸载完成！"
    echo ""
    read -p "按 Enter 返回..."
}

# 全新安装
full_install() {
    show_banner
    log_step "开始安装..."
    echo ""

    check_root
    detect_arch
    echo ""

    install_docker
    echo ""

    setup_substore
    echo ""

    install_cloudflared
    echo ""

    setup_cloudflare_tunnel

    echo ""
    read -p "按 Enter 返回..."
}

# 主函数
main() {
    check_root

    while true; do
        show_banner
        show_menu

        case $choice in
            1) full_install ;;
            2) show_status; read -p "按 Enter 返回..." ;;
            3) restart_services ;;
            4) show_logs ;;
            5) reconfigure ;;
            6) uninstall_all ;;
            0) log_info "退出"; exit 0 ;;
            *) log_error "无效选项"; sleep 2 ;;
        esac
    done
}

# 运行
main
