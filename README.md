# mysql-backup-automation · MySQL 备份与恢复自动化

> 一套完整的数据库备份方案：**自动备份 → 完整性校验 → 安全恢复**。
> 核心观点：**没验证过的备份等于没有备份**。

## 为什么做这个

数据库备份这件事，很多人的做法是「配个 crontab 跑 mysqldump 就完事了」。
但真正的坑从来不在备份这一步，而在**恢复的时候你才发现备份是坏的**。

行业里那句老话：*You don't have a backup until you've tested a restore.*
这个项目就是围绕这句话设计的——备份、校验、恢复三件事做成闭环。

## 三个脚本

| 脚本 | 职责 |
| --- | --- |
| `src/backup.sh` | 全量/分库导出、压缩、生成 MD5、清理过期备份、记录日志 |
| `src/verify_backup.py` | 恢复前的静态校验：6 项检查判断备份能不能用 |
| `src/restore.sh` | 三重防护的恢复流程，默认只演练，加 `--force` 才真执行 |

## 快速开始

```bash
# 备份（演练模式，看看会做什么）
DRY_RUN=1 ./src/backup.sh

# 真备份
export MYSQL_USER=backup_user MYSQL_PASS='xxx'
./src/backup.sh

# 校验备份能不能用
python3 src/verify_backup.py backups/2026-10-08/

# 恢复（先演练）
./src/restore.sh backups/2026-10-08/swddb_020000.sql.gz --target swddb
# 确认没问题再真执行
./src/restore.sh backups/2026-10-08/swddb_020000.sql.gz --target swddb --force
```

## 实测：校验脚本抓出坏备份

仓库 `backups/` 里放了两个样本（一个是完整备份，一个被截断），跑校验：

```
❌ broken_020000.sql.gz  (0.0 MB, 库 swddb, 2 表 / 1 条 INSERT)
  ✓ 文件非空            ✓ MD5 一致         ✓ gzip 完整可解压
  ✓ 包含建表语句 — 2 张表   ✓ 包含数据 — 1 条 INSERT
  ✗ 转储完整结束 — 未找到结束标记，可能已被截断   ← 抓住了

✅ swddb_020000.sql.gz  (0.0 MB, 库 swddb, 2 表 / 2 条 INSERT)
  ✓ 全部 6 项通过
```

注意这个坏备份**MD5 是对的、gzip 能解压、也有建表语句**——
只校验 MD5 和解压是发现不了的，必须检查「转储是否完整结束」。这正是这个项目的价值。

## 六项校验

| 检查 | 抓的是什么问题 |
| --- | --- |
| 文件存在且非空 | 备份任务失败产生了空文件 |
| MD5 一致 | 传输/存储过程中文件损坏 |
| gzip 可完整解压 | 压缩包 CRC 错误、写到一半断了 |
| 包含 CREATE TABLE | 库选错、权限不足导致只导出结构或什么都没导出 |
| 包含 INSERT | 只导了结构没导数据（`--no-data` 误用） |
| 以 `-- Dump completed` 收尾 | **备份被截断**（磁盘满、超时、进程被 kill） |

## 设计取舍

**① 为什么用 `--single-transaction`？**
InnoDB 下它会开启一个事务拿到一致性快照，**不需要锁表**，备份期间业务照常读写。
对比 `--lock-all-tables`：那个会锁全库，备份期间整个业务不可用。
代价：`--single-transaction` 只对 InnoDB 有效，MyISAM 表还是要锁。

**② 为什么密码不直接写在命令行？**
```bash
mysqldump -uroot -p123456 db    # 危险：ps aux 能看到明文密码
```
本脚本改用临时 `defaults-extra-file`（权限 600），并用 `trap` 保证脚本退出时删除：
```bash
MY_CNF=$(mktemp); chmod 600 "$MY_CNF"
trap cleanup EXIT
```

**③ 为什么要带 `--routines --triggers --events`？**
默认 `mysqldump` **不导出存储过程、触发器、事件**。
只导表结构和数据的话，恢复完业务跑不起来——因为存储过程没了。这是个很常见的坑。

**④ 恢复脚本为什么默认只演练？**
恢复会覆盖数据，是高风险操作。所以：
- 默认不加 `--force` 就只打印将要执行的命令
- 真执行前**先自动把目标库备份一遍**（留退路）
- 目标库非空时要求手动输入 `yes`

## 目录结构

```
mysql-backup-automation/
├── src/
│   ├── backup.sh            # 备份
│   ├── verify_backup.py     # 校验（零依赖，可单独用）
│   └── restore.sh           # 恢复（三重防护）
├── backups/                 # 备份样本（含一个故意损坏的，用于演示校验）
├── docs/讲解文档.md
└── README.md
```

## 后续可做

- [ ] 异地备份：备份完成后 `rsync`/`rclone` 同步到对象存储（本地磁盘一起挂就完了）
- [ ] 恢复演练自动化：定期自动恢复到临时库并比对表数量，形成「可恢复性报告」
- [ ] 增量备份：基于 binlog 做时间点恢复（PITR）
