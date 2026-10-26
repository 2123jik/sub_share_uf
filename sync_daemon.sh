#!/bin/bash
set -e

# 配置 Git 基础信息
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# 采用你验证 100% 成功的连接数组
SVN_OPTS=(
  "--username" "test"
  "--password" ""
  "--no-auth-cache"
  "--non-interactive"
  "--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other"
)

TRUNK_URL="https://svn.acgdev.com:505/svn/sub_share/trunk"
REV_FILE=".last_sync_rev"

# ==========================================
# 阶段 1：补齐“完全体”（根目录文件 + 其他分类）
# ==========================================
echo ">>> [1/3] 检查并补全完全体结构..."

# 1. 导出 trunk 根目录下的所有非文件夹文件（README、说明等）
svn export --force "${SVN_OPTS[@]}" --depth files "$TRUNK_URL" ./

# 2. 检查并补全 subs_list 下非 animation 的其他分类（如 movie 等）
SUB_CATS=$(svn list "${SVN_OPTS[@]}" "$TRUNK_URL/subs_list")
for CAT in $SUB_CATS; do
  CAT="${CAT%/}"
  if [ "$CAT" != "animation" ] && [ ! -d "subs_list/$CAT" ]; then
    echo ">>> 正在补全缺失的分类: subs_list/$CAT"
    mkdir -p "subs_list/$CAT"
    svn export --force "${SVN_OPTS[@]}" "$TRUNK_URL/subs_list/$CAT" "subs_list/$CAT"
  fi
done

# ==========================================
# 阶段 2：获取版本号并比对增量差异
# ==========================================
echo ">>> [2/3] 连接原站查询最新版本号..."
HEAD_REV=$(svn info "${SVN_OPTS[@]}" --show-item revision "$TRUNK_URL")
if [[ -z "$HEAD_REV" || ! "$HEAD_REV" =~ ^[0-9]+$ ]]; then
  echo "[-] 获取 SVN HEAD 版本号失败，网络或原站异常"
  exit 1
fi
echo "[+] 原站当前最新版本: r$HEAD_REV"

# 如果是第一次运行完全体脚本，记录当前 HEAD 作为起点
if [ ! -f "$REV_FILE" ]; then
  echo "$HEAD_REV" > "$REV_FILE"
  git add -A
  if ! git diff --staged --quiet; then
    git commit -m "chore: finalize repository full structure at r$HEAD_REV"
    git push origin HEAD
  fi
  echo ">>> [SUCCESS] 完全体结构补齐成功！基准版本已对齐至 r$HEAD_REV"
  exit 0
fi

LAST_REV=$(tr -d '[:space:]' < "$REV_FILE")
if [ "$LAST_REV" -ge "$HEAD_REV" ]; then
  echo ">>> [SUCCESS] 本地已是最新版本 (r$LAST_REV)，原站无任何更新！"
  exit 0
fi

START_REV=$((LAST_REV + 1))
echo ">>> [3/3] 检测到原站更新：r$START_REV -> r$HEAD_REV，执行精准增量同步..."

# ==========================================
# 阶段 3：按清单精准增删（只下改动的文件）
# ==========================================
# 使用 svn log 解析原生中文路径（不经过 URL 编码，避免乱码和空格问题）
svn log "${SVN_OPTS[@]}" -r "$START_REV:$HEAD_REV" -v -q "$TRUNK_URL" | grep -E '^   [AMD] /trunk/' | while read -r ACTION PATH_WITH_TRUNK; do
  REL_PATH="${PATH_WITH_TRUNK#/trunk/}"

  case "$ACTION" in
    D)
      echo "[-] 原站已删除: $REL_PATH"
      rm -rf "$REL_PATH"
      ;;
    A|M)
      echo "[+] 原站新增/修改: $REL_PATH"
      mkdir -p "$(dirname "$REL_PATH")"
      svn export --force "${SVN_OPTS[@]}" "$TRUNK_URL/$REL_PATH" "$REL_PATH" || true
      ;;
  esac
done

# 更新版本号并推送到 GitHub
echo "$HEAD_REV" > "$REV_FILE"
git add -A
if ! git diff --staged --quiet; then
  git commit -m "sync: upstream r$LAST_REV -> r$HEAD_REV"
  git push origin HEAD
  echo ">>> [SUCCESS] 增量更新已推送至 GitHub，当前对齐版本: r$HEAD_REV"
else
  echo ">>> 原站变更无有效文件变动，版本号已推进至 r$HEAD_REV"
  git commit -m "chore: bump sync rev to r$HEAD_REV"
  git push origin HEAD
fi
