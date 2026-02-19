#!/bin/bash
set -e

# ========= root 检查 =========
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

#################################
# 交互式配置（回车使用默认）
#################################
read -p "Hysteria2 实际监听端口（默认 36800）: " REAL_PORT
REAL_PORT=${REAL_PORT:-36800}

# 选择是否启用端口跳跃功能
read -p "是否启用 UDP 端口跳跃功能？(y/n, 默认 n): " ENABLE_JUMP
ENABLE_JUMP=${ENABLE_JUMP:-n}

# 如果启用端口跳跃，才要求输入跳跃端口
if [ "$ENABLE_JUMP" == "y" ]; then
  read -p "UDP 跳跃起始端口（默认 36801）: " JUMP_START
  JUMP_START=${JUMP_START:-36801}

  read -p "UDP 跳跃结束端口（默认 36850）: " JUMP_END
  JUMP_END=${JUMP_END:-36850}

  if (( JUMP_END <= JUMP_START )); then
    echo "❌ 跳跃端口区间不合法"
    exit 1
  fi
else
  # 如果不启用端口跳跃，JUMP_START 和 JUMP_END 设置为 null（无效值）
  JUMP_START=""
  JUMP_END=""
fi

read -p "伪装域名 / SNI / 证书 CN（默认 www.bing.com）: " FAKE_DOMAIN
FAKE_DOMAIN=${FAKE_DOMAIN:-www.bing.com}

read -p "上行带宽 Mbps（默认 20）: " UP_MBPS
UP_MBPS=${UP_MBPS:-20}

read -p "下行带宽 Mbps（默认 100）: " DOWN_MBPS
DOWN_MBPS=${DOWN_MBPS:-100}

# ========= 安装基础依赖 =========
echo ">>> 安装基础依赖"
apt update
apt install -y curl unzip openssl iptables-persistent

# ========= 安装 Hysteria2 =========
echo ">>> 安装 Hysteria2"
bash <(curl -fsSL https://get.hy2.sh/)

# ========= 生成自签证书 =========
echo ">>> 生成自签证书"
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=${FAKE_DOMAIN}" -days 36500
chown hysteria:hysteria /etc/hysteria/server.key /etc/hysteria/server.crt

# ========= 配置 UDP 端口跳跃 =========
if [ "$ENABLE_JUMP" == "y" ]; then
  echo ">>> 启用端口跳跃功能"

  # 删除已存在的规则（避免重复）
  ETH0=$(ip route | grep default | awk '{print $5}')  # 默认使用默认路由网卡
  iptables -t nat -D PREROUTING -i "$ETH0" -p udp --dport "${JUMP_START}:${JUMP_END}" -j REDIRECT --to-ports "$REAL_PORT" || true
  ip6tables -t nat -D PREROUTING -i "$ETH0" -p udp --dport "${JUMP_START}:${JUMP_END}" -j REDIRECT --to-ports "$REAL_PORT" || true

  # 添加新的规则
  iptables -t nat -A PREROUTING -i "$ETH0" -p udp --dport "${JUMP_START}:${JUMP_END}" -j REDIRECT --to-ports "$REAL_PORT"
  ip6tables -t nat -A PREROUTING -i "$ETH0" -p udp --dport "${JUMP_START}:${JUMP_END}" -j REDIRECT --to-ports "$REAL_PORT"
  netfilter-persistent save
  echo ">>> UDP端口跳跃已配置: $JUMP_START ~ $JUMP_END -> $REAL_PORT"
else
  echo ">>> 未启用端口跳跃功能"
fi

# ========= 生成随机认证密码 =========
echo ">>> 生成随机认证密码"
AUTH_PASS=$(openssl rand -hex 16)

# ========= 写 Hysteria2 服务端配置 =========
echo ">>> 写入 Hysteria2 配置文件"
cat > /etc/hysteria/config.yaml <<EOF
listen: :$REAL_PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $AUTH_PASS
  
masquerade:
  type: proxy
  proxy:
    url: https://$FAKE_DOMAIN
    rewriteHost: true

outbounds:
  - name: direct
    type: direct
    direct:
      mode: 46
      fastOpen: false
EOF

# ========= 启动 Hysteria2 =========
echo ">>> 启动 Hysteria2 服务"
systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server
sleep 1
systemctl is-active --quiet hysteria-server && echo "✅ Hysteria2 运行正常" || echo "❌ Hysteria2 启动失败"

# ========= 获取服务器 IP =========
echo ">>> 获取服务器公网 IP"
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ip.sb)

# ========= 确保 HYSTERIA_LINK 正确构建 =========
HYSTERIA_LINK="hysteria2://${AUTH_PASS}@${SERVER_IP}:${REAL_PORT}?sni=${FAKE_DOMAIN}&insecure=1&allowInsecure=1#Hysteria2"

# ========= 输出 =========
echo "===================================="
echo " Hysteria2 已安装完成"
echo "------------------------------------"
echo "服务器IP   : $SERVER_IP"
echo "监听端口   : $REAL_PORT"
echo "UDP跳跃区间: $JUMP_START ~ $JUMP_END"
echo "认证密码   : $AUTH_PASS"
echo "伪装域名   : $FAKE_DOMAIN"
echo "上行带宽   : $UP_MBPS Mbps"
echo "下行带宽   : $DOWN_MBPS Mbps"
echo "------------------------------------"
echo "v2rayN / Sing-box 节点链接（可直接导入）:"
echo ""
echo "$HYSTERIA_LINK"
echo ""
echo "===================================="
