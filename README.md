# 中国大陆 IP 白名单一键脚本

这个项目用于在普通中国大陆服务器上按国家/省级 IP 段限制入站访问：只有交互选择的中国大陆 `CN`、省/自治区/直辖市、三大运营商公众接入网（近似普通家宽）、当前 SSH 客户端 IP，以及可选的 ASN/IP 白名单可以访问服务器，其他来源访问入站端口会被拒绝。脚本支持全局单 IP 允许/屏蔽、端口白名单和最高优先级的“单端口+单 IP/ASN”允许/屏蔽。所有端口规则同时覆盖 TCP、UDP 和 DNAT 原始目标端口。

脚本不管理 `OUTPUT` 出站流量，服务器向外连接不受限制；默认只托管本机 `INPUT` 和 DNAT/端口转发类入站 `FORWARD` 流量，因此本机服务和 flvx 这类 nftables 端口转发会走同一套整机白名单。

仓库会通过 GitHub Actions 每小时同步一次上游 CIDR 数据，并把 APNIC 国家级 `CN` IPv4、省份索引和省级 CIDR 文件一起打进仓库。服务器运行 `apply` 或 `dry-run` 时默认直接使用随包数据，不需要安装 Python。

默认入口面向中国大陆服务器：一行 `bash <(curl ...)` 通过 GitHub 代理下载完整项目，拿到的就是仓库最近一次同步好的 IP 数据。

## 项目结构

- `bootstrap.sh`：默认的一键拉取入口，会下载完整项目并执行 `install.sh`
- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省份索引
- `data/regions.tsv`：服务器 Bash 运行时读取的省份索引
- `data/country/CN.txt`：APNIC 国家级中国大陆 IPv4 段，用于“全国/CN”
- `data/regions/*.txt`：本地省级 CIDR 段
- `data/asn/*.txt`：可选的预制 ASN IPv4 段，例如 `AS16509`
- `data/carriers/home-broadband-asns.tsv`：保守筛选的电信、联通、移动公众接入网 ASN 清单
- `data/carriers/home-broadband.txt`：由上述 ASN 生成的离线 IPv4 前缀包
- `tools/region_tool.py`：开发/测试用的本地数据解析工具
- `tools/firewall_lib.sh`：防火墙辅助函数
- `tools/prepare_home_broadband_data.sh`：刷新三大运营商公众接入网前缀包
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

正式应用后，脚本会先临时加载规则并等待 60 秒确认。请用新窗口测试 SSH/业务端口，确认可访问后输入 `YES`、`yes` 或 `y`，脚本才会保存配置并启用开机恢复；如果超时或未确认，会自动清理本次规则。可用 `CN_POST_APPLY_TIMEOUT=120` 调整等待时间，或用 `CN_POST_APPLY_CONFIRM=0` 关闭这个保护。

`bootstrap.sh` 会把项目安装或更新到 `/opt/china-region-whitelist`，然后用 root 权限执行真正的 `install.sh`。如果当前不是 root，会自动调用 `sudo`。

如需手动方式，也可以克隆仓库后运行：

```bash
git clone https://github.com/GHUNLIL/china-region-whitelist.git
cd china-region-whitelist
sudo bash install.sh apply
```

脚本默认进入键盘配置主界面：上/下键移动，空格勾选或取消，回车确认。如果已经保存过配置，主界面会先载入 `/etc/china-region-whitelist.conf` 作为当前草案，并提供这些操作：

- 编辑全局白名单：勾选 `全国（中国大陆 CN）`、`三大运营商公众接入网（近似普通家宽）`，或按省/自治区/直辖市逐个勾选
- 编辑全局 ASN 白名单：适合加入国外管理服务器所在云厂商 ASN，例如 `AS16509 AS14061`
- 编辑全局单 IP 允许/屏蔽：例如 `allow:1.2.3.4,deny:5.6.7.8`
- 新增端口白名单：输入单端口或端口范围，再勾选这个端口允许的省份，也可以补充 ASN/IP/CIDR
- 修改端口白名单：选择已有端口策略后重新编辑
- 删除端口白名单：选择已有端口策略后删除
- 手动编辑全部端口白名单：直接输入完整规则文本
- 编辑端口 IP/ASN 例外：例如 `22=allow:1.2.3.4,deny:AS4809`，这是最高优先级
- 同步最新预制 IP 数据：从 GitHub 拉取仓库已预制好的 `data/` 到 `/var/lib/china-region-whitelist/data`，包含全国、省份和预制 ASN，不需要 Python
- 清理已应用规则和开机配置：删除本脚本创建的防火墙规则、保存配置和 systemd 开机恢复

规则优先级从高到低如下：

1. 单端口+单 IP 允许/屏蔽；同一单 IP 不允许同时配置相反动作。
2. 单端口+ASN 允许/屏蔽；若同一来源同时命中端口 IP 与端口 ASN，以更具体的单 IP 为准。
3. 端口白名单；命中端口策略后必须匹配该端口自己的白名单，否则拒绝。
4. 全局单 IP 允许/屏蔽。
5. 全局地区、家宽和 ASN 白名单。
6. 未命中则拒绝。

同一优先级若不同 ASN 前缀重叠，屏蔽先于允许。已经建立的连接仍由 `ESTABLISHED,RELATED` 保护；新连接按上述优先级判断。

`全国` / `中国` / `CN` 会使用国家级 `data/country/CN.txt`，不会再展开成所有省份 CIDR；只有选择具体省份时才读取省级 CIDR 文件。

## 三大运营商普通家宽模式

在全局白名单或端口白名单中选择 `三大运营商公众接入网（近似普通家宽）`，手动格式可写 `HOME`、`家庭宽带` 或 `普通家宽`。该模式使用 `data/carriers/home-broadband-asns.tsv` 中保守筛选的电信、联通、移动公众接入网 ASN，并明确不包含独立的 IDC、云、IoT、5G-only、工业互联网和国际精品网 ASN；例如不包含电信 CN2 `AS4809`、联通 CUII `AS9929` 和移动国际 `AS58453`。

重要限制：ASN 只能判断 IP 前缀由哪个自治系统宣告，无法证明某个具体 IP 一定是住宅用户。同一个公众接入 ASN 仍可能混有政企或机房地址。若必须做到商业数据库级别的“住宅代理/机房 IP”识别，需要另接带 usage-type 的实时 IP 情报源；本项目当前提供的是可审计、可离线运行的 ASN 级近似。

端口策略也支持高级手动输入完整格式：

```text
22=上海市,AS16509,1.2.3.4/32;10000-20000=广东省,江苏省
```

白名单项可写：

- `全国` / `中国` / `CN`
- `HOME` / `家庭宽带` / `普通家宽`
- 省份或直辖市，例如 `上海市`、`广东省`
- ASN，例如 `AS16509`
- IPv4 或 IPv4 CIDR，例如 `1.2.3.4`、`1.2.3.0/24`

全局单 IP 规则只接受单个 IPv4，不接受 CIDR：

```text
allow:1.2.3.4,deny:5.6.7.8
```

也可简写为 `+1.2.3.4,-5.6.7.8`。

端口 IP/ASN 例外只接受单端口，以及单个 IPv4 或 ASN：

```text
22=allow:1.2.3.4,deny:AS4809;443=allow:AS4134,deny:5.6.7.8
```

每个端口只写一次，并把该端口的所有例外合并在同一条中。这些规则同时生成 TCP、UDP 规则；对 DNAT/端口转发会匹配连接的原始目标端口。

如果当前环境没有可用 TTY，脚本会自动退回文本输入模式。也可以设置 `CN_VISUAL_MENU=0` 关闭键盘菜单。

默认整机托管本机服务和 DNAT/端口转发类入站 `FORWARD` 流量，不托管 `OUTPUT`，也不会拦截普通出站转发。如果你的转发都由 [Sagit-chu/flvx](https://github.com/Sagit-chu/flvx) 的 nftables 模式管理，flvx 转发端口会自动受同一白名单保护。本脚本在 nft 后端下只创建 `table inet china_region_whitelist`，不会删除或重写 flvx 使用的 `table inet flvx`。

nftables 本身没有“国家等于 CN”的内置匹配，国家/省份/ASN 白名单最终都需要转换成 IPv4 CIDR set。nft 后端会用单次 `nft -f` 批量加载整张表，并在写入前去掉已被大网段覆盖的小网段，避免逐条 `nft add element` 造成的慢速导入和 interval overlap。

高级用法：如果只想限制本机服务、不托管 DNAT 入站转发，可以设置 `CN_FORWARD_MODE_DEFAULT=none`；如果只想托管指定接口上的 DNAT 入站转发，可以设置 `CN_FORWARD_MODE_DEFAULT=selected CN_FORWARD_IFACES_DEFAULT="tun0 wg0"`。

`apply` 成功后会保存选择到 `/etc/china-region-whitelist.conf`，并安装 `china-region-whitelist.service`。服务器重启后，systemd 会自动按保存的省份、ASN 和端口策略恢复规则；恢复时默认使用随包数据和本地 ASN 缓存，不依赖网络或 Python。

防火墙后端默认 `CN_FIREWALL_BACKEND=auto`：检测到 `nft` 时优先使用 nftables，否则回落到 iptables/ipset。也可以显式指定：

```bash
CN_FIREWALL_BACKEND=nft bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
CN_FIREWALL_BACKEND=iptables bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

默认随包数据已经由仓库定时同步。若需要在服务器上更新到 GitHub 仓库里的最新预制数据，可以运行下面命令；这一步只需要 `curl` 和 `tar`，不需要 Python：

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

国家级 `CN` IPv4 数据来自 APNIC delegated stats，省级 CIDR 数据来自 `metowolf/iplist`，家宽 ASN 登记和用户规模参考 APNIC/APNIC Labs，ASN 前缀来自 `ipverse/as-ip-blocks`。这些数据由 GitHub Actions 生成后预制进仓库，服务器默认不需要 Python。已预制的 ASN 会优先从 `data/asn/` 读取；未预制的 ASN 才会从 `ipverse/as-ip-blocks` 拉取，默认同样会走 `https://gh-proxy.com/`。若服务器缺少 `nftables`、`iptables` 或 `ipset`，脚本会尝试使用系统默认软件源安装依赖；这一步可能访问发行版软件源。

默认 GitHub 访问会经过 `https://gh-proxy.com/`。如果需要换代理或直连：

```bash
CN_GITHUB_PROXY=https://your-proxy.example/ bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
CN_GITHUB_PROXY=direct bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

ASN 前缀源也可以覆盖：

```bash
sudo CN_ASN_BASE_URL=https://your-mirror.example/as-ip-blocks/as bash /opt/china-region-whitelist/install.sh update-asn
```

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --refresh-index --force --ipdb /path/to/ipipfree.ipdb
bash tools/prepare_home_broadband_data.sh
```

然后把整个目录复制到服务器即可。
