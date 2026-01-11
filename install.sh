cat <<'EOF' > /usr/bin/hy && chmod +x /usr/bin/hy
#!/bin/bash

# Hysteria 2 V3.1 全功能端口跳跃增强版
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

# 配置端口跳跃 (iptables)
setup_port_hopping() {
    echo -e "${YELLOW}正在配置端口跳跃防火墙规则 (20000-50000)...${PLAIN}"
    # 清理旧规则
    iptables -t nat -F HY2_PORT_HOPPING 2>/dev/null
    iptables -t nat -D PREROUTING -p udp -m udp --dport 20000:50000 -j HY2_PORT_HOPPING 2>/dev/null
    iptables -t nat -X HY2_PORT_HOPPING 2>/dev/null
    
    # 创建新规则：将 20000-50000 的 UDP 流量全转发到 443
    iptables -t nat -N HY2_PORT_HOPPING
    iptables -t nat -A HY2_PORT_HOPPING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
    iptables -t nat -A PREROUTING -p udp -m udp --dport 20000:50000 -j HY2_PORT_HOPPING
    
    # 持久化规则 (Debian/Ubuntu)
    if [ -f /etc/debian_version ]; then
        apt install -y iptables-persistent
        netfilter-persistent save
    fi
}

# 核心安装函数
install_hy3() {
    echo -e "${BLUE}===== 开始安装 Hysteria 2 V3.1 端口跳跃增强版 =====${PLAIN}"
    apt update && apt install -y curl socat openssl cron wget psmisc iptables
    
    while true; do
        echo -e "${YELLOW}请输入你的域名 (不能带下划线 _ ):${PLAIN}"
        read -p "> " MY_DOMAIN
        if [[ "$MY_DOMAIN" == *"_"* ]]; then
            echo -e "${RED}错误：域名包含下划线，请修改为横杠 '-'${PLAIN}"
        else
            break
        fi
    done

    echo -e "${YELLOW}请输入你的邮箱:${PLAIN}"
    read -p "> " MY_EMAIL

    rm -rf ~/.acme.sh/
    fuser -k 80/tcp

    echo -e "${YELLOW}正在申请正式 CA 证书...${PLAIN}"
    curl https://get.acme.sh | sh -s email=$MY_EMAIL
    source ~/.bashrc
    ~/.acme.sh/acme.sh --issue -d $MY_DOMAIN --standalone --server letsencrypt
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}证书申请失败！请确认域名解析。${PLAIN}"
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

    setup_port_hopping
    chown -R hysteria:hysteria /etc/hysteria
    systemctl enable hysteria-server && systemctl restart hysteria-server
    echo -e "${GREEN}安装部署成功！端口跳跃已开启。${PLAIN}"
    show_config
}

show_config() {
    if [ ! -f $CONF_FILE ]; then echo -e "${RED}检测到未安装！${PLAIN}"; return; fi
    IP=$(curl -s4 https://api.ipify.org)
    PASS=$(grep 'password:' $CONF_FILE | head -n 1 | awk '{print $2}' | tr -d '"')
    OBFS=$(grep 'password:' $CONF_FILE | tail -n 1 | awk '{print $2}' | tr -d '"')
    SNI=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
    # 生成带端口跳跃参数的链接
    URL="hysteria2://$PASS@$IP:443/?insecure=0&sni=$SNI&obfs=salamander&obfs-password=$OBFS&mport=20000-50000#Hy2_V3_PortHopping"
    echo -e "\n${BLUE}========== V3.1 配置信息 ==========${PLAIN}"
    echo -e "域名 (SNI): ${GREEN}$SNI${PLAIN}"
    echo -e "端口跳跃范围: ${YELLOW}20000-50000 (UDP)${PLAIN}"
    echo -e "配置链接: ${CYAN}$URL${PLAIN}"
    echo -e "${BLUE}===================================${PLAIN}"
}

if [ ! -f $CONF_FILE ]; then
    install_hy3
fi

while true; do
    echo -ne "\n${BLUE}--- Hy2 V3.1 管理 ---${PLAIN}\n1. 重新安装\n2. 查看当前配置\n3. 重启服务\n4. 停止服务\n5. 彻底卸载\n0. 退出\n选择: "
    read choice
    case $choice in
        1) install_hy3 ;;
        2) show_config ;;
        3) systemctl restart hysteria-server; setup_port_hopping; echo "服务已重启" ;;
        4) systemctl stop hysteria-server; echo "服务已停止" ;;
        5) 
            systemctl stop hysteria-server
            iptables -t nat -F HY2_PORT_HOPPING 2>/dev/null
            rm -rf /etc/hysteria /usr/bin/hy
            echo "已彻底卸载"; exit 0 ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
done
EOF
chmod +x /usr/bin/hy
hy
