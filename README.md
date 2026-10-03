# Pubb Swift SDK

Native Swift client for Pubb public, private and presence subscriptions. Uses
Foundation's `URLSessionWebSocketTask` with no third-party dependencies.
Supports Swift 5.9+, iOS 15+, macOS 12+, tvOS 15+ and watchOS 8+.

## Install

Add this repository as a Swift Package in Xcode using
`https://github.com/pubbio/sdk-swift.git` and select the `main` branch
(or pin a verified commit). No version tag is assumed to exist. Add the `Pubb`
library product to your target. Package registry publication is a separate step.

## Subscribe

All SDK access and callbacks run on the main actor. Retain one client per app
session or relevant screen, and close it when the owning lifecycle ends:

```swift
import Pubb

@MainActor
func startRealtime() throws -> Pubb {
    let pubb = try Pubb(key: "YOUR_PUBLIC_APP_KEY")
    pubb.onStateChange = { state in print(state.rawValue) }
    pubb.onError = { error in print(error) }
    pubb.subscribe("notifications").bind("message.sent") { data in
        print(data["message"]?.string ?? "Message received")
    }
    pubb.connect()
    return pubb
}
// On teardown, call pubb.disconnect().
```

You can pass `wsHost: URL` for a local or self-hosted socket server. Only the
public application key belongs in the client. Publish events from a trusted
backend using a server SDK or the HTTP API; never embed `PUBB_APP_SECRET` in an
Apple app. JSON event payloads use the Codable `JSONValue` enum.

Repeated `connect()` calls reuse the connection. Unexpected failures reconnect
with 2, 4, 8, 16 and 30 second delays (at most five retries); a successful handshake
resets the retry budget and resubscribes. `disconnect()` cancels pending retries
and authorizations, clears the socket ID and presence state, and retains channel
listeners for a later explicit `connect()`. Refetch durable state after reconnect;
events missed while offline are not replayed. Pause/disconnect as appropriate for
the app's background lifecycle.

`bind` returns a token for `channel.unbind(event, token:)`. Use
`pubb.unsubscribe(channelName)` to remove the channel and all of its listeners.
Avoid capturing the client strongly in a callback owned by that client.

## Private and presence channels

Use an authenticated endpoint on your existing backend:

```swift
let authorize = Pubb.httpAuthorizer(
    endpoint: URL(string: "https://your-app.example/api/pubb/auth")!,
    headers: { ["Authorization": "Bearer \(currentUserSessionToken)"] }
)
let pubb = try Pubb(key: "YOUR_PUBLIC_APP_KEY", authorizer: authorize)
let room = pubb.subscribe("presence-room")
room.bind("pubb:subscription_succeeded") { [weak room] _ in
    print(room?.members ?? [:])
}
room.bind("pubb:member_added") { print($0) }
room.bind("pubb:member_removed") { print($0) }
pubb.connect()
```

Your server receives JSON `socket_id` and `channel_name`. It must authenticate
the user and check channel access before returning `auth` and, for presence,
`channel_data`. Presence identity must come from the verified server session.
The headers closure runs for each authorization request, so it can read refreshed
user credentials. Alternatively provide your own async `Authorizer` closure.
Observe `pubb:subscription_error` on a channel for authorization/subscription
failures. Known legacy `pusher:*` event names alias to the native `pubb:*` events.

## Checks and example

```sh
swift test
swift build -c release
PUBB_APP_KEY=your-public-key swift run PubbExample
```

The console example listens for one minute; publish `message.sent` to
`notifications` from your trusted backend during that window. `PUBB_WS_HOST` can
override the socket host. `.env.example` is a template, not an automatic loader.

Tests cover encoded public keys, Pubb frames, lifecycle cleanup, private auth
races, presence, bounded retries, HTTP authorization and callback removal using
fake sockets and URLProtocol. A live deployment check is separate and is not
claimed by those tests. CI builds and tests on macOS. Implementation uses the
[Foundation WebSocket API](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)
and the [Swift Package Manager](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).

License: [MIT](LICENSE).
