import Foundation
import Pubb

@main
struct Example {
    @MainActor static func main() async throws {
        guard let key = ProcessInfo.processInfo.environment["PUBB_APP_KEY"] else {
            print("Set PUBB_APP_KEY to your public application key."); return
        }
        let host = URL(string: ProcessInfo.processInfo.environment["PUBB_WS_HOST"] ?? "wss://ws.pubb.io")!
        let pubb = try Pubb(key: key, wsHost: host)
        pubb.onStateChange = { print("Connection: \($0.rawValue)") }
        pubb.onError = { print("Pubb error: \($0)") }
        pubb.subscribe("notifications").bind("message.sent") { print("Message: \($0)") }
        pubb.connect()
        defer { pubb.disconnect() }
        // Example window for publishing an event from your trusted backend.
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}
