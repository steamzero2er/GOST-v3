#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  gost-server.sh <客户端公网IP> <服务端转发端口> <decrypt|encrypt|plain> [隧道端口=8443] [隧道ID]

decrypt/encrypt 表示启用 TLS/WSS；plain 表示明文。
服务端会同时开放指定端口的 TCP 和 UDP，并将隧道连接来源限制为客户端 IP。
隧道 ID 不填时自动生成。加密模式会生成 server.crt/server.key。
USAGE
}

fail() { echo "错误: $*" >&2; exit 1; }
valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  local n=$((10#$1))
  (( n >= 1 && n <= 65535 ))
}

[[ $# -ge 3 && $# -le 5 ]] || { usage; exit 2; }
CLIENT_IP=$1
FORWARD_PORT=$2
MODE=$3
TUNNEL_PORT=${4:-8443}
CONFIG_DIR=${GOST_FORWARD_DIR:-/etc/gost-forward}

[[ "$CLIENT_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || fail "客户端 IP 必须是 IPv4 或 IPv6 地址"
valid_port "$FORWARD_PORT" || fail "转发端口必须在 1-65535 之间"
valid_port "$TUNNEL_PORT" || fail "隧道端口必须在 1-65535 之间"
[[ "$FORWARD_PORT" != "$TUNNEL_PORT" ]] || fail "服务端转发端口和隧道端口不能相同"
[[ "$CONFIG_DIR" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "GOST_FORWARD_DIR 只允许字母、数字、点、下划线、斜杠和短横线"

case "$MODE" in
  decrypt|encrypt|tls|加密|解密) ENCRYPTED=1 ;;
  plain|none|不加密) ENCRYPTED=0 ;;
  *) fail "模式请填写 decrypt、encrypt 或 plain" ;;
esac

if [[ $# -ge 5 && -n ${5:-} ]]; then
  TUNNEL_ID=$5
else
  TUNNEL_ID=$(cat /proc/sys/kernel/random/uuid)
fi
[[ "$TUNNEL_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail "隧道 ID 必须是 UUID"

command -v gost >/dev/null 2>&1 || fail "没有找到 gost，请先安装 GOST v3 并确保它在 PATH 中"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

CERT_FILE="$CONFIG_DIR/server.crt"
KEY_FILE="$CONFIG_DIR/server.key"
CONFIG_FILE="$CONFIG_DIR/server.yml"

if (( ENCRYPTED )); then
  command -v openssl >/dev/null 2>&1 || fail "加密模式需要 openssl"
  if [[ -e "$CERT_FILE" || -e "$KEY_FILE" ]]; then
    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || fail "证书或私钥只存在一个；请检查 $CONFIG_DIR 后再运行"
  else
    openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
      -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=gost-forward" \
      -addext "subjectAltName=DNS:gost-forward" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign"
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
  fi
  TUNNEL_LISTENER_TYPE=wss
  TUNNEL_DIALER_TYPE=wss
  TLS_LISTENER_BLOCK=$(cat <<EOF
      tls:
        certFile: "$CERT_FILE"
        keyFile: "$KEY_FILE"
EOF
)
  TLS_DIALER_BLOCK=$(cat <<EOF
              tls:
                caFile: "$CERT_FILE"
                secure: true
                serverName: gost-forward
EOF
)
else
  TUNNEL_LISTENER_TYPE=tcp
  TUNNEL_DIALER_TYPE=tcp
  TLS_LISTENER_BLOCK=""
  TLS_DIALER_BLOCK=""
fi

cat > "$CONFIG_FILE" <<EOF
services:
  - name: tunnel-server
    addr: ":$TUNNEL_PORT"
    admission: tunnel-peers
    handler:
      type: tunnel
      metadata:
        tunnel.direct: true
    listener:
      type: $TUNNEL_LISTENER_TYPE
$(printf '%s\n' "$TLS_LISTENER_BLOCK")
  - name: public-tcp
    addr: ":$FORWARD_PORT"
    handler:
      type: tcp
      chain: client-tunnel
    listener:
      type: tcp

  - name: public-udp
    addr: ":$FORWARD_PORT"
    handler:
      type: udp
      chain: client-tunnel
    listener:
      type: udp
      metadata:
        keepalive: true

chains:
  - name: client-tunnel
    hops:
      - name: tunnel-hop
        nodes:
          - name: client
            addr: "127.0.0.1:$TUNNEL_PORT"
            connector:
              type: tunnel
              metadata:
                tunnel.id: "$TUNNEL_ID"
            dialer:
              type: $TUNNEL_DIALER_TYPE
$(printf '%s\n' "$TLS_DIALER_BLOCK")
admissions:
  - name: tunnel-peers
    whitelist: true
    matchers:
      - "$CLIENT_IP"
      - "127.0.0.1"
      - "::1"

log:
  level: info
  format: text
EOF

chmod 600 "$CONFIG_FILE"
printf '%s\n' "$TUNNEL_ID" > "$CONFIG_DIR/tunnel.id"
chmod 600 "$CONFIG_DIR/tunnel.id"

echo "GOST 服务端配置已生成: $CONFIG_FILE"
echo "允许建立隧道的客户端 IP: $CLIENT_IP"
echo "TCP 和 UDP 转发端口: $FORWARD_PORT"
echo "隧道控制端口 (TCP): $TUNNEL_PORT"
echo "隧道 ID (复制到客户端): $TUNNEL_ID"
if (( ENCRYPTED )); then
  echo "TLS 证书: $CERT_FILE"
  echo "将 server.crt 安全复制到客户端；客户端加密模式需要它来验证服务端。"
fi
echo "启动 GOST... 按 Ctrl+C 停止。"
exec gost -C "$CONFIG_FILE"
