#!/bin/bash

set -e

echo "========== apoolminer 自动安装并注册为服务 =========="

# 默认账户和矿池配置
ACCOUNT="${1:-CP_desb91pu36}"
INSTALL_DIR="/opt/apoolminer"
SERVICE_FILE="/etc/systemd/system/apoolminer.service"
POOL="xmr.eu.apool.net:8080" # 注意：脚本中的算法参数是 --algo xmr，但矿池地址qubic.eu.apool.net:8080是Qubic矿池。请确保算法和矿池匹配。

# 目录清理或创建
if [ -d "$INSTALL_DIR" ]; then
    echo "清理安装目录 $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"/*
else
    echo "创建安装目录 $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
fi

# 安装依赖
echo "安装必要组件..."
# 检查当前系统是否为 Debian/Ubuntu 或其他使用 apt 的系统
if command -v apt &> /dev/null; then
    apt update
    apt install -y wget tar jq
elif command -v yum &> /dev/null; then
    yum install -y wget tar jq
else
    echo "警告：无法识别包管理器 (apt/yum)。请手动确保安装了 wget, tar, jq。"
fi


# 下载
echo "下载 apoolminer..."
# 获取最新版本号
VERSION=$(wget -qO- https://api.github.com/repos/apool-io/apoolminer/releases/latest | jq -r .tag_name)
[ -z "$VERSION" ] && VERSION="v3.2.0"
DOWNLOAD_URL="https://github.com/apool-io/apoolminer/releases/download/${VERSION}/apoolminer_linux_qubic_autoupdate_${VERSION}.tar.gz"

# 下载并解压
wget -qO- "$DOWNLOAD_URL" | tar -zxf - -C "$INSTALL_DIR" --strip-components=1
echo "Apoolminer 版本 $VERSION 下载完成。"

# 写入 update.sh (保持不变，用于自动更新)
echo "写入 update.sh..."
cat > "$INSTALL_DIR/update.sh" <<EOF
#!/bin/bash
LAST_VERSION=\$(wget -qO- https://api.github.com/repos/apool-io/apoolminer/releases/latest | jq -r .tag_name | cut -b 2-)
LOCAL_VERSION=\$("$INSTALL_DIR"/apoolminer --version | awk '{print \$2}')
[ "\$LAST_VERSION" == "\$LOCAL_VERSION" ] && echo '无更新' && exit 0
echo "\$LAST_VERSION" | awk -F . '{print \$1\$2\$3, "LAST_VERSION"}' > /tmp/versions
echo "\$LOCAL_VERSION" | awk -F . '{print \$1\$2\$3, "LOCAL_VERSION"}' >> /tmp/versions
NEW_VERSION=\$(sort -n /tmp/versions | tail -1 | awk '{print \$2}')
[ "\$NEW_VERSION" == "\$LOCAL_VERSION" ] && exit 0
bash <(wget -qO- https://raw.githubusercontent.com/chuben/script/main/apoolminer.sh) "$ACCOUNT"
EOF

chmod +x "$INSTALL_DIR/update.sh"

# 写入 run.sh (已修改，直接使用 IP 作为 worker)
echo "写入 run.sh (不含IP转换)..."
cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash

# 检查并执行更新
/bin/bash "$INSTALL_DIR/update.sh"

# 尝试获取公网IP
# 169.254.169.254 是云服务商的元数据服务地址，如果获取不到，尝试使用通用 IP 服务
ip=\$(wget -T 3 -t 2 -qO- http://169.254.169.254/2021-03-23/meta-data/public-ipv4)

if [ -z "\$ip" ]; then
    echo "尝试从通用服务获取公网IP..."
    ip=\$(wget -T 3 -t 2 -qO- ipinfo.io/ip)
fi

if [ -z "\$ip" ]; then
    echo "错误：无法获取公网IP地址。退出。"
    exit 1
fi

# 直接使用 IP 作为矿工别名
minerAlias="\$ip"

echo "启动矿工，Worker名称: \$minerAlias"

# 执行 apoolminer
# 注意：您的原始脚本中使用了 --algo xmr，但矿池是Qubic的地址。请确保这两个参数匹配您实际要挖的币种。
exec ${INSTALL_DIR}/apoolminer --algo xmr --account "$ACCOUNT" --worker "\$minerAlias" --pool "$POOL"
EOF

chmod +x "$INSTALL_DIR/run.sh"

# 写入 systemd 服务 (保持不变)
echo "写入 systemd 服务文件 $SERVICE_FILE..."
tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Apool XMR Miner
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/run.sh
Restart=always
RestartSec=30
Environment="LD_LIBRARY_PATH=$INSTALL_DIR"

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
echo "启用并启动 apoolminer 服务..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable apoolminer
systemctl restart apoolminer
echo "========== 安装完成，服务已启动 =========="
