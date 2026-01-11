cat <<'EOF' > /usr/bin/hy && chmod +x /usr/bin/hy
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
CONF_FILE="/etc/hysteria/config.yaml"
check_status() {
    if systemctl is-active --quiet hysteria-server; then return 0; else return 1; fi
}
install_hy3() {
    apt update && apt install -y curl socat openssl cron wget psmisc
    echo -e "${YELLOW}请输入你的域名 (例如: usa_wawo.nodec.ggff.net):${PLAIN}"
    read -p "> " MY_DOMAIN
    echo -e "${YELLOW}请输入你的邮箱:${PLAIN}"
    read -p "> " MY_EMAIL
    rm -rf ~/.acme.sh/
    fuser -k 80/tcp
    echo -e "${YELLOW}正在通过 acme.sh 申请正式 CA 证书...${PLAIN}"
    curl https://get.acme.sh | sh -s email=$MY_EMAIL
    source ~/.bashrc
    ~/.acme.sh/acme.sh --issue -d $MY_DOMAIN --standalone --server letsencrypt
    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请失败！请确认域名已解析到此IP且80端口未被占用。${PLAIN}"
        exit 1
    fi
    bash <(curl -fsSL https://get.hy2.sh/)
    mkdir -p /etc/hysteria
    ~/.acme.sh/acme.sh --install-cert -d $MY_DOMAIN --key-file /etc/hysteria/server.key --fullchain-file /etc/hysteria/server.crt
    PASS=$(openssl rand -base64 16 | tr -d '/+=')
    OBFS=$(openssl rand -base64 16 | tr -d '/+=')
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
    show_config
}
show_config() {
    if [ ! -f $CONF_FILE ]; then echo -e "${RED}未安装！${PLAIN}"; return; fi
    IP=$(curl -s4 https://api.ipify.org); PASS=$(grep 'password:' $CONF_FILE | head -n 1 | awk '{print $2}' | tr -d '"')
    OBFS=$(grep 'password:' $CONF_FILE | tail -n 1 | awk '{print $2}' | tr -d '"'); SNI=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
    URL="hysteria2://$PASS@$IP:443/?insecure=0&sni=$SNI&obfs=salamander&obfs-password=$OBFS#Hy2_V3_Secure"
    echo -e "\n${BLUE}========== 配置信息 ==========${PLAIN}"
    echo -e "配置链接: ${YELLOW}$URL${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
}
while true; do
    echo -ne "\n${BLUE}--- Hy2 V3.0 管理 ---${PLAIN}\n1. 安装\n2. 配置\n3. 重启\n4. 停止\n5. 卸载\n0. 退出\n选择: "
    read choice
    case $choice in
        1) install_hy3 ;;
        2) show_config ;;
        3) systemctl restart hysteria-server ;;
        4) systemctl stop hysteria-server ;;
        5) systemctl stop hysteria-server; rm -rf /etc/hysteria /usr/bin/hy; echo "已卸载"; exit 0 ;;
        0) exit 0 ;;
    esac
done
EOF
echo "V3.0 菜单脚本已生成。请直接输入 hy 启动！"
