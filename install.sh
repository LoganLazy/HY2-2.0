#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONF_FILE="/etc/hysteria/config.yaml"
BIN_FILE="/usr/local/bin/hysteria"
HY_SCRIPT="/usr/bin/hy"

# 1. 环境检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统版本！${PLAIN}" && exit 1
fi

# 2. 强制领证函数
get_cert() {
    local domain=$1
    mkdir -p /etc/hysteria
    
    echo -e "${YELLOW}正在通过 ACME 申请正式证书 (强制清理模式)...${PLAIN}"
    
    case "$OS" in
        alpine) apk add --no-cache socat ;;
        *) apt install -y socat || yum install -y socat ;;
    esac

    curl https://get.acme.sh | sh -s email=cert@${domain}
    alias acme.sh='/root/.acme.sh/acme.sh'
    
    # 彻底清理旧记忆，防止 Skipping
    rm -rf /root/.acme.sh/${domain}_ecc
    rm -rf /root/.acme.sh/${domain}
    
    # 暴力释放 80 端口
    [ -f /usr/bin/fuser ] && fuser -k 80/tcp 2>/dev/null
    
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 --force
    
    if [ $? -eq 0 ]; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file /etc/hysteria/server.key \
            --fullchain-file /etc/hysteria/server.crt
        echo -e "${GREEN}正式证书申请成功！${PLAIN}"
        CERT_STAT="Official"
    else
        echo -e "${RED}正式证书申请失败，将回退至自签模式。${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -subj "/CN=$domain" -days 3650
        CERT_STAT="Self-Signed"
    fi
}

# 3. 安装主函数
install_hy2() {
    case "$OS" in
        alpine) apk update && apk add --no-cache curl openssl ca-certificates bash wget ;;
        *) apt update && apt install -y curl openssl ca-certificates wget ;;
    esac
    
    echo -e "\n${CYAN}--- Hysteria 2 自动化配置 (V3.0) ---${PLAIN}"
    read -p "请输入你的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}域名不能为空！${PLAIN}" && return
    
    read -p "请输入端口 [默认 443]: " PORT
    [[ -z "$PORT" ]] && PORT="443"

    # 安装内核
    if [[ "$OS" == "alpine" ]]; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BIN="hysteria-linux-amd64" || BIN="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BIN}"
        chmod +x $BIN_FILE
    else
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    get_cert "$DOMAIN"

    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
    
    # 写入配置
    cat <<EOF > $CONF_FILE
listen: :$PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: "$PASSWORD"
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
quic:
  maxIdleTimeout: 30s
EOF

    # 启动服务
    if [[ "$OS" != "alpine" ]]; then
        sed -i 's/User=hysteria/User=root/g' /etc/systemd/system/hysteria-server.service 2>/dev/null
        systemctl daemon-reload && systemctl enable hysteria-server && systemctl restart hysteria-server
    else
        # Alpine OpenRC
        cat <<EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
name="Hysteria2"
command="$BIN_FILE"
command_args="server -c $CONF_FILE"
command_background="yes"
pidfile="/run/hysteria.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default && rc-service hysteria restart
    fi

    # 快捷键安装：从 GitHub 重新同步自身
    curl -fsSL https://raw.githubusercontent.com/LoganLazy/HY2-2.0/refs/heads/main/install.sh -o $HY_SCRIPT
    chmod +x $HY_SCRIPT
    
    echo -e "${GREEN}部署成功！以后输入 hy 即可管理。${PLAIN}"
    show_link
}

# 4. 节点信息 (精准提取域名)
show_link() {
    [ ! -f "/etc/hysteria/server.crt" ] && echo -e "${RED}未发现证书！${PLAIN}" && return
    
    # 修复：兼容多种格式的域名提取逻辑
    CN=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/^.*CN = //; s/^.*CN=//')
    ISSUER=$(openssl x509 -in /etc/hysteria/server.crt -noout -issuer)
    
    [[ "$ISSUER" == *"Let's Encrypt"* ]] && TYPE="Official" || TYPE="Self-Signed"
    [[ "$TYPE" == "Official" ]] && INS="0" || INS="1"

    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}' | tr -d ' ')
    URL="hysteria2://${PW}@${CN}:${PT}/?sni=${CN}&insecure=${INS}#Hy2_${CN}"
    
    echo -e "\n${BLUE}========== 节点配置信息 ==========${PLAIN}"
    echo -e "域名 (CN):  ${GREEN}${CN}${PLAIN}"
    echo -e "证书状态:   ${CYAN}${TYPE}${PLAIN}"
    echo -e "验证密码:   ${GREEN}${PW}${PLAIN}"
    echo -e "监听端口:   ${GREEN}${PT}${PLAIN}"
    echo -e "\n${YELLOW}通用配置链接:${PLAIN}"
    echo -e "${CYAN}${URL}${PLAIN}"
    echo -e "${BLUE}==================================${PLAIN}"
    read -p "按回车返回..."
}

# 5. 简单菜单
show_menu() {
    clear
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 终极全自动版 (V3.0)    ${PLAIN}"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装/重构 Hysteria 2"
    echo -e " 2. 查看配置信息"
    echo -e " 3. 启动服务      4. 停止服务"
    echo -e " 5. 重启服务      6. 开启内核 BBR"
    echo -e " 7. 卸载服务      0. 退出"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    read -p "选择: " num
    case "$num" in
        1) install_hy2 ;;
        2) show_link ;;
        3|4|5) [[ "$OS" == "alpine" ]] && rc-service hysteria ${num/3/start}${num/4/stop}${num/5/restart} || systemctl ${num/3/start}${num/4/stop}${num/5/restart} hysteria-server ;;
        6) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; sysctl -p ;;
        7) [[ "$OS" == "alpine" ]] && (rc-service hysteria stop; rc-update del hysteria default) || (systemctl stop hysteria-server; systemctl disable hysteria-server); rm -f $CONF_FILE $HY_SCRIPT ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}
show_menu
