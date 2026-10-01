#!/bin/bash
# =======================================================
# 极简无日志端口转发管理脚本 (IEPL / 专线适用) 
# 版本：v2.0 (全彩UI增强版)
# =======================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# 基础目录配置
APP_DIR="/opt/pf-manager"
RULES_FILE="${APP_DIR}/rules.txt"
CONFIG_FILE="${APP_DIR}/config.toml"
BIN_FILE="${APP_DIR}/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[错误] 请使用 root 用户运行此脚本 (执行 sudo -i 切换)${NC}"
  exit 1
fi

# 初始化环境 (含守护进程与开机自启配置)
init_env() {
    if [ ! -d "${APP_DIR}" ]; then
        echo -e "${CYAN}>>> 首次运行，正在初始化环境...${NC}"
        mkdir -p "${APP_DIR}"
        touch "${RULES_FILE}"
    fi
    
    if [ ! -f "${BIN_FILE}" ]; then
        echo -e "${YELLOW}>>> 正在下载核心转发组件 (Realm)...${NC}"
        wget -qO realm.tar.gz "https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-musl.tar.gz"
        tar -xf realm.tar.gz -C "${APP_DIR}"
        chmod +x "${BIN_FILE}"
        rm -f realm.tar.gz
        echo -e "${GREEN}>>> 核心组件下载完成！${NC}"
    fi

    # 写入系统服务 (强制关闭所有日志输出，保护隐私，设置崩溃自动重启)
    if [ ! -f "${SERVICE_FILE}" ]; then
        echo -e "${YELLOW}>>> 配置进程守护与开机自启...${NC}"
        cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Secure Port Forwarding Guardian
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_FILE} -c ${CONFIG_FILE}
Restart=always
RestartSec=3s
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1
        echo -e "${GREEN}>>> 进程守护与开机自启配置完毕！${NC}"
        sleep 1
    fi
}

# 开启 BBR 加速
enable_bbr() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${YELLOW}正在检测系统 BBR 状态...${NC}"
    
    # 检查内核参数是否已经包含了bbr
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}[INFO] BBR 加速已经处于开启状态，无需重复配置！${NC}"
    else
        echo -e "${YELLOW}[INFO] 正在开启 BBR 加速...${NC}"
        # 写入 sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}[SUCCESS] BBR 加速已成功开启！${NC}"
    fi
    echo -e "按任意键返回主菜单..."
    read -n 1 -s -r
}

# 获取 BBR 状态 (用于UI展示)
get_bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}已开启 (BBR)${NC}"
    else
        echo -e "${RED}未开启${NC}"
    fi
}

# 获取服务运行状态 (用于UI展示)
get_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}▶ 运行中 (Active & Guarded)${NC}"
    else
        echo -e "${RED}■ 已停止 / 休眠 (Inactive)${NC}"
    fi
}

# 生成配置文件并重启服务
apply_config() {
    if [ ! -s "${RULES_FILE}" ]; then
        systemctl stop realm
        echo -e "${YELLOW}[提示] 当前无转发规则，服务已进入休眠状态。${NC}"
        return
    fi

    cat > "${CONFIG_FILE}" <<EOF
[network]
no_tcp_keepalive = false
tcp_timeout = 300

EOF

    while read -r LPORT RIP RPORT; do
        cat >> "${CONFIG_FILE}" <<EOF
[[endpoints]]
listen = "0.0.0.0:${LPORT}"
remote = "${RIP}:${RPORT}"

EOF
    done < "${RULES_FILE}"

    systemctl restart realm
    echo -e "${GREEN}[成功] 配置已生效，转发服务正在运行！(完全无日志模式)${NC}"
    sleep 1.5
}

# 随机端口生成函数
get_random_port() {
    while true; do
        PORT=$(shuf -i 10000-65535 -n 1)
        if ! ss -tuln | grep -q ":${PORT} "; then
            echo "${PORT}"
            break
        fi
    done
}

# 添加规则
add_rule() {
    echo -e "${CYAN}======================================${NC}"
    read -rp "1. 请输入被转发的出口机/目标 IP: " REMOTE_IP
    read -rp "2. 请输入目标 IP 的监听端口 (如 3389): " REMOTE_PORT
    
    echo -e "\n请选择本地入口机使用的端口方式："
    echo -e "  ${PURPLE}1)${NC} 随机生成 (10000-65535)"
    echo -e "  ${PURPLE}2)${NC} 自定义输入"
    read -rp "请选择 [1-2]: " PORT_CHOICE

    if [ "$PORT_CHOICE" == "1" ]; then
        LOCAL_PORT=$(get_random_port)
        echo -e "${GREEN}[成功] 已分配随机端口: ${LOCAL_PORT}${NC}"
    else
        read -rp "请输入自定义本地端口: " LOCAL_PORT
    fi

    echo "${LOCAL_PORT} ${REMOTE_IP} ${REMOTE_PORT}" >> "${RULES_FILE}"
    echo -e "\n${GREEN}规则添加成功！${NC}"
    echo -e "映射关系: [入口本机端口 ${CYAN}${LOCAL_PORT}${NC}] ---> [目标 ${CYAN}${REMOTE_IP}:${REMOTE_PORT}${NC}]"
    
    apply_config
}

# 列表展示
list_rules() {
    echo -e "${CYAN}======================================${NC}"
    echo -e "${BLUE}        当前转发规则列表${NC}"
    echo -e "${CYAN}======================================${NC}"
    echo -e "序号 | 本地监听端口  --->  目标IP:目标端口"
    echo -e "--------------------------------------"
    if [ ! -s "${RULES_FILE}" ]; then
        echo -e "${YELLOW}暂无任何规则。${NC}"
    else
        awk -v cyan="${CYAN}" -v nc="${NC}" '{print cyan NR nc "    | 0.0.0.0:" $1 " ---> " $2 ":" $3}' "${RULES_FILE}"
    fi
    echo -e "${CYAN}======================================${NC}"
}

# 删除规则
delete_rule() {
    list_rules
    if [ ! -s "${RULES_FILE}" ]; then
        echo -e "按任意键返回..."
        read -n 1 -s -r
        return
    fi
    read -rp "请输入要删除的规则序号 (直接回车取消): " DEL_NUM
    if [[ -z "$DEL_NUM" ]]; then
        return
    fi
    if [[ "$DEL_NUM" =~ ^[0-9]+$ ]]; then
        sed -i "${DEL_NUM}d" "${RULES_FILE}"
        echo -e "${GREEN}[成功] 规则已删除。${NC}"
        apply_config
    else
        echo -e "${RED}[错误] 输入无效。${NC}"
        sleep 1
    fi
}

# 主菜单UI
show_menu() {
    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${PURPLE}       IEPL 安全转发管理面板 v2.0            ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo -e "守护服务状态 : $(get_service_status)"
    echo -e "系统 BBR 状态: $(get_bbr_status)"
    echo -e "开机自启设定 : ${GREEN}已启用 (Systemd托管)${NC}"
    echo -e "${CYAN}---------------------------------------------${NC}"
    echo -e "  ${GREEN}1.${NC} 添加转发规则"
    echo -e "  ${GREEN}2.${NC} 删除转发规则"
    echo -e "  ${GREEN}3.${NC} 查看当前规则"
    echo -e "  ${GREEN}4.${NC} 一键开启 BBR 拥塞控制算法 (加速)"
    echo -e "  ${GREEN}0.${NC} 退出面板 (后台将持续安全运行)"
    echo -e "${CYAN}=============================================${NC}"
}

# 主循环
init_env
while true; do
    show_menu
    read -rp "请输入选项 [0-4]: " CHOICE
    case "$CHOICE" in
        1) add_rule ;;
        2) delete_rule ;;
        3) 
            list_rules
            echo -e "按任意键返回主菜单..."
            read -n 1 -s -r
            ;;
        4) enable_bbr ;;
        0) 
            echo -e "${GREEN}已退出面板。转发服务正在系统后台默默守护！${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}输入无效，请重新输入!${NC}"
            sleep 1 
            ;;
    esac
done
