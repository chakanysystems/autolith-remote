import Foundation
import NIOCore
import NIOPosix

/// TCP transport shared by HTTP RPC and WebSocket streams. Protocol parsing and
/// admission run on `queue`; socket state belongs exclusively to NIO's event loop.
final class BridgeConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias Receive = (Data?, Bool, Error?) -> Void

    private let channel: Channel
    private let queue: DispatchQueue
    private var pendingRead: Receive?
    private var buffered: Data?
    private var inputEnded = false
    private var terminalError: Error?
    // Accessed only on the application's serial queue.
    private var closed = false
    var onClose: (() -> Void)? {
        didSet { if closed { onClose?() } }
    }

    init(channel: Channel, queue: DispatchQueue) {
        self.channel = channel; self.queue = queue
    }

    func receive(_ completion: @escaping Receive) {
        channel.eventLoop.execute {
            precondition(self.pendingRead == nil, "Only one socket receive may be outstanding")
            self.pendingRead = completion
            if let data = self.buffered {
                self.buffered = nil
                self.deliver(data, ended: self.inputEnded, error: self.terminalError)
            } else if self.inputEnded {
                self.deliver(nil, ended: true, error: self.terminalError)
            } else if self.channel.isActive {
                self.channel.read()
            }
        }
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer).whenComplete { result in
            self.queue.async {
                switch result {
                case .success: completion(nil)
                case .failure(let error): completion(error)
                }
            }
        }
    }

    func cancel() { channel.close(promise: nil) }

    private func deliver(_ data: Data?, ended: Bool, error: Error?) {
        guard let callback = pendingRead else { return }
        pendingRead = nil
        queue.async { callback(data, ended, error) }
    }

    func channelActive(context: ChannelHandlerContext) {
        if pendingRead != nil { context.read() }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        if pendingRead != nil {
            deliver(bytes, ended: false, error: nil)
        } else {
            // autoRead is disabled and each read is limited to one 64 KiB chunk.
            // Bound any unsolicited input as well, rather than queueing it forever.
            guard (buffered?.count ?? 0) + bytes.count <= 65536 else {
                errorCaught(context: context, error: TransportError.unexpectedInput)
                return
            }
            if buffered == nil { buffered = bytes } else { buffered!.append(bytes) }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            inputEnded = true
            deliver(nil, ended: true, error: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        terminalError = error
        inputEnded = true
        deliver(nil, ended: true, error: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        inputEnded = true
        deliver(nil, ended: true, error: terminalError)
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            let callback = self.onClose
            self.onClose = nil
            callback?()
        }
        context.fireChannelInactive()
    }

    private enum TransportError: Error { case unexpectedInput }
}

final class BridgeListener {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let queue: DispatchQueue
    private var channel: Channel?
    var port: Int? { channel?.localAddress?.port }

    init(queue: DispatchQueue) { self.queue = queue }

    func start(port: UInt16, accept: @escaping (BridgeConnection) -> Void) throws {
        let queue = self.queue
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 65536))
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                let connection = BridgeConnection(channel: channel, queue: queue)
                return channel.pipeline.addHandler(connection).map {
                    queue.async { accept(connection) }
                }
            }
            .bind(host: "127.0.0.1", port: Int(port)).wait()
    }

    func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }
}
