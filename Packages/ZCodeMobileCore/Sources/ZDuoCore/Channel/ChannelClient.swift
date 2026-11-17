import Foundation

/// 通道 RPC 客户端:IPC 报文之上的寻址与关联。
/// 出站 100(call)/102(listen)/103(dispose);入站 200(ready)/201(success)/202(error)/203(errorObj)/204(event)。
/// 一切请求必须在收到 200 之后发出(awaitReady)。
public final class ChannelClient: @unchecked Sendable {

    public enum ChannelError: Error, Equatable {
        case timeout(String)
        case promiseRejected(message: String, code: String?)
        case notReady
    }

    public static let channelAgent = "zcode-agent"
    public static let channelWindowController = "window-controller"

    private final class Pending {
        let continuation: CheckedContinuation<IpcValue, Error>
        let timeoutItem: DispatchWorkItem
        init(continuation: CheckedContinuation<IpcValue, Error>, timeoutItem: DispatchWorkItem) {
            self.continuation = continuation
            self.timeoutItem = timeoutItem
        }
    }

    private final class ReadyWaiter {
        let continuation: CheckedContinuation<Void, Error>
        init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    }

    private let lock = NSLock()
    private var nextRequestId = 0
    private var pending: [Int: Pending] = [:]
    private var listeners: [Int: (IpcValue) -> Void] = [:]
    private var ready = false
    private var readyWaiters: [ReadyWaiter] = []
    private var sendBytes: ((Data) throws -> Void)?
    private let logger: (String) -> Void

    public init(onLog: ((String) -> Void)? = nil) {
        self.logger = onLog ?? { _ in }
    }

    /// 接上传输层(bridge ready 后调用;reset 后重接)
    public func attach(sendBytes: @escaping (Data) throws -> Void) {
        lock.lock()
        self.sendBytes = sendBytes
        lock.unlock()
    }

    /// 换桥:pending 全部失败收场、监听表清空、ready 复位
    public func reset() {
        lock.lock()
        let oldPending = pending
        pending.removeAll()
        listeners.removeAll()
        ready = false
        let waiters = readyWaiters
        readyWaiters.removeAll()
        sendBytes = nil
        lock.unlock()
        for p in oldPending.values {
            p.timeoutItem.cancel()
            p.continuation.resume(throwing: ChannelError.notReady)
        }
        for w in waiters { w.continuation.resume(throwing: ChannelError.notReady) }
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// 等待 200 Initialize(每桥一次)
    public func awaitReady(timeout: TimeInterval = 30) async throws {
        if isReadyNow() { return }
        try await withCheckedThrowingContinuation { cont in
            let waiter = ReadyWaiter(cont)
            if !enqueueWaiterIfNotReady(waiter) {
                cont.resume() // 已 ready,直接放行
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                if let w = self.dequeueWaiter(waiter) {
                    w.continuation.resume(throwing: ChannelError.timeout("channel initialize"))
                }
            }
        }
    }

    private func isReadyNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// 返回 false 表示已 ready(调用方需立即 resume);true 表示已入队
    private func enqueueWaiterIfNotReady(_ waiter: ReadyWaiter) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ready else { return false }
        readyWaiters.append(waiter)
        return true
    }

    private func dequeueWaiter(_ waiter: ReadyWaiter) -> ReadyWaiter? {
        lock.lock(); defer { lock.unlock() }
        if let idx = readyWaiters.firstIndex(where: { $0 === waiter }) {
            return readyWaiters.remove(at: idx)
        }
        return nil
    }

    // MARK: - 出站

    /// 100 Promise 调用。args = 参数数组(第二段编码为数组)。
    @discardableResult
    public func call(_ channel: String, _ method: String, args: [IpcValue], timeout: TimeInterval = 30) async throws -> IpcValue {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IpcValue, Error>) in
            beginRequest(channel: channel, method: method, args: args, timeout: timeout, continuation: cont)
        }
    }

    /// 同步上下文里开始一次请求(分配 id → 注册 pending → 发送 → 挂超时)
    private func beginRequest(channel: String, method: String, args: [IpcValue], timeout: TimeInterval,
                              continuation: CheckedContinuation<IpcValue, Error>) {
        let id: Int
        let sender: ((Data) throws -> Void)?
        lock.lock()
        if !ready || sendBytes == nil {
            lock.unlock()
            continuation.resume(throwing: ChannelError.notReady)
            return
        }
        id = nextRequestId
        nextRequestId += 1
        sender = sendBytes
        lock.unlock()

        let bytes = IpcCodec.encodeRequest(type: 100, id: id, channel: channel, method: method, args: args)
        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.failPending(id: id, error: .timeout("\(channel).\(method)#\(id)"))
        }
        lock.lock()
        pending[id] = Pending(continuation: continuation, timeoutItem: timeoutItem)
        lock.unlock()

        guard let sender else {
            failPending(id: id, error: .notReady)
            return
        }
        do {
            try sender(Data(bytes))
        } catch {
            failPending(id: id, error: .notReady)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    /// 102 EventListen:serialize([102, id, channel, event]) ++ serialize(arg 裸值)。
    /// 返回监听 id(204 事件挂此 id)。
    @discardableResult
    public func listen(_ channel: String, event: String, arg: IpcValue, handler: @escaping (IpcValue) -> Void) throws -> Int {
        lock.lock()
        if !ready { lock.unlock(); throw ChannelError.notReady }
        let id = nextRequestId
        nextRequestId += 1
        guard let sender = sendBytes else { lock.unlock(); throw ChannelError.notReady }
        listeners[id] = handler
        lock.unlock()

        let header = IpcCodec.encode(.array([.int(102), .int(id), .string(channel), .string(event)]))
        let body = IpcCodec.encode(arg)
        do {
            try sender(Data(header + body))
        } catch {
            lock.lock(); listeners.removeValue(forKey: id); lock.unlock()
            throw ChannelError.notReady
        }
        return id
    }

    /// 103 EventDispose:serialize([103, id]) ++ serialize(undefined);无应答
    public func dispose(listenerId: Int) {
        lock.lock()
        listeners.removeValue(forKey: listenerId)
        guard let sender = sendBytes else { lock.unlock(); return }
        lock.unlock()
        let header = IpcCodec.encode(.array([.int(103), .int(listenerId)]))
        try? sender(Data(header + IpcCodec.encode(.undefined)))
    }

    private func failPending(id: Int, error: ChannelError) {
        lock.lock()
        guard let p = pending.removeValue(forKey: id) else { lock.unlock(); return }
        lock.unlock()
        p.timeoutItem.cancel()
        p.continuation.resume(throwing: error)
    }

    // MARK: - 入站

    /// 传输层投递完整 IPC 报文(两个顶层值:head 数组 + data;200 Initialize 只有 head)
    public func handleData(_ data: Data) {
        let reader = VarintReader([UInt8](data))
        guard let headerValue = try? IpcCodec.decode(from: reader),
              case .array(let items) = headerValue,
              let first = items.first,
              case .int(let type) = first else {
            logger("[channel] malformed ipc message")
            return
        }
        let second: IpcValue
        if reader.remaining > 0, let v = try? IpcCodec.decode(from: reader) {
            second = v
        } else {
            second = .undefined
        }
        let id: Int?
        if items.count > 1, case .int(let i) = items[1] { id = i } else { id = nil }

        switch type {
        case 200:
            lock.lock()
            ready = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()
            for w in waiters { w.continuation.resume() }

        case 201:
            guard let id else { return }
            lock.lock()
            if let p = pending.removeValue(forKey: id) {
                lock.unlock()
                p.timeoutItem.cancel()
                p.continuation.resume(returning: second)
            } else {
                lock.unlock()
            }

        case 202:
            var message = "promise rejected"
            var code: String?
            if case .json(let text) = second,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                message = obj["message"] as? String ?? message
                code = obj["code"] as? String
            }
            guard let id else { return }
            lock.lock()
            if let p = pending.removeValue(forKey: id) {
                lock.unlock()
                p.timeoutItem.cancel()
                p.continuation.resume(throwing: ChannelError.promiseRejected(message: message, code: code))
            } else {
                lock.unlock()
            }

        case 203:
            guard let id else { return }
            lock.lock()
            if let p = pending.removeValue(forKey: id) {
                lock.unlock()
                p.timeoutItem.cancel()
                p.continuation.resume(throwing: ChannelError.promiseRejected(message: "rejected", code: nil))
            } else {
                lock.unlock()
            }

        case 204:
            guard let id else { return }
            lock.lock()
            let handler = listeners[id]
            lock.unlock()
            handler?(second)

        default:
            logger("[channel] unknown inbound type \(type)")
        }
    }
}
