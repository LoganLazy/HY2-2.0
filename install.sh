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
# 强制定义脚本位置，解决 bash <(curl) 的路径问题
HY_SCRIPT="/usr/bin/hy"

# 1. 环境检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}无法识别系统版本！${PLAIN}" && exit 1
fi

check_status() {
    if [[ "$OS" == "alpine" ]]; then
        if [ ! -f "/etc/init.d/hysteria" ]; then return 2; fi
        rc-service hysteria status | grep -q "started" && return 0 || return 1
    else
        if ! systemctl is-active --quiet hysteria-server.service; then
            if [ ! -f "/etc/systemd/system/hysteria-server.service" ]; then return 2; fi
            return 1
        fi
        return 0
    fi
}

# 2. 自动申请正式证书 (增加 --force 强制覆盖)
get_cert() {
    local domain=$1
    mkdir -p /etc/hysteria
    
    echo -e "${YELLOW}正在通过 ACME 申请正式证书 (强制模式)...${PLAIN}"
    # 安装依赖
    case "$OS" in
        alpine) apk add --no-cache socat ;;
        *) apt install -y socat || yum install -y socat ;;
    esac

    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=cert@${domain}
    alias acme.sh='/root/.acme.sh/acme.sh'
    
    # 强制释放 80 端口
    fuser -k 80/tcp 2>/dev/null
    
    # 强制申请并安装证书
    /root/.acme.sh/acme.sh --upgrade --auto-upgrade
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    # 增加 --force 确保跳过缓存直接重新领证
    /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256 --force
    
    if [ $? -eq 0 ]; then
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
            --key-file /etc/hysteria/server.key \
            --fullchain-file /etc/hysteria/server.crt
        echo -e "${GREEN}正式证书申请并安装成功！${PLAIN}"
        CERT_STAT="Official"
    else
        echo -e "${RED}正式证书申请失败，将使用自签证书备选。${PLAIN}"
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
    
    echo -e "\n${CYAN}--- Hysteria 2 自动化配置 (V8.0) ---${PLAIN}"
    read -p "请输入你的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && echo -e "${RED}必须输入域名！${PLAIN}" && return
    
    read -p "请输入端口 [默认 443]: " PORT
    [[ -z "$PORT" ]] && PORT="443"

    # 安装内核
    if [[ "$OS" == "alpine" ]]; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BINARY="hysteria-linux-amd64" || BINARY="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BINARY}"
        chmod +x $BIN_FILE
    else
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    get_cert "$DOMAIN"

    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
    
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

    # 权限与自启
    if [[ "$OS" != "alpine" ]]; then
        sed -i 's/User=hysteria/User=root/g' /etc/systemd/system/hysteria-server.service 2>/dev/null
        chown -R root:root /etc/hysteria
        systemctl daemon-reload && systemctl enable hysteria-server && systemctl restart hysteria-server
    else
        # Alpine OpenRC 配置略... (保持之前的即可)
        rc-service hysteria restart
    fi

    # 关键修复：直接从 GitHub 下载自己到 /usr/bin/hy，解决悬空软链接问题
    curl -fsSL https://raw.githubusercontent.com/LoganLazy/HY2-2.0/refs/heads/main/install.sh -o $HY_SCRIPT
    chmod +x $HY_SCRIPT
    
    echo -e "${GREEN}安装成功！以后输入 hy 即可管理服务。${PLAIN}"
    show_link
}

# 4. 信息查看
show_link() {
    if [ ! -f "/etc/hysteria/server.crt" ]; then echo -e "${RED}证书不存在！${PLAIN}" && return; fi
    
    CN=$(openssl x509 -in /etc/hysteria/server.crt -noout -subject | sed 's/.*CN = //')
    ISSUER=$(openssl x509 -in /etc/hysteria/server.crt -noout -issuer)
    
    [[ "$ISSUER" == *"Let's Encrypt"* ]] && C_TYPE="Official" || C_TYPE="Self-Signed"
    [[ "$C_TYPE" == "Official" ]] && INSECURE="0" || INSECURE="1"

    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}' | tr -d ' ')
    URL="hysteria2://${PW}@${CN}:${PT}/?sni=${CN}&insecure=${INSECURE}#Hy2_${CN}"
    
    echo -e "\n${BLUE}========== 节点信息 ==========${PLAIN}"
    echo -e "域名 (CN):  ${GREEN}${CN}${PLAIN}"
    echo -e "证书状态:   ${CYAN}${C_TYPE}${PLAIN}"
    echo -e "配置链接:   ${YELLOW}${URL}${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    read -p "按回车返回..."
}

# 5. 菜单
show_menu() {
    clear
    check_status
    S_RES=$?
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 全自动证书版 (V3.0)    ${PLAIN}"
    if [ $S_RES -eq 0 ]; then echo -e " 状态: ${GREEN}运行中${PLAIN}"
    elif [ $S_RES -eq 1 ]; then echo -e " 状态: ${RED}已停止${PLAIN}"
    else echo -e " 状态: ${YELLOW}未安装${PLAIN}"; fi
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装/重构 Hysteria 2"
    echo -e " 2. 查看配置信息"
    echo -e " 3. 启动服务      4. 停止服务"
    echo -e " 5. 重启服务      6. 开启内核 BBR 加速"
    echo -e " 7. 卸载服务      0. 退出"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    read -p "选择 [0-7]: " num
    case "$num" in
        1) install_hy2 ;;
        2) show_link ;;
        3|4|5) systemctl ${num/3/start}${num/4/stop}${num/5/restart} hysteria-server ;;
        6) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf && sysctl -p ;;
        7) systemctl stop hysteria-server; systemctl disable hysteria-server; rm -f $CONF_FILE $HY_SCRIPT ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}
show_menu
