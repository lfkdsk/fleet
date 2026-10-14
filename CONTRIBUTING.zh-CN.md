[English](CONTRIBUTING.md) | 中文

# 参与贡献

Fleet 是一个可以直接运行的小仓库，不是安装后使用的 Python 包。改动要保住「clone 下来就能跑」：`bin/fleet` 必须继续相对仓库目录找到 `schema.sql`、`channels.json`、适配器和模板。

## 开发环境

需要 Python 3.10 或更高版本、Bash、Git 和 SQLite。Fleet 核心只用 Python 标准库；只有测试 YAML 格式的 check 规格时才需要 PyYAML。完整测试矩阵还要求 `PATH` 上有 `python3.14`。

```bash
git clone https://github.com/lfkdsk/fleet.git
cd fleet
export PATH="$PWD/bin:$PATH"
export FLEET_HOME=/var/tmp/fleet/dev-home
fleet init
```

别拿你在用的台账跑开发测试。测试套件会自己建隔离的 home 和假的模型 CLI，不会消耗供应商额度。

## 测试

先跑和改动相关的那组测试，再跑两组公开验收：

```bash
bash tests/smoke.sh
bash tests/contrib_smoke.sh
```

提交代码改动前，跑完整矩阵，并确认每条变异仍然能套用：

```bash
bash tests/run-all.sh
bash tests/mutate.sh --check-only
```

`tests/run-all.sh --jobs N` 控制套件并行度。它把每个 `*smoke*.sh` 用默认 `python3` 跑一遍、再用 Python 3.14 跑一遍。`tests/mutate.sh --check-only` 是快速的清单完整性检查：证明每条变异仍会改动它的目标。完整的变异运行 `bash tests/mutate.sh --jobs N` 慢得多，它检查点名的用例确实会变红。

测试不能调用真实的模型供应商。把一个替身可执行文件放在 `PATH` 最前面，或用 `FLEET_ADAPTER_DRYRUN=1` 驱动适配器。每个套件用自己的 `FLEET_HOME` 和 `/var/tmp/fleet` 下的临时仓库；并行的套件不能共用任务临时目录或 worktree。

## 项目无关守卫

Fleet 的调度器、适配器、模板、测试和公开文档里，不能写死某个产品、组织、checkout 路径、私有端点或某个人的机器。好几组 smoke 测试会扫描具体的项目名：一个写死的例子很容易悄悄变成调度规则或 prompt 里的前提。

扫描的名字来自 `FLEET_FORBIDDEN_NAMES`（扩展正则），默认是个占位名。如果你把 Fleet 用在自己的项目上，跑测试时把它设成那些项目的名字，例如 `FLEET_FORBIDDEN_NAMES='MyCompany|my-service' bash tests/run-all.sh`。

夹具要自给自足：

- 仓库、渠道、凭证和模型名都在测试里自己造；
- 用临时绝对路径，不用开发者的 home 目录；
- 渠道需要什么能力就在夹具里写明，不要指望出厂渠道表无限变大；
- 示例任务的文字要足够通用，拿到一个无关的仓库也能跑。

如果某个功能需要项目策略，把它表达成 goal 上下文、任务规格、checks 或运行时的渠道配置，而不是源码里的特例。

## 改动纪律

一个提交只管一种行为或一处文档。标题用简短的祈使句；原因不明显时，在正文里写清要守住的不变量或用户能看到的理由；PR 描述里写上你跑过哪些测试。

改 schema 需要：`fleet init` 里幂等的迁移路径、从旧库形状出发的测试、检查所有只读消费者。改适配器需要：DRYRUN 断言、退出码覆盖、大 prompt 的传递、并发任务之间的隔离。改 CLI 先改 `--help`，并保持中英文文档同步。

不要提交生成出来的台账、运行目录、worktree、供应商凭证或本机的 service 文件。不要为了让夹具通过而削弱 claim、attempt、复审模型族或 check 完整性的守卫；改夹具，让它写明自己需要的能力。

架构和适配器约定见 [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md) 和 [docs/adapters.zh-CN.md](docs/adapters.zh-CN.md)。
