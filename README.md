# 中国大陆省/市白名单一键脚本

这个项目用于在普通中国大陆服务器上按中国地区 IP 段限制入站访问：只有交互选择的省份或城市可以访问服务器，其他来源访问任意端口都会被拒绝。脚本会托管 `INPUT` 链，也可以在交互菜单里选择如何托管 `FORWARD` 转发链，因此机器上的转发端口或 TUN/TAP/WireGuard 接口也能使用同一白名单限制。

仓库会通过 GitHub Actions 每小时同步一次上游 CIDR 数据。服务器运行 `apply` 或 `dry-run` 时，默认还会在本机再同步一次上游数据到 `/var/lib/china-region-whitelist`，确保配置时使用的是当时可获取到的最新数据。

默认入口面向中国大陆服务器：一行 `bash <(curl ...)` 通过 GitHub 代理下载完整项目，运行时同步上游 IP 数据也默认走同一个代理。

## 项目结构

- `bootstrap.sh`：默认的一键拉取入口，会下载完整项目并执行 `install.sh`
- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省市索引
- `data/regions/*.txt`：本地 CIDR 段
- `tools/region_tool.py`：本地数据解析和命令生成工具
- `tools/firewall_lib.sh`：防火墙辅助函数
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

脚本会直接列出所有省份，例如 `1.北京市`、`19.广东省`。选择省份后会继续列出该省全部城市，例如 `1.广州市`、`3.深圳市`。你可以输入编号，也可以直接输入名称；多个选择用空格、英文逗号、中文逗号或顿号分隔。

地区选择后，脚本会显示 TUN/转发接口菜单：

- `0`：不托管 `FORWARD`，只限制服务器本机入站端口
- `1`：托管所有 `FORWARD` 转发流量，兼容旧版本默认行为
- 检测到的 `tun`、`tap`、`wg`、`tailscale` 等接口会以编号列出，可选择一个或多个
- 如果接口没有被自动识别，也可以直接输入接口名，例如 `tun0 wg0`

选择指定接口时，脚本会同时匹配该接口的入方向和出方向转发流量。

`apply` 成功后会保存选择到 `/etc/china-region-whitelist.conf`，并安装 `china-region-whitelist.service`。服务器重启后，systemd 会自动按保存的地区配置恢复 ipset/iptables 规则；恢复时会尝试更新数据，更新失败则使用已有运行时数据或仓库内置数据。

只同步最新数据、不改防火墙：

```bash
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) update-data
```

离线使用仓库内置数据：

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

## 本地验证

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh tools/firewall_lib.sh
```

## 安全提示

`apply` 会拒绝所有未命中白名单的入站流量，包括 SSH。脚本会检测当前 SSH 客户端 IP，并询问是否加入本次白名单，建议保留默认 `Y`。

地区 CIDR 数据来自 `metowolf/iplist`。默认模式会访问上游数据源；如果服务器无法访问上游，可以先 `git pull` 获取仓库定时同步的数据，再用 `--offline` 配置。若服务器缺少 `iptables` 或 `ipset`，脚本会尝试使用系统默认软件源安装依赖；这一步可能访问发行版软件源。

默认 GitHub 访问会经过 `https://gh-proxy.com/`。如果需要换代理或直连：

```bash
CN_GITHUB_PROXY=https://your-proxy.example/ bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
CN_GITHUB_PROXY=direct bash <(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/china-region-whitelist/main/bootstrap.sh) apply
```

也可以只覆盖上游 IP 数据源：

```bash
sudo CN_DATA_BASE_URL=https://your-mirror.example/iplist/data/cncity bash /opt/china-region-whitelist/install.sh apply
```

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --refresh-index --force --ipdb /path/to/ipipfree.ipdb
```

然后把整个目录复制到服务器即可。
