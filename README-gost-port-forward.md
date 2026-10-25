# GOST TCP/UDP 端口转发

脚本使用 GOST v3 的反向隧道：客户端主动连接服务端；服务端公开一个 TCP 端口和同号 UDP 端口；客户端把请求转到本机目标服务的同一端口。GOST 的 tunnel 支持在同一隧道承载 TCP 和 UDP。

## 参数对应

- 服务端：客户端公网 IP、服务端公开转发端口、模式、隧道控制端口（默认 8443）、隧道 ID（可自动生成）。
- 客户端：服务端 IP、客户端本机接收/目标端口、模式、隧道 ID、隧道控制端口、服务端证书、本地目标地址。
- `客户端接收端口` 默认对应客户端本机 `127.0.0.1:端口` 上已经运行的 TCP/UDP 服务。可用最后一个参数改本地目标 IP。

## 模式配对

- 加密：客户端和服务端都选 TLS 模式。推荐参数名为服务端 `decrypt`、客户端 `encrypt`；也可用 `encrypt`/`decrypt`/`tls`/`加密`/`解密` 表示 TLS。TLS 是双向加密，会在两端自动完成加密和解密。
- 不加密：两边都填 `plain`（或 `none`、`不加密`）。
- 一端选 TLS、另一端选 `plain` 会连接失败。

## 示例：启用加密

把两个脚本分别复制到服务器和客户端，安装好 GOST v3。服务端加密模式还需要 `openssl`。

服务端运行：

```bash
chmod +x gost-server.sh
sudo ./gost-server.sh 203.0.113.20 25565 decrypt 8443
```

启动信息会打印隧道 ID。把该 ID 记下来，并把服务端生成的 `server.crt` 安全复制到客户端。默认文件位置是 `/etc/gost-forward/server.crt`，可通过 `GOST_FORWARD_DIR` 环境变量更改。

客户端运行（接收服务的本地端口为 25565）：

```bash
chmod +x gost-client.sh
sudo ./gost-client.sh 198.51.100.10 25565 encrypt <服务端打印的隧道ID> 8443 /etc/gost-forward/server.crt
```

上例客户端会把服务端 `25565/TCP` 和 `25565/UDP` 转发到客户端本机 `127.0.0.1:25565`。如果本机服务在其他地址，例如 `10.0.0.8`，在证书参数后再加 `10.0.0.8`。

## 明文示例

服务端和客户端都使用 `plain`：

```bash
sudo ./gost-server.sh <客户端公网IP> <服务端转发端口> plain
sudo ./gost-client.sh <服务端IP> <客户端本机服务端口> plain <隧道ID>
```

## 网络与运行

- 服务端防火墙/云安全组开放转发端口的 TCP 和 UDP。
- 隧道控制端口（默认 TCP 8443）只需允许客户端公网 IP 连接；GOST 配置也会限制隧道连接来源为脚本中的客户端 IP及本机回环地址。
- 脚本以前台方式运行，按 `Ctrl+C` 停止。生产环境可将命令配置为 systemd 服务。
- 加密模式下，客户端必须安全获得服务端的 `server.crt`；不要通过不可信渠道传输。`server.key` 只留在服务端。
- 两端需要使用兼容的 GOST v3 版本。脚本不自动安装或升级 GOST。
