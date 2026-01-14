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

# 2. 状态检查
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
        alpine) apk update && apk add --no-cache curl openssl ca-certificates file bash wget ;;
        debian|ubuntu) apt update && apt install -y curl openssl ca-certificates wget ;;
        *) yum install -y curl openssl ca-certificates wget || dnf install -y curl openssl ca-certificates wget ;;
    esac
}

enable_bbr() {
    echo -e "${YELLOW}正在开启内核 BBR 加速...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR 开启成功！${PLAIN}"
    read -p "按回车返回..."
}

# 3. 安装/重组 Hysteria 2
install_hy2() {
    install_deps
    
    echo -e "\n${CYAN}--- 基础配置 ---${PLAIN}"
    read -p "请输入你的域名 (例如 de.yourdomain.com): " DOMAIN
    [ -z "${DOMAIN}" ] && echo -e "${RED}必须输入域名！${PLAIN}" && return
    
    read -p "请输入服务监听端口 [默认 443]: " PORT
    [ -z "${PORT}" ] && PORT="443"

    read -p "请输入伪装域名 [默认 https://www.bing.com]: " MASK_URL
    [ -z "${MASK_URL}" ] && MASK_URL="https://www.bing.com"

    # 安装二进制
    if [[ "$OS" == "alpine" ]]; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BINARY="hysteria-linux-amd64" || BINARY="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BINARY}"
        chmod +x $BIN_FILE
    else
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    # 证书处理逻辑
    mkdir -p /etc/hysteria
    echo -e "\n${YELLOW}请确保你已经将域名证书放置在以下位置:${PLAIN}"
    echo -e "证书 (CRT): ${CYAN}/etc/hysteria/server.crt${PLAIN}"
    echo -e "私钥 (KEY): ${CYAN}/etc/hysteria/server.key${PLAIN}"
    
    if [ ! -f "/etc/hysteria/server.crt" ]; then
        echo -e "${RED}警告: 未发现证书文件，将先生成临时自签证书，请后续手动替换以启用域名模式！${PLAIN}"
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
            -subj "/CN=$DOMAIN" -days 365
    fi

    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
    
    # 写入配置 (移除带宽限制，增加伪装)
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

    # 权限修复 (关键)
    if [[ "$OS" != "alpine" ]]; then
        # 兼容旧版本可能存在的 User=hysteria
        sed -i 's/User=hysteria/User=root/g' /etc/systemd/system/hysteria-server.service 2>/dev/null
        chown -R root:root /etc/hysteria
        chmod 600 /etc/hysteria/server.key
        systemctl daemon-reload
        systemctl enable hysteria-server
        systemctl restart hysteria-server
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
        rc-update add hysteria default
        rc-service hysteria restart
    fi

    # 创建快捷命令
    ln -sf "$(realpath "$0")" /usr/bin/hy2 2>/dev/null
    echo -e "${GREEN}Hysteria 2 域名版部署完成！${PLAIN}"
    show_link "$DOMAIN"
}

# 4. 显示配置 (去掉 insecure, 增加 SNI)
show_link() {
    DOMAIN=${1:-"你的域名"}
    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}')
    
    # 生成客户端链接
    URL="hysteria2://${PW}@${DOMAIN}:${PT}/?sni=${DOMAIN}#Hy2_${DOMAIN}"
    
    echo -e "\n${BLUE}========== 客户端配置信息 ==========${PLAIN}"
    echo -e "服务器地址: ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "监听端口:   ${GREEN}${PT}${PLAIN}"
    echo -e "验证密码:   ${GREEN}${PW}${PLAIN}"
    echo -e "SNI:        ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "允许不安全: ${RED}OFF (已禁用, 请使用正式证书)${PLAIN}"
    echo -e "\n${YELLOW}通用节点链接:${PLAIN}"
    echo -e "${CYAN}${URL}${PLAIN}"
    echo -e "${BLUE}====================================${PLAIN}"
    read -p "按回车返回..."
}

show_menu() {
    clear
    check_status
    S_RES=$?
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 域名版管理脚本 (正式版)    ${PLAIN}"
    echo -e "${BLUE} 系统: ${GREEN}$OS${PLAIN}  端口: ${GREEN}UDP 443 优先${PLAIN}"
    if [ $S_RES -eq 0 ]; then echo -e " 状态: ${GREEN}运行中${PLAIN}"
    elif [ $S_RES -eq 1 ]; then echo -e " 状态: ${RED}已停止${PLAIN}"
    else echo -e " 状态: ${YELLOW}未安装${PLAIN}"; fi
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装/重构 Hysteria 2 (正式证书)"
    echo -e " 2. 查看节点链接信息"
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
