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
SCRIPT_PATH="$(realpath "$0")"

# 1. 环境检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统版本！${PLAIN}" && exit 1
fi

# 状态检查
check_status() {
    if [[ "$OS" == "alpine" ]]; then
        if [ ! -f "/etc/init.d/hysteria" ]; then return 2; fi
        rc-service hysteria status | grep -q "started" && return 0 || return 1
    else
        if ! systemctl is-active --quiet hysteria-server.service; then
            if [ ! -f "/lib/systemd/system/hysteria-server.service" ] && [ ! -f "/etc/systemd/system/hysteria-server.service" ]; then return 2; fi
            return 1
        fi
        return 0
    fi
}

# 2. 自动申请正式证书
get_cert() {
    local domain=$1
    mkdir -p /etc/hysteria
    
    echo -e "${YELLOW}正在安装 acme.sh 依赖并申请证书...${PLAIN}"
    # 安装依赖
    case "$OS" in
        alpine) apk add --no-cache socat ;;
        *) apt install -y socat || yum install -y socat ;;
    esac

    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=cert@$(echo $domain | cut -d'.' -f2-).com
    alias acme.sh='/root/.acme.sh/acme.sh'
    
    # 释放 80 端口
    if [[ "$OS" == "alpine" ]]; then
        rc-service nginx stop 2>/dev/null
        rc-service apache2 stop 2>/dev/null
    else
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
    fi
    
    # 申请正式证书 (Let's Encrypt)
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
    
    if [ $? -eq 0 ]; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file /etc/hysteria/server.key \
            --fullchain-file /etc/hysteria/server.crt
        echo -e "${GREEN}正式证书申请并安装成功！${PLAIN}"
    else
        echo -e "${RED}正式证书申请失败，正在生成自签证书作为备选...${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -subj "/CN=$domain" -days 3650
    fi
}

# 3. 安装/重构
install_hy2() {
    echo -e "${YELLOW}正在同步系统环境...${PLAIN}"
    case "$OS" in
        alpine) apk update && apk add --no-cache curl openssl ca-certificates file bash wget ;;
        *) apt update && apt install -y curl openssl ca-certificates wget ;;
    esac
    
    echo -e "\n${CYAN}--- Hysteria 2 自动化配置 ---${PLAIN}"
    read -p "请输入你的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}必须输入域名！${PLAIN}" && return
    
    read -p "请输入端口 [默认 443]: " PORT
    [[ -z "$PORT" ]] && PORT="443"
    
    read -p "请输入伪装站 [默认 https://www.bing.com]: " MASK_URL
    [[ -z "$MASK_URL" ]] && MASK_URL="https://www.bing.com"

    # 安装内核
    if [[ "$OS" == "alpine" ]]; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BINARY="hysteria-linux-amd64" || BINARY="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BINARY}"
        chmod +x $BIN_FILE
    else
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    # 领证
    get_cert "$DOMAIN"

    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
    
    # 生成配置 (按你要求：无带宽限制，增加伪装)
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
    url: $MASK_URL
    rewriteHost: true
quic:
  maxIdleTimeout: 30s
EOF

    # 权限与自启
    if [[ "$OS" != "alpine" ]]; then
        sed -i 's/User=hysteria/User=root/g' /etc/systemd/system/hysteria-server.service 2>/dev/null
        chown -R root:root /etc/hysteria
        systemctl daemon-reload
        systemctl enable hysteria-server
        systemctl restart hysteria-server
    else
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
        rc-update add hysteria default
        rc-service hysteria restart
    fi

    # 创建快捷键 hy
    ln -sf "$SCRIPT_PATH" /usr/bin/hy
    chmod +x /usr/bin/hy
    echo -e "${GREEN}安装成功！以后输入 hy 即可管理服务。${PLAIN}"
    show_link
}

# 4. 智能查看信息 (自动识别证书真伪)
show_link() {
    if [ ! -f "$CONF_FILE" ]; then echo -e "${RED}配置文件不存在，请先安装！${PLAIN}" && return; fi

    # 自动识别证书信息
    if [ -f "/etc/hysteria/server.crt" ]; then
        REAL_DOMAIN=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
        ISSUER=$(openssl x509 -in /etc/hysteria/server.crt -noout -issuer)
        
        if [[ "$ISSUER" == *"Let's Encrypt"* || "$ISSUER" == *"ZeroSSL"* ]]; then
            C_TYPE="Official (正式证书)"
            INSECURE="0"
        else
            C_TYPE="Self-Signed (自签证书)"
            INSECURE="1"
        fi
    else
        REAL_DOMAIN="Unknown"
        C_TYPE="Error (证书丢失)"
        INSECURE="1"
    fi

    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}' | tr -d ' ')
    URL="hysteria2://${PW}@${REAL_DOMAIN}:${PT}/?sni=${REAL_DOMAIN}&insecure=${INSECURE}#Hy2_${REAL_DOMAIN}"
    
    echo -e "\n${BLUE}========== 节点信息 (智能检测) ==========${PLAIN}"
    echo -e "域名 (CN):  ${GREEN}${REAL_DOMAIN}${PLAIN}"
    echo -e "监听端口:   ${GREEN}${PT}${PLAIN}"
    echo -e "验证密码:   ${GREEN}${PW}${PLAIN}"
    echo -e "证书状态:   ${CYAN}${C_TYPE}${PLAIN}"
    echo -e "SNI 设定:   ${GREEN}${REAL_DOMAIN}${PLAIN}"
    echo -e "\n${YELLOW}通用配置链接:${PLAIN}"
    echo -e "${CYAN}${URL}${PLAIN}"
    echo -e "${BLUE}========================================${PLAIN}"
    read -p "按回车返回..."
}

# 5. 主菜单
show_menu() {
    clear
    check_status
    S_RES=$?
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 全自动证书版 (V3.0)    ${PLAIN}"
    echo -e "${BLUE} 系统: ${GREEN}$OS${PLAIN}  快捷键: ${GREEN}hy${PLAIN}"
    if [ $S_RES -eq 0 ]; then echo -e " 状态: ${GREEN}运行中${PLAIN}"
    elif [ $S_RES -eq 1 ]; then echo -e " 状态: ${RED}已停止${PLAIN}"
    else echo -e " 状态: ${YELLOW}未安装${PLAIN}"; fi
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装/重构 Hysteria 2 (自动领证)"
    echo -e " 2. 查看配置信息"
    echo -e " 3. 启动服务      4. 停止服务"
    echo -e " 5. 重启服务      6. 开启内核 BBR 加速"
    echo -e " 7. 卸载服务      0. 退出"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    read -p "选择 [0-7]: " num
    case "$num" in
        1) install_hy2 ;;
        2) show_link ;;
        3) [[ "$OS" == "alpine" ]] && rc-service hysteria start || systemctl start hysteria-server ;;
        4) [[ "$OS" == "alpine" ]] && rc-service hysteria stop || systemctl stop hysteria-server ;;
        5) [[ "$OS" == "alpine" ]] && rc-service hysteria restart || systemctl restart hysteria-server ;;
        6) 
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p
            echo -e "${GREEN}BBR 已开启${PLAIN}" && read -p "返回..." ;;
        7) 
            [[ "$OS" == "alpine" ]] && (rc-service hysteria stop; rc-update del hysteria default; rm -rf /etc/init.d/hysteria) || (systemctl stop hysteria-server; systemctl disable hysteria-server)
            rm -rf $CONF_FILE /usr/bin/hy
            echo -e "${GREEN}卸载完成${PLAIN}" ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

show_menu
