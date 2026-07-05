# singbox-click

一个面向 Linux 服务器的 `sing-box` 交互式管理脚本，用来安装内核、添加入站协议、保存链式代理节点，并配置简单流量规则。

项目地址: <https://github.com/mikuuu3981/singbox-click.git>

## 功能

- 安装、更新、删除 `sing-box` 内核
- 安装 AnyTLS 入站
- 安装 Shadowsocks / SS2022 入站，并选择加密方式
- 保存 SS / SS2022 链式代理节点到节点库
- 启用、停用、删除链式代理出口
- 设置链式代理域名解析策略
- 配置禁止回国流量、广告拦截、自定义规则文件和默认出口
- 查看、启动、停止、重启 `sing-box` systemd 服务
- 安装本脚本的快捷命令
- 从 GitHub 检测并更新脚本

## 环境要求

- Linux 服务器
- root 权限
- systemd
- Debian / Ubuntu 推荐，内核安装功能使用 SagerNet 官方 apt 源
- 基础依赖: `curl`、`jq`、`openssl`

## 使用

```bash
git clone https://github.com/mikuuu3981/singbox-click.git
cd singbox-click
chmod +x singbox-manager.sh
sudo ./singbox-manager.sh
```

首次使用建议先进入「内核管理」安装 `sing-box` 内核。未安装内核时，主菜单不会显示「协议管理」。

也可以在脚本内安装快捷命令，默认命令名是:

```bash
singbox-click
```

## 配置路径

`singbox-click` 自己管理的文件放在:

```text
/etc/singbox-click/
```

主要文件:

```text
/etc/singbox-click/config.json              sing-box 运行配置
/etc/singbox-click/nodes.json               链式代理节点库
/etc/singbox-click/chain-domain-strategy    链式代理域名解析策略
/etc/singbox-click/certs/                   脚本生成的证书
```

安装内核后，脚本会创建兼容链接:

```text
/etc/sing-box/config.json -> /etc/singbox-click/config.json
```

这样官方 `sing-box` 服务仍然可以按默认路径读取配置，同时项目自己的数据不直接混在 `/etc/sing-box` 里。

## 协议说明

### AnyTLS

AnyTLS 需要 `sing-box >= 1.12.0`。

证书支持两种方式:

- 自动生成自签证书，客户端需要允许不安全证书
- 使用已有证书和私钥路径，例如 certbot 生成的 `fullchain.pem` / `privkey.pem`

脚本不会自动申请或续期 Let's Encrypt 证书。

### Shadowsocks / SS2022

服务端入站支持:

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`
- `aes-128-gcm`
- `aes-192-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`
- `xchacha20-ietf-poly1305`

SS2022 仍然使用标准 `ss://` 分享链接，通过 `2022-*` 加密方式区分，不使用 `ss2022://`。

## 链式代理

链式代理节点库只保存节点，不会自动写入运行配置。

流程是:

```text
导入节点 -> 写入 /etc/singbox-click/nodes.json
启用节点 -> 写入 config.json 的出口
设置流量规则 -> 按规则选择出口；没有命中规则时走默认出口
```

当前链式代理只支持 SS / SS2022 节点。

链式代理节点服务器地址为域名时，脚本会按当前解析策略写入 `domain_resolver`，并自动创建本地 DNS 解析器 `singbox-click-local`。旧配置里的 `domain_strategy` 会在脚本启动时自动迁移，避免触发 `sing-box >= 1.12.0` 的弃用检查。

涉及 `config.json` 的变更会先写入临时配置并执行校验；校验通过后才替换正式配置，避免出现“校验失败但已写入半成品配置”的状态。

## 安全

脚本会尽量收紧配置权限:

- 节点库和内部策略文件为 root-only
- 配置文件和私钥只允许 root，或 `sing-box` 服务组读取
- 自签私钥保存在 `/etc/singbox-click/certs/`

不要把 `/etc/singbox-click` 下的配置、节点库或证书提交到 Git。

## 注意

- 本项目面向服务器环境，不适合在本地桌面系统运行
- 删除内核时可以选择是否同时删除 `/etc/singbox-click`
- 规则文件远程 URL 检测会访问网络
- 自定义规则和链式代理变更后，如果服务正在运行，脚本会尝试重启服务生效
