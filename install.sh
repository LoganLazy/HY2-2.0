#!/bin/bash

# Hysteria 2 V3.0 全功能管理脚本
# 集成：自动CA证书、Salamander混淆、深度伪装、菜单管理

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

CONF_FILE="/etc/hysteria/config.yaml"

# 检查状态
check_status() {
    if systemctl is-active --quiet hysteria-server; then
        return 0
    else
        return 1
    fi
}

# 核心安装函数
install_hy3() {
    apt update && apt install -y curl socat openssl cron wget psmisc
    echo -e "${YELLOW}请输入你的域名:${PLAIN}"
    read -p "> " MY_DOMAIN
    echo -e "${YELLOW}请输入你的邮箱 (请确保输入正确，不要有退格符):${PLAIN}"
    read -p "> " MY_EMAIL

    # 1. 彻底清理旧证书环境
    rm -rf ~/.acme.sh/
    fuser -k 80/tcp

    # 2. 申请真证书
    echo -e "${YELLOW}正在申请 Let's Encrypt 证书...${PLAIN}"
    curl https://get.acme.sh | sh -s email=$MY_EMAIL
    source ~/.bashrc
    ~/.acme.sh/acme.sh --issue -d $MY_DOMAIN --standalone --server letsencrypt
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请失败！请检查域名解析是否正确指向量该服务器 IP。${PLAIN}"
        exit 1
    fi

    # 3. 安装官方内核
    bash <(curl -fsSL https://get.hy2.sh/)

    # 4. 部署证书
    mkdir -p /etc/hysteria
    ~/.acme.sh/acme.sh --install-cert -d $MY_DOMAIN \
    --key-file       /etc/hysteria/server.key  \
    --fullchain-file /etc/hysteria/server.crt

    # 5. 生成 V3.0 配置文件
    PASS=$(openssl rand -base64 16 | tr -d '/+=')
    OBFS=$(openssl rand -base64 16 | tr -d '/+=')
    cat <<EOF > $CONF_FILE
listen: :443
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: "$PASS"
obfs:
  type: salamander
  password: "$OBFS"
masquerade:
  type: proxy
  proxy:
    url: https://www.universityofcalifornia.edu
    rewriteHost: true
EOF

    chown -R hysteria:hysteria /etc/hysteria
    systemctl enable hysteria-server
    systemctl restart hysteria-server
    echo -e "${GREEN}安装完成！${PLAIN}"
    show_config
}

# 显示配置
show_config() {
    if [ ! -f $CONF_FILE ]; then
        echo -e "${RED}未发现配置文件！${PLAIN}"
        return
    fi
    IP=$(curl -s4 https://api.ipify.org)
    PASS=$(grep 'password:' $CONF_FILE | head -n 1 | awk '{print $2}' | tr -d '"')
    OBFS=$(grep 'password:' $CONF_FILE | tail -n 1 | awk '{print $2}' | tr -d '"')
    SNI=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
    URL="hysteria2://$PASS@$IP:443/?insecure=0&sni=$SNI&obfs=salamander&obfs-password=$OBFS#Hy2_V3_Secure"
    
    echo -e "\n${BLUE}========== 配置信息 ==========${PLAIN}"
    echo -e "域名 (SNI): ${GREEN}$SNI${PLAIN}"
    echo -e "节点链接: ${YELLOW}$URL${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
}

# 主菜单
while true; do
    echo -e "${BLUE}--- Hysteria 2 V3.0 管理菜单 ---${PLAIN}"
    check_status
    if [ $? -eq 0 ]; then
        echo -e "服务状态: ${GREEN}运行中${PLAIN}"
    else
        echo -e "服务状态: ${RED}未运行${PLAIN}"
    fi
    echo -e "1. 安装/覆盖安装 V3.0"
    echo -e "2. 查看配置信息"
    echo -e "3. 重启服务"
    echo -e "4. 停止服务"
    echo -e "5. 卸载"
    echo -e "0. 退出"
    read -p "请选择: " choice
    case $choice in
        1) install_hy3 ;;
        2) show_config ;;
        3) systemctl restart hysteria-server ;;
        4) systemctl stop hysteria-server ;;
        5) 
            systemctl stop hysteria-server
            rm -rf /etc/hysteria /usr/bin/hy
            echo -e "${GREEN}已卸载${PLAIN}"
            exit 0 ;;
        0) exit 0 ;;
    esac
done
