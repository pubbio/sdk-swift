import Foundation

@MainActor
protocol SocketTransport: AnyObject {
    func start()
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor
final class URLSessionTransport: SocketTransport {
    private let task: URLSessionWebSocketTask
    init(url: URL, session: URLSession) { task = session.webSocketTask(with: url) }
    func start() { task.resume() }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let value): return value
        case .data(let value):
            guard let text = String(data: value, encoding: .utf8) else { throw PubbError.invalidMessage }
            return text
        @unknown default: throw PubbError.invalidMessage
        }
    }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
    deinit { task.cancel(with: .normalClosure, reason: nil) }
}
