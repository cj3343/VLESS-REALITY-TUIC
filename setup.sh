#!/bin/bash
set -e

###################################
#   日志输出函数
###################################
log() { echo -e "\033[32m[INFO] $1\033[0m"; }
warn() { echo -e "\033[33m[WARN] $1\033[0m"; }
err() { echo -e "\033[31m[ERR ] $1\033[0m"; }

###################################
#   0. 环境准备
###################################
log "正在安装依赖..."
apt update -y
apt install -y curl wget jq qrencode iputils-ping openssl

###################################
#   1. 安装最新 sing-box
###################################
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) err "不支持的 CPU 架构: $ARCH"; exit 1 ;;
esac

LATEST=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST}/sing-box-${LATEST}-linux-${ARCH}.tar.gz"

log "下载并安装 sing-box $LATEST ..."
wget -O sb.tar.gz "$URL"
tar -xzf sb.tar.gz
install -m 755 sing-box*/sing-box /usr/local/bin/sing-box
rm -rf sing-box* sb.tar.gz

###################################
#   2. 域名池测速（使用你的 Gist）
###################################
DOMAIN_LIST_URL="https://gist.githubusercontent.com/cj3343/8d38d603440ea50105319d7c09909faf/raw/47e05fcfdece890d1480f462afadc0baffcbb120/domain-list.txt"

log "获取域名池 ..."
DOMAIN_LIST=$(curl -s "$DOMAIN_LIST_URL")

log "开始测试 Reality 目标域名延迟（openssl + 443）..."

BEST_DOMAIN=""
BEST_RTT=99999

for d in $DOMAIN_LIST; do
  t1=$(date +%s%3N)
  if timeout 1 openssl s_client -connect $d:443 -servername $d </dev/null &>/dev/null; then
    t2=$(date +%s%3N)
    rtt=$((t2 - t1))
    echo "  $d: ${rtt} ms"
    if [ "$rtt" -lt "$BEST_RTT" ]; then
      BEST_RTT=$rtt
      BEST_DOMAIN=$d
    fi
  else
    echo "  $d: timeout"
  fi
done

log "🔥 首轮测速最低延迟：$BEST_DOMAIN (${BEST_RTT} ms)"

###################################
#  用户选择：重新测速 / 手动输入 / 直接用
###################################
while true; do
    echo
    read -rp "Reality 域名选择 [回车=自动 ${BEST_DOMAIN}, R=重新测速, M=手动输入]: " CHOICE
    case "$CHOICE" in
        "")
            REALITY_DOMAIN="$BEST_DOMAIN"
            break
            ;;
        "R"|"r")
            log "重新执行脚本进行测速..."
            exec bash "$0"
            exit 0
            ;;
        "M"|"m")
            read -rp "请输入自定义 Reality 伪装域名（必须能 443 直连）: " REALITY_DOMAIN
            [ -z "$REALITY_DOMAIN" ] && err "域名不能为空" && exit 1
            break
            ;;
        *)
            echo "无效选项，请重新输入。"
            ;;
    esac
done

log "✅ 最终 Reality 伪装域名：$REALITY_DOMAIN"

###################################
#   3. 用户输入端口
###################################
read -rp "VLESS Reality 端口 [默认 443]: " VPORT
VPORT=${VPORT:-443}

read -rp "TUIC 端口 [默认 8443]: " TPORT
TPORT=${TPORT:-8443}

log "✅ VLESS 端口: $VPORT"
log "✅ TUIC  端口: $TPORT"

###################################
#   4. 生成 UUID + Reality 密钥
###################################
UUID=$(sing-box generate uuid)
log "生成 UUID: $UUID"

mkdir -p /etc/sing-box
sing-box generate reality-keypair > /etc/sing-box/reality.txt

PRIV=$(grep PrivateKey /etc/sing-box/reality.txt | awk '{print $2}')
PUB=$(grep PublicKey /etc/sing-box/reality.txt | awk '{print $2}')
SID=$(openssl rand -hex 8)

log "Reality PrivateKey: $PRIV"
log "Reality PublicKey : $PUB"
log "Reality ShortID   : $SID"

###################################
# 5. 备份旧配置并写入新 config.json
###################################
if [ -f /etc/sing-box/config.json ]; then
  BACKUP="/etc/sing-box/config.json.bak-$(date +%s)"
  cp /etc/sing-box/config.json "$BACKUP"
  warn "已备份旧 config.json 为 $BACKUP"
fi

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${VPORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "private_key": "${PRIV}",
          "short_id": [ "${SID}" ]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": ${TPORT},
      "users": {
        "${UUID}": {
          "password": "${UUID}"
        }
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

###################################
# 6. 检查配置合法性（不再使用特殊 outbounds）
###################################
log "检查配置合法性..."
sing-box check -c /etc/sing-box/config.json

###################################
# 7. 写 systemd 服务（不再设置 ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS）
###################################
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/sing-box -c /etc/sing-box/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart sing-box
systemctl enable sing-box

###################################
# 8. 获取服务器 IPv4
###################################
IPV4=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

###################################
# 9. 生成分享链接
###################################
VLESS_URL="vless://${UUID}@${IPV4}:${VPORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#VLESS-REALITY"
TUIC_URL="tuic://${UUID}:${UUID}@${IPV4}:${TPORT}?alpn=h3&congestion_control=bbr#TUIC"

echo
log "================= VLESS Reality 链接 ================="
echo "$VLESS_URL"
echo "===================================================="
echo
log "===================== TUIC 链接 ====================="
echo "$TUIC_URL"
echo "===================================================="
echo

###################################
# 10. 生成二维码
###################################
mkdir -p /root/singbox-qrcode
qrencode -o /root/singbox-qrcode/vless.png "$VLESS_URL"
qrencode -o /root/singbox-qrcode/tuic.png "$TUIC_URL"

log "二维码已保存到 /root/singbox-qrcode/"
log "全部完成！🎉 现在可以在 NekoBox / Surge / sing-box 客户端里导入链接测试了。"
