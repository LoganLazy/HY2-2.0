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

# 1. 系统检测
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统版本！${PLAIN}" && exit 1
fi

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

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

install_deps() {
    echo -e "${YELLOW}正在安装基础依赖...${PLAIN}"
    case "$OS" in
        alpine) apk update && apk add --no-cache curl openssl ca-certificates file bash wget socat ;;
        debian|ubuntu) apt update && apt install -y curl openssl ca-certificates wget socat ;;
        *) yum install -y curl openssl ca-certificates wget socat || dnf install -y curl openssl ca-certificates wget socat ;;
    esac
}

# 2. 自动申请证书逻辑
get_cert() {
    local domain=$1
    mkdir -p /etc/hysteria
    
    echo -e "${YELLOW}正在安装 acme.sh 并申请正式证书...${PLAIN}"
    curl https://get.acme.sh | sh -s email=my@example.com
    alias acme.sh='/root/.acme.sh/acme.sh'
    
    # 释放 80 端口
    if [[ "$OS" == "alpine" ]]; then
        rc-service nginx stop 2>/dev/null
        rc-service apache2 stop 2>/dev/null
    else
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
    fi
    
    # 申请证书 (使用 Let's Encrypt 提高兼容性)
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
    
    if [ $? -eq 0 ]; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file /etc/hysteria/server.key \
            --fullchain-file /etc/hysteria/server.crt
        echo -e "${GREEN}正式证书申请并安装成功！${PLAIN}"
        CERT_TYPE="Official"
    else
        echo -e "${RED}证书申请失败！可能原因: 1. 80端口被占用 2. 域名解析未生效。${PLAIN}"
        echo -e "${YELLOW}正在生成临时自签证书以保证服务启动...${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -subj "/CN=$domain" -days 3650
        CERT_TYPE="Self-Signed"
    fi
}

# 3. 安装主函数
install_hy2() {
    install_deps
    
    echo -e "\n${CYAN}--- Hysteria 2 部署 ---${PLAIN}"
    read -p "请输入你的域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空！${PLAIN}" && return; fi
    
    read -p "请输入监听端口 [默认 443]: " PORT
    [ -z "$PORT" ] && PORT="443"
    
    read -p "请输入伪装域名 [默认 https://www.bing.com]: " MASK_URL
    [ -z "$MASK_URL" ] && MASK_URL="https://www.bing.com"

    # 安装二进制
    if [[ "$OS" == "alpine" ]]; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BINARY="hysteria-linux-amd64" || BINARY="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BINARY}"
        chmod +x $BIN_FILE
    else
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    # 核心步骤：申请证书
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
    url: $MASK_URL
    rewriteHost: true
quic:
  maxIdleTimeout: 30s
EOF

    # 权限与服务启动
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

    ln -sf "$(realpath "$0")" /usr/bin/hy2 2>/dev/null
    echo -e "${GREEN}安装完成！${PLAIN}"
    show_link "$DOMAIN" "$CERT_TYPE"
}

# 4. 信息显示
show_link() {
    DOMAIN=$1
    C_TYPE=$2
    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}')
    
    INSECURE="0"
    [ "$C_TYPE" == "Self-Signed" ] && INSECURE="1"

    URL="hysteria2://${PW}@${DOMAIN}:${PT}/?sni=${DOMAIN}&insecure=${INSECURE}#Hy2_${DOMAIN}"
    
    echo -e "\n${BLUE}========== 节点信息 ==========${PLAIN}"
    echo -e "域名:     ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "端口:     ${GREEN}${PT}${PLAIN}"
    echo -e "密码:     ${GREEN}${PW}${PLAIN}"
    echo -e "证书类型: ${CYAN}${C_TYPE}${PLAIN}"
    echo -e "SNI:      ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "\n${YELLOW}通用配置链接:${PLAIN}"
    echo -e "${CYAN}${URL}${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    [ "$C_TYPE" == "Self-Signed" ] && echo -e "${RED}注意：当前使用的是自签证书，请确保客户端开启 '允许不安全'。${PLAIN}"
    read -p "按回车返回..."
}

# 菜单略 (与之前一致，仅修改 install_hy2 调用)
show_menu() {
    clear
    check_status
    S_RES=$?
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 全自动证书版 (V6.0)    ${PLAIN}"
    if [ $S_RES -eq 0 ]; then echo -e " 状态: ${GREEN}运行中${PLAIN}"
    elif [ $S_RES -eq 1 ]; then echo -e " 状态: ${RED}已停止${PLAIN}"
    else echo -e " 状态: ${YELLOW}未安装${PLAIN}"; fi
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装/重构 Hysteria 2"
    echo -e " 2. 查看配置信息"
    echo -e " 3. 启动服务      4. 停止服务"
    echo -e " 5. 重启服务      6. 开启 BBR"
    echo -e " 7. 卸载服务      0. 退出"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    read -p "选择: " num
    case "$num" in
        1) install_hy2 ;;
        2) show_link "$(grep 'cert:' $CONF_FILE -A 2 | grep -v 'cert' | head -n 1 | awk '{print $NF}' | xargs dirname | xargs basename | cut -d'_' -f1)" "Unknown" ;;
        3|4|5) [[ "$OS" == "alpine" ]] && rc-service hysteria ${num/3/start}; [[ "$OS" == "alpine" ]] && rc-service hysteria ${num/4/stop}; [[ "$OS" == "alpine" ]] && rc-service hysteria ${num/5/restart} || systemctl ${num/3/start}${num/4/stop}${num/5/restart} hysteria-server ;;
        6) enable_bbr ;;
        7) 
            [[ "$OS" == "alpine" ]] && (rc-service hysteria stop; rc-update del hysteria default; rm -rf /etc/init.d/hysteria) || (systemctl stop hysteria-server; systemctl disable hysteria-server)
            rm -rf $CONF_FILE /usr/bin/hy2
            echo -e "${GREEN}卸载完成${PLAIN}" ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}
show_menu
