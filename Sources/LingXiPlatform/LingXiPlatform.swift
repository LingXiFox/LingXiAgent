import Foundation

/// 跨平台统一门面与服务定位器 (Platform Facade)
/// 将底层操作系统差异（macOS / Linux / Windows）彻底封装，
/// 上层所有业务模块（Core, Application, Client, TUI）统一通过本门面交互。
public enum LingXiPlatform {
    /// 进程生命周期、路径发现与级联清理适配器
    public static let process: any PlatformProcessProtocol = {
        #if canImport(Darwin)
        return DarwinProcessAdapter()
        #elseif os(Linux) || canImport(Glibc)
        return LinuxProcessAdapter()
        #elseif os(Windows)
        return WindowsProcessAdapter()
        #else
        fatalError("Unsupported operating system for process adapter")
        #endif
    }()

    /// 终端/控制台模式与尺寸适配器
    public static let terminal: any PlatformTerminalProtocol = {
        #if canImport(Darwin)
        return DarwinTerminalAdapter()
        #elseif os(Linux) || canImport(Glibc)
        return LinuxTerminalAdapter()
        #elseif os(Windows)
        return WindowsTerminalAdapter()
        #else
        fatalError("Unsupported operating system for terminal adapter")
        #endif
    }()

    /// 沙箱隔离执行器
    public static let sandbox: any PlatformSandboxProtocol = {
        #if canImport(Darwin)
        return DarwinSandboxAdapter()
        #elseif os(Linux) || canImport(Glibc)
        return LinuxSandboxAdapter()
        #elseif os(Windows)
        return WindowsSandboxAdapter()
        #else
        fatalError("Unsupported operating system for sandbox adapter")
        #endif
    }()

    /// 跨平台机密权限与安全随机数 (CPRNG)
    public static let secureStorage: any PlatformSecureStorageProtocol = {
        #if canImport(Darwin)
        return DarwinSecureStorageAdapter()
        #elseif os(Linux) || canImport(Glibc)
        return LinuxSecureStorageAdapter()
        #elseif os(Windows)
        return WindowsSecureStorageAdapter()
        #else
        fatalError("Unsupported operating system for secure storage adapter")
        #endif
    }()

    /// 跨平台桌面与系统集成（浏览器、剪贴板、目录标准）
    public static let system: any PlatformSystemProtocol = {
        #if canImport(Darwin)
        return DarwinSystemAdapter()
        #elseif os(Linux) || canImport(Glibc)
        return LinuxSystemAdapter()
        #elseif os(Windows)
        return WindowsSystemAdapter()
        #else
        fatalError("Unsupported operating system for system adapter")
        #endif
    }()

    /// 纯 ANSI 软渲染控制台兜底对象
    public static let fallbackTerminal = ANSIFallbackTerminal()

    /// 跨平台桌面辅助能力（视觉 OCR、覆盖层、屏幕几何）
    public static let desktopHelper: any PlatformDesktopHelperProtocol = {
        #if os(macOS)
        return DarwinDesktopHelperAdapter()
        #else
        return HeadlessDesktopHelperAdapter()
        #endif
    }()

    /// 跨平台路径与环境变量工具
    public static let path = PathUtilities.self

    /// 跨平台加密散列工具
    public static let crypto = PlatformCrypto.self

    /// 跨平台异步按行读取器
    public static let lineReader = AsyncLineReader.self

    /// 跨平台类型反射与 JSON 值语义判断
    public static let types = PlatformTypeInspector.self

    /// 跨平台统一环境变量访问门面
    public enum environment {
        public static func get(_ name: String) -> String? {
            LingXiPlatform.system.getEnvironmentVariable(name)
        }

        public static func set(_ name: String, value: String) {
            LingXiPlatform.system.setEnvironmentVariable(name, value: value)
        }

        public static func unset(_ name: String) {
            LingXiPlatform.system.unsetEnvironmentVariable(name)
        }
    }
}
