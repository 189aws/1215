#!/bin/bash

systemctl stop tari || true
systemctl stop bitz || true
systemctl disable tari || true
systemctl disable bitz || true

set -e

echo "========== apoolminer 自动安装并注册为服务 =========="

ACCOUNT="${1:-CP_desb91pu36}"
INSTALL_DIR="/opt/apoolminer"
SERVICE_FILE="/etc/systemd/system/apoolminer.service"
POOL="xmr.asia.apool.io:4334"

if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"/*
else
    mkdir -p "$INSTALL_DIR"
fi

# 安装依赖
echo "安装必要组件..."
apt update
apt install -y wget tar jq

# 下载
echo "下载 apoolminer..."
VERSION=$(wget -qO- https://api.github.com/repos/apool-io/apoolminer/releases/latest | jq -r .tag_name)
[ -z "$VERSION" ] && VERSION="v3.2.0"
DOWNLOAD_URL="https://github.com/apool-io/apoolminer/releases/download/${VERSION}/apoolminer_linux_qubic_autoupdate_${VERSION}.tar.gz"
wget -qO- "$DOWNLOAD_URL" | tar -zxf - -C "$INSTALL_DIR" --strip-components=1

# 写入 update.sh
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

# 写入 run.sh
cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash

/bin/bash "$INSTALL_DIR/update.sh"

ip=\$(wget -T 3 -t 2 -qO- http://169.254.169.254/2021-03-23/meta-data/public-ipv4)
[ -z "\$ip" ] && exit 1

declare -A encrypt_dict=(
    ["0"]="a" ["1"]="b" ["2"]="c" ["3"]="d" ["4"]="e"
    ["5"]="f" ["6"]="g" ["7"]="h" ["8"]="i" ["9"]="j"
    ["."]="k"
)

encrypt_ip() {
    local ip=\$1
    local result=""
    for (( i=0; i<\${#ip}; i++ )); do
        char="\${ip:\$i:1}"
        result+="\${encrypt_dict[\$char]:-\$char}"
    done
    echo "\$result"
}

minerAlias=\$(encrypt_ip "\$ip")
exec ${INSTALL_DIR}/apoolminer --algo xmr --account "$ACCOUNT" --worker "\$minerAlias" --pool "$POOL"
EOF

chmod +x "$INSTALL_DIR/run.sh"

# 写入 systemd 服务
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
