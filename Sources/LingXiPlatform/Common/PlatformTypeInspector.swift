import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 跨平台类型反射与 JSON 动态值语义判断 (PlatformTypeInspector)
/// 隔离 Darwin (CoreFoundation/NSNumber/__NSCFBoolean) 与 Linux / Windows (纯 Swift / Corelibs-Foundation) 的类型桥接差异。
public enum PlatformTypeInspector: Sendable {

    /// 判断任意动态值在语义上是否为布尔类型
    public static func isBoolean(_ value: Any) -> Bool {
        #if canImport(CoreFoundation)
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        return value is Bool
        #else
        return value is Bool
        #endif
    }

    /// 判断任意动态值在语义上是否为整数数值（非布尔值，且无小数位截断）
    public static func isInteger(_ value: Any) -> Bool {
        #if canImport(CoreFoundation)
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && floor(number.doubleValue) == number.doubleValue
        #else
        guard !(value is Bool) else { return false }
        if value is Int || value is Int64 || value is Int32 || value is UInt || value is UInt64 || value is UInt32 {
            return true
        }
        if let num = value as? Double {
            return floor(num) == num
        }
        return false
        #endif
    }

    /// 判断任意动态值在语义上是否为普通实数数值（排除布尔）
    public static func isNumber(_ value: Any) -> Bool {
        #if canImport(CoreFoundation)
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
        #else
        guard !(value is Bool) else { return false }
        return value is Double || value is Int || value is Float || value is Int64 || value is UInt64
        #endif
    }
}
