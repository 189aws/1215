#!/bin/bash

set -e

echo "========== ApoolMiner (Debian 12 优化版) 自动更新安装脚本 =========="

# 默认账户和矿池配置
ACCOUNT="${1:-CP_desb91pu36}"
INSTALL_DIR="/opt/apoolminer"
SERVICE_FILE="/etc/systemd/system/apoolminer.service"
POOL="qubic.eu.apool.net:8080"

# 1. 基础依赖与环境准备
echo "正在安装系统依赖..."
apt update
apt install -y wget tar jq curl ca-certificates libcurl4

# 2. 解决 Debian 12 缺少 libssl1.1 的兼容性问题
if ! dpkg -s libssl1.1 >/dev/null 2>&1; then
    echo "正在下载 libssl1.1 兼容包 (针对 Debian 12)..."
    wget -q http://nz2.archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
    dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb || apt --fix-broken install -y
    rm libssl1.1_1.1.1f-1ubuntu2_amd64.deb
fi

# 3. 目录清理或创建
if [ -d "$INSTALL_DIR" ]; then
    echo "清理安装目录 $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"/*
else
    echo "创建安装目录 $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# 4. 下载最新版 Apoolminer
echo "正在从 GitHub 获取最新版本..."
VERSION=$(wget -qO- https://api.github.com/repos/apool-io/apoolminer/releases/latest | jq -r .tag_name)
[ -z "$VERSION" ] && VERSION="v3.3.0"  # 兜底版本
DOWNLOAD_URL="https://github.com/apool-io/apoolminer/releases/download/${VERSION}/apoolminer_linux_qubic_autoupdate_${VERSION}.tar.gz"

echo "开始下载 $VERSION..."
wget -qO- "$DOWNLOAD_URL" | tar -zxf - -C "$INSTALL_DIR" --strip-components=1
echo "Apoolminer 版本 $VERSION 下载并解压完成。"

# 5. 写入 update.sh (完全保留你要求的自动更新逻辑)
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

# 6. 写入 run.sh (使用 checkip.amazonaws.com 方式)
echo "写入 run.sh..."
cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash

# 检查并执行更新
/bin/bash "$INSTALL_DIR/update.sh"

# 仅通过 checkip.amazonaws.com 获取公网 IP 作为 Worker 名称
# tr -d '.' 去掉点号, cut -c 1-15 限制长度
raw_ip=\$(curl -s --connect-timeout 5 http://checkip.amazonaws.com | tr -d '.' | tr -d '\n')
worker=\$(echo \$raw_ip | cut -c 1-15)

if [ -z "\$worker" ]; then
    worker="node\${RANDOM}"
fi

echo "启动矿工，Worker名称: \$worker"

# 执行 apoolminer
# 这里的 --algo 设置为 qubic_xmr 适配 Qubic 矿池
exec "$INSTALL_DIR/apoolminer" --algo qubic_xmr --account "$ACCOUNT" --worker "\$worker" --pool "$POOL"
EOF

chmod +x "$INSTALL_DIR/run.sh"

# 7. 写入 systemd 服务
echo "注册系统服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Apool Qubic Miner
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

# 8. 启动
systemctl daemon-reload
systemctl enable apoolminer
systemctl restart apoolminer

echo "========== 安装完成 =========="
echo "当前版本: $VERSION"
echo "监控状态: systemctl status apoolminer"
echo "实时日志: journalctl -u apoolminer -f"
