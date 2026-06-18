# po0 省/市白名单一键脚本

这个项目用于在 po0 服务器上按中国地区 IP 段限制入站访问：只有交互选择的省份或城市可以访问服务器，其他来源访问任意端口都会被拒绝。脚本同时托管 `INPUT` 和 `FORWARD` 链，因此机器上的转发端口也会受到同一白名单限制。

## 项目结构

- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省市索引
- `data/regions/*.txt`：本地 CIDR 段
- `tools/region_tool.py`：本地数据解析和命令生成工具
- `tools/firewall_lib.sh`：防火墙辅助函数
- `vendor/ipipfree.ipdb`：本地 ipdb 参考文件
- `tests/`：不触碰真实防火墙的本地测试

## 使用

建议先预览将要执行的规则：

```bash
sudo bash install.sh dry-run
```

确认无误后正式运行：

```bash
sudo bash install.sh apply
```

脚本会直接列出所有省份，例如 `1.北京市`、`19.广东省`。选择省份后会继续列出该省全部城市，例如 `1.广州市`、`3.深圳市`。你可以输入编号，也可以直接输入名称；多个选择用空格、英文逗号、中文逗号或顿号分隔。

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

地区 CIDR 数据随仓库离线打包，运行时不会下载地区数据。若服务器缺少 `iptables` 或 `ipset`，脚本会尝试使用系统默认软件源安装依赖；这一步可能访问发行版软件源。

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --ipdb /path/to/ipipfree.ipdb
```

然后把整个目录复制到服务器即可。
