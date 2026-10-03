import Foundation
import XCTest
@testable import Pubb

private final class MockHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class AuthorizerTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: config)
    }

    func testHTTPAuthorizationUsesCurrentIdentityAndSessionHeaders() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); MockHTTP.handler = nil }
        MockHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            // URLSession may hand URLProtocol a streamed request body.
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
            }
            let body = try JSONDecoder().decode([String: String].self, from: bytes)
            XCTAssertEqual(body, ["socket_id": "1.2", "channel_name": "private-room"])
            return (200, Data("{\"auth\":\"key:signature\"}".utf8))
        }
        let authorize = Pubb.httpAuthorizer(endpoint: URL(string: "https://example.test/pubb/auth")!, session: session, headers: { ["Authorization": "Bearer user-session"] })
        let result = try await authorize("1.2", "private-room")
        XCTAssertEqual(result.auth, "key:signature")
    }

    func testHTTPAuthorizationRejectsFailuresAndInvalidPayloads() async {
        let session = session()
        defer { session.invalidateAndCancel(); MockHTTP.handler = nil }
        let authorize = Pubb.httpAuthorizer(endpoint: URL(string: "https://example.test/pubb/auth")!, session: session)
        MockHTTP.handler = { _ in (403, Data("do not echo this response".utf8)) }
        do { _ = try await authorize("1.2", "private-room"); XCTFail("Expected 403") }
        catch { XCTAssertEqual(error as? PubbError, .authorizationFailed(403)) }
        MockHTTP.handler = { _ in (200, Data("{\"auth\":\"\"}".utf8)) }
        do { _ = try await authorize("1.2", "private-room"); XCTFail("Expected invalid auth") }
        catch { XCTAssertEqual(error as? PubbError, .invalidAuthorization) }
    }
}
