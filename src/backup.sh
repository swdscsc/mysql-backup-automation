#!/usr/bin/env bash
# ==============================================================================
# MySQL 数据库备份脚本（全量 / 分库）
#
# 做四件事：
#   1. 用 mysqldump 导出并 gzip 压缩（--single-transaction 保证 InnoDB 一致性且不锁表）
#   2. 生成 .md5 校验文件（备份能不能用，恢复前必须能验证）
#   3. 按保留天数清理过期备份
#   4. 写日志 + 以退出码反馈成败（可接告警）
#
# 用法：
#   ./backup.sh                       # 备份配置里的所有库
#   ./backup.sh --db order_db         # 只备份一个库
#   DRY_RUN=1 ./backup.sh             # 演练模式，不真正执行
#
# 定时任务（每天凌晨 2 点）：
#   0 2 * * * /opt/scripts/backup.sh >> /var/log/backup_cron.log 2>&1
# ==============================================================================
set -uo pipefail

# ------------------------------ 配置（用环境变量覆盖）-------------------------
MYSQL_USER=${MYSQL_USER:-"backup_user"}
MYSQL_PASS=${MYSQL_PASS:-""}          # 生产环境建议改用 ~/.my.cnf，避免密码出现在命令行
MYSQL_HOST=${MYSQL_HOST:-"127.0.0.1"}
MYSQL_PORT=${MYSQL_PORT:-"3306"}
BACKUP_DIR=${BACKUP_DIR:-"./backups"}
RETENTION_DAYS=${RETENTION_DAYS:-7}   # 备份保留天数
LOG_FILE=${LOG_FILE:-"$BACKUP_DIR/backup.log"}
DRY_RUN=${DRY_RUN:-0}
TARGET_DB=${TARGET_DB:-""}
EXCLUDE_DB=${EXCLUDE_DB:-"information_schema performance_schema mysql sys"}

for arg in "$@"; do
  case "$arg" in
    --db) shift; TARGET_DB="$1" ;;
    --dry-run) DRY_RUN=1 ;;
  esac
done

mkdir -p "$BACKUP_DIR"
DATE=$(date +%F)
TIME=$(date +%H%M%S)
FAILED=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" | tee -a "$LOG_FILE"; }

log "===== 备份开始 ====="

# 密码不直接拼在命令行（会出现在 ps 输出里），改用临时配置文件
MY_CNF=""
if [[ -n "$MYSQL_PASS" ]]; then
  MY_CNF=$(mktemp)
  chmod 600 "$MY_CNF"
  cat >"$MY_CNF" <<EOF
[client]
user=$MYSQL_USER
password=$MYSQL_PASS
host=$MYSQL_HOST
port=$MYSQL_PORT
EOF
  MYSQL_OPTS="--defaults-extra-file=$MY_CNF"
else
  MYSQL_OPTS="-u$MYSQL_USER -h$MYSQL_HOST -P$MYSQL_PORT"
fi
cleanup() { [[ -n "$MY_CNF" && -f "$MY_CNF" ]] && rm -f "$MY_CNF"; }
trap cleanup EXIT

# ------------------------------ 确定要备份哪些库 ------------------------------
if [[ -n "$TARGET_DB" ]]; then
  DATABASES=("$TARGET_DB")
else
  mapfile -t DATABASES < <(mysql $MYSQL_OPTS -N -e "SHOW DATABASES;" 2>/dev/null)
  # 过滤掉系统库
  FILTERED=()
  for db in "${DATABASES[@]}"; do
    skip=0
    for ex in $EXCLUDE_DB; do [[ "$db" == "$ex" ]] && skip=1 && break; done
    [[ "$skip" -eq 0 && -n "$db" ]] && FILTERED+=("$db")
  done
  DATABASES=("${FILTERED[@]}")
fi

if [[ ${#DATABASES[@]} -eq 0 ]]; then
  log "[ERROR] 没有可备份的数据库，请检查连接配置"
  exit 1
fi

# ------------------------------ 逐个导出 --------------------------------------
for DB in "${DATABASES[@]}"; do
  OUTDIR="$BACKUP_DIR/$DATE"
  mkdir -p "$OUTDIR"
  FILE="$OUTDIR/${DB}_${TIME}.sql.gz"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将备份 $DB -> $FILE"
    continue
  fi

  log "备份数据库 $DB ..."

  # --single-transaction：InnoDB 下通过事务拿到一致性快照，不锁表，业务无感知
  # --routines --triggers --events：存储过程、触发器、事件一起带出来，否则还原后不完整
  if mysqldump $MYSQL_OPTS \
      --single-transaction \
      --routines --triggers --events \
      --default-character-set=utf8mb4 \
      "$DB" 2>>"$LOG_FILE" | gzip -9 >"$FILE"; then

    SIZE=$(du -h "$FILE" | awk '{print $1}')
    # 生成校验文件：恢复之前先能验证备份没损坏
    (cd "$OUTDIR" && md5sum "$(basename "$FILE")" >"${FILE##*/}.md5")
    log "[OK] $DB 备份完成 -> $FILE ($SIZE)"
  else
    log "[ERROR] $DB 备份失败！"
    rm -f "$FILE"
    FAILED=$((FAILED + 1))
  fi
done

# ------------------------------ 清理过期备份 ----------------------------------
if [[ "$DRY_RUN" -eq 0 && "$RETENTION_DAYS" -gt 0 ]]; then
  DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" | wc -l)
  find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null
  log "清理 ${RETENTION_DAYS} 天前的备份，共删除 $DELETED 个目录"
fi

if [[ "$FAILED" -gt 0 ]]; then
  log "===== 备份结束：$FAILED 个库失败 ====="
  exit 1
fi
log "===== 备份结束：全部成功 ====="
