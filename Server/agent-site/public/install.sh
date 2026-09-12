#!/usr/bin/env bash
# ==============================================================================
#  🦊 LingXiAgent 一键全自动安装部署器 (Official One-Line Installer)
#  URL: https://agent.lingxifox.cn/install.sh
#  Repo: https://github.com/LingXiFox/LingXiAgent
# ==============================================================================

set -e

# 终端彩色输出
BOLD="\033[1m"
GREEN="\033[38;5;82m"
PURPLE="\033[38;5;141m"
CYAN="\033[38;5;51m"
AMBER="\033[38;5;214m"
RED="\033[38;5;196m"
GRAY="\033[38;5;245m"
RESET="\033[0m"

echo -e "${PURPLE}"
cat << "EOF"
  /\_/\  
 ( o.o )  🦊 LingXiAgent — Native Swift AI Coding Agent
  > ^ <   LingXiAgent · Terminal AI Coding Agent Installer
EOF
echo -e "${RESET}"

# 1. 检测系统与 CPU 架构
OS="$(uname -s)"
ARCH="$(uname -m)"

if [ "$OS" != "Darwin" ]; then
    echo -e "${RED}[ERROR] 抱歉，LingXiAgent 当前版本专为 macOS (Apple Silicon & Intel) 原生打造，暂未支持 ${OS}。${RESET}"
    echo -e "${GRAY}系统深度集成了 macOS Keychain 安全凭据体系与 Darwin 原生网络层。${RESET}"
    echo -e "${AMBER}Linux 等多平台支持正在筹备与适配中，敬请期待！${RESET}"
    echo -e "${GRAY}项目主页: https://agent.lingxifox.cn | GitHub: https://github.com/LingXiFox/LingXiAgent${RESET}"
    exit 1
fi
PLATFORM="macos"

case "$ARCH" in
    arm64|aarch64)
        CPU_ARCH="arm64"
        ;;
    x86_64|amd64)
        CPU_ARCH="x86_64"
        ;;
    *)
        echo -e "${RED}[ERROR] 暂不支持的处理器架构: ${ARCH}${RESET}"
        exit 1
        ;;
esac

echo -e "${GRAY}[1/5] 检测到系统环境: ${BOLD}macOS (${CPU_ARCH})${RESET}"

# 2. 准备安装目录
INSTALL_ROOT="$HOME/.lingxiagent"
BIN_DIR="$INSTALL_ROOT/bin"
TARGET_BIN="$BIN_DIR/lingxiagent"

mkdir -p "$BIN_DIR"
mkdir -p "$INSTALL_ROOT/logs"
mkdir -p "$INSTALL_ROOT/sessions"

echo -e "${GRAY}[2/5] 准备本地安装路径: ${BOLD}${BIN_DIR}${RESET}"

# 3. 部署二进制文件
INSTALLED=false

# 场景 A: 如果当前目录下存在 Package.swift 且是 LingXiAgent 源码目录
if [ -f "./Package.swift" ] && grep -q "LingXiAgent" ./Package.swift 2>/dev/null; then
    echo -e "${CYAN}[*] 检测到处于本地源码仓库，正在直接以 Release 模式编译...${RESET}"
    swift build -c release --product lingxiagent
    RELEASE_PATH="$(swift build -c release --show-bin-path)/lingxiagent"
    if [ -f "$RELEASE_PATH" ]; then
        cp -f "$RELEASE_PATH" "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
        INSTALLED=true
        echo -e "${GREEN}[✓] 本地编译并成功安装至 ${TARGET_BIN}${RESET}"
    fi
fi

# 场景 B: 从 GitHub Releases 获取预编译 Release 包
if [ "$INSTALLED" = false ]; then
    RELEASE_URL="https://github.com/LingXiFox/LingXiAgent/releases/latest/download/lingxiagent-macos-${CPU_ARCH}.tar.gz"
    FALLBACK_URL="https://github.com/LingXiFox/LingXiAgent/releases/latest/download/lingxiagent-macos-universal.tar.gz"
    echo -e "${GRAY}[3/5] 正在从 GitHub Releases 下载预编译发布包...${RESET}"
    TMP_DIR="$(mktemp -d /tmp/lingxiagent-install.XXXXXX)"
    
    HTTP_CODE=$(curl -s -L -o "$TMP_DIR/release.tar.gz" -w "%{http_code}" "$RELEASE_URL" || true)
    if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMP_DIR/release.tar.gz" ]; then
        echo -e "${AMBER}[!] 尝试获取通用发布包 (Universal)...${RESET}"
        HTTP_CODE=$(curl -s -L -o "$TMP_DIR/release.tar.gz" -w "%{http_code}" "$FALLBACK_URL" || true)
    fi

    if [ "$HTTP_CODE" = "200" ] && [ -s "$TMP_DIR/release.tar.gz" ]; then
        echo -e "${CYAN}[*] 正在解压安装预编译二进制...${RESET}"
        tar -xzf "$TMP_DIR/release.tar.gz" -C "$TMP_DIR"
        if [ -f "$TMP_DIR/lingxiagent" ]; then
            cp -f "$TMP_DIR/lingxiagent" "$TARGET_BIN"
            chmod +x "$TARGET_BIN"
            INSTALLED=true
            echo -e "${GREEN}[✓] 预编译二进制安装成功!${RESET}"
        fi
    fi
    rm -rf "$TMP_DIR"
fi

# 场景 C: 若无预编译包，且系统存在 swift 环境，则自动浅克隆极速编译
if [ "$INSTALLED" = false ]; then
    if command -v swift >/dev/null 2>&1; then
        echo -e "${AMBER}[!] 暂无对应平台的预编译二进制，正在从 GitHub 源码编译安装 (Swift 原生快速编译)...${RESET}"
        CLONE_DIR="$(mktemp -d /tmp/lingxiagent-src.XXXXXX)"
        git clone --depth 1 https://github.com/LingXiFox/LingXiAgent.git "$CLONE_DIR"
        (
            cd "$CLONE_DIR"
            swift build -c release --product lingxiagent
            RELEASE_PATH="$(swift build -c release --show-bin-path)/lingxiagent"
            cp -f "$RELEASE_PATH" "$TARGET_BIN"
            chmod +x "$TARGET_BIN"
        )
        rm -rf "$CLONE_DIR"
        INSTALLED=true
        echo -e "${GREEN}[✓] 源码构建并安装成功!${RESET}"
    else
        echo -e "${RED}[ERROR] 未检测到 Swift 运行环境且未找到预编译二进制。${RESET}"
        echo -e "${GRAY}请先安装 Xcode Command Line Tools (macOS: xcode-select --install) 或 Swift 工具链。${RESET}"
        exit 1
    fi
fi

# 4. 配置用户 Shell 环境变量 PATH
echo -e "${GRAY}[4/5] 正在配置 Shell 环境变量...${RESET}"
CONFIGURED_SHELL=""

add_path_to_rc() {
    RC_FILE="$1"
    LINE_TO_ADD="$2"
    if [ -f "$RC_FILE" ]; then
        if ! grep -q "$BIN_DIR" "$RC_FILE" 2>/dev/null; then
            echo "" >> "$RC_FILE"
            echo "# LingXiAgent CLI Path" >> "$RC_FILE"
            echo "$LINE_TO_ADD" >> "$RC_FILE"
            CONFIGURED_SHELL="$RC_FILE"
        fi
    fi
}

# 检测 zsh
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    add_path_to_rc "$HOME/.zshrc" "export PATH=\"\$HOME/.lingxiagent/bin:\$PATH\""
fi

# 检测 bash
if [ -f "$HOME/.bashrc" ]; then
    add_path_to_rc "$HOME/.bashrc" "export PATH=\"\$HOME/.lingxiagent/bin:\$PATH\""
elif [ -f "$HOME/.bash_profile" ]; then
    add_path_to_rc "$HOME/.bash_profile" "export PATH=\"\$HOME/.lingxiagent/bin:\$PATH\""
fi

# 检测 fish
if [ -d "$HOME/.config/fish" ]; then
    FISH_CONF="$HOME/.config/fish/config.fish"
    if [ -f "$FISH_CONF" ] && ! grep -q "$BIN_DIR" "$FISH_CONF" 2>/dev/null; then
        echo "" >> "$FISH_CONF"
        echo "# LingXiAgent CLI Path" >> "$FISH_CONF"
        echo "fish_add_path \$HOME/.lingxiagent/bin" >> "$FISH_CONF"
        CONFIGURED_SHELL="$FISH_CONF"
    fi
fi

# 5. 初始化配置模板
echo -e "${GRAY}[5/5] 初始化本地配置模板...${RESET}"
PROVIDERS_FILE="$INSTALL_ROOT/providers.json"
if [ ! -f "$PROVIDERS_FILE" ]; then
    cat << "EOF" > "$PROVIDERS_FILE"
{
  "version": "1.0",
  "providers": []
}
EOF
fi

# 6. 自检并打印完成信息
echo ""
if [ -x "$TARGET_BIN" ]; then
    echo -e "${GREEN}${BOLD}🎉 LingXiAgent 安装完成！${RESET}"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  📍 安装路径: ${BOLD}${TARGET_BIN}${RESET}"
    if [ -n "$CONFIGURED_SHELL" ]; then
        echo -e "  ⚙️  已更新配置: ${BOLD}${CONFIGURED_SHELL}${RESET}"
    fi
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${BOLD}🚀 快速上手:${RESET}"
    echo -e "  1. 刷新当前终端环境（或新开一个终端窗口）："
    echo -e "     ${CYAN}source ${CONFIGURED_SHELL:-~/.zshrc}${RESET}"
    echo ""
    echo -e "  2. 认证你的 AI 提供商账号（可选，支持官方订阅或通用 API）："
    echo -e "     ${GRAY}# 登录 OpenAI ChatGPT Plus/Pro 订阅 (Codex OAuth):${RESET}"
    echo -e "     ${CYAN}lingxiagent auth login openai-codex${RESET}"
    echo ""
    echo -e "     ${GRAY}# 登录 Claude Code 订阅:${RESET}"
    echo -e "     ${CYAN}lingxiagent auth login anthropic-claude-subscription${RESET}"
    echo ""
    echo -e "  3. 立即启动极速 TUI 交互终端："
    echo -e "     ${GREEN}${BOLD}lingxiagent${RESET}"
    echo ""
    echo -e "${GRAY}📖 官方文档: https://agent.lingxifox.cn/#docs${RESET}"
    echo -e "${GRAY}🦊 祝主人编程愉快！${RESET}"
    echo ""
else
    echo -e "${RED}[ERROR] 安装验证失败，未找到可执行文件: ${TARGET_BIN}${RESET}"
    exit 1
fi
