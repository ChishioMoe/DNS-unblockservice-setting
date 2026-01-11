#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 配置文件路径
SNIPROXY_CONF="/etc/sniproxy.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_UNLOCK_FILE="/etc/dnsmasq.d/unlock_domains.conf"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}" 
   exit 1
fi

# --- 辅助函数 ---

get_host_ip() {
    # 尝试自动获取
    AUTO_IP=$(curl -s4 ifconfig.me)
    if [[ -n "$AUTO_IP" ]]; then
        DEFAULT_IP="$AUTO_IP"
    else
        DEFAULT_IP=""
    fi

    read -p "请输入本机(解锁机器)的公网 IP 地址 [默认: ${DEFAULT_IP}]: " HOST_IP
    HOST_IP=${HOST_IP:-$DEFAULT_IP}
    
    if [[ -z "$HOST_IP" ]]; then
        echo -e "${RED}IP 不能为空！${PLAIN}"
        get_host_ip
    fi
}

save_firewall() {
    echo -e "${GREEN}正在保存防火墙规则...${PLAIN}"
    netfilter-persistent save > /dev/null 2>&1
    if command -v service >/dev/null 2>&1; then
        service iptables save > /dev/null 2>&1
    fi
}

# --- 核心安装功能 ---

install_env() {
    echo -e "${GREEN}正在更新软件源并安装依赖...${PLAIN}"
    apt update
    apt install sniproxy dnsmasq iptables iptables-persistent netfilter-persistent dnsutils -y

    echo -e "${GREEN}正在配置 SNIProxy...${PLAIN}"
    cat > $SNIPROXY_CONF <<EOF
user daemon
pidfile /var/run/sniproxy.pid

error_log {
    syslog daemon
    priority notice
}

listener 80 {
    proto http
}

listener 443 {
    proto tls
}

table {
    .* *
}
EOF
    systemctl restart sniproxy
    systemctl enable sniproxy
    echo -e "${GREEN}SNIProxy 配置完成。${PLAIN}"
}

config_dnsmasq_base() {
    if ! command -v dnsmasq &> /dev/null; then
        echo -e "${RED}Dnsmasq 未安装成功，尝试重新安装...${PLAIN}"
        apt install dnsmasq -y
    fi

    get_host_ip
    
    # 强制修改 resolv.conf 防止死循环
    echo -e "${GREEN}正在优化系统 DNS (防止回环死循环)...${PLAIN}"
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    # 尝试锁定文件 (如果不报错的话)
    chattr +i /etc/resolv.conf >/dev/null 2>&1

    echo -e "${GREEN}正在配置 Dnsmasq 基础设置...${PLAIN}"
    if [ ! -f "${DNSMASQ_CONF}.bak" ]; then
        cp $DNSMASQ_CONF "${DNSMASQ_CONF}.bak"
    fi

    # 这里的 listen-address 设为 0.0.0.0 配合防火墙使用更稳健
    cat > $DNSMASQ_CONF <<EOF
listen-address=$HOST_IP,127.0.0.1
server=8.8.8.8
conf-dir=/etc/dnsmasq.d
EOF
    
    touch $DNSMASQ_UNLOCK_FILE
    
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    echo -e "${GREEN}Dnsmasq 基础配置完成 (IP: $HOST_IP)。${PLAIN}"
}

# --- 域名管理功能 ---

manage_domains() {
    if [ ! -f "$DNSMASQ_CONF" ]; then
        echo -e "${RED}请先执行安装步骤！${PLAIN}"
        return
    fi
    
    # 获取当前 IP 用于写入规则
    CURRENT_HOST_IP=$(grep "address=" $DNSMASQ_UNLOCK_FILE | head -n 1 | cut -d/ -f3)
    if [[ -z "$CURRENT_HOST_IP" ]]; then
        get_host_ip
    else
        HOST_IP=$CURRENT_HOST_IP
    fi

    while true; do
        echo -e "\n${YELLOW}--- 域名管理菜单 ---${PLAIN}"
        echo "1. 查看当前解锁域名"
        echo "2. 添加解锁域名"
        echo "3. 删除解锁域名"
        echo "4. 导入全套预设 (Netflix/Disney/OpenAI/Gemini/Claude/Copilot)"
        echo "5. 生成客户端配置文件 (复制用)"
        echo "6. 清空所有域名"
        echo "0. 返回主菜单"
        read -p "请选择: " sub_choice
        
        case $sub_choice in
            1)
                echo -e "${GREEN}当前列表:${PLAIN}"
                grep "address=" $DNSMASQ_UNLOCK_FILE | grep -v "::" | cut -d/ -f2
                ;;
            2)
                read -p "请输入要解锁的主域名 (如 netflix.com): " domain
                if [[ -z "$domain" ]]; then continue; fi
                echo "address=/$domain/$HOST_IP" >> $DNSMASQ_UNLOCK_FILE
                echo "address=/$domain/::" >> $DNSMASQ_UNLOCK_FILE
                systemctl restart dnsmasq
                echo -e "${GREEN}已添加: $domain${PLAIN}"
                ;;
            3)
                read -p "请输入要删除的域名: " domain
                if [[ -z "$domain" ]]; then continue; fi
                sed -i "/\/$domain\//d" $DNSMASQ_UNLOCK_FILE
                systemctl restart dnsmasq
                echo -e "${GREEN}已删除: $domain${PLAIN}"
                ;;
            4)
                echo -e "${YELLOW}正在导入全套预设...${PLAIN}"
                cat > $DNSMASQ_UNLOCK_FILE <<EOF
# --- Netflix ---
address=/netflix.com/$HOST_IP
address=/netflix.net/$HOST_IP
address=/nflximg.net/$HOST_IP
address=/nflxext.com/$HOST_IP
address=/nflxvideo.net/$HOST_IP
address=/nflxso.net/$HOST_IP
address=/netflix.com/::
address=/netflix.net/::
address=/nflximg.net/::
address=/nflxext.com/::
address=/nflxvideo.net/::
address=/nflxso.net/::

# --- Disney+ ---
address=/disney.com/$HOST_IP
address=/disneyplus.com/$HOST_IP
address=/bamgrid.com/$HOST_IP
address=/disney.com/::
address=/disneyplus.com/::
address=/bamgrid.com/::

# --- OpenAI (ChatGPT) ---
address=/openai.com/$HOST_IP
address=/chatgpt.com/$HOST_IP
address=/ai.com/$HOST_IP
address=/oaistatic.com/$HOST_IP
address=/oaiusercontent.com/$HOST_IP
address=/api.openai.com/$HOST_IP
address=/auth0.com/$HOST_IP
address=/identrust.com/$HOST_IP
address=/openai.com/::
address=/chatgpt.com/::
address=/ai.com/::
address=/oaistatic.com/::
address=/oaiusercontent.com/::
address=/api.openai.com/::
address=/auth0.com/::
address=/identrust.com/::

# --- Anthropic (Claude) ---
address=/anthropic.com/$HOST_IP
address=/claude.ai/$HOST_IP
address=/anthropic.com/::
address=/claude.ai/::

# --- Google AI (Gemini/Bard) ---
address=/googleapis.com/$HOST_IP
address=/bard.google.com/$HOST_IP
address=/gemini.google.com/$HOST_IP
address=/ai.google.dev/$HOST_IP
address=/aistudio.google.com/$HOST_IP
address=/googleapis.com/::
address=/bard.google.com/::
address=/gemini.google.com/::
address=/ai.google.dev/::
address=/aistudio.google.com/::

# --- Microsoft (Copilot/Bing) ---
address=/bing.com/$HOST_IP
address=/copilot.microsoft.com/$HOST_IP
address=/openai.azure.com/$HOST_IP
address=/bing.com/::
address=/copilot.microsoft.com/::
address=/openai.azure.com/::
EOF
                systemctl restart dnsmasq
                echo -e "${GREEN}预设导入完成。${PLAIN}"
                ;;
            5)
                # 生成客户端配置逻辑
                echo -e "\n${BLUE}========== 客户端 Dnsmasq 配置文件内容 ==========${PLAIN}"
                echo -e "${YELLOW}# 请将以下内容复制到客户端 VPS 的 /etc/dnsmasq.d/unlock.conf 文件中${PLAIN}"
                echo -e "${YELLOW}# 或者添加到 /etc/dnsmasq.conf 末尾${PLAIN}\n"
                
                # 读取规则文件，提取域名，转换为 server=/domain/HOST_IP 格式
                # 过滤掉 :: (IPv6屏蔽行)，只保留 IPv4 转发
                grep "address=" $DNSMASQ_UNLOCK_FILE | grep -v "::" | while read -r line; do
                    # 提取域名 (cut -d/ -f2)
                    DOMAIN=$(echo $line | cut -d/ -f2)
                    # 输出客户端格式
                    echo "server=/$DOMAIN/$HOST_IP"
                done
                
                echo -e "\n${BLUE}================================================${PLAIN}"
                echo -e "提示: 复制后记得在客户端执行 ${GREEN}systemctl restart dnsmasq${PLAIN}"
                echo -e "提示: 确保客户端 IP 已经加入到了本机的防火墙白名单中！"
                read -p "按回车键继续..."
                ;;
            6)
                echo "" > $DNSMASQ_UNLOCK_FILE
                systemctl restart dnsmasq
                echo -e "${GREEN}已清空规则。${PLAIN}"
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
    done
}

# --- 防火墙管理功能 ---

manage_firewall() {
    while true; do
        echo -e "\n${YELLOW}--- 防火墙(客户端IP) 管理菜单 ---${PLAIN}"
        echo "1. 查看已允许的客户端 IP"
        echo "2. 添加允许连接的客户端 IP"
        echo "3. 删除允许连接的客户端 IP"
        echo "4. 初始化/重置防火墙"
        echo "0. 返回主菜单"
        read -p "请选择: " fw_choice

        case $fw_choice in
            1)
                echo -e "${GREEN}当前允许的客户端 IP 列表:${PLAIN}"
                iptables -S INPUT | grep -e "-j ACCEPT" | grep -e "-s" | awk '{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' | sort | uniq
                ;;
            2)
                read -p "请输入要【添加】的客户端 IP: " ADD_IP
                if [[ -z "$ADD_IP" ]]; then echo -e "${RED}IP不能为空${PLAIN}"; continue; fi
                
                iptables -I INPUT -s $ADD_IP -p udp --dport 53 -j ACCEPT
                iptables -I INPUT -s $ADD_IP -p tcp --dport 53 -j ACCEPT
                iptables -I INPUT -s $ADD_IP -p tcp --dport 80 -j ACCEPT
                iptables -I INPUT -s $ADD_IP -p tcp --dport 443 -j ACCEPT
                
                save_firewall
                echo -e "${GREEN}已添加 IP: $ADD_IP${PLAIN}"
                ;;
            3)
                read -p "请输入要【删除】的客户端 IP: " DEL_IP
                if [[ -z "$DEL_IP" ]]; then echo -e "${RED}IP不能为空${PLAIN}"; continue; fi
                
                iptables -D INPUT -s $DEL_IP -p udp --dport 53 -j ACCEPT 2>/dev/null
                iptables -D INPUT -s $DEL_IP -p tcp --dport 53 -j ACCEPT 2>/dev/null
                iptables -D INPUT -s $DEL_IP -p tcp --dport 80 -j ACCEPT 2>/dev/null
                iptables -D INPUT -s $DEL_IP -p tcp --dport 443 -j ACCEPT 2>/dev/null
                
                save_firewall
                echo -e "${GREEN}已移除 IP: $DEL_IP${PLAIN}"
                ;;
            4)
                echo -e "${RED}警告：這将清空所有现有规则！${PLAIN}"
                read -p "请输入新的唯一客户端 IP: " INIT_IP
                if [[ -z "$INIT_IP" ]]; then echo -e "${RED}IP不能为空${PLAIN}"; continue; fi
                
                iptables -P INPUT ACCEPT
                iptables -F
                iptables -A INPUT -i lo -j ACCEPT
                iptables -A INPUT -p tcp --dport 22 -j ACCEPT
                
                iptables -A INPUT -s $INIT_IP -p udp --dport 53 -j ACCEPT
                iptables -A INPUT -s $INIT_IP -p tcp --dport 53 -j ACCEPT
                iptables -A INPUT -s $INIT_IP -p tcp --dport 80 -j ACCEPT
                iptables -A INPUT -s $INIT_IP -p tcp --dport 443 -j ACCEPT
                
                iptables -A INPUT -p udp --dport 53 -j DROP
                iptables -A INPUT -p tcp --dport 53 -j DROP
                iptables -A INPUT -p tcp --dport 80 -j DROP
                iptables -A INPUT -p tcp --dport 443 -j DROP
                
                save_firewall
                echo -e "${GREEN}防火墙已重置，仅允许 $INIT_IP${PLAIN}"
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选项${PLAIN}"
                ;;
        esac
    done
}

# --- 主菜单 ---

main_menu() {
    clear
    echo -e "${YELLOW}====================================${PLAIN}"
    echo -e "${YELLOW}   DNS 解锁服务管理脚本 v2.2   ${PLAIN}"
    echo -e "${YELLOW}====================================${PLAIN}"
    echo "1. 全新安装 (安装环境 + 初始化配置)"
    echo "2. 域名管理 (添加/删除/导入预设/生成客户端配置)"
    echo "3. 防火墙/客户端管理 (添加/删除 IP)"
    echo "0. 退出"
    echo -e "${YELLOW}====================================${PLAIN}"
    
    read -p "请输入选项: " choice
    case $choice in
        1)
            install_env
            config_dnsmasq_base
            echo -e "${YELLOW}接下来进行防火墙初始化...${PLAIN}"
            read -p "请输入第一个允许连接的客户端 IP: " CLIENT_IP
            if [[ -n "$CLIENT_IP" ]]; then
                 iptables -P INPUT ACCEPT
                 iptables -F
                 iptables -A INPUT -i lo -j ACCEPT
                 iptables -A INPUT -p tcp --dport 22 -j ACCEPT
                 iptables -A INPUT -s $CLIENT_IP -p udp --dport 53 -j ACCEPT
                 iptables -A INPUT -s $CLIENT_IP -p tcp --dport 53 -j ACCEPT
                 iptables -A INPUT -s $CLIENT_IP -p tcp --dport 80 -j ACCEPT
                 iptables -A INPUT -s $CLIENT_IP -p tcp --dport 443 -j ACCEPT
                 iptables -A INPUT -p udp --dport 53 -j DROP
                 iptables -A INPUT -p tcp --dport 53 -j DROP
                 iptables -A INPUT -p tcp --dport 80 -j DROP
                 iptables -A INPUT -p tcp --dport 443 -j DROP
                 save_firewall
            fi
            echo -e "${GREEN}安装全部完成！${PLAIN}"
            ;;
        2)
            manage_domains
            ;;
        3)
            manage_firewall
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
}

main_menu
