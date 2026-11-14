import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ModelErrorTests {
    @Test func plainWords() {
        let unknown = explainModelError(#"The model at http://localhost:11434/v1 returned 404: {"error":{"message":"model \"qwen9\" not found, try pulling it first"}}"#)
        #expect(unknown.contains("isn’t on that server") && unknown.contains("Settings › Summaries"))
        #expect(explainModelError("Could not connect to the server.").contains("couldn’t be reached"))
        #expect(explainModelError(#"The model at http://127.0.0.1:5000/v1 returned 400: {"error":{"message":"the request exceeds the available context size"}}"#).contains("too long"))
        // Already plain: unchanged.
        for plain in [notLocalMessage, modelNotDownloadedMessage, outOfRoomMessage, "Set the endpoint and model in Settings first."] {
            #expect(explainModelError(plain) == plain)
        }
    }
}
