import SwiftUI

/// 灵犀 GUI 尺度层。
///
/// 基线取自 Apple macOS 27 Sketch UI Kit：工具栏 52pt、工具栏控件 36pt、
/// 侧栏内容内缩 14pt、侧栏行 32pt、选中圆角 8、Popover 圆角 20。
/// 字阶锚在系统语义字阶上；间距 4 / 8 / 12 / 16 / 20 / 24 六档，
/// 仅 Kit 规定的侧栏内缩 14 例外。圆角按窗口同心关系推导，不各自取值。
public enum LingXiMetrics {

    // MARK: - 栅格（全站唯一间距来源）

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
    }

    // MARK: - 圆角（仅三类容器）

    public enum Radius {
        /// 内嵌输出块：代码、diff、命令原文
        public static let inset: CGFloat = 8
        /// 悬浮玻璃表面：Composer、权限面板、命令面板（= Kit Popover 圆角）
        public static let surface: CGFloat = 20
        /// macOS 27 带工具栏窗口的外圆角
        public static let window: CGFloat = 26
        /// 浮动侧面板：与窗口同心，= 窗口圆角 − 面板边距
        public static let panel: CGFloat = window - Split.panelMargin
        /// 用户气泡
        public static let bubble: CGFloat = 18
    }

    // MARK: - 行高

    public enum Row {
        /// 时间线事件单行
        public static let event: CGFloat = 28
        /// 列表行（Kit 侧栏 Medium 行高）
        public static let list: CGFloat = 32
    }

    // MARK: - 列宽

    public enum Column {
        /// 阅读列上限（拓宽至 1080，告别窄条空洞）
        public static let measure: CGFloat = 1080
        /// 阅读列两侧最小留白
        public static let gutter: CGFloat = 28
        /// 用户气泡上限
        public static let userBubble: CGFloat = 720
        /// 事件图标列宽，保证标题在同一竖线上对齐
        public static let eventGlyph: CGFloat = 18
    }

    // MARK: - 浮动面板布局

    public enum Split {
        public static let navigatorWidth: CGFloat = 272
        public static let inspectorWidth: CGFloat = 304
        /// 面板与窗口边缘、面板与舞台之间的间隙
        public static let panelMargin: CGFloat = Space.sm
        /// 面板内容水平内缩（Kit 侧栏 256 宽、内容 228 宽）
        public static let panelContentInset: CGFloat = 14
        /// 窗口宽于此值时检查器为舞台让位，否则浮在内容之上
        public static let inspectorDockMinWidth: CGFloat = 1120
        public static let windowMinWidth: CGFloat = 760
        public static let windowMinHeight: CGFloat = 520
    }

    // MARK: - 输出块

    /// 工具输出、diff 预览的封顶高度，超出转为内部滚动
    public static let outputMaxHeight: CGFloat = 260
    /// Composer 输入区最多展开行数，超出内部滚动
    public static let composerMaxLines = 8
}

// MARK: - 字阶（高清晰度、增强暗黑环境对比度）

public extension Font {
    /// 助手正文与用户消息（提升至 15pt，字重优化）
    static let lxBody: Font = .system(size: 15, weight: .regular)
    /// 区块标题
    static let lxTitle: Font = .system(size: 18, weight: .semibold)
    /// 时间线事件、检查器正文（提升至 13.5pt）
    static let lxCallout: Font = .system(size: 13.5, weight: .medium)
    /// 元数据：耗时、计数、副标题
    static let lxMeta: Font = .system(size: 12, weight: .regular)
    /// 徽章与计数
    static let lxMicro: Font = .system(size: 11, weight: .semibold)
    /// 等宽，仅用于代码、命令、路径、ID
    static let lxMono: Font = .system(size: 13, weight: .regular, design: .monospaced)
}

public extension ShapeStyle where Self == Color {
    /// 用户气泡：文字色 6% 洗白，跟随明暗自动反相，不用彩色底
    static var lxUserBubble: Color { Color.primary.opacity(0.06) }
}
