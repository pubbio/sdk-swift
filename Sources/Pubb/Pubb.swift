import Foundation

public enum ConnectionState: String, Sendable { case initialized, connecting, connected, disconnected, failed }
public enum PubbError: Error, Equatable { case invalidConfiguration, invalidMessage, authorizationRequired, authorizationFailed(Int), invalidAuthorization, transportFailed }

public struct ChannelAuthorization: Codable, Sendable {
    public let auth: String
    public let channelData: String?
    public init(auth: String, channelData: String? = nil) { self.auth = auth; self.channelData = channelData }
    enum CodingKeys: String, CodingKey { case auth; case channelData = "channel_data" }
}

@MainActor
public final class Pubb {
    public typealias Authorizer = (_ socketID: String, _ channel: String) async throws -> ChannelAuthorization
    public private(set) var state: ConnectionState = .initialized
    public private(set) var socketID: String?
    public var onStateChange: ((ConnectionState) -> Void)?
    public var onError: ((Error) -> Void)?

    private let makeTransport: () -> SocketTransport
    private let authorizer: Authorizer?
    private let sleep: (UInt64) async throws -> Void
    private var channels: [String: Channel] = [:]
    private var transport: SocketTransport?
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var subscriptions: [String: Task<Void, Never>] = [:]
    private var stopped = true
    private var attempts = 0

    public convenience init(key: String, wsHost: URL = URL(string: "wss://ws.pubb.io")!, session: URLSession = .shared, authorizer: Authorizer? = nil) throws {
        let url = try Self.socketURL(key: key, host: wsHost)
        self.init(makeTransport: { URLSessionTransport(url: url, session: session) }, authorizer: authorizer)
    }

    init(makeTransport: @escaping () -> SocketTransport, authorizer: Authorizer? = nil, sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.makeTransport = makeTransport
        self.authorizer = authorizer
        self.sleep = sleep
    }

    static func socketURL(key: String, host: URL) throws -> URL {
        guard !key.isEmpty, ["ws", "wss"].contains(host.scheme), var components = URLComponents(url: host, resolvingAgainstBaseURL: false), components.host != nil, components.user == nil, components.password == nil else { throw PubbError.invalidConfiguration }
        components.path = "/socket"
        components.fragment = nil
        components.queryItems = [URLQueryItem(name: "appKey", value: key)]
        guard let url = components.url else { throw PubbError.invalidConfiguration }
        return url
    }

    /// Use the app's existing authenticated server endpoint. Never sign in the client.
    public static func httpAuthorizer(endpoint: URL, session: URLSession = .shared, headers: @escaping () -> [String: String] = { [:] }) -> Authorizer {
        return { socketID, channel in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = headers()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["socket_id": socketID, "channel_name": channel])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PubbError.invalidAuthorization }
            guard (200..<300).contains(http.statusCode) else { throw PubbError.authorizationFailed(http.statusCode) }
            let authorization = try JSONDecoder().decode(ChannelAuthorization.self, from: data)
            guard !authorization.auth.isEmpty else { throw PubbError.invalidAuthorization }
            return authorization
        }
    }

    public func connect() {
        guard transport == nil else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        stopped = false; attempts = 0
        startConnection()
    }

    public func disconnect() {
        stopped = true
        reconnectTask?.cancel(); reconnectTask = nil
        resetConnection()
        attempts = 0
        setState(.disconnected)
    }

    @discardableResult
    public func subscribe(_ name: String) -> Channel {
        if let channel = channels[name] { return channel }
        let channel = Channel(name: name)
        channels[name] = channel
        if state == .connected { subscribe(channel, connection: connectionID) }
        return channel
    }

    public func channel(_ name: String) -> Channel? { channels[name] }

    public func unsubscribe(_ name: String) {
        guard let channel = channels.removeValue(forKey: name) else { return }
        subscriptions.removeValue(forKey: name)?.cancel()
        channel.unbindAll(); channel.setMembers([:])
        if state == .connected { send(.object(["action": .string("unsubscribe"), "channel": .string(name)]), connection: connectionID) }
    }

    private func startConnection() {
        guard !stopped, transport == nil else { return }
        let socket = makeTransport()
        let id = UUID(); connectionID = id
        transport = socket
        socket.start()
        receiveTask = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    guard let self, self.connectionID == id, !self.stopped else { break }
                    self.handle(text, connection: id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(connection: id)
            }
        }
        setState(.connecting)
    }

    private func resetConnection() {
        connectionID = UUID()
        receiveTask?.cancel(); receiveTask = nil
        subscriptions.values.forEach { $0.cancel() }; subscriptions.removeAll()
        transport?.close(); transport = nil; socketID = nil
        channels.values.forEach { $0.setMembers([:]) }
    }

    private func failed(connection: UUID) {
        guard connectionID == connection, !stopped else { return }
        resetConnection()
        let generation = connectionID
        setState(.disconnected)
        onError?(PubbError.transportFailed)
        guard !stopped, transport == nil, connectionID == generation else { return }
        guard attempts < 5 else { setState(.failed); return }
        attempts += 1
        let delay = UInt64(min(pow(2.0, Double(attempts)), 30)) * 1_000_000_000
        let sleeper = sleep
        reconnectTask = Task { [weak self] in
            do { try await sleeper(delay) } catch { return }
            guard !Task.isCancelled, let self, !self.stopped, self.connectionID == generation else { return }
            self.reconnectTask = nil
            self.startConnection()
        }
    }

    private func setState(_ value: ConnectionState) { state = value; onStateChange?(value) }

    private func decoded(_ data: JSONValue) -> JSONValue {
        guard let text = data.string, let bytes = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return data }
        return value
    }

    private func handle(_ text: String, connection: UUID) {
        do {
            let packet = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard packet.object != nil else { throw PubbError.invalidMessage }
            let event = packet["event"]?.string.map(canonicalEvent)
            let data = decoded(packet["data"] ?? .null)
            if event == "pubb:connection_established" {
                guard let id = data["socket_id"]?.string, !id.isEmpty else { throw PubbError.invalidMessage }
                socketID = id; attempts = 0
                let pending = Array(channels.values)
                setState(.connected)
                for channel in pending { subscribe(channel, connection: connection) }
                return
            }
            guard let name = packet["channel"]?.string, let channel = channels[name] else {
                if event == "pubb:error" { onError?(PubbError.transportFailed) }
                return
            }
            switch event {
            case "pubb:subscription_succeeded":
                if name.hasPrefix("presence-"), let members = data["presence"]?["hash"]?.object { channel.setMembers(members) }
                channel.emit("pubb:subscription_succeeded", data: data)
            case "pubb:subscription_error": channel.emit("pubb:subscription_error", data: data)
            case "pubb:member_added":
                if name.hasPrefix("presence-"), let id = data["user_id"]?.string { channel.addMember(id, info: data["user_info"] ?? .object([:])); channel.emit("pubb:member_added", data: data) }
            case "pubb:member_removed":
                if name.hasPrefix("presence-"), let id = data["user_id"]?.string { channel.removeMember(id); channel.emit("pubb:member_removed", data: data) }
            case nil:
                guard let eventName = data["name"]?.string else { throw PubbError.invalidMessage }
                channel.emit(eventName, data: data["data"] ?? .null)
            default: break
            }
        } catch { onError?(PubbError.invalidMessage) }
    }

    private func subscribe(_ channel: Channel, connection: UUID) {
        guard connectionID == connection, state == .connected, let id = socketID, let socket = transport, channels[channel.name] === channel, subscriptions[channel.name] == nil else { return }
        let authorize = authorizer
        subscriptions[channel.name] = Task { [weak self, channel] in
            do {
                var frame: [String: JSONValue] = ["action": .string("subscribe"), "channel": .string(channel.name)]
                if channel.name.hasPrefix("private-") || channel.name.hasPrefix("presence-") {
                    guard let authorize else { throw PubbError.authorizationRequired }
                    let authorization = try await authorize(id, channel.name)
                    guard !authorization.auth.isEmpty else { throw PubbError.invalidAuthorization }
                    frame["auth"] = .string(authorization.auth)
                    if let data = authorization.channelData { frame["channel_data"] = .string(data) }
                }
                guard !Task.isCancelled, let self, self.connectionID == connection, self.channels[channel.name] === channel else { return }
                let bytes = try JSONEncoder().encode(JSONValue.object(frame))
                try await socket.send(String(decoding: bytes, as: UTF8.self))
            } catch {
                guard !Task.isCancelled, let self, self.connectionID == connection, self.channels[channel.name] === channel else { return }
                self.subscriptions[channel.name] = nil
                channel.emit("pubb:subscription_error", data: .string("Channel authorization or subscription failed"))
                self.onError?(error)
            }
        }
    }

    private func send(_ value: JSONValue, connection: UUID) {
        guard let socket = transport else { return }
        Task { [weak self] in
            guard let self, self.connectionID == connection else { return }
            do { try await socket.send(String(decoding: JSONEncoder().encode(value), as: UTF8.self)) }
            catch { self.failed(connection: connection) }
        }
    }

    deinit {
        receiveTask?.cancel()
        reconnectTask?.cancel()
        subscriptions.values.forEach { $0.cancel() }
        let socket = transport
        Task { @MainActor in socket?.close() }
    }
}
