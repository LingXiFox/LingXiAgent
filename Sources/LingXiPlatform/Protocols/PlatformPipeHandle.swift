import Foundation

/// 跨平台不透明管道句柄 (PlatformPipeHandle)
/// 隔离 Darwin / Linux 的 FileDescriptor / FileHandle 与 Windows 的 Win32 HANDLE，
/// 使得 PlatformProcessProtocol 与 PlatformAsyncIOProtocol 不再泄漏具体 OS 的底层对象。
public struct PlatformPipeHandle: Sendable, Hashable {
    #if os(Windows)
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

    #if !os(Windows)
    public init(fileHandle: FileHandle) {
        self.fileDescriptor = fileHandle.fileDescriptor
    }

    public var fileHandle: FileHandle {
        FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
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
