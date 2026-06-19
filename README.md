# 中国大陆省份白名单一键脚本

这个项目用于在普通中国大陆服务器上按省级 IP 段限制入站访问：只有交互选择的省/自治区/直辖市、当前 SSH 客户端 IP、以及可选的 ASN 白名单可以访问服务器，其他来源访问任意端口都会被拒绝。脚本会托管 `INPUT` 链，也可以在交互菜单里选择如何托管 `FORWARD` 转发链，因此机器上的转发端口、TUN/TAP/WireGuard 接口，或 flvx 这类 nftables 转发规则也能使用同一白名单限制。

仓库会通过 GitHub Actions 每小时同步一次上游 CIDR 数据，并把省份索引和 CIDR 文件一起打进仓库。服务器运行 `apply` 或 `dry-run` 时默认直接使用随包数据，不需要安装 Python。

默认入口面向中国大陆服务器：一行 `bash <(curl ...)` 通过 GitHub 代理下载完整项目，拿到的就是仓库最近一次同步好的 IP 数据。

## 项目结构

- `bootstrap.sh`：默认的一键拉取入口，会下载完整项目并执行 `install.sh`
- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省份索引
- `data/regions.tsv`：服务器 Bash 运行时读取的省份索引
- `data/regions/*.txt`：本地省级 CIDR 段
- `tools/region_tool.py`：开发/测试用的本地数据解析工具
- `tools/firewall_lib.sh`：防火墙辅助函数
- `tests/fixtures/asn/`：测试用 ASN 前缀夹具
- `tests/`：不触碰真实防火墙的本地测试

## 使用

推荐在大陆服务器上直接运行：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh)
```

建议先预览将要执行的规则：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) dry-run
```

确认无误后正式运行：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

`bootstrap.sh` 会把项目安装或更新到 `/opt/china-region-whitelist`，然后用 root 权限执行真正的 `install.sh`。如果当前不是 root，会自动调用 `sudo`。

如需手动方式，也可以克隆仓库后运行：

```bash
git clone https://github.com/GHUNLIL/china-region-whitelist.git
cd china-region-whitelist
sudo bash install.sh apply
```

脚本会直接列出所有省/自治区/直辖市，例如 `1.北京市`、`9.上海市`、`19.广东省`。你可以输入编号，也可以直接输入名称；多个选择用空格、英文逗号、中文逗号或顿号分隔。

省份选择后，脚本会询问是否追加 ASN 白名单。这个功能适合把国外管理服务器所在云厂商 ASN 加进去，避免省份白名单生效后海外管理机无法登录。可以输入 `AS16509 AS14061` 这种格式，也可以留空。

然后脚本会显示 TUN/转发接口菜单：

- `0`：不托管 `FORWARD`，只限制服务器本机入站端口
- `1`：托管所有 `FORWARD` 转发流量，兼容旧版本默认行为
- 检测到的 `tun`、`tap`、`wg`、`tailscale` 等接口会以编号列出，可选择一个或多个
- 如果接口没有被自动识别，也可以直接输入接口名，例如 `tun0 wg0`

如果你的转发都由 [Sagit-chu/flvx](https://github.com/Sagit-chu/flvx) 的 nftables 模式管理，通常选 `1` 即可让 flvx 转发端口也受同一白名单保护；如果只想限制服务器本机 SSH/面板/网站端口，则选 `0`。本脚本在 nft 后端下只创建 `table inet china_region_whitelist`，不会删除或重写 flvx 使用的 `table inet flvx`。

选择指定接口时，脚本会同时匹配该接口的入方向和出方向转发流量。

`apply` 成功后会保存选择到 `/etc/china-region-whitelist.conf`，并安装 `china-region-whitelist.service`。服务器重启后，systemd 会自动按保存的省份和 ASN 配置恢复规则；恢复时默认使用随包数据和本地 ASN 缓存，不依赖网络或 Python。

防火墙后端默认 `CN_FIREWALL_BACKEND=auto`：检测到 `nft` 时优先使用 nftables，否则回落到 iptables/ipset。也可以显式指定：

```bash
CN_FIREWALL_BACKEND=nft bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
CN_FIREWALL_BACKEND=iptables bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

默认随包数据已经由仓库定时同步。若你确实要在服务器上实时同步上游数据，可以运行下面命令；这一步需要服务器有 `python3/python`：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) update-data
```

明确使用仓库内置数据：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply --offline
```

查看状态：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) status
```

清除规则：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) clear
```

重新同步已保存的 ASN 前缀并恢复规则：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) update-asn
```

## 本地验证

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh tools/firewall_lib.sh
```

## 安全提示

`apply` 会拒绝所有未命中白名单的入站流量，包括 SSH。脚本会检测当前 SSH 客户端 IP，并询问是否加入本次白名单，建议保留默认 `Y`。

省级 CIDR 数据来自 `metowolf/iplist`。默认模式不会在服务器上访问上游数据源；如果需要最新数据，重新运行 `bootstrap.sh` 拉取仓库最新包即可。ASN 前缀来自 `ipverse/as-ip-blocks` 的每日聚合 IPv4 数据，首次添加 ASN 或运行 `update-asn` 时需要访问 GitHub raw；默认同样会走 `https://gh-proxy.com/`。若服务器缺少 `nftables`、`iptables` 或 `ipset`，脚本会尝试使用系统默认软件源安装依赖；这一步可能访问发行版软件源。

默认 GitHub 访问会经过 `https://gh-proxy.com/`。如果需要换代理或直连：

```bash
CN_GITHUB_PROXY=https://your-proxy.example/ bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
CN_GITHUB_PROXY=direct bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

实时同步上游时，也可以覆盖上游 IP 数据源：

```bash
sudo CN_DATA_BASE_URL=https://your-mirror.example/iplist/data/cncity bash /opt/china-region-whitelist/install.sh apply --update
```

ASN 前缀源也可以覆盖：

```bash
sudo CN_ASN_BASE_URL=https://your-mirror.example/as-ip-blocks/as bash /opt/china-region-whitelist/install.sh update-asn
```

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --refresh-index --force --ipdb /path/to/ipipfree.ipdb
```

然后把整个目录复制到服务器即可。
