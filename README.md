# 中国大陆省/市白名单一键脚本

这个项目用于在普通中国大陆服务器上按中国地区 IP 段限制入站访问：只有交互选择的省份或城市可以访问服务器，其他来源访问任意端口都会被拒绝。脚本同时托管 `INPUT` 和 `FORWARD` 链，因此机器上的转发端口也会受到同一白名单限制。

仓库会通过 GitHub Actions 每小时同步一次上游 CIDR 数据。服务器运行 `apply` 或 `dry-run` 时，默认还会在本机再同步一次上游数据到 `/var/lib/china-region-whitelist`，确保配置时使用的是当时可获取到的最新数据。

## 项目结构

- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省市索引
- `data/regions/*.txt`：本地 CIDR 段
- `tools/region_tool.py`：本地数据解析和命令生成工具
- `tools/firewall_lib.sh`：防火墙辅助函数
- `tests/`：不触碰真实防火墙的本地测试

## 使用

在服务器上拉取后进入目录：

```bash
git clone https://github.com/GHUNLIL/china-region-whitelist.git
cd china-region-whitelist
```

建议先预览将要执行的规则：

```bash
sudo bash install.sh dry-run
```

确认无误后正式运行：

```bash
sudo bash install.sh apply
```

脚本会直接列出所有省份，例如 `1.北京市`、`19.广东省`。选择省份后会继续列出该省全部城市，例如 `1.广州市`、`3.深圳市`。你可以输入编号，也可以直接输入名称；多个选择用空格、英文逗号、中文逗号或顿号分隔。

`apply` 成功后会保存选择到 `/etc/china-region-whitelist.conf`，并安装 `china-region-whitelist.service`。服务器重启后，systemd 会自动按保存的地区配置恢复 ipset/iptables 规则；恢复时会尝试更新数据，更新失败则使用已有运行时数据或仓库内置数据。

只同步最新数据、不改防火墙：

```bash
sudo bash install.sh update-data
```

离线使用仓库内置数据：

```bash
sudo bash install.sh apply --offline
```

查看状态：

```bash
sudo bash install.sh status
```

清除规则：

```bash
sudo bash install.sh clear
```

## 本地验证

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh tools/firewall_lib.sh
```

## 安全提示

`apply` 会拒绝所有未命中白名单的入站流量，包括 SSH。脚本会检测当前 SSH 客户端 IP，并询问是否加入本次白名单，建议保留默认 `Y`。

地区 CIDR 数据来自 `metowolf/iplist`。默认模式会访问上游数据源；如果服务器无法访问上游，可以先 `git pull` 获取仓库定时同步的数据，再用 `--offline` 配置。若服务器缺少 `iptables` 或 `ipset`，脚本会尝试使用系统默认软件源安装依赖；这一步可能访问发行版软件源。

如果你的服务器访问默认上游较慢，可以用环境变量指定镜像：

```bash
sudo CN_DATA_BASE_URL=https://your-mirror.example/iplist/data/cncity bash install.sh apply
```

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --refresh-index --force --ipdb /path/to/ipipfree.ipdb
```

然后把整个目录复制到服务器即可。
