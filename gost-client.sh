#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  gost-client.sh                         # 交互式填写
  gost-client.sh <服务端IP> <客户端接收端口> <encrypt|decrypt|plain> <隧道ID> [隧道端口=8443] [服务端证书=/etc/gost-forward/server.crt] [本地目标地址=127.0.0.1]

encrypt/decrypt 表示启用 TLS/WSS；plain 表示明文。
客户端会把服务端 TCP/UDP 流量转发到本机的 <本地目标地址>:<客户端接收端口>。
USAGE
}

fail() { echo "错误: $*" >&2; exit 1; }
valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  local n=$((10#$1))
  (( n >= 1 && n <= 65535 ))
}
host_port() {
  local host=$1 port=$2
  host=${host#[}
  host=${host%]}
  if [[ "$host" == *:* ]]; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

CONFIG_DIR=${GOST_FORWARD_DIR:-/etc/gost-forward}

if (( $# == 0 )); then
  echo "GOST 客户端配置（直接回车使用方括号中的默认值）"
  read -r -p "服务端 IP: " SERVER_IP
  read -r -p "客户端本机接收/目标端口: " RECEIVE_PORT
  while true; do
    read -r -p "传输模式 [1=加密/解密（TLS，推荐）, 2=不加密] (1): " MODE_CHOICE
    MODE_CHOICE=${MODE_CHOICE:-1}
    case "$MODE_CHOICE" in
      1) MODE=encrypt; break ;;
      2) MODE=plain; break ;;
      *) echo "请输入 1 或 2。" ;;
    esac
  done
  read -r -p "隧道 ID（从服务端启动信息复制）: " TUNNEL_ID
  read -r -p "隧道控制端口 [8443]: " TUNNEL_PORT
  TUNNEL_PORT=${TUNNEL_PORT:-8443}
  read -r -p "服务端证书路径 [$CONFIG_DIR/server.crt]: " CA_FILE
  CA_FILE=${CA_FILE:-$CONFIG_DIR/server.crt}
  read -r -p "本地目标地址 [127.0.0.1]: " TARGET_HOST
  TARGET_HOST=${TARGET_HOST:-127.0.0.1}
  set -- "$SERVER_IP" "$RECEIVE_PORT" "$MODE" "$TUNNEL_ID" "$TUNNEL_PORT" "$CA_FILE" "$TARGET_HOST"
fi

[[ $# -ge 4 && $# -le 7 ]] || { usage; exit 2; }
SERVER_IP=$1
RECEIVE_PORT=$2
MODE=$3
TUNNEL_ID=$4
TUNNEL_PORT=${5:-8443}
CA_FILE=${6:-$CONFIG_DIR/server.crt}
TARGET_HOST=${7:-127.0.0.1}

SERVER_IP=${SERVER_IP#[}
SERVER_IP=${SERVER_IP%]}
[[ "$SERVER_IP" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "服务端地址格式无效"
[[ "$TARGET_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "本地目标地址格式无效"
valid_port "$RECEIVE_PORT" || fail "客户端接收端口必须在 1-65535 之间"
valid_port "$TUNNEL_PORT" || fail "隧道端口必须在 1-65535 之间"
[[ "$TUNNEL_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail "隧道 ID 必须是 UUID"
[[ "$CONFIG_DIR" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "GOST_FORWARD_DIR 只允许字母、数字、点、下划线、斜杠和短横线"

case "$MODE" in
  decrypt|encrypt|tls|加密|解密) ENCRYPTED=1 ;;
  plain|none|不加密) ENCRYPTED=0 ;;
  *) fail "模式请填写 encrypt、decrypt 或 plain" ;;
esac

command -v gost >/dev/null 2>&1 || fail "没有找到 gost，请先安装 GOST v3 并确保它在 PATH 中"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/client.yml"

SERVER_ADDR=$(host_port "$SERVER_IP" "$TUNNEL_PORT")
TARGET_ADDR=$(host_port "$TARGET_HOST" "$RECEIVE_PORT")

if (( ENCRYPTED )); then
  [[ "$CA_FILE" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "证书路径只允许字母、数字、点、下划线、斜杠和短横线"
  [[ -r "$CA_FILE" ]] || fail "找不到服务端证书 $CA_FILE；请先从服务端安全复制 server.crt"
  TUNNEL_DIALER_TYPE=wss
  TLS_DIALER_BLOCK=$(cat <<EOF
              tls:
                caFile: "$CA_FILE"
                secure: true
                serverName: gost-forward
EOF
)
else
  TUNNEL_DIALER_TYPE=tcp
  TLS_DIALER_BLOCK=""
fi

cat > "$CONFIG_FILE" <<EOF
services:
  - name: client-tcp
    addr: ":0"
    handler:
      type: rtcp
    listener:
      type: rtcp
      chain: server-tunnel
    forwarder:
      nodes:
        - name: local-tcp-service
          addr: "$TARGET_ADDR"

  - name: client-udp
    addr: ":0"
    handler:
      type: rudp
    listener:
      type: rudp
      chain: server-tunnel
    forwarder:
      nodes:
        - name: local-udp-service
          addr: "$TARGET_ADDR"

chains:
  - name: server-tunnel
    hops:
      - name: tunnel-hop
        nodes:
          - name: server
            addr: "$SERVER_ADDR"
            connector:
              type: tunnel
              metadata:
                tunnel.id: "$TUNNEL_ID"
            dialer:
              type: $TUNNEL_DIALER_TYPE
$(printf '%s\n' "$TLS_DIALER_BLOCK")
log:
  level: info
  format: text
EOF

chmod 600 "$CONFIG_FILE"
echo "GOST 客户端配置已生成: $CONFIG_FILE"
echo "服务端隧道: $SERVER_ADDR"
echo "本地 TCP/UDP 目标: $TARGET_ADDR"
echo "启动 GOST... 按 Ctrl+C 停止。"
exec gost -C "$CONFIG_FILE"
