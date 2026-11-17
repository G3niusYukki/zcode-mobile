import Foundation

/// Swift 6 禁止在 async 上下文(含嵌套闭包)直接使用 NSLock。
/// 用独立的同步函数承载临界区即可绕开诊断。
@inline(__always)
public func synced<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

/// 联调日志:走 stdout(devicectl --console 可见)+ 系统日志
public func ZDlog(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    print(message)
}
