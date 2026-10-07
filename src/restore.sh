#!/usr/bin/env bash
# ==============================================================================
# 备份恢复脚本（含安全确认）
#
# 恢复是危险操作：会覆盖现有数据。所以脚本做了三重防护：
#   1. 恢复前先自动跑一次备份（留退路）
#   2. 必须显式传入 --force 才真正执行，否则只做演练
#   3. 目标库不为空时二次确认
#
# 用法：
#   ./restore.sh backups/2026-10-08/swddb_020000.sql.gz --target swddb_restore
#   ./restore.sh <备份文件> --target <库名> --force      # 真正执行
# ==============================================================================
set -uo pipefail

MYSQL_USER=${MYSQL_USER:-"root"}
MYSQL_PASS=${MYSQL_PASS:-""}
MYSQL_HOST=${MYSQL_HOST:-"127.0.0.1"}
MYSQL_PORT=${MYSQL_PORT:-"3306"}
BACKUP_FILE=""
TARGET_DB=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_DB="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    *)        BACKUP_FILE="$1"; shift ;;
  esac
done

if [[ -z "$BACKUP_FILE" || -z "$TARGET_DB" ]]; then
  echo "用法: $0 <备份文件.sql.gz> --target <目标库名> [--force]"
  exit 1
fi
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "[ERROR] 备份文件不存在: $BACKUP_FILE"
  exit 1
fi

MY_CNF=""
if [[ -n "$MYSQL_PASS" ]]; then
  MY_CNF=$(mktemp); chmod 600 "$MY_CNF"
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
    "$MYSQL_USER" "$MYSQL_PASS" "$MYSQL_HOST" "$MYSQL_PORT" >"$MY_CNF"
  MYSQL_OPTS="--defaults-extra-file=$MY_CNF"
else
  MYSQL_OPTS="-u$MYSQL_USER -h$MYSQL_HOST -P$MYSQL_PORT"
fi
cleanup() { [[ -n "$MY_CNF" && -f "$MY_CNF" ]] && rm -f "$MY_CNF"; }
trap cleanup EXIT

echo "===== 恢复演练 / 执行 ====="
echo "备份文件 : $BACKUP_FILE"
echo "目标库   : $TARGET_DB"
echo "确认执行 : $([[ $FORCE -eq 1 ]] && echo 是 || echo 否（仅演练）)"

# --- 第一重防护：先校验备份能不能用 ---
echo
echo "[1/4] 校验备份完整性..."
if command -v python3 >/dev/null 2>&1; then
  python3 "$(dirname "$0")/verify_backup.py" "$BACKUP_FILE" || {
    echo "[ERROR] 备份校验未通过，拒绝恢复（避免用坏备份覆盖好数据）"
    exit 1
  }
else
  echo "[WARN] 未找到 python3，跳过静态校验；将依赖 gzip -t"
  gzip -t "$BACKUP_FILE" || { echo "[ERROR] 备份文件损坏"; exit 1; }
fi

# --- 第二重防护：恢复前先把当前状态备份一遍 ---
if [[ "$FORCE" -eq 1 ]]; then
  echo
  echo "[2/4] 恢复前先备份目标库（留退路）..."
  ROLLBACK_DIR="./rollback_$(date +%s)"
  mkdir -p "$ROLLBACK_DIR"
  mysqldump $MYSQL_OPTS --single-transaction --routines --triggers \
    "$TARGET_DB" 2>/dev/null | gzip -9 >"$ROLLBACK_DIR/before_restore.sql.gz" || \
    echo "[WARN] 目标库可能不存在或无法访问，跳过回滚备份"
else
  echo
  echo "[2/4] 演练模式：跳过回滚备份"
fi

# --- 第三重防护：目标库非空要二次确认 ---
TABLE_COUNT=$(mysql $MYSQL_OPTS -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${TARGET_DB}';" 2>/dev/null)
TABLE_COUNT=${TABLE_COUNT:-0}
echo
echo "[3/4] 目标库现有表数量: ${TABLE_COUNT}"
if [[ "$TABLE_COUNT" -gt 0 && "$FORCE" -eq 1 ]]; then
  read -r -p "目标库非空，恢复将覆盖现有数据。输入 yes 继续: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "已取消"; exit 0; }
fi

# --- 执行恢复 ---
echo
if [[ "$FORCE" -eq 1 ]]; then
  echo "[4/4] 正在恢复..."
  mysql $MYSQL_OPTS -e "CREATE DATABASE IF NOT EXISTS \`${TARGET_DB}\` DEFAULT CHARSET utf8mb4;"
  if gzip -dc "$BACKUP_FILE" | mysql $MYSQL_OPTS "$TARGET_DB"; then
    echo "[OK] 恢复完成 -> ${TARGET_DB}"
    mysql $MYSQL_OPTS -N -e \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${TARGET_DB}';" \
      | xargs -I{} echo "      目标库现有表数量: {}"
  else
    echo "[ERROR] 恢复失败！可用回滚备份: ${ROLLBACK_DIR}"
    exit 1
  fi
else
  echo "[4/4] 演练模式：未真正执行。确认无误后加 --force 执行"
  echo "      将执行: gzip -dc $BACKUP_FILE | mysql -u$MYSQL_USER $TARGET_DB"
fi
