# ModelPass

*[English](README.md) · 中文*

每天记录开源 AI 模型元数据变化的采集系统。

这个项目的价值**不在于**"现在有哪些模型"——那个今天下午谁都能爬一遍,而且已经有人用 76 万个模型的规模做过了。价值在于**什么时候变了什么**:某个许可证是哪一天被改写的、哪一天 LICENSE 文件从仓库里消失、哪一天一个模型悄悄变成需要申请、哪一天它不见了。

**这些只能靠时间积累,补不回来。**

**序列起点:2026-09-04。** 从这天起,每过一天就多一天无法被任何人重建的记录。

在线中控:**https://hoigo2025.github.io/modelpass/**

改动任何东西之前先读 [CLAUDE.md](CLAUDE.md) —— 整个设计服从的五条铁律都在那里。

---

## 快速开始

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # 至少填 CONTACT_EMAIL

python -m src.collect --source huggingface --top 20
```

这会写出 `data/raw/huggingface/{date}.jsonl.gz`,把观测插入 `db/modelpass.db`,计算变更,并生成 `data/daily/{date}.md`。

## 常用命令

```bash
python -m src.collect --source huggingface --top 1000     # 采下载量前 1000
python -m src.collect --source huggingface --list config/watchlist.txt

python -m src.collect --replay 2026-09-04                 # 从归档重放,全程不联网
python -m src.collect --replay 2026-09-04 --db /tmp/x.db  # 重建到另一个库

python -m src.diff --date 2026-09-04                      # 重算变更(派生数据,随时可重算)
python -m src.export --date 2026-09-04                    # 当日摘要
python -m src.export --date 2026-09-04 --digest           # 给手机看的短摘要
python -m src.site                                        # 重新生成中控页面

python scripts/verify_merkle.py --all data/raw/huggingface # 独立校验归档
```

`collect` 的退出码:**0** 成功 · **1** 失败 · **2** 部分成功。

## 一次运行做什么

1. 在 `runs` 表插入 `status='running'`
2. 拉取目标清单
3. 逐个请求详情,**每条原始响应立即落盘**
4. 打包成 `{date}.jsonl.gz` + manifest(sha256、Merkle root),`chmod 444` 冻结
5. **解析冻结后的归档**,写入 `entities` 和 `observations`
6. 关闭 `runs` 记录
7. `diff` —— 与该模型的上一次观测比对
8. `export` —— 生成当日摘要和中控页面

第 3 步先落盘,所以之后任何位置崩溃都能用 `--replay` 恢复。第 5 步读的是 `.gz` 而不是临时文件,所以**线上采集和重放走的是同一条代码路径**——这才使"重放结果与原始一致"这句话有意义。

## 数据模型

`db/schema.sql`,四张表:

| 表 | 是什么 | 可变性 |
|---|---|---|
| `entities` | 每个模型一行,只记身份 | 只插入 |
| `observations` | **核心资产**,每次观测一行 | 只插入,永不更新、永不删除 |
| `changes` | 由 `diff.py` 从观测算出 | 随时可删了重算 |
| `runs` | 每次采集尝试一行,成功与否都记 | 铁律 4 的落地 |

同一个模型今天和昨天值完全一样,仍然插入一条新观测。这不是浪费:**它证明了那一天没有变化。**

### 变更严重度

| 级别 | 字段 |
|---|---|
| `high` | `declared_license` 变化 · `has_license_file` 由 1 变 0 · `is_gated` 由 0 变 1 · 模型消失(`presence`) |
| `medium` | `base_model_ref`、`revision` |
| `low` | 其余(`downloads`、`likes`、`tags_json`、`pipeline_tag`、`last_modified` …) |

"相邻观测"指**同一个模型**按 `observed_at` 的上一次观测,不论隔了几天。重跑、断档、事后重放都自然落入这个定义,不需要特例。

这张表是系统里唯一的判断,它住在 `diff.py`,永不混入 `observations`(铁律 5)。

## 成功、失败、消失

- **成功** —— 拿到了回应并已归档
- **失败** —— 重试后仍然没有可用回应(超时、连接错误、5xx),这个模型今天丢了
- **消失** —— 对方明确回答"这个模型不再公开可见"。计入成功,记在 `runs.error_note`,并且**只有在此前观测过它**时才由 `diff.py` 报为 `high` 级 `presence` 变更

  HuggingFace 对已删除、转私有或从不存在的仓库一律返回 **401 而不是 404** —— 它拒绝告诉你是哪一种。带 `HF_TOKEN` 时,真正被删除的仓库才返回 404。

仅仅跌出今日前 N 名的模型**不会**产生 presence 变更。我们没问过它,就没了解到关于它的任何事。**沉默不是消失的证据。**

## 归档

每个数据源每天一个 gzip jsonl(铁律 3),外加一个 manifest,两者都冻结为 `chmod 444`。同一天重跑写入 `{date}.2.jsonl.gz`;文件用 `O_EXCL` 创建,已冻结的归档不可能被覆盖。

诚实地说明 `444` 到底提供了什么:在正常文件系统上它能阻止**修改**,即使是文件属主——但挡不住 `root`,也挡不住删除(删除由目录权限决定)。所以它是防误操作的护栏,不是防蓄意的锁。真正的完整性保证是哈希链:manifest 钉住每条记录的 sha256、归档文件自身的 sha256 和 Merkle root,由 `verify_merkle.py` 用一份独立实现重算。**如果采集进程以 root 运行,`444` 就完全没有意义**(容器里跑的是非 root 用户)。

每行一个 JSON 对象:

```json
{"kind": "model", "source": "huggingface", "external_id": "Qwen/Qwen3-32B",
 "url": "...", "fetched_at": "2026-09-04T03:00:11Z", "http_status": 200,
 "raw_sha256": "…", "raw": "<响应正文,逐字节原样>"}
```

`raw` 是**字符串**而不是重新序列化的对象——重新序列化会悄悄改写键序和数字格式。`raw_sha256` 取自网络上收到的原始字节,所以 `sha256(raw.encode("utf-8"))` 能复现它。榜单响应也存(`kind: "list"`):**当天的排名本身就是时间序列。**

### Merkle 定义

```
leaf   = sha256(原始响应字节).hexdigest()     # 按文件顺序,小写十六进制
parent = sha256((左 hex + 右 hex).encode("utf-8")).hexdigest()
某层节点数为奇数 -> 最后一个与自身配对
零条记录         -> sha256(b"")
```

在 `src/archive.py` 实现一次,在 `scripts/verify_merkle.py` **独立再实现一次**,后者不 import `src/` 里的任何东西。两者哪天不一致,正是这个检查在起作用。**永远不要事后修改这个定义。**

## 备份:三份副本,只有一份是服务器毁不掉的

`data/raw/` 是这个项目里唯一无法从别处重建的东西。它需要不止一份副本,而且这些副本并不等价:

| 副本 | 方式 | 采集主机能毁掉它吗 |
|---|---|---|
| `scripts/pull_backup.sh`(笔记本/NAS) | **拉取** | **不能** —— 主机没有指向它的凭据 |
| Cloudflare R2 **加 bucket lock** | 推送 | **不能** —— 能写,但无权解锁 |
| Cloudflare R2 不加锁 | 推送 | 能 —— 主机持有写密钥 |
| rsync 到另一台服务器(`BACKUP_HOST`) | 推送 | 能 —— 同上 |

最后一列就是全部要点。推送型备份的安全上限**通常**就是那台推送的机器:入侵、勒索软件、误 `rm -rf`、账号被封 —— 这些同时带走推送目标。有两件事能打破它。

第一是方向。从一台"主机连不上"的机器拉取,能在主机遭遇任何事时幸存,因为主机没有任何反向通路。它也是笔记本合盖就停的那一份,所以不能取代无人值守的那份。

第二是在对端加锁 —— 这正是 R2 值得要的原因。

### R2 加 bucket lock

[R2 bucket lock](https://developers.cloudflare.com/r2/buckets/bucket-locks/) 能让对象在指定期限内、或**无限期**不可删除、不可覆盖;并且**只要还存在任何锁规则,整个桶就无法被清空**。移除规则需要账号级权限,而给采集主机的是**只授权单个桶的 Object Read & Write token** —— 它能写,不能解锁。

于是主机能加上明天的归档,却毁不掉昨天的 —— 这恰好是一份只追加的序列对它的备份的要求。

配置要点:

1. **建专用桶**,不要复用现有的。别的 lifecycle 规则或清理脚本永远不该够得到归档。
2. token **只授权这一个桶**。这里的最小权限不是卫生习惯,而是锁能成立的原因。
3. 锁规则:**前缀 `raw/`,期限设为无限期**。

第 3 条的前缀不是可选项。`backup.sh` 往 R2 推的两样东西性质相反:

```
data/raw/    -> r2:<桶>/raw/    归档,永不改变     <- 该锁
snapshot.db  -> r2:<桶>/db/     每天覆盖         <- 必须保持可写
```

**整桶加锁会让第二天的数据库快照覆盖失败。** 锁规则也优先于 lifecycle 规则,所以账号里其他策略无法把归档过期掉。

诚实说代价:无限期锁意味着**你自己也删不掉**,除非先移除规则。对一个第一条铁律就是"只追加,永不覆盖"的项目,这个取舍是对的。

```bash
# 采集主机的 .env
R2_REMOTE=r2:modelpass
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_REGION=auto
RCLONE_CONFIG_R2_ENDPOINT=https://<账号ID>.r2.cloudflarestorage.com
RCLONE_CONFIG_R2_ACCESS_KEY_ID=...
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=...
```

免费额度够用很多年:10 GB 存储、每月百万次写,而你每天 3.2 MB、约十次写,出站流量永远免费。

**配好当天就验证,不要等到需要它的那个早上:**

```bash
scripts/backup.sh    # 结尾应当是 "pushed to r2:<桶>"
scripts/verify.sh    # 从 R2 随机取一天,重算哈希并重放
```

不要把归档放进公开仓库。提交 `.gz` 是每天 3.0 MB 且完全没有 delta 压缩(gzip 对 git 是不透明的),一年 1.1 GB,几个月内就超过 GitHub 的建议上限。不压缩提交能 delta 到每天约 35 KB,但那仍然是**同一个已经持有代码和摘要的供应商**,而且公开仓库会在采集当天就公开原始数据,而不是等到预定的延迟期之后。

`docs/` 只在采集主机上生成并提交。在别的机器上请用 `--out` 输出到别处预览:两台机器生成同一个被提交的文件,每次推送都会冲突,而且其中一份必然是错的(只有持有权威数据库的那台生成的才对)。

## 运维

两条 cron,必须分开:`daily.sh` 死掉时,它本该发出的告警会跟着一起死,所以陈旧检查必须是另一个只读数据库的进程。

```cron
0 3 * * *   /opt/modelpass/scripts/daily.sh
17 * * * *  /opt/modelpass/scripts/check_freshness.sh   # 25 小时无成功即告警
0 5 * * 0   /opt/modelpass/scripts/verify.sh            # 每周恢复演练
```

告警分两级,因为**永远红着的告警等于没有告警**:

- **ALERT** —— 这一天的数据丢了或有风险(采集或导出失败)
- **WARN** —— 数据采到了也归档了,但运行不完整,或备份/发布失败

`check_freshness.sh` 打印 WARN 后继续;只有 ALERT 判红。

告警通道见 `scripts/notify.sh`:Telegram、飞书、钉钉、企业微信、Bark,或任意 SMTP 中继(不需要在主机上装 MTA)。全都没配时它安静降级,**永不让告警失败拖垮一次好的采集**。

## 容器

镜像是一次性的,数据不是。

```bash
cp .env.example .env
echo "MODELPASS_UID=$(id -u)" >> .env && echo "MODELPASS_GID=$(id -g)" >> .env
docker compose up -d --build
```

`docker-compose.yml` 把 `./data`、`./db`、`./logs`、`./docs` 从宿主机挂载进去。**绝不要换成命名卷,绝不要在这里跑 `docker compose down -v`。** 注意宿主机的 `db/` 挂在 **`/app/state`** 而不是 `/app/db`:挂到 `/app/db` 会遮住镜像里的 `schema.sql`,每次运行都会在建表时失败。

容器用一个 bash 循环自我调度而不是 cron 守护进程,只为一件 cron 做不到的事:**启动补跑**。每次启动先跑 `check_freshness.sh`,没有成功记录就立即采集。重启过的主机、或凌晨三点正在休眠的笔记本,会把缺口补上而不是静静跳过。

## 礼貌与限流

请求间隔 0.3 秒、30 秒超时、3 次指数退避重试、遵守 `Retry-After`、消失的模型不重试,以及一个写明项目和联系方式的 User-Agent。单个模型失败不会中断整体。

**机房 IP 会被限流,家用宽带不会。** 采集主机第一次跑 1000 个模型丢了 31 个(HTTP 429);同样的运行从家用线路零丢失。三项应对:429 有独立于普通错误的更大重试预算;第一个 429 就让整轮降速(间隔翻倍,上限 `MAX_PAUSE`,本轮内不回落);**归档冻结前对仍然失败的目标做第二轮补采**。实测 31 → 3 → 0。

真正的解法是 `.env` 里的 `HF_TOKEN`:认证请求的限额高得多,只读 token 就够。

## 目录

```
db/schema.sql              四张表
src/collect.py             运行编排、重放
src/archive.py             冻结 + manifest + merkle
src/diff.py                相邻观测比对、严重度
src/export.py              每日摘要、CSV、手机摘要
src/site.py                中控静态页面
src/db.py                  连接助手(不用 ORM)
src/sources/huggingface.py 列表 / 抓取 / 解析 —— 每个数据源一个模块
scripts/                   cron、备份、恢复演练、独立校验器、告警
data/raw/                  归档(gitignore,需备份)
data/daily/                每日摘要(提交进 git —— 公开记录)
docs/                      中控页面(提交进 git —— GitHub Pages)
```

新增一个数据源 = 在 `src/sources/` 加一个模块,提供 `build_session`、`list_targets`、`read_watchlist`、`fetch_model`、`parse_observation`、`ABSENT_STATUS`、`REQUEST_PAUSE`、`Pacer`、`FetchError`,再在 `src/collect.py` 的 `SOURCES` 里加一行。

## 自检

```bash
grep -rn "DO UPDATE\|DELETE FROM observations" src/    # 必须无输出
python scripts/verify_merkle.py --all data/raw/huggingface
sqlite3 db/modelpass.db "SELECT status, count(*) FROM runs GROUP BY status;"
```
