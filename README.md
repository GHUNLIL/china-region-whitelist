# 中国大陆 IP 白名单一键脚本

这个项目用于在普通中国大陆服务器上按国家/省级 IP 段限制整机访问：只有交互选择的中国大陆 `CN`、省/自治区/直辖市、当前 SSH 客户端 IP、以及可选的 ASN 白名单可以访问服务器，其他来源访问任意端口都会被拒绝。默认同时托管本机 `INPUT` 和转发 `FORWARD` 流量，因此本机服务、转发端口、TUN/TAP/WireGuard 接口，或 flvx 这类 nftables 转发规则都会走同一套整机白名单。

仓库会通过 GitHub Actions 每小时同步一次上游 CIDR 数据，并把国家级 `CN` CIDR、省份索引和省级 CIDR 文件一起打进仓库。服务器运行 `apply` 或 `dry-run` 时默认直接使用随包数据，不需要安装 Python。

默认入口面向中国大陆服务器：一行 `bash <(curl ...)` 通过 GitHub 代理下载完整项目，拿到的就是仓库最近一次同步好的 IP 数据。

## 项目结构

- `bootstrap.sh`：默认的一键拉取入口，会下载完整项目并执行 `install.sh`
- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省份索引
- `data/regions.tsv`：服务器 Bash 运行时读取的省份索引
- `data/country/CN.txt`：国家级中国大陆 CIDR 段，用于“全国/CN”
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

脚本默认进入键盘配置主界面：上/下键移动，空格勾选或取消，回车确认。主界面会显示当前草案，并提供这些操作：

- 编辑全局白名单：勾选 `全国（中国大陆 CN）`，或按省/自治区/直辖市逐个勾选
- 编辑全局 ASN 白名单：适合加入国外管理服务器所在云厂商 ASN，例如 `AS16509 AS14061`
- 新增端口白名单：输入单端口或端口范围，再勾选这个端口允许的省份，也可以补充 ASN/IP/CIDR
- 修改端口白名单：选择已有端口策略后重新编辑
- 删除端口白名单：选择已有端口策略后删除
- 手动编辑全部端口白名单：直接输入完整规则文本
- 清理已应用规则和开机配置：删除本脚本创建的防火墙规则、保存配置和 systemd 开机恢复

端口白名单优先级高于整机默认全局白名单：如果某个端口命中了端口策略，来源必须匹配该端口自己的白名单，否则即使来源在全局白名单里也会被拒绝。`全国` / `中国` / `CN` 会使用国家级 `data/country/CN.txt`，不会再展开成所有省份 CIDR；只有单端口选择具体省份时才读取省级 CIDR 文件。

端口策略也支持高级手动输入完整格式：

```text
22=上海市,AS16509,1.2.3.4/32;10000-20000=广东省,江苏省
```

白名单项可写：

- `全国` / `中国` / `CN`
- 省份或直辖市，例如 `上海市`、`广东省`
- ASN，例如 `AS16509`
- IPv4 或 IPv4 CIDR，例如 `1.2.3.4`、`1.2.3.0/24`

如果当前环境没有可用 TTY，脚本会自动退回文本输入模式。也可以设置 `CN_VISUAL_MENU=0` 关闭键盘菜单。

默认整机托管本机服务和所有 `FORWARD` 转发流量。如果你的转发都由 [Sagit-chu/flvx](https://github.com/Sagit-chu/flvx) 的 nftables 模式管理，flvx 转发端口会自动受同一白名单保护。本脚本在 nft 后端下只创建 `table inet china_region_whitelist`，不会删除或重写 flvx 使用的 `table inet flvx`。

nftables 本身没有“国家等于 CN”的内置匹配，国家/省份/ASN 白名单最终都需要转换成 IPv4 CIDR set。nft 后端会用单次 `nft -f` 批量加载整张表，并在写入前去掉已被大网段覆盖的小网段，避免逐条 `nft add element` 造成的慢速导入和 interval overlap。

高级用法：如果只想限制本机服务、不托管 `FORWARD`，可以设置 `CN_FORWARD_MODE_DEFAULT=none`；如果只想托管指定接口，可以设置 `CN_FORWARD_MODE_DEFAULT=selected CN_FORWARD_IFACES_DEFAULT="tun0 wg0"`。

`apply` 成功后会保存选择到 `/etc/china-region-whitelist.conf`，并安装 `china-region-whitelist.service`。服务器重启后，systemd 会自动按保存的省份、ASN 和端口策略恢复规则；恢复时默认使用随包数据和本地 ASN 缓存，不依赖网络或 Python。

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

如果已经无法正常联网拉取脚本，请从云厂商控制台或仍未断开的 SSH 窗口直接执行：

```bash
systemctl disable --now china-region-whitelist.service 2>/dev/null || true
rm -f /etc/systemd/system/china-region-whitelist.service /etc/china-region-whitelist.conf
systemctl daemon-reload 2>/dev/null || true
nft delete table inet china_region_whitelist 2>/dev/null || true
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
