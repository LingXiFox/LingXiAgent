import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 跨平台类型反射与 JSON 动态值语义判断 (PlatformTypeInspector)
/// 隔离 Darwin (CoreFoundation/NSNumber/__NSCFBoolean) 与 Linux / Windows (纯 Swift / Corelibs-Foundation) 的类型桥接差异。
public enum PlatformTypeInspector: Sendable {

    /// Discriminates a boolean-backed NSNumber from a numeric-backed one.
    ///
    /// `value is Bool` cannot do this: every NSNumber bridges leniently to Bool, so on
    /// platforms without CoreFoundation it reported JSON integers such as `"version": 1` as
    /// booleans and the schema validation rejected them. Where CoreFoundation exists its
    /// boolean type ID is authoritative and is returned as-is, because objCType "c" also
    /// matches Int8/CChar-backed numbers; objCType is only the fallback where no type ID is
    /// available.
    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return String(cString: number.objCType) == "c"
        #endif
    }

    /// 判断任意动态值在语义上是否为布尔类型
    public static func isBoolean(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return isBooleanNumber(number)
        }
        return value is Bool
    }

    /// 判断任意动态值在语义上是否为整数数值（非布尔值，且无小数位截断）
    public static func isInteger(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            guard !isBooleanNumber(number) else { return false }
            return floor(number.doubleValue) == number.doubleValue
        }
        if value is Int || value is Int64 || value is Int32 || value is UInt || value is UInt64 || value is UInt32 {
            return true
        }
        if let num = value as? Double {
            return floor(num) == num
        }
        return false
    }

    /// 判断任意动态值在语义上是否为普通实数数值（排除布尔）
    public static func isNumber(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return !isBooleanNumber(number)
        }
        return value is Double || value is Int || value is Float || value is Int64 || value is UInt64
    }
}
