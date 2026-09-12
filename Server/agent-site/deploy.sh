#!/usr/bin/env bash
# ==============================================================================
#  🦊 LingXiAgent 官网一键部署脚本 (Deploy to agent.lingxifox.cn)
# ==============================================================================

set -e

REMOTE_HOST="${1:-aliyun}"
REMOTE_DIR="/var/www/agent.lingxifox.cn"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_DIR="$SCRIPT_DIR/public"

echo "🦊 开始部署 LingXiAgent 官网至 $REMOTE_HOST:$REMOTE_DIR ..."

# 1. 确保远程目录存在
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

# 2. 同步静态页面与安装脚本
rsync -avz --delete "$PUBLIC_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"

# 3. 部署 Caddyfile 配置
ssh "$REMOTE_HOST" "sudo systemctl reload caddy || true"

echo "🎉 部署完成！访问: https://agent.lingxifox.cn"
