cat <<'EOF' > /usr/bin/hy && chmod +x /usr/bin/hy
#!/bin/bash

# Hysteria 2 V3.0 全功能管理脚本 (安全增强版)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
CONF_FILE="/etc/hysteria/config.yaml"

# 检查状态
check_status() {
    if systemctl is-active --quiet hysteria-server; then return 0; else return 1; fi
}

# 核心安装函数
install_hy3() {
    echo -e "${BLUE}===== 开始安装 Hysteria 2 V3.0 安全增强版 =====${PLAIN}"
    apt update && apt install -y curl socat openssl cron wget psmisc
    
    while true; do
        echo -e "${YELLOW}请输入你的域名 (千万不能带下划线 _ ):${PLAIN}"
        read -p "> " MY_DOMAIN
        if [[ "$MY_DOMAIN" == *"_"* ]]; then
            echo -e "${RED}错误：域名中包含下划线 '_'，证书机构不支持！请修改为横杠 '-' 或连写。${PLAIN}"
        else
            break
        fi
    done

    echo -e "${YELLOW}请输入你的邮箱 (用于接收证书续期通知):${PLAIN}"
    read -p "> " MY_EMAIL

    # 1. 环境洗白
    rm -rf ~/.acme.sh/
    fuser -k 80/tcp

    # 2. 申请正式 CA 证书
    echo -e "${YELLOW}正在通过 acme.sh 申请正式 CA 证书 (Let's Encrypt)...${PLAIN}"
    curl https://get.acme.sh | sh -s email=$MY_EMAIL
    source ~/.bashrc
    ~/.acme.sh/acme.sh --issue -d $MY_DOMAIN --standalone --server letsencrypt
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请失败！请确认域名已解析到此IP且80端口未被占用。${PLAIN}"
        exit 1
    fi

    # 3. 安装官方内核
    echo -e "${YELLOW}正在下载并安装 Hysteria 2 官方核心...${PLAIN}"
    bash <(curl -fsSL https://get.hy2.sh/)

    # 4. 部署证书
    mkdir -p /etc/hysteria
    ~/.acme.sh/acme.sh --install-cert -d $MY_DOMAIN --key-file /etc/hysteria/server.key --fullchain-file /etc/hysteria/server.crt

    # 5. 生成随机强密码和混淆
    PASS=$(openssl rand -base64 16 | tr -d '/+=')
    OBFS=$(openssl rand -base64 16 | tr -d '/+=')

    # 6. 写入 V3.0 深度伪装配置
    cat <<EOC > $CONF_FILE
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
EOC

    chown -R hysteria:hysteria /etc/hysteria
    systemctl enable hysteria-server && systemctl restart hysteria-server
    echo -e "${GREEN}安装部署成功！${PLAIN}"
    show_config
}

# 显示配置
show_config() {
    if [ ! -f $CONF_FILE ]; then echo -e "${RED}检测到未安装或配置文件缺失！${PLAIN}"; return; fi
    IP=$(curl -s4 https://api.ipify.org)
    PASS=$(grep 'password:' $CONF_FILE | head -n 1 | awk '{print $2}' | tr -d '"')
    OBFS=$(grep 'password:' $CONF_FILE | tail -n 1 | awk '{print $2}' | tr -d '"')
    SNI=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
    URL="hysteria2://$PASS@$IP:443/?insecure=0&sni=$SNI&obfs=salamander&obfs-password=$OBFS#Hy2_V3_Secure"
    echo -e "\n${BLUE}========== V3.0 配置信息 ==========${PLAIN}"
    echo -e "域名 (SNI): ${GREEN}$SNI${PLAIN}"
    echo -e "配置链接: ${YELLOW}$URL${PLAIN}"
    echo -e "${BLUE}===================================${PLAIN}"
}

# 主循环
if [ ! -f $CONF_FILE ]; then
    install_hy3
fi

while true; do
    echo -ne "\n${BLUE}--- Hy2 V3.0 管理 ---${PLAIN}\n1. 重新安装 (更换域名/重申证书)\n2. 查看当前配置\n3. 重启服务\n4. 停止服务\n5. 彻底卸载\n0. 退出\n选择: "
    read choice
    case $choice in
        1) install_hy3 ;;
        2) show_config ;;
        3) systemctl restart hysteria-server; echo "服务已重启" ;;
        4) systemctl stop hysteria-server; echo "服务已停止" ;;
        5) systemctl stop hysteria-server; rm -rf /etc/hysteria /usr/bin/hy; echo "已彻底卸载"; exit 0 ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
EOF
# 立即赋予权限并启动安装
chmod +x /usr/bin/hy
hy
