#!/bin/bash

set -e

# ================= 配置区域 =================
# 请将这里的地址替换为你自己的 XMR 钱包地址
WALLET="41u1VQNRXLW3CTroWe59d79ZGuREUCp9UZPjxHiRgATtAKyFgp16xW7esgvEvy9Wf84JnezSvCiWgH43Q6PfVYH8CvSXteJ"
EMAIL="189aws@gmail.com"

# --- 修改部分：从 amazonaws 获取公网 IP ---
echo "正在获取公网 IP..."
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com | tr -d '\n')
RIG_NAME="c${PUBLIC_IP}"
# ---------------------------------------

# 安装路径
INSTALL_DIR="/opt/nanominer"
SERVICE_FILE="/etc/systemd/system/nanominer.service"
# ===========================================

echo "========== Nanominer 官方锄头自动安装脚本 =========="

# 1. 环境准备与依赖安装
echo "[1/6] 正在安装系统依赖..."
# 增加 curl 依赖确保能获取 IP
apt update && apt install -y wget tar msr-tools screen curl

# 2. 目录清理与创建
if [ -d "$INSTALL_DIR" ]; then
    echo "清理现有安装目录..."
    rm -rf "$INSTALL_DIR"/*
else
    mkdir -p "$INSTALL_DIR"
fi

# 3. 下载最新的 nanominer v3.10.0
echo "[2/6] 正在从官方 GitHub 下载 nanominer v3.10.0..."
# 直接指定 3.10.0 版本
DOWNLOAD_URL="https://github.com/nanopool/nanominer/releases/download/v3.10.0/nanominer-linux-3.10.0.tar.gz"
wget -qO- "$DOWNLOAD_URL" | tar -zxf - -C "$INSTALL_DIR" --strip-components=0
# 注意：nanominer压缩包内通常带一级目录，手动移动到根目录
mv "$INSTALL_DIR"/nanominer-linux-3.10.0/* "$INSTALL_DIR"/ || true

# 4. 写入针对 8488C 优化的 config.ini
echo "[3/6] 生成官方配置文件 config.ini..."
cat > "$INSTALL_DIR/config.ini" <<EOF
[RandomX]
wallet = $WALLET
rigName = $RIG_NAME
email = $EMAIL
pool1 = xmr-us-west1.nanopool.org:10343
pool2 = xmr-us-east1.nanopool.org:10343
# 自动选择最快指令集 (AVX-512)
sortPools = true
EOF

# 5. 写入启动包装脚本 run.sh (用于处理 Huge Pages 和 MSR)
echo "[4/6] 写入启动脚本 run.sh..."
cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash
# 开启大页内存优化
sysctl -w vm.nr_hugepages=2560
# 尝试开启 MSR 寄存器优化 (针对 Intel Xeon)
modprobe msr
# 进入目录运行
cd $INSTALL_DIR
exec ./nanominer
EOF
chmod +x "$INSTALL_DIR/run.sh"

# 6. 注册为 systemd 系统服务 (实现开机自启和恢复)
echo "[5/6] 注册 systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nanominer XMR Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/run.sh
Restart=always
RestartSec=60
# 限制日志大小防止撑爆磁盘
StandardOutput=append:$INSTALL_DIR/miner.log
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF

# 7. 启动服务
echo "[6/6] 启动服务并设置开机自启..."
systemctl daemon-reload
systemctl enable nanominer
systemctl restart nanominer

echo "========== 安装完成！ =========="
echo "查看运行状态: systemctl status nanominer"
echo "查看实时日志: tail -f $INSTALL_DIR/miner.log"
echo "您的 Worker 名称为: $RIG_NAME"