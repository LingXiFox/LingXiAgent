import Foundation
#if os(Windows)
import WinSDK
#endif

/// 跨平台不透明管道句柄 (PlatformPipeHandle)
/// 隔离 Darwin / Linux 的文件描述符与 Windows 的 Win32 HANDLE，
/// 使得 PlatformProcessProtocol 与 PlatformAsyncIOProtocol 不再泄漏具体 OS 的底层对象。
public struct PlatformPipeHandle: Sendable, Hashable {
    #if os(Windows)
    /// Win32 `HANDLE` 的指针位宽形式；`0` 表示无有效句柄。
    public let rawHandle: UInt64
    public init(rawHandle: UInt64) {
        self.rawHandle = rawHandle
    }
    #else
    public let fileDescriptor: Int32
    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }
    #endif
}

// MARK: - Foundation.FileHandle bridging
//
// `FileHandle` exists on all three platforms but does not carry a file descriptor on
// Windows, so the conversion itself is the platform boundary: business modules hand the
// Foundation handle over and never branch on the OS.

public extension PlatformPipeHandle {
    init(fileHandle: FileHandle) {
        #if os(Windows)
        self.rawHandle = unsafeBitCast(fileHandle._handle, to: UInt64.self)
        #else
        self.fileDescriptor = fileHandle.fileDescriptor
        #endif
    }

    #if !os(Windows)
    var fileHandle: FileHandle {
        FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
    }
    #else
    /// The `HANDLE` carried by `rawHandle`, or `nil` when no handle is held.
    var win32Handle: HANDLE? {
        guard rawHandle != 0 else { return nil }
        return unsafeBitCast(rawHandle, to: HANDLE?.self)
    }
    #endif
}

#if !os(Windows)
extension FileHandle {
    public var platformPipeHandle: PlatformPipeHandle {
        PlatformPipeHandle(fileHandle: self)
    }
}
#endif
