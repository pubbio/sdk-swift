import XCTest
import Foundation
@testable import Pubb

@MainActor
final class FakeSocket: SocketTransport {
    var sent: [JSONValue] = []
    var closed = false
    var starts = 0
    private var queue: [Result<String, Error>] = []
    private var receiver: CheckedContinuation<String, Error>?
    func start() { starts += 1 }
    func send(_ text: String) async throws { sent.append(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) }
    func receive() async throws -> String {
        if !queue.isEmpty { return try queue.removeFirst().get() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func deliver(_ result: Result<String, Error>) {
        if let receiver { self.receiver = nil; receiver.resume(with: result) } else { queue.append(result) }
    }
    func frame(_ json: String) { deliver(.success(json)) }
    func handshake(_ id: String = "1.2") { frame("{\"event\":\"pubb:connection_established\",\"data\":{\"socket_id\":\"\(id)\"}}") }
    func close() { closed = true; if let receiver { self.receiver = nil; receiver.resume(throwing: CancellationError()) } }
}

@MainActor
final class PubbTests: XCTestCase {
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testSocketURLAndInvalidConfiguration() throws {
        let key = "a&b? /ç"
        let url = try Pubb.socketURL(key: key, host: URL(string: "ws://localhost:38001/path?old=1")!)
        XCTAssertEqual(url.path, "/socket")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "appKey", value: key)])
        XCTAssertThrowsError(try Pubb(key: "", wsHost: URL(string: "wss://ws.pubb.io")!))
        XCTAssertThrowsError(try Pubb(key: "key", wsHost: URL(string: "https://example.com")!))
    }

    func testPublicSubscriptionDeliveryAndLifecycle() async {
        let socket = FakeSocket()
        let pubb = Pubb(makeTransport: { socket })
        var states: [ConnectionState] = [], events: [JSONValue] = [], errors = 0
        pubb.onStateChange = { states.append($0) }
        pubb.onError = { _ in errors += 1 }
        pubb.subscribe("notifications").bind("message.sent") { events.append($0) }
        pubb.connect(); pubb.connect()
        socket.handshake()
        await settle()
        XCTAssertEqual(socket.starts, 1)
        XCTAssertEqual(socket.sent, [.object(["action": .string("subscribe"), "channel": .string("notifications")])])
        socket.frame("{\"channel\":\"notifications\",\"data\":\"{\\\"name\\\":\\\"message.sent\\\",\\\"data\\\":{\\\"message\\\":\\\"Hello\\\"}}\"}")
        socket.frame("{\"channel\":\"other\",\"data\":{\"name\":\"message.sent\",\"data\":\"ignore\"}}")
        socket.frame("invalid json")
        await settle()
        XCTAssertEqual(events, [.object(["message": .string("Hello")])])
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(states, [.connecting, .connected])
        XCTAssertEqual(pubb.socketID, "1.2")
        pubb.disconnect()
        XCTAssertTrue(socket.closed)
        XCTAssertNil(pubb.socketID)
        XCTAssertEqual(pubb.state, .disconnected)
    }

    func testPresenceUsesNativeAndLegacyEvents() async {
        let socket = FakeSocket()
        let pubb = Pubb(makeTransport: { socket }, authorizer: { _, _ in ChannelAuthorization(auth: "key:signature", channelData: "{\"user_id\":\"a\"}") })
        let channel = pubb.subscribe("presence-room")
        var added = 0, subscribed = 0
        channel.bind("pusher:member_added") { _ in added += 1 }
        channel.bind("pubb:subscription_succeeded") { _ in subscribed += 1 }
        pubb.connect(); socket.handshake(); await settle()
        XCTAssertEqual(socket.sent.first?["auth"], .string("key:signature"))
        XCTAssertEqual(socket.sent.first?["channel_data"], .string("{\"user_id\":\"a\"}"))
        socket.frame("{\"event\":\"pusher_internal:subscription_succeeded\",\"channel\":\"presence-room\",\"data\":{\"presence\":{\"hash\":{\"a\":{\"name\":\"Ada\"}},\"ids\":[\"a\"],\"count\":1}}}")
        socket.frame("{\"event\":\"pubb:member_added\",\"channel\":\"presence-room\",\"data\":\"{\\\"user_id\\\":\\\"b\\\",\\\"user_info\\\":{}}\"}")
        await settle()
        XCTAssertEqual(channel.members.count, 2)
        XCTAssertEqual(added, 1); XCTAssertEqual(subscribed, 1)
        socket.frame("{\"event\":\"pusher_internal:member_removed\",\"channel\":\"presence-room\",\"data\":{\"user_id\":\"a\"}}")
        await settle()
        XCTAssertEqual(channel.members.count, 1)
        pubb.disconnect()
        XCTAssertTrue(channel.members.isEmpty)
    }

    func testMissingAuthorizerAndServerSubscriptionErrorsAreVisible() async {
        let socket = FakeSocket()
        let client = Pubb(makeTransport: { socket })
        var errors = 0
        let channel = client.subscribe("private-room")
        channel.bind("pubb:subscription_error") { _ in errors += 1 }
        client.connect(); socket.handshake(); await settle()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(errors, 1)
        socket.frame("{\"event\":\"subscription_error\",\"channel\":\"private-room\",\"data\":\"Denied\"}")
        await settle()
        XCTAssertEqual(errors, 2)
        client.disconnect()
    }

    func testUnsubscribeDiscardsDelayedAuthorization() async {
        let socket = FakeSocket()
        var resolve: CheckedContinuation<ChannelAuthorization, Error>?
        let pubb = Pubb(makeTransport: { socket }, authorizer: { socketID, channel in
            XCTAssertEqual(socketID, "1.2"); XCTAssertEqual(channel, "private-room")
            return try await withCheckedThrowingContinuation { resolve = $0 }
        })
        pubb.subscribe("private-room")
        pubb.connect(); socket.handshake(); await settle()
        pubb.unsubscribe("private-room")
        resolve?.resume(returning: ChannelAuthorization(auth: "stale")); await settle()
        XCTAssertEqual(socket.sent, [.object(["action": .string("unsubscribe"), "channel": .string("private-room")])])
        XCTAssertNil(pubb.channel("private-room"))
        pubb.disconnect()
    }

    func testOldConnectionAuthorizationCannotSubscribeNewSocket() async {
        var sockets: [FakeSocket] = [], resolvers: [CheckedContinuation<ChannelAuthorization, Error>] = []
        let pubb = Pubb(makeTransport: { let socket = FakeSocket(); sockets.append(socket); return socket }, authorizer: { _, _ in
            try await withCheckedThrowingContinuation { resolvers.append($0) }
        })
        pubb.subscribe("private-room")
        pubb.connect(); sockets[0].handshake(); await settle()
        pubb.disconnect(); pubb.connect(); sockets[1].handshake("3.4"); await settle()
        resolvers[0].resume(returning: ChannelAuthorization(auth: "stale")); await settle()
        XCTAssertTrue(sockets[1].sent.isEmpty)
        resolvers[1].resume(returning: ChannelAuthorization(auth: "fresh")); await settle()
        XCTAssertEqual(sockets[1].sent.first?["auth"], .string("fresh"))
        pubb.disconnect()
    }

    func testUnexpectedFailureResubscribesAndExplicitDisconnectCancelsRetry() async {
        var sockets: [FakeSocket] = [], waits: [CheckedContinuation<Void, Error>] = [], delays: [UInt64] = []
        let pubb = Pubb(makeTransport: { let socket = FakeSocket(); sockets.append(socket); return socket }, sleep: { delay in
            delays.append(delay); try await withCheckedThrowingContinuation { waits.append($0) }
        })
        pubb.subscribe("notifications")
        pubb.connect(); sockets[0].handshake(); await settle()
        sockets[0].deliver(.failure(PubbError.transportFailed)); await settle()
        XCTAssertEqual(delays, [2_000_000_000])
        waits[0].resume(); await settle()
        XCTAssertEqual(sockets.count, 2)
        sockets[1].handshake("3.4"); await settle()
        XCTAssertEqual(sockets[1].sent.first?["channel"], .string("notifications"))
        sockets[1].deliver(.failure(PubbError.transportFailed)); await settle()
        pubb.disconnect(); waits[1].resume(); await settle()
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(pubb.state, .disconnected)
    }

    func testRetriesStopAfterFiveAttempts() async {
        var sockets: [FakeSocket] = []
        let pubb = Pubb(makeTransport: { let socket = FakeSocket(); sockets.append(socket); return socket }, sleep: { _ in await Task.yield() })
        pubb.connect()
        for _ in 0..<6 { sockets.last!.deliver(.failure(PubbError.transportFailed)); await settle() }
        XCTAssertEqual(sockets.count, 6)
        XCTAssertEqual(pubb.state, .failed)
        pubb.disconnect()
    }

    func testBindingsCanBeRemoved() {
        let channel = Channel(name: "notifications")
        var calls = 0
        let token = channel.bind("message.sent") { _ in calls += 1 }
        channel.unbind("message.sent", token: token)
        channel.emit("message.sent", data: .null)
        XCTAssertEqual(calls, 0)
    }

    func testReleasingClientClosesSocket() async {
        let socket = FakeSocket()
        var pubb: Pubb? = Pubb(makeTransport: { socket })
        weak var reference = pubb
        pubb?.connect(); await settle()
        pubb = nil; await settle()
        XCTAssertNil(reference)
        XCTAssertTrue(socket.closed)
    }

    func testJSONValuePreservesNestedValues() throws {
        let json = "{\"array\":[1,true,null,\"hi\"],\"object\":{\"x\":false}}"
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["array"], .array([.number(1), .bool(true), .null, .string("hi")]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
}
