# ==============================================================================
#  🦊 LingXiAgent 一键全自动安装部署器 (Official Windows PowerShell Installer)
#  URL: https://agent.lingxifox.cn/install.ps1
#  Repo: https://github.com/LingXiFox/LingXiAgent
# ==============================================================================

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "  /\_/\  " -ForegroundColor Magenta
Write-Host " ( o.o )  🦊 LingXiAgent — Native Swift AI Coding Agent" -ForegroundColor Magenta
Write-Host "  > ^ <   Windows PowerShell Installer" -ForegroundColor Magenta
Write-Host ""

# 1. 检测系统与 CPU 架构
$RawArch = $env:PROCESSOR_ARCHITECTURE
$CpuArch = "x86_64"
if ($RawArch -eq "ARM64") {
    $CpuArch = "arm64"
} elseif ($RawArch -eq "AMD64") {
    $CpuArch = "x86_64"
} else {
    Write-Host "[!] 未知架构 $RawArch，默认回退至 x86_64" -ForegroundColor Yellow
}

Write-Host "[1/5] 检测到系统环境: Windows ($CpuArch)" -ForegroundColor DarkGray

# 2. 准备安装目录
$InstallRoot = Join-Path $env:USERPROFILE ".lingxiagent"
$BinDir = Join-Path $InstallRoot "bin"
$LogsDir = Join-Path $InstallRoot "logs"
$SessionsDir = Join-Path $InstallRoot "sessions"
$TargetBin = Join-Path $BinDir "lingxiagent.exe"

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
New-Item -ItemType Directory -Force -Path $SessionsDir | Out-Null

Write-Host "[2/5] 准备本地安装路径: $BinDir" -ForegroundColor DarkGray

# 3. 部署二进制文件
$Installed = $false

function Install-Sidecars-And-Bundles($SourceDir, $TargetBinDir, $Root) {
    # 1. 复制 LingXiCore 资源 Bundle 与 Resources
    Get-ChildItem -Path $SourceDir -Directory -Filter "*LingXiCore*" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Force -Recurse $_.FullName (Join-Path $TargetBinDir $_.Name)
    }

    # 2. 部署 Browser Sidecar 及其依赖
    $SrcSidecar = Join-Path $SourceDir "Sidecars\browser-host"
    if (Test-Path $SrcSidecar) {
        $DestSidecar = Join-Path $Root "sidecars\browser-host"
        $BinSidecar = Join-Path $TargetBinDir "Sidecars\browser-host"
        New-Item -ItemType Directory -Force -Path $DestSidecar | Out-Null
        New-Item -ItemType Directory -Force -Path $BinSidecar | Out-Null
        Copy-Item -Force -Recurse (Join-Path $SrcSidecar "*") $DestSidecar
        Copy-Item -Force -Recurse (Join-Path $SrcSidecar "*") $BinSidecar

        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Push-Location $DestSidecar
            try {
                npm install --omit=dev --silent | Out-Null
                Write-Host "[*] 已成功部署 Browser Sidecar 运行时 (Playwright 依赖就绪)" -ForegroundColor DarkGray
            } catch {
                Write-Host "[!] Browser Sidecar npm 依赖安装失败，浏览器能力将降级" -ForegroundColor Yellow
            } finally {
                Pop-Location
            }
        }
    }
}

# 场景 A: 如果当前目录下存在 Package.swift 且是 LingXiAgent 源码目录
if ((Test-Path "Package.swift") -and (Select-String -Path "Package.swift" -Pattern "LingXiAgent" -Quiet -ErrorAction SilentlyContinue)) {
    if (Get-Command swift -ErrorAction SilentlyContinue) {
        Write-Host "[*] 检测到处于本地源码仓库，正在以 Release 模式编译..." -ForegroundColor Cyan
        swift build -c release --product lingxiagent
        swift build -c release --product LingXiCoreHost
        $BinPath = (swift build -c release --show-bin-path).Trim()
        $BuiltAgent = Join-Path $BinPath "lingxiagent.exe"
        $BuiltCore = Join-Path $BinPath "LingXiCoreHost.exe"
        if (Test-Path $BuiltAgent) {
            Copy-Item -Force $BuiltAgent $TargetBin
            if (Test-Path $BuiltCore) {
                Copy-Item -Force $BuiltCore (Join-Path $BinDir "LingXiCoreHost.exe")
            }
            Install-Sidecars-And-Bundles $BinPath $BinDir $InstallRoot
            if (Test-Path "Sidecars\browser-host") {
                Install-Sidecars-And-Bundles "." $BinDir $InstallRoot
            }
            $Installed = $true
            Write-Host "[✓] 本地源码编译并成功安装至 $TargetBin" -ForegroundColor Green
        }
    }
}

# 场景 B: 从 GitHub Releases 获取预编译 Release 包
if (-not $Installed) {
    $ReleaseUrl = "https://github.com/LingXiFox/LingXiAgent/releases/latest/download/lingxiagent-windows-$CpuArch.zip"
    $FallbackUrl = "https://github.com/LingXiFox/LingXiAgent/releases/latest/download/lingxiagent-windows-x86_64.zip"
    Write-Host "[3/5] 正在从 GitHub Releases 下载预编译发布包..." -ForegroundColor DarkGray
    
    $TempZip = Join-Path ([System.IO.Path]::GetTempPath()) "lingxiagent-release.zip"
    $TempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    
    try {
        Invoke-WebRequest -Uri $ReleaseUrl -OutFile $TempZip -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($CpuArch -ne "x86_64") {
            Write-Host "[!] 尝试获取 x86_64 预编译包..." -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri $FallbackUrl -OutFile $TempZip -UseBasicParsing -ErrorAction Stop
            } catch {
                # 下载失败
            }
        }
    }

    if (Test-Path $TempZip) {
        try {
            Expand-Archive -Path $TempZip -DestinationPath $TempExtract -Force
            $CandidateAgent = Join-Path $TempExtract "lingxiagent.exe"
            if (Test-Path $CandidateAgent) {
                Copy-Item -Force $CandidateAgent $TargetBin
                $CandidateCore = Join-Path $TempExtract "LingXiCoreHost.exe"
                if (Test-Path $CandidateCore) {
                    Copy-Item -Force $CandidateCore (Join-Path $BinDir "LingXiCoreHost.exe")
                }
                Install-Sidecars-And-Bundles $TempExtract $BinDir $InstallRoot
                $Installed = $true
                Write-Host "[✓] 预编译二进制安装成功!" -ForegroundColor Green
            }
        } finally {
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $TempExtract
            Remove-Item -Force -ErrorAction SilentlyContinue $TempZip
        }
    }
}

# 场景 C: 若无预编译包，且系统存在 swift 环境，则自动浅克隆极速编译
if (-not $Installed) {
    if (Get-Command swift -ErrorAction SilentlyContinue) {
        Write-Host "[!] 暂无对应预编译包，正在从 GitHub 源码克隆并编译 (Swift Native Build)..." -ForegroundColor Yellow
        $TempClone = Join-Path ([System.IO.Path]::GetTempPath()) "lingxiagent-src-$([System.Guid]::NewGuid().ToString())"
        git clone --depth 1 https://github.com/LingXiFox/LingXiAgent.git $TempClone
        Push-Location $TempClone
        try {
            swift build -c release --product lingxiagent
            swift build -c release --product LingXiCoreHost
            $BinPath = (swift build -c release --show-bin-path).Trim()
            $BuiltAgent = Join-Path $BinPath "lingxiagent.exe"
            $BuiltCore = Join-Path $BinPath "LingXiCoreHost.exe"
            if (Test-Path $BuiltAgent) {
                Copy-Item -Force $BuiltAgent $TargetBin
                if (Test-Path $BuiltCore) {
                    Copy-Item -Force $BuiltCore (Join-Path $BinDir "LingXiCoreHost.exe")
                }
                Install-Sidecars-And-Bundles $BinPath $BinDir $InstallRoot
                Install-Sidecars-And-Bundles "." $BinDir $InstallRoot
                $Installed = $true
                Write-Host "[✓] 源码构建并安装成功!" -ForegroundColor Green
            }
        } finally {
            Pop-Location
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $TempClone
        }
    } else {
        Write-Host "[ERROR] 未检测到 Swift 运行环境且未下载到预编译二进制。" -ForegroundColor Red
        Write-Host "请先安装 Swift for Windows (https://www.swift.org/install/windows/)。" -ForegroundColor DarkGray
        exit 1
    }
}

# 4. 配置用户环境变量 PATH
Write-Host "[4/5] 正在配置系统用户环境变量 PATH..." -ForegroundColor DarkGray
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$PathUpdated = $false

if ($UserPath -notlike "*$BinDir*") {
    $NewUserPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    $PathUpdated = $true
}

# 更新当前会话中的 PATH 供立刻使用
if ($env:Path -notlike "*$BinDir*") {
    $env:Path = "$BinDir;$env:Path"
}

# 5. 初始化配置模板
Write-Host "[5/5] 初始化本地配置模板..." -ForegroundColor DarkGray
$ProvidersFile = Join-Path $InstallRoot "providers.json"
if (-not (Test-Path $ProvidersFile)) {
    @"
{
  "version": "1.0",
  "providers": []
}
"@ | Out-File -FilePath $ProvidersFile -Encoding UTF8
}

# 6. 自检并输出欢迎指南
Write-Host ""
if (Test-Path $TargetBin) {
    Write-Host "🎉 LingXiAgent 安装完成！" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host "  📍 安装路径: $TargetBin" -ForegroundColor White
    if ($PathUpdated) {
        Write-Host "  ⚙️  已添加到用户 PATH 环境变量 (新建终端窗口后永久生效)" -ForegroundColor Cyan
    }
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host ""
    Write-Host "🚀 快速上手:" -ForegroundColor White
    Write-Host "  1. 认证你的 AI 提供商账号（可选，支持官方订阅或通用 API）："
    Write-Host "     # 登录 OpenAI ChatGPT Plus/Pro 订阅 (Codex OAuth):" -ForegroundColor DarkGray
    Write-Host "     lingxiagent auth login openai-codex" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "     # 登录 Claude Code 订阅:" -ForegroundColor DarkGray
    Write-Host "     lingxiagent auth login anthropic-claude-subscription" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  2. 立即启动极速 TUI 交互终端："
    Write-Host "     lingxiagent" -ForegroundColor Green
    Write-Host ""
    Write-Host "📖 官方文档: https://agent.lingxifox.cn/#docs" -ForegroundColor DarkGray
    Write-Host "🦊 祝主人编程愉快！" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Host "[ERROR] 安装验证失败，未找到可执行文件: $TargetBin" -ForegroundColor Red
    exit 1
}
