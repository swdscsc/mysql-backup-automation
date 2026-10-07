#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
备份文件完整性校验工具（零依赖）

备份最大的谎言是「备份成功了」——真正的问题是：**备份能不能恢复**。
这个脚本在恢复之前先做静态校验，把「坏备份」提前暴露出来。

检查项：
  1. 文件存在且非空
  2. gzip 能否正常解压（不落盘，流式校验 CRC）
  3. MD5 与 .md5 文件是否一致
  4. 是否包含 CREATE TABLE / INSERT（空备份或半截备份会被抓出来）
  5. 是否以完整语句收尾（判断有没有被截断）
  6. 统计库名、表数量、预估数据量

用法：
    python verify_backup.py backups/2026-10-08/order_db_020000.sql.gz
    python verify_backup.py backups/2026-10-08/          # 校验整个目录
"""
from __future__ import annotations

import gzip
import hashlib
import os
import re
import sys
from typing import Dict, List

CREATE_RE = re.compile(rb"CREATE TABLE\s+`?([\w$]+)`?")
INSERT_RE = re.compile(rb"INSERT INTO\s+`?([\w$]+)`?")
USE_RE = re.compile(rb"^USE\s+`?([\w$]+)`?\s*;", re.M)
DUMPED_RE = re.compile(rb"-- Dump completed")


def md5_of_file(path: str, chunk: int = 1 << 20) -> str:
    """分块算 MD5，大文件也不会吃满内存。"""
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def verify(path: str) -> Dict:
    """校验单个备份文件，返回结构化结果。"""
    res: Dict = {
        "file": os.path.basename(path),
        "size_mb": 0.0,
        "ok": True,
        "checks": [],
        "tables": 0,
        "inserts": 0,
        "db": "-",
    }

    def check(name: str, passed: bool, detail: str = "") -> None:
        res["checks"].append((name, passed, detail))
        if not passed:
            res["ok"] = False

    if not os.path.isfile(path):
        check("文件存在", False, "文件不存在")
        return res

    size = os.path.getsize(path)
    res["size_mb"] = round(size / 1024 / 1024, 2)
    check("文件非空", size > 0, f"{res['size_mb']} MB")

    # --- MD5 校验（若存在同名 .md5 文件）---
    md5_path = path + ".md5"
    actual = md5_of_file(path)
    if os.path.isfile(md5_path):
        with open(md5_path, "r", encoding="utf-8", errors="ignore") as f:
            expected = f.read().split()[0]
        check("MD5 一致", actual == expected, f"实际 {actual[:12]}... 期望 {expected[:12]}...")
    else:
        check("MD5 文件存在", False, "未找到 .md5 校验文件（建议备份时生成）")

    # --- 流式解压校验：不落盘，顺带抽取元信息 ---
    content = bytearray()
    try:
        with gzip.open(path, "rb") as f:
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                content.extend(b)
        check("gzip 完整可解压", True)
    except Exception as e:  # gzip.BadGzipFile / CRC 错误都会落到这
        check("gzip 完整可解压", False, f"解压失败: {e}")
        return res

    tables = CREATE_RE.findall(content)
    inserts = INSERT_RE.findall(content)
    res["tables"] = len(tables)
    res["inserts"] = len(inserts)

    dbs = USE_RE.findall(content)
    if dbs:
        res["db"] = dbs[0].decode("utf-8", "ignore")

    check("包含建表语句", len(tables) > 0, f"{len(tables)} 张表")
    check("包含数据", len(inserts) > 0, f"{len(inserts)} 条 INSERT 语句")
    check("转储完整结束", bool(DUMPED_RE.search(content)),
          "找到 -- Dump completed" if DUMPED_RE.search(content) else "未找到结束标记，可能已被截断")

    return res


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    target = sys.argv[1]
    if os.path.isdir(target):
        files: List[str] = []
        for root, _, names in os.walk(target):
            for n in names:
                if n.endswith(".sql.gz"):
                    files.append(os.path.join(root, n))
        files.sort()
    else:
        files = [target]

    if not files:
        raise SystemExit(f"未找到 .sql.gz 备份文件: {target}")

    all_ok = True
    for fp in files:
        r = verify(fp)
        icon = "✅" if r["ok"] else "❌"
        print(f"\n{icon} {r['file']}  ({r['size_mb']} MB, 库 {r['db']}, "
              f"{r['tables']} 表 / {r['inserts']} 条 INSERT)")
        for name, passed, detail in r["checks"]:
            mark = "  ✓" if passed else "  ✗"
            print(f"{mark} {name}" + (f"  — {detail}" if detail else ""))
        if not r["ok"]:
            all_ok = False

    print("\n" + ("全部备份校验通过" if all_ok else "存在不合格备份，请重新备份！"))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
