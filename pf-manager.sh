#!/bin/bash
# =======================================================
# 极简无日志端口转发管理脚本 (IEPL / 专线适用)
# =======================================================

# 基础目录配置
APP_DIR="/opt/pf-manager"
RULES_FILE="${APP_DIR}/rules.txt"
CONFIG_FILE="${APP_DIR}/config.toml"
BIN_FILE="${APP_DIR}/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本 (sudo -i)"
  exit 1
fi

# 初始化环境
init_env() {
    mkdir -p "${APP_DIR}"
    touch "${RULES_FILE}"
    
    if [ ! -f "${BIN_FILE}" ]; then
        echo "正在下载核心转发组件..."
        wget -qO realm.tar.gz "https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-musl.tar.gz"
        tar -xf realm.tar.gz -C "${APP_DIR}"
        chmod +x "${BIN_FILE}"
        rm -f realm.tar.gz
    fi

    # 写入系统服务 (强制关闭所有日志输出，保护隐私)
    if [ ! -f "${SERVICE_FILE}" ]; then
        cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Secure Port Forwarding
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_FILE} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1
    fi
}

# 生成配置文件并重启服务
apply_config() {
    if [ ! -s "${RULES_FILE}" ]; then
        systemctl stop realm
        echo "当前无转发规则，服务已进入休眠状态。"
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
    echo "配置已生效，转发服务正在运行！(完全无日志模式)"
}

# 随机端口生成函数
get_random_port() {
    while true; do
        PORT=$(shuf -i 10000-65535 -n 1)
        # 检查端口是否被占用
        if ! ss -tuln | grep -q ":${PORT} "; then
            echo "${PORT}"
            break
        fi
    done
}

# 添加规则
add_rule() {
    echo "============================="
    read -rp "请输入被转发的出口机/目标 IP: " REMOTE_IP
    read -rp "请输入目标 IP 的监听端口 (例如 3389): " REMOTE_PORT
    
    echo "请选择本地入口机使用的端口方式："
    echo "1) 随机生成 (10000-65535)"
    echo "2) 自定义输入"
    read -rp "请选择 [1-2]: " PORT_CHOICE

    if [ "$PORT_CHOICE" == "1" ]; then
        LOCAL_PORT=$(get_random_port)
        echo "已分配随机端口: ${LOCAL_PORT}"
    else
        read -rp "请输入自定义本地端口: " LOCAL_PORT
    fi

    echo "${LOCAL_PORT} ${REMOTE_IP} ${REMOTE_PORT}" >> "${RULES_FILE}"
    echo "添加成功！[入口机 ${LOCAL_PORT}] ---> [目标 ${REMOTE_IP}:${REMOTE_PORT}]"
    
    apply_config
}

# 列表展示
list_rules() {
    echo "============================="
    echo "当前转发规则列表："
    echo "序号 | 本地监听端口 ---> 目标IP:目标端口"
    echo "-----------------------------"
    if [ ! -s "${RULES_FILE}" ]; then
        echo "暂无任何规则。"
    else
        awk '{print NR " | 0.0.0.0:" $1 " ---> " $2 ":" $3}' "${RULES_FILE}"
    fi
    echo "============================="
}

# 删除规则
delete_rule() {
    list_rules
    if [ ! -s "${RULES_FILE}" ]; then
        return
    fi
    read -rp "请输入要删除的规则序号: " DEL_NUM
    if [[ "$DEL_NUM" =~ ^[0-9]+$ ]]; then
        sed -i "${DEL_NUM}d" "${RULES_FILE}"
        echo "规则已删除。"
        apply_config
    else
        echo "输入无效。"
    fi
}

# 主菜单
init_env
while true; do
    echo ""
    echo "======================================"
    echo "   IEPL 安全转发管理面板 (无日志版)"
    echo "======================================"
    echo "1. 添加转发规则"
    echo "2. 删除转发规则"
    echo "3. 查看当前规则"
    echo "0. 退出脚本"
    echo "======================================"
    read -rp "请输入选项 [0-3]: " CHOICE

    case "$CHOICE" in
        1) add_rule ;;
        2) delete_rule ;;
        3) list_rules ;;
        0) exit 0 ;;
        *) echo "输入无效，请重新输入!" ;;
    esac
done
