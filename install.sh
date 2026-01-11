#!/bin/bash

# Hysteria 2 自动化安全增强脚本 V3.0
# 功能：自动申请CA证书 + 安装Hy2 + 开启深度伪装

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

# 1. 基础依赖安装
echo -e "${YELLOW}正在安装必要依赖...${PLAIN}"
apt update && apt install -y curl socat openssl cron wget
# 确保 80 端口没被占用，以便申请证书
fuser -k 80/tcp 

# 2. 交互式输入
read -p "请输入你的域名 (例如: my.domain.com): " MY_DOMAIN
read -p "请输入你的邮箱 (用于证书续期提醒): " MY_EMAIL
[ -z "${MY_DOMAIN}" ] || [ -z "${MY_EMAIL}" ] && echo -e "${RED}域名和邮箱不能为空！${PLAIN}" && exit 1

# 3. 申请正式 CA 证书 (acme.sh)
echo -e "${YELLOW}开始申请 Let's Encrypt 证书...${PLAIN}"
curl https://get.acme.sh | sh -s email=$MY_EMAIL
source ~/.bashrc
~/.acme.sh/acme.sh --issue -d $MY_DOMAIN --standalone --server letsencrypt

# 4. 安装 Hysteria 2 官方程序
echo -e "${YELLOW}正在安装 Hysteria 2 核心...${PLAIN}"
bash <(curl -fsSL https://get.hy2.sh/)

# 5. 创建证书目录并安装证书
mkdir -p /etc/hysteria
~/.acme.sh/acme.sh --install-cert -d $MY_DOMAIN \
--key-file       /etc/hysteria/server.key  \
--fullchain-file /etc/hysteria/server.crt

# 6. 生成随机强密码和混淆密码
PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')
OBFS_PW=$(openssl rand -base64 16 | tr -d '/+=')

# 7. 写入优化后的配置文件
cat <<EOF > /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$PASSWORD"

# 开启混淆，对抗识别
obfs:
  type: salamander
  password: "$OBFS_PW"

# 深度伪装：更换为真实的海外冷门网站
masquerade:
  type: proxy
  proxy:
    url: https://www.ikea.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
EOF

# 8. 设置权限并启动
chown -R hysteria:hysteria /etc/hysteria
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# 9. 输出结果
IP=$(curl -s4 https://api.ipify.org)
URL="hysteria2://$PASSWORD@$IP:443/?insecure=0&sni=$MY_DOMAIN&obfs=salamander&obfs-password=$OBFS_PW#Hy2_V3_Secure"

echo -e "\n${GREEN}Hysteria 2 V3.0 部署成功！${PLAIN}"
echo -e "${BLUE}==============================================${PLAIN}"
echo -e "域名: ${GREEN}$MY_DOMAIN${PLAIN}"
echo -e "密码: ${GREEN}$PASSWORD${PLAIN}"
echo -e "混淆密码: ${GREEN}$OBFS_PW${PLAIN}"
echo -e "客户端配置请确保: ${YELLOW}insecure = false (开启证书校验)${PLAIN}"
echo -e "配置链接: ${YELLOW}$URL${PLAIN}"
echo -e "${BLUE}==============================================${PLAIN}"
