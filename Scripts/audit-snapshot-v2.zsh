#!/bin/zsh
set -euo pipefail

# LingXiAgent 全系统审计快照脚本
# 在 Git 仓库内运行。生成一个适合提交给 ChatGPT/Agent 联合审计的 ZIP。

INCLUDE_UNTRACKED=1
MAX_FILE_MB=10
OUTPUT_DIR=""

while (( $# > 0 )); do
  case "$1" in
    --no-untracked)
      INCLUDE_UNTRACKED=0; shift ;;
    --max-file-mb)
      [[ $# -ge 2 ]] || { echo "缺少 --max-file-mb 参数" >&2; exit 2; }
      MAX_FILE_MB="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || { echo "缺少 --output 参数" >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
用法：
  ./audit-snapshot.zsh
  ./audit-snapshot.zsh --no-untracked
  ./audit-snapshot.zsh --max-file-mb 20
  ./audit-snapshot.zsh --output ~/Desktop
HELP
      exit 0 ;;
    *)
      echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "错误：未找到 git" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "错误：未找到 zip" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "错误：请在 Git 仓库内部运行" >&2
  exit 1
}
cd "$REPO_ROOT"

REPO_NAME="$(basename "$REPO_ROOT")"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || BRANCH="detached"
SAFE_BRANCH="${BRANCH//\//-}"
SNAPSHOT_NAME="${REPO_NAME}-audit-${SAFE_BRANCH}-${SHORT_SHA}-${TIMESTAMP}"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(dirname "$REPO_ROOT")"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lingxi-audit.XXXXXX")"
STAGE="$TMP_ROOT/$SNAPSHOT_NAME"
META="$STAGE/__audit__"
mkdir -p "$META"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

MAX_BYTES=$(( MAX_FILE_MB * 1024 * 1024 ))

is_sensitive_path() {
  local p="$1"
  local base="${p:t}"
  case "$base" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.mobileprovision|credentials.json|credential.json|secrets.json|secret.json|auth.json|tokens.json|token.json|cookies.json|cookies.sqlite|id_rsa|id_ed25519)
      return 0 ;;
  esac
  case "$p" in
    */.ssh/*|*/.gnupg/*|*/Keychains/*|*/keychain/*|*/Secrets/*|*/secrets/*|*/Credentials/*|*/credentials/*)
      return 0 ;;
  esac
  return 1
}

is_noise_path() {
  local p="$1"
  case "$p" in
    .git/*|.build/*|build/*|DerivedData/*|.swiftpm/*|.cache/*|.idea/*|.vscode/*|node_modules/*|Pods/*|Carthage/Build/*|.DS_Store|*/.DS_Store|*.xcuserstate|*.xcuserdata/*|*.dSYM/*|*.app/*|*.framework/*|*.xcarchive/*|*.zip|*.tar|*.tar.gz|*.tgz|*.7z|*.rar|*.iso|*.dmg|*.sqlite-shm|*.sqlite-wal)
      return 0 ;;
  esac
  return 1
}

is_binary_or_heavy() {
  local p="$1"
  case "$p" in
    *.gguf|*.safetensors|*.bin|*.onnx|*.mlmodelc/*|*.mp4|*.mov|*.mkv|*.avi|*.wav|*.flac|*.mp3|*.png|*.jpg|*.jpeg|*.webp|*.gif|*.heic|*.tiff|*.pdf)
      return 0 ;;
  esac
  return 1
}

: > "$META/skipped-noise.txt"
: > "$META/skipped-sensitive.txt"
: > "$META/skipped-binary-heavy.txt"
: > "$META/skipped-large.txt"

copy_one() {
  local rel="$1"
  local src="$REPO_ROOT/$rel"
  local dst="$STAGE/$rel"
  [[ -f "$src" ]] || return 0

  if is_noise_path "$rel"; then
    print -r -- "$rel" >> "$META/skipped-noise.txt"
    return 0
  fi
  if is_sensitive_path "$rel"; then
    print -r -- "$rel" >> "$META/skipped-sensitive.txt"
    return 0
  fi
  if is_binary_or_heavy "$rel"; then
    print -r -- "$rel" >> "$META/skipped-binary-heavy.txt"
    return 0
  fi

  local bytes
  bytes="$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)"
  if (( bytes > MAX_BYTES )); then
    printf '%s\t%s bytes\n' "$rel" "$bytes" >> "$META/skipped-large.txt"
    return 0
  fi

  mkdir -p "${dst:h}"
  cp -p "$src" "$dst"
}

# 已跟踪文件：复制当前工作区版本，因此会包含未提交修改。
while IFS= read -r -d '' rel; do
  copy_one "$rel"
done < <(git ls-files -z)

# 未跟踪但未被 .gitignore 忽略的文件。
if (( INCLUDE_UNTRACKED )); then
  while IFS= read -r -d '' rel; do
    copy_one "$rel"
  done < <(git ls-files --others --exclude-standard -z)
fi

# 审计元数据
{
  echo "Snapshot: $SNAPSHOT_NAME"
  echo "Repository: $REPO_NAME"
  echo "Repository root: $REPO_ROOT"
  echo "Branch: $BRANCH"
  echo "HEAD: $(git rev-parse HEAD 2>/dev/null || true)"
  echo "Created at: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Include untracked: $INCLUDE_UNTRACKED"
  echo "Max single file: ${MAX_FILE_MB} MB"
} > "$META/snapshot-info.txt"

git status --short --branch > "$META/git-status.txt" 2>&1 || true
git diff --stat > "$META/git-diff-stat.txt" 2>&1 || true
git diff --no-ext-diff --no-color > "$META/git-diff.patch" 2>&1 || true
git diff --cached --stat > "$META/git-staged-diff-stat.txt" 2>&1 || true
{
  if git diff --no-ext-diff --no-color --quiet 2>/dev/null; then
    echo "working-tree-diff: clean"
  else
    echo "working-tree-diff: present"
  fi
  if git diff --cached --no-ext-diff --no-color --quiet 2>/dev/null; then
    echo "staged-diff: clean"
  else
    echo "staged-diff: present"
  fi
} > "$META/git-diff-check.txt"
git diff --cached --no-ext-diff --no-color > "$META/git-staged-diff.patch" 2>&1 || true
git log -20 --decorate --oneline > "$META/git-log-last-20.txt" 2>&1 || true

{
  echo "=== Swift ==="
  swift --version 2>&1 || true
  echo
  echo "=== Xcode ==="
  xcodebuild -version 2>&1 || true
  echo
  echo "=== macOS ==="
  sw_vers 2>&1 || true
  echo
  echo "=== Architecture ==="
  uname -a 2>&1 || true
} > "$META/environment.txt"

{
  echo "=== Top-level ==="
  find . -maxdepth 1 -mindepth 1 ! -name .git ! -name .build -print | sort
  echo
  echo "=== Source tree ==="
  for d in Sources Tests docs Documentation scripts; do
    if [[ -d "$d" ]]; then
      find "$d" -type f ! -path '*/.build/*' ! -path '*/DerivedData/*' | sort
    fi
  done
} > "$META/repository-tree.txt"

{
  for f in skipped-sensitive skipped-large skipped-binary-heavy skipped-noise; do
    count="$(grep -cve '^$' "$META/$f.txt" 2>/dev/null || true)"
    echo "$f: $count"
  done
} > "$META/skipped-summary.txt"

ZIP_PATH="$OUTPUT_DIR/$SNAPSHOT_NAME.zip"
(
  cd "$TMP_ROOT"
  /usr/bin/zip -qry "$ZIP_PATH" "$SNAPSHOT_NAME"
)

ZIP_SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"

echo
echo "✓ 全系统审计快照已生成"
echo "  $ZIP_PATH"
echo "  大小：$ZIP_SIZE"
echo
echo "附带：Git 状态 / diff / staged diff / 最近提交 / 工程树 / Swift+Xcode 环境"
echo "敏感文件、构建产物、常见大二进制已自动过滤。"
echo
echo "过滤摘要："
cat "$META/skipped-summary.txt"
echo
echo "把这个 ZIP 直接拖给 ChatGPT 即可。"
