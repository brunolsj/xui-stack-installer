# 3x-ui + VLESS + Hysteria2 一键安装器

这是一个面向全新 VPS 的交互式 Bash 安装器，部署以下组件：

- 3x-ui，以及由面板监管的 Xray-core；
- VLESS + TCP + TLS + XTLS Vision，使用随机 TCP 端口；
- Hysteria2，使用随机 UDP 端口；
- acme.sh 与自动续期；
- HTTP-01 或 Cloudflare DNS-01；
- 共用 TLS 证书和续期后的服务重启回调；
- `stackctl` 本地管理命令。

## 支持范围

- Ubuntu 20.04 及更高版本；
- Debian 11 及更高版本；
- CentOS Stream 9 及更高版本；
- amd64、arm64；
- systemd。

CentOS 7/8、32 位系统、OpenRC 和容器内安装不在支持范围内。

## 使用方法

先把脚本上传到服务器，检查内容后执行：

```bash
chmod 700 install.sh
sudo ./install.sh
```

安装器必须在交互式终端运行。检测到旧的 x-ui、独立 Xray 或 Hysteria 时，会列出目标、创建 root-only 备份，并要求输入 `DELETE` 才会删除。

脚本启动后提供管理菜单：选项 1 用于全新安装或清除旧配置后重装，选项 2 只读显示上次保存的安装摘要和证书资料，选项 0 退出。清除重装仍需要输入 `DELETE` 二次确认；`~/.acme.sh` 账户目录不会被删除。

安装完成时会明文显示证书 SHA-256 指纹、完整 PEM 证书链、证书链路径和私钥路径。私钥仅显示路径，绝不输出私钥内容。

## Cloudflare API Token

推荐创建只允许目标 Zone 的 Token：

```text
Zone > DNS > Edit
Zone Resources > Include > Specific zone
```

脚本会要求输入 Token 和 `Zone ID`；也支持 `Account ID`。Cloudflare Global API Key 仅作为兼容方式保留，因为它的账户权限过大。

DNS 凭据由 acme.sh 写入自己的 root-only `account.conf`，脚本不会再额外复制一份。
Cloudflare API Token 和 Global API Key 在交互输入时会正常显示，便于确认粘贴内容；请避免在录屏、共享终端或他人可见的控制台中执行。

## 安装后的命令

```bash
stackctl status
stackctl summary
stackctl panel
stackctl links
stackctl cert
stackctl renew
stackctl logs 200
stackctl restart
```

`sudo stackctl cert` 会输出证书 SHA-256 指纹、完整 PEM 证书链以及证书链/私钥的绝对路径，便于复制到 v2rayN。3x-ui 自带的 SSL 菜单主要用于申请和设置证书路径，不提供同样的完整导出视图。

`sudo stackctl summary` 会重新显示上次安装保存的面板地址、初始用户名/密码、VLESS/Hysteria2 端口以及完整证书资料。若已在面板中修改密码，保存的初始密码不会自动更新。

对于已经使用旧版安装器部署的服务器，可以把项目中的独立脚本上传到服务器后运行，无需重新安装：

```bash
chmod 700 view-certificate.sh
sudo ./view-certificate.sh
```

该脚本默认从 `/etc/xui-stack/state.env` 自动读取实际证书路径，也可以手动传入证书链和私钥路径：

```bash
sudo ./view-certificate.sh /path/to/fullchain.pem /path/to/privkey.pem
```

3x-ui 自身的菜单仍可通过以下命令进入：

```bash
x-ui
```

## 文件布局

```text
/etc/xui-stack/state.env                 安装状态，不包含用户密码和 CF Token
/etc/xui-stack/client-links.txt          初始客户端链接，0600
/etc/xui-stack/certs/<domain>/           正式证书和私钥
/etc/x-ui/install-result.env             3x-ui 登录信息/API Token，0600
/usr/local/libexec/xui-stack-cert-reload 证书续期回调
/usr/local/sbin/stackctl                 管理命令
/var/backups/xui-stack/                  清理旧安装前的备份
```

## 重要说明

- 脚本不会额外安装独立的 `xray.service` 或 `hysteria-server.service`。Hysteria2 是 Xray 入站，由 3x-ui 统一管理。
- 脚本不会清空 iptables/nftables，也不会删除整个 `~/.acme.sh`。
- 自动防火墙配置只支持活动状态下的 UFW 或 firewalld；云厂商安全组仍需单独检查。
- `XUI_INSTALL_SHA256` 和 `ACME_BOOTSTRAP_SHA256` 可用于给远程引导脚本指定预期哈希。
- `XUI_VERSION` 可指定 3x-ui 发行版本；默认由官方安装器选择当前稳定版。
- 安装器会校验 Hysteria2 的 `auth` 字段是否正确回写，但不能代替不同公网网络下的真实客户端连通测试。
- 已存在且尚未到续期时间的 acme.sh 证书会被直接复用并部署，不会使用 `--force` 重复签发。

请只在遵守服务器所在地法律、服务商条款和网络使用政策的前提下使用。
