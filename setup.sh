#!/usr/bin/env bash
# VLESS-REALITY + TUIC 一键脚本 v1.2
# 适配：Debian / Ubuntu，默认使用 sing-box + systemd
# 功能：
# 1）自动安装依赖 & sing-box
# 2）从你的 Gist 域名池测试延迟 → 自动选最快伪装域名（可手动改）
# 3）生成 Reality 密钥对、公私钥、UUID、TUIC 证书
# 4）写入 /etc/sing-box/config.json
# 5）启动 sing-box，并输出 vless:// / tuic:// 链接 + 终端二维码（可扫码）

set -e

########################################
# 基本校验
########################################

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 root 运行：sudo bash setup.sh"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "❌ 当前不是 Debian / Ubuntu 系统，暂不支持这个脚本。"
  exit 1
fi

########################################
# 配置参数（可按需改）
########################################

# 你的域名池 Gist
GIST_URL="https://gist.githubusercontent.com/cj3343/8d38d603440ea50105319d7c09909faf/raw/74ab1e5c3cd93a94ecfb8227bdc0db136228c9eb/domain-list.txt"

# 默认端口
DEFAULT_VLESS_PORT=443
DEFAULT_TUIC_PORT=8443

# sing-box 安装版本（官方二进制）
SINGBOX_VERSION="1.12.12"

########################################
# 安装依赖
########################################

echo "👉 更新软件源 & 安装依赖..."
apt update -y
apt install -y curl wget jq openssl qrencode coreutils

########################################
# 安装 sing-box
########################################

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "✅ 已检测到 sing-box：$(sing-box version 2>/dev/null || true)"
    return
  fi

  echo "👉 开始安装 sing-box v${SINGBOX_VERSION} ..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    *) echo "❌ 暂不支持当前架构：$ARCH"; exit 1 ;;
  esac

  TMP_DIR=$(mktemp -d)
  cd "$TMP_DIR"

  SB_TAR="sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${SB_TAR}"

  echo "👉 下载: $SB_URL"
  curl -fSL "$SB_URL" -o "$SB_TAR"
  tar -xzf "$SB_TAR"

  install "sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}/sing-box" /usr/local/bin/sing-box
  chmod +x /usr/local/bin/sing-box

  cd /
  rm -rf "$TMP_DIR"

  echo "✅ sing-box 安装完成: $(sing-box version 2>/dev/null || true)"
}

install_sing_box

########################################
# 选择 Reality 伪装域名：自动测试 + 可手动覆盖
########################################

choose_reality_domain() {
  echo "👉 从 Gist 拉取域名池并测试延迟：$GIST_URL"

  local domain_list
  if ! domain_list=$(curl -fsSL "$GIST_URL"); then
    echo "⚠️ 拉取域名池失败，将使用默认 www.apple.com"
    BEST_DOMAIN="www.apple.com"
    return
  fi

  local domains
  domains=$(printf "%s\n" "$domain_list" | shuf | head -n 10)

  local best_domain=""
  local best_rtt=999999

  echo "测速结果（单位：ms）："
  for d in $domains; do
    local t1 t2 rtt
    t1=$(date +%s%3N)
    if timeout 1 openssl s_client -connect "$d:443" -servername "$d" </dev/null &>/dev/null; then
      t2=$(date +%s%3N)
      rtt=$((t2 - t1))
      echo "  $d: ${rtt} ms"
      if [ "$rtt" -lt "$best_rtt" ]; then
        best_rtt=$rtt
        best_domain=$d
      fi
    else
      echo "  $d: timeout"
    fi
  done

  if [ -z "$best_domain" ]; then
    echo "⚠️ 未找到可用域名，使用默认 www.apple.com"
    best_domain="www.apple.com"
  else
    echo "✅ 选中的最低延迟域名：$best_domain (${best_rtt} ms)"
  fi

  BEST_DOMAIN="$best_domain"
}

choose_reality_domain

read -rp "Reality 伪装域名 [回车使用自动选择: ${BEST_DOMAIN}]：" REALITY_DOMAIN
REALITY_DOMAIN=${REALITY_DOMAIN:-$BEST_DOMAIN}
echo "✅ 最终使用的伪装域名：$REALITY_DOMAIN"

########################################
# 端口配置
########################################

read -rp "VLESS Reality 端口 [默认: ${DEFAULT_VLESS_PORT}]：" VLESS_PORT
VLESS_PORT=${VLESS_PORT:-$DEFAULT_VLESS_PORT}

read -rp "TUIC 端口 [默认: ${DEFAULT_TUIC_PORT}]：" TUIC_PORT
TUIC_PORT=${TUIC_PORT:-$DEFAULT_TUIC_PORT}

echo "✅ VLESS 端口: $VLESS_PORT"
echo "✅ TUIC  端口: $TUIC_PORT"

########################################
# 生成 UUID / Reality 密钥对 / TUIC 证书
########################################

echo "👉 生成 UUID ..."
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
TUIC_PASSWORD=$(openssl rand -hex 16)
SHORT_ID=$(openssl rand -hex 8)

echo "👉 生成 Reality 密钥对 ..."
REALITY_JSON=$(sing-box generate reality-keypair)
REALITY_PRIVATE_KEY=$(echo "$REALITY_JSON" | jq -r '.private_key')
REALITY_PUBLIC_KEY=$(echo "$REALITY_JSON" | jq -r '.public_key')

if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
  echo "❌ Reality 密钥对生成失败，请检查 sing-box 版本。"
  exit 1
fi

echo "✅ Reality private_key/public_key 已生成"

echo "👉 生成 TUIC 自签证书（仅用于 TLS 握手，不验证真实域名）..."
mkdir -p /etc/sing-box

openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/tuic-key.pem >/dev/null 2>&1
openssl req -new -x509 -days 36500 \
  -key /etc/sing-box/tuic-key.pem \
  -out /etc/sing-box/tuic-cert.pem \
  -subj "/CN=${REALITY_DOMAIN}" >/dev/null 2>&1

echo "✅ TUIC 证书 & 私钥: /etc/sing-box/tuic-cert.pem /etc/sing-box/tuic-key.pem"

########################################
# 写 config.json
########################################

echo "👉 写入 /etc/sing-box/config.json ..."

cat >/etc/sing-box/config.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "223.5.5.5"
      },
      {
        "tag": "remote",
        "address": "8.8.8.8"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "${VLESS_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_DOMAIN}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "${TUIC_UUID}",
          "password": "${TUIC_PASSWORD}"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/sing-box/tuic-cert.pem",
        "key_path": "/etc/sing-box/tuic-key.pem"
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
    "rules": [
      {
        "protocol": [
          "quic"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct"
      }
    ]
  }
}
EOF

echo "✅ config.json 写入完成"

########################################
# 写 systemd 服务
########################################

echo "👉 写入 /etc/systemd/system/sing-box.service ..."

cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

########################################
# 检查配置并启动
########################################

echo "👉 检查配置语法..."
if ! sing-box check -c /etc/sing-box/config.json; then
  echo "❌ 配置检查失败，请查看 /etc/sing-box/config.json"
  exit 1
fi
echo "✅ 配置检查通过"

echo "👉 重新加载 systemd & 启动 sing-box..."
systemctl daemon-reload
systemctl enable sing-box --now

sleep 2

if ! systemctl is-active --quiet sing-box; then
  echo "❌ sing-box 启动失败，请执行：journalctl -u sing-box -e 查看日志"
  exit 1
fi

echo "✅ sing-box 服务已启动"

########################################
# 生成 vless:// / tuic:// 链接 + 二维码
########################################

# 获取服务器 IP
echo "👉 获取服务器公网 IP ..."
SERVER_IP=$(curl -s4m8 ip.sb || curl -s ifconfig.me || echo "your_server_ip")

TAG_VLESS="VLESS-REALITY-${SERVER_IP}"
TAG_TUIC="TUIC-${SERVER_IP}"

VLESS_URL="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${TAG_VLESS}"

TUIC_URL="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&sni=${REALITY_DOMAIN}&alpn=h3#${TAG_TUIC}"

echo ""
echo "================= 节点信息 ================="
echo "VLESS Reality:"
echo "  $VLESS_URL"
echo ""
echo "TUIC:"
echo "  $TUIC_URL"
echo "==========================================="
echo ""

echo "👉 终端二维码（可直接手机扫码）："

echo "【VLESS Reality】"
echo "$VLESS_URL" | qrencode -o - -t ANSIUTF8

echo ""
echo "【TUIC】"
echo "$TUIC_URL" | qrencode -o - -t ANSIUTF8

echo ""
echo "✅ 全部完成！"
echo "提示："
echo "1）安卓 NekoBox：直接导入 vless:// 或 tuic:// 即可；"
echo "2）Mac Surge / sing-box / Nekoray：新建节点 → 粘贴链接导入；"
echo "3）后续你可以把 VLESS_URL / TUIC_URL 直接发给朋友或写进 README/X 帖子。"
