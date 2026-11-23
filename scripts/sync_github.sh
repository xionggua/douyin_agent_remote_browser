#!/usr/bin/env bash
# 手动触发的 GitHub 同步：把 gitea main（或指定 tag）导出为 GitHub 上的一个版本 commit。
#
# 保护规则（按维护者要求）：
#  1. 只导出 main / 指定 tag 的最终内容，不带 gitea 内部提交历史；
#  2. GitHub main 若出现非本脚本产生的提交（网友 PR 被合并等），
#     中止同步并提示先把 GitHub 侧内容拉回 gitea，绝不覆盖；
#  3. 普通 push（非 force），不触碰 GitHub 的 PR 引用与其它分支。
#
# 用法（由 sync-github.yml 调用）— 远程浏览器仓：bash scripts/sync_github.sh [tag]
# 环境变量：GH_PAT（gitea Secret GH_MIRROR_PAT）
set -euo pipefail

GH_URL="https://xionggua:${GH_PAT:?缺少 GH_PAT（请配置仓库 Secret GH_MIRROR_PAT）}@github.com/xionggua/douyin_agent_remote_browser.git"
TAG="${1:-}"
SRC_DIR="${GITHUB_WORKSPACE:-$(pwd)}"

cd "$SRC_DIR"
# --force --tags：tag 被重指时确保拿到最新值（普通 fetch 不覆盖已存在的本地 tag ref）
git fetch --force --tags origin >/dev/null 2>&1 || true
if [ -n "$TAG" ]; then
    git rev-parse -q --verify "refs/tags/${TAG}^{commit}" >/dev/null || { echo "::error::gitea 上不存在 tag ${TAG}"; exit 1; }
    SRC_SHA=$(git rev-parse "refs/tags/${TAG}^{commit}")
else
    SRC_SHA=$(git rev-parse refs/remotes/origin/main)
fi
echo "同步源：${TAG:-main} @ ${SRC_SHA}"

# ── GitHub Release（含 zip 附件），幂等：已存在则跳过 ─────────────────
create_github_release() {
    local tag="$1" src_sha="$2"
    local ver="${tag#v}"
    local api="https://api.github.com/repos/xionggua/douyin_agent_remote_browser"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GH_PAT}" "${api}/releases/tags/${tag}")
    if [ "$code" = "200" ]; then
        echo "GitHub Release ${tag} 已存在，跳过创建"
        return 0
    fi
    echo "创建 GitHub Release ${tag}（HTTP ${code}）..."

    # 从源树的 CHANGELOG 提取本版本说明
    local body=""
    if [ -f "${SRC_DIR}/docs/CHANGELOG.md" ]; then
        body=$(awk -v ver="## ${ver}" '
            $0 ~ "^" ver { found=1; next }
            found && /^## / { exit }
            found { print }
        ' "${SRC_DIR}/docs/CHANGELOG.md" | sed -e '/^$/d' -e 's/^### */### /')
    fi
    [ -n "$body" ] || body="${tag} 发布。详见仓库 docs/CHANGELOG.md。"

    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1]+" 正式版","body":sys.argv[2],"draft":False,"prerelease":False}))' "$tag" "$body")
    local rel_id
    rel_id=$(curl -s -X POST -H "Authorization: Bearer ${GH_PAT}" -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" -d "$payload" "${api}/releases" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
    if [ -z "$rel_id" ]; then
        echo "::warning::GitHub Release 创建失败（可稍后在网页手动创建）"
        return 0
    fi
    echo "Release id: ${rel_id}"

    # 打 zip（与同步导出同口径：排除 .gitea）
    local zip="/tmp/douyin_agent_remote_browser_${tag}.zip"
    git -C "$SRC_DIR" archive --format=zip -o "$zip" "$src_sha" -- . ':(exclude).gitea' ':(exclude).gitea/**'
    curl -s -X POST -H "Authorization: Bearer ${GH_PAT}" -H "Content-Type: application/zip" \
        --data-binary "@$zip" \
        "https://uploads.github.com/repos/xionggua/douyin_agent_remote_browser/releases/${rel_id}/assets?name=douyin_agent_remote_browser_${tag}.zip" \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print("附件:",d.get("name",d.get("message","?")),d.get("size",""))'
    echo "GitHub Release ${tag} 完成"
}

WORK=$(mktemp -d)
if git clone -q --single-branch --branch main "$GH_URL" "$WORK/gh" 2>/dev/null; then
    cd "$WORK/gh"
    GH_HEAD=$(git rev-parse HEAD)
    LAST_SRC=$(git log -1 --pretty=%B | sed -n 's/.*source: \([0-9a-f]\{7,40\}\).*/\1/p' | head -1)
    echo "GitHub main HEAD=${GH_HEAD}（上次同步源：${LAST_SRC:-未知}）"
    if [ -z "$LAST_SRC" ]; then
        echo "::error::GitHub main 的最新提交不是本同步脚本产生的（可能合并了网友 PR）。请先把 GitHub main 的新内容拉回 gitea main（git pull），再重新触发同步。" >&2
        exit 1
    fi
    if ! git -C "$SRC_DIR" merge-base --is-ancestor "$LAST_SRC" "$SRC_SHA" 2>/dev/null; then
        echo "::error::GitHub main 记录的源提交 ${LAST_SRC} 不在当前 gitea 历史内（历史变更或存在外部提交）。请人工核对后再同步。" >&2
        exit 1
    fi
    echo "保护检查通过：GitHub main 可安全前移"
else
    echo "GitHub 仓库为空或首次同步，初始化镜像目录"
    mkdir -p "$WORK/gh"
    cd "$WORK/gh"
    git init -q -b main
fi

# 清空镜像工作树（保留 .git），用 gitea 源树精确覆盖
# 排除 .gitea/：内部 CI/CD 定义与部署结构不对外公开；运行记录不在 git 对象内、天然不会导出
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git -C "$SRC_DIR" archive "$SRC_SHA" -- . ':(exclude).gitea' ':(exclude).gitea/**' | tar -x -C "$WORK/gh"
git add -A

if git rev-parse -q --verify HEAD >/dev/null && git diff --cached --quiet; then
    echo "内容与 GitHub main 完全一致，无需提交"
else
    MSG="Release ${TAG:-main snapshot} (source: ${SRC_SHA})"
    git -c user.name="xionggua" -c user.email="145264198+xionggua@users.noreply.github.com" commit -qm "$MSG"
    git push -q "$GH_URL" main
    echo "已推送版本提交：${MSG}"
fi

if [ -n "$TAG" ]; then
    if git ls-remote --tags "$GH_URL" "refs/tags/${TAG}" | grep -q .; then
        echo "GitHub 已存在 tag ${TAG}，跳过 tag 推送（如需重发请先在 GitHub 删除该 tag）"
    else
        git tag -f "$TAG" HEAD >/dev/null
        git push -q "$GH_URL" "refs/tags/${TAG}"
        echo "已同步 tag ${TAG}"
    fi
    create_github_release "$TAG" "$SRC_SHA"
fi
echo "同步完成"
