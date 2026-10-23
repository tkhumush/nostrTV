import Testing
@testable import CoveIOS

struct BunkerHandshakeTests {
    @Test func connectionRequiresTheExactSecret() {
        #expect(BunkerResponse(id: "1", result: "secret", error: nil).validatesConnection(secret: "secret"))
        #expect(!BunkerResponse(id: "1", result: "ack", error: nil).validatesConnection(secret: "secret"))
        #expect(!BunkerResponse(id: "1", result: "another-secret", error: nil).validatesConnection(secret: "secret"))
        #expect(!BunkerResponse(id: "1", result: "secret", error: "denied").validatesConnection(secret: "secret"))
        #expect(!BunkerResponse(id: "1", result: "", error: nil).validatesConnection(secret: ""))
    }
}
