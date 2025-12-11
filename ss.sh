#!/bin/bash

# =================配置区域=================
# 设置监听端口
LISTEN_PORT=8844
# 设置固定密码
PASSWORD='AAABBBCCC'
# 设置加密方式 (推荐 aes-256-gcm)
METHOD='aes-256-gcm'
# =========================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

WORK_DIR='/etc/sing-box'
TEMP_DIR='/tmp/sing-box'

# 检查是否为 Root 用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 检查系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64)
        SING_BOX_ARCH="amd64"
        ;;
    aarch64|arm64)
        SING_BOX_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
        exit 1
        ;;
esac

echo -e "${GREEN}正在准备安装环境...${PLAIN}"

# 安装依赖
if [ -x "$(command -v apt)" ]; then
    apt update && apt install -y wget tar curl
elif [ -x "$(command -v yum)" ]; then
    yum install -y wget tar curl
elif [ -x "$(command -v apk)" ]; then
    apk add wget tar curl
fi

# 创建工作目录
mkdir -p $WORK_DIR
mkdir -p $TEMP_DIR
mkdir -p $WORK_DIR/logs

# 获取 Sing-box 最新版本
echo -e "${GREEN}正在获取 Sing-box 最新版本...${PLAIN}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}获取版本失败，使用默认版本 1.10.0${PLAIN}"
    LATEST_VERSION="1.10.0"
fi

# 下载并安装 Sing-box
echo -e "${GREEN}正在下载 Sing-box v${LATEST_VERSION}...${PLAIN}"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${SING_BOX_ARCH}.tar.gz"

wget -O $TEMP_DIR/sing-box.tar.gz "$DOWNLOAD_URL"
if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败，请检查网络连接。${PLAIN}"
    exit 1
fi

tar -zxvf $TEMP_DIR/sing-box.tar.gz -C $TEMP_DIR
mv $TEMP_DIR/sing-box-*/sing-box $WORK_DIR/sing-box
chmod +x $WORK_DIR/sing-box
rm -rf $TEMP_DIR

# 生成配置文件 (config.json)
echo -e "${GREEN}正在生成配置文件...${PLAIN}"
cat > $WORK_DIR/config.json <<EOF
{
  "log": {
    "level": "info",
    "output": "$WORK_DIR/logs/box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "method": "$METHOD",
      "password": "$PASSWORD",
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 创建 Systemd 服务文件
echo -e "${GREEN}配置系统服务...${PLAIN}"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/sing-box run -c $WORK_DIR/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 开放防火墙端口 (简单处理)
if command -v ufw >/dev/null; then
    ufw allow $LISTEN_PORT/tcp
    ufw allow $LISTEN_PORT/udp
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --zone=public --add-port=$LISTEN_PORT/tcp --permanent
    firewall-cmd --zone=public --add-port=$LISTEN_PORT/udp --permanent
    firewall-cmd --reload
elif command -v iptables >/dev/null; then
    iptables -I INPUT -p tcp --dport $LISTEN_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
fi

# 启动服务
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# 检查运行状态
sleep 2
if systemctl is-active --quiet sing-box; then
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}Sing-box (Shadowsocks) 安装并启动成功！${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    
    # 获取本机 IP
    IP=$(curl -s4 ip.sb)
    if [[ -z "$IP" ]]; then
        IP="你的服务器IP"
    fi

    # 生成 SS 链接 (base64)
    SS_BASE64=$(echo -n "${METHOD}:${PASSWORD}@${IP}:${LISTEN_PORT}" | base64 -w0)
    SS_LINK="ss://${SS_BASE64}#SingBox-SS"

    echo -e "配置信息如下："
    echo -e "地址 (IP): ${YELLOW}${IP}${PLAIN}"
    echo -e "端口 (Port): ${YELLOW}${LISTEN_PORT}${PLAIN}"
    echo -e "密码 (Password): ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "加密 (Method): ${YELLOW}${METHOD}${PLAIN}"
    echo -e ""
    echo -e "SS 链接 (复制到客户端):"
    echo -e "${GREEN}${SS_LINK}${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
else
    echo -e "${RED}服务启动失败，请检查日志: cat $WORK_DIR/logs/box.log${PLAIN}"
    exit 1
fi