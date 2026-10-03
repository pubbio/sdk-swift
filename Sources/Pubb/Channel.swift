import Foundation

func canonicalEvent(_ name: String) -> String {
    for event in ["subscription_succeeded", "subscription_error", "member_added", "member_removed", "connection_established", "error"] {
        if ["pusher:\(event)", "pusher_internal:\(event)"].contains(name) { return "pubb:\(event)" }
    }
    return name == "subscription_error" ? "pubb:subscription_error" : name
}

@MainActor
public final class Channel {
    public let name: String
    public private(set) var members: [String: JSONValue] = [:]
    private var listeners: [String: [UUID: (JSONValue) -> Void]] = [:]

    init(name: String) { self.name = name }

    @discardableResult
    public func bind(_ event: String, handler: @escaping (JSONValue) -> Void) -> UUID {
        let token = UUID()
        listeners[canonicalEvent(event), default: [:]][token] = handler
        return token
    }

    public func unbind(_ event: String, token: UUID? = nil) {
        let name = canonicalEvent(event)
        if let token { listeners[name]?[token] = nil } else { listeners[name] = nil }
    }

    public func unbindAll() { listeners.removeAll() }

    func emit(_ event: String, data: JSONValue) {
        let callbacks = Array(listeners[canonicalEvent(event), default: [:]].values)
        callbacks.forEach { $0(data) }
    }

    func setMembers(_ value: [String: JSONValue]) { members = value }
    func addMember(_ id: String, info: JSONValue) { members[id] = info }
    func removeMember(_ id: String) { members[id] = nil }
}
