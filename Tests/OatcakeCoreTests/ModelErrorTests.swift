import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct ModelErrorTests {
    /// A failed request is sorted by the server's HTTP status and the error code in its reply, or by
    /// the system's error code when nothing answered, not by words in a message.
    @Test func plainWords() async throws {
        let unknown = explainModelError(#"The model at http://localhost:11434/v1 returned 404: {"error":{"message":"model \"qwen9\" not found, try pulling it first"}}"#)
        #expect(unknown.contains("isn’t on that server") && unknown.contains("Settings › Models"))
        let tooLong = "This call is too long for the model to take in at once on this Mac."
        // llama.cpp's error type, OpenAI's code, and a request too big to be taken at all.
        #expect(explainModelError(#"The model at http://127.0.0.1:5000/v1 returned 400: {"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":40000,"n_ctx":32768}}"#) == tooLong)
        #expect(explainModelError(#"The model at http://localhost:1234/v1 returned 400: {"error":{"message":"Too many tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#) == tooLong)
        #expect(explainModelError("The model at http://localhost:8080/v1 returned 413: Payload Too Large") == tooLong)
        // A server that gives no code is read for its words, as a last resort.
        #expect(explainModelError(#"The model at http://localhost:8000/v1 returned 400: {"error":"the prompt is too long for the context window"}"#) == tooLong)
        #expect(explainModelError(#"The model at http://localhost:8000/v1 returned 400: {"error":"bad request"}"#).hasSuffix(#"{"error":"bad request"}"#))
        // The words don't count anywhere else: llama.cpp's log as it failed to start isn't a call too
        // long, or a server that couldn't be reached.
        let log = "The language model couldn’t start. llama.cpp said: …the connection to the device was lost; the context would exceed what’s free"
        #expect(explainModelError(log) == log)

        // Nothing answering is told by the system's code, so the Mac's language doesn't matter.
        let reached = "The model couldn’t be reached. If it’s a server of your own, check that it’s running."
        do {
            _ = try await LocalChat(baseUrl: "http://127.0.0.1:9/v1", model: "stand-in").complete([ChatMessage("user", "Say OK.")])
            Issue.record("nothing should answer on port 9")
        } catch {
            #expect(explainModelError(error.localizedDescription) == reached)
        }
        #expect(explainModelError("The model at http://studio.local:11434/v1 couldn’t be reached: Impossible de se connecter au serveur.") == reached)
        #expect(explainModelError("Could not connect to the server.") == "Could not connect to the server.")

        // Already plain: unchanged.
        for plain in [notLocalMessage, modelNotDownloadedMessage, outOfRoomMessage, "Set the endpoint and model in Settings first."] {
            #expect(explainModelError(plain) == plain)
        }
    }
}
