#!/bin/bash

# =================配置区域=================
LISTEN_PORT=8844
PASSWORD='AAAAAolRPFnZRyVerojPbAAAAA'
METHOD='aes-256-gcm'
# =========================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

CONTAINER_NAME='shadowsocks-gvisor'
IMAGE_NAME='ss-rust-gvisor'
WORK_DIR='/etc/shadowsocks'

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须使用 root 用户运行！${PLAIN}"
    exit 1
fi

# 检查架构
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) 
        DOCKER_ARCH="amd64"
        SS_ARCH="x86_64-unknown-linux-gnu"
        ;;
    aarch64|arm64) 
        DOCKER_ARCH="arm64"
        SS_ARCH="aarch64-unknown-linux-gnu"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
        exit 1
        ;;
esac

clear
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  Shadowsocks-Rust + gVisor 一键安装  ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}\n"

# 1. 安装 Docker
echo -e "${YELLOW}[1/5] 安装 Docker...${PLAIN}"
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null 2>&1
    
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker
    echo -e "${GREEN}✓ Docker 安装完成${PLAIN}"
else
    echo -e "${GREEN}✓ Docker 已安装${PLAIN}"
fi
echo ""

# 2. 安装配置 gVisor
echo -e "${YELLOW}[2/5] 安装并配置 gVisor...${PLAIN}"

if ! command -v runsc &> /dev/null; then
    echo "正在下载 gVisor..."
    GVISOR_URL="https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)"
    wget -q --show-progress -O /usr/local/bin/runsc "${GVISOR_URL}/runsc"
    chmod +x /usr/local/bin/runsc
    echo -e "${GREEN}✓ gVisor 安装完成${PLAIN}"
else
    echo -e "${GREEN}✓ gVisor 已安装${PLAIN}"
fi

# 配置 Docker 使用 gVisor
mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%s)
fi

cat > /etc/docker/daemon.json <<'DOCKERJSON'
{
  "runtimes": {
    "runsc": {
      "path": "/usr/local/bin/runsc",
      "runtimeArgs": [
        "--platform=systrap"
      ]
    }
  }
}
DOCKERJSON

echo "正在重启 Docker..."
systemctl restart docker
sleep 3

if ! docker info &> /dev/null; then
    echo -e "${RED}Docker 启动失败${PLAIN}"
    exit 1
fi

echo -e "${GREEN}✓ gVisor 配置完成${PLAIN}\n"

# 3. 创建 Shadowsocks 配置和镜像
echo -e "${YELLOW}[3/5] 构建 Shadowsocks 镜像...${PLAIN}"

rm -rf $WORK_DIR
mkdir -p $WORK_DIR
cd $WORK_DIR

# 创建配置文件
cat > config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": $LISTEN_PORT,
    "password": "$PASSWORD",
    "timeout": 300,
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

# 创建 Dockerfile
cat > Dockerfile <<SSDOCKERFILE
FROM debian:12-slim

ENV SS_VERSION=1.19.1
ENV RUST_BACKTRACE=1

RUN apt-get update && \\
    apt-get install -y wget xz-utils && \\
    wget -q -O /tmp/shadowsocks.tar.xz \\
        "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v\${SS_VERSION}/shadowsocks-v\${SS_VERSION}.${SS_ARCH}.tar.xz" && \\
    tar -xJf /tmp/shadowsocks.tar.xz -C /usr/local/bin/ && \\
    chmod +x /usr/local/bin/ssserver && \\
    rm -rf /tmp/* && \\
    apt-get remove -y wget xz-utils && \\
    apt-get autoremove -y && \\
    apt-get clean && \\
    rm -rf /var/lib/apt/lists/*

WORKDIR /etc/shadowsocks

EXPOSE $LISTEN_PORT

ENTRYPOINT ["/usr/local/bin/ssserver"]
CMD ["-c", "/etc/shadowsocks/config.json"]
SSDOCKERFILE

# 构建镜像
echo "正在构建镜像（首次运行需要几分钟）..."
docker build -q -t $IMAGE_NAME . >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}镜像构建失败，显示详细错误：${PLAIN}"
    docker build -t $IMAGE_NAME .
    exit 1
fi

echo -e "${GREEN}✓ 镜像构建完成${PLAIN}\n"

# 4. 测试 gVisor
echo -e "${YELLOW}[4/5] 测试 gVisor 运行时...${PLAIN}"
docker run --rm --runtime=runsc alpine echo "gVisor 测试成功" >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ gVisor 运行时可用${PLAIN}"
    USE_GVISOR=true
    RUNTIME="--runtime=runsc"
    RUNTIME_NAME="gVisor (runsc/systrap)"
else
    echo -e "${YELLOW}⚠ gVisor 不可用，使用标准运行时${PLAIN}"
    USE_GVISOR=false
    RUNTIME=""
    RUNTIME_NAME="runc (标准)"
fi
echo ""

# 5. 启动容器
echo -e "${YELLOW}[5/5] 启动 Shadowsocks 容器...${PLAIN}"

# 停止旧容器
docker stop $CONTAINER_NAME >/dev/null 2>&1
docker rm $CONTAINER_NAME >/dev/null 2>&1

# 启动新容器
docker run -d \
  --name $CONTAINER_NAME \
  $RUNTIME \
  -p ${LISTEN_PORT}:${LISTEN_PORT}/tcp \
  -p ${LISTEN_PORT}:${LISTEN_PORT}/udp \
  --restart=always \
  -v $WORK_DIR/config.json:/etc/shadowsocks/config.json:ro \
  $IMAGE_NAME >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}容器启动失败${PLAIN}"
    docker logs $CONTAINER_NAME
    exit 1
fi

echo -e "${GREEN}✓ 容器已启动${PLAIN}\n"

# 等待服务启动
sleep 3

# 检查容器状态
if ! docker ps | grep -q $CONTAINER_NAME; then
    echo -e "${RED}容器未正常运行${PLAIN}"
    docker ps -a | grep $CONTAINER_NAME
    docker logs $CONTAINER_NAME
    exit 1
fi

# 显示结果
clear
echo -e "${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  ✓ Shadowsocks 安装成功！${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}\n"

# 获取 IP
IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
if [[ -z "$IP" ]]; then
    IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
fi
if [[ -z "$IP" ]]; then
    IP=$(hostname -I | awk '{print $1}')
fi
if [[ -z "$IP" ]]; then
    IP="你的服务器IP"
fi

# 生成 SS 链接
SS_BASE64=$(echo -n "${METHOD}:${PASSWORD}@${IP}:${LISTEN_PORT}" | base64 -w0)
SS_LINK="ss://${SS_BASE64}#SS-gVisor"

echo -e "${GREEN}【配置信息】${PLAIN}"
echo -e "服务器地址: ${YELLOW}${IP}${PLAIN}"
echo -e "端口号: ${YELLOW}${LISTEN_PORT}${PLAIN}"
echo -e "密码: ${YELLOW}${PASSWORD}${PLAIN}"
echo -e "加密方式: ${YELLOW}${METHOD}${PLAIN}"
echo -e "运行环境: ${YELLOW}${RUNTIME_NAME}${PLAIN}"

if [ "$USE_GVISOR" = true ]; then
    echo -e "安全级别: ${GREEN}gVisor 沙箱隔离${PLAIN}"
else
    echo -e "安全级别: ${YELLOW}Docker 容器隔离${PLAIN}"
fi

echo -e "\n${GREEN}【Shadowsocks 链接】${PLAIN}"
echo -e "${GREEN}${SS_LINK}${PLAIN}"

echo -e "\n${GREEN}【管理命令】${PLAIN}"
echo -e "查看状态: ${YELLOW}docker ps | grep shadowsocks${PLAIN}"
echo -e "查看日志: ${YELLOW}docker logs -f shadowsocks-gvisor${PLAIN}"
echo -e "重启服务: ${YELLOW}docker restart shadowsocks-gvisor${PLAIN}"
echo -e "停止服务: ${YELLOW}docker stop shadowsocks-gvisor${PLAIN}"
echo -e "卸载服务: ${YELLOW}docker stop shadowsocks-gvisor && docker rm shadowsocks-gvisor${PLAIN}"

echo -e "\n${GREEN}【服务状态】${PLAIN}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|shadowsocks"

echo -e "\n${GREEN}【端口监听】${PLAIN}"
ss -tuln 2>/dev/null | grep $LISTEN_PORT || netstat -tuln 2>/dev/null | grep $LISTEN_PORT

if [ "$USE_GVISOR" = true ]; then
    echo -e "\n${YELLOW}【注意】${PLAIN}"
    echo -e "日志中的警告 'failed to disable IP fragmentation' 是正常的"
    echo -e "这是 gVisor 的限制，不影响代理功能"
fi

echo -e "\n${GREEN}==========================================${PLAIN}"
echo -e "${GREEN}  安装完成！请在客户端导入上面的链接  ${PLAIN}"
echo -e "${GREEN}==========================================${PLAIN}\n"