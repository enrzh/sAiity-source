import CryptoKit
import Foundation
import Testing

@testable import sAiity

@Suite(.serialized)
@MainActor
struct FileDownloaderTests {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static var provider: ((URLRequest) -> Response)?

    @Test("A fresh download validates size, magic, and checksum")
    func freshDownload() async throws {
        let body = Self.modelData("fresh")
        try await Self.withStub { request in
            Response(status: 200,
                     headers: ["Content-Length": "\(body.count)", "ETag": "fresh"],
                     body: body)
        } operation: { destination in
            let checksum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            try await FileDownloader.download(
                from: URL(string: "https://models.test/fresh.gguf")!,
                to: destination,
                expectedBytes: Int64(body.count),
                requireMagic: FileDownloader.ggufMagic,
                expectedSHA256: checksum,
                progress: { _ in })
            #expect(try Data(contentsOf: destination) == body)
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
        }
    }

    @Test("A matching validator resumes from the partial offset")
    func resumesWithValidator() async throws {
        let body = Self.modelData("resume")
        let split = 7
        try await Self.withStub { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(split)-")
            #expect(request.value(forHTTPHeaderField: "If-Range") == "v1")
            return Response(status: 206,
                            headers: ["Content-Range": "bytes \(split)-\(body.count - 1)/\(body.count)",
                                      "ETag": "v1"],
                            body: body.suffix(from: split))
        } operation: { destination in
            let part = destination.appendingPathExtension("part")
            try Data(body.prefix(split)).write(to: part)
            try "v1".write(to: part.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
            try await FileDownloader.download(from: URL(string: "https://models.test/resume.gguf")!,
                                              to: destination,
                                              expectedBytes: Int64(body.count),
                                              requireMagic: FileDownloader.ggufMagic,
                                              progress: { _ in })
            #expect(try Data(contentsOf: destination) == body)
        }
    }

    @Test("A 200 response cleanly restarts an old partial")
    func restartsOnFullResponse() async throws {
        let body = Self.modelData("new-file")
        try await Self.withStub { _ in
            Response(status: 200, headers: ["Content-Length": "\(body.count)", "ETag": "v2"], body: body)
        } operation: { destination in
            let part = destination.appendingPathExtension("part")
            try Data("GGUF-old".utf8).write(to: part)
            try "v1".write(to: part.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
            try await FileDownloader.download(from: URL(string: "https://models.test/restart.gguf")!,
                                              to: destination,
                                              expectedBytes: Int64(body.count),
                                              requireMagic: FileDownloader.ggufMagic,
                                              progress: { _ in })
            #expect(try Data(contentsOf: destination) == body)
        }
    }

    @Test("A stale range retries once with a clean request")
    func retries416() async throws {
        let body = Self.modelData("retry")
        var requests = 0
        try await Self.withStub { request in
            requests += 1
            if requests == 1 {
                #expect(request.value(forHTTPHeaderField: "Range") != nil)
                return Response(status: 416, headers: [:], body: Data())
            }
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return Response(status: 200,
                            headers: ["Content-Length": "\(body.count)"],
                            body: body)
        } operation: { destination in
            let part = destination.appendingPathExtension("part")
            try Data(body.prefix(5)).write(to: part)
            try "stale".write(to: part.appendingPathExtension("etag"), atomically: true, encoding: .utf8)
            try await FileDownloader.download(from: URL(string: "https://models.test/416.gguf")!,
                                              to: destination,
                                              expectedBytes: Int64(body.count),
                                              requireMagic: FileDownloader.ggufMagic,
                                              progress: { _ in })
            #expect(requests == 2)
            #expect(try Data(contentsOf: destination) == body)
        }
    }

    @Test("Expected size rejects a clean but truncated response")
    func rejectsTruncatedResponse() async throws {
        let body = Self.modelData("short")
        try await Self.withStub { _ in
            Response(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
        } operation: { destination in
            let failed: Bool
            do {
                try await FileDownloader.download(from: URL(string: "https://models.test/truncated.gguf")!,
                                                  to: destination,
                                                  expectedBytes: Int64(body.count + 4),
                                                  requireMagic: FileDownloader.ggufMagic,
                                                  progress: { _ in })
                failed = false
            } catch {
                failed = true
            }
            #expect(failed)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("Checksum and magic failures preserve an existing installed model")
    func integrityFailuresAreAtomic() async throws {
        let old = Self.modelData("installed")
        let replacement = Self.modelData("replacement")
        try await Self.withStub { _ in
            Response(status: 200, headers: ["Content-Length": "\(replacement.count)"], body: replacement)
        } operation: { destination in
            try old.write(to: destination)
            let checksumFailed: Bool
            do {
                try await FileDownloader.download(from: URL(string: "https://models.test/checksum.gguf")!,
                                                  to: destination,
                                                  expectedBytes: Int64(replacement.count),
                                                  requireMagic: FileDownloader.ggufMagic,
                                                  expectedSHA256: String(repeating: "0", count: 64),
                                                  progress: { _ in })
                checksumFailed = false
            } catch {
                checksumFailed = true
            }
            #expect(checksumFailed)
            let installedAfterChecksum = try Data(contentsOf: destination)
            #expect(installedAfterChecksum == old)
        }

        try await Self.withStub { _ in
            Response(status: 200, headers: ["Content-Length": "5"], body: Data("HTML!".utf8))
        } operation: { destination in
            try old.write(to: destination)
            let magicFailed: Bool
            do {
                try await FileDownloader.download(from: URL(string: "https://models.test/magic.gguf")!,
                                                  to: destination,
                                                  expectedBytes: 5,
                                                  requireMagic: FileDownloader.ggufMagic,
                                                  progress: { _ in })
                magicFailed = false
            } catch {
                magicFailed = true
            }
            #expect(magicFailed)
            let installedAfterMagic = try Data(contentsOf: destination)
            #expect(installedAfterMagic == old)
        }
    }

    private static func modelData(_ suffix: String) -> Data {
        var data = Data("GGUF".utf8)
        data.append(Data(suffix.utf8))
        data.append(Data(repeating: 7, count: 32))
        return data
    }

    private static func destination() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-downloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model.gguf")
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func withStub<T>(
        _ provider: @escaping (URLRequest) -> Response,
        operation: (URL) async throws -> T
    ) async throws -> T {
        Self.provider = provider
        StubURLProtocol.provider = provider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        FileDownloader.testSessionConfiguration = { configuration }
        let destination = try Self.destination()
        defer {
            Self.provider = nil
            StubURLProtocol.provider = nil
            FileDownloader.testSessionConfiguration = nil
            Self.remove(destination)
        }
        return try await operation(destination)
    }
}

private final class StubURLProtocol: URLProtocol {
    typealias Response = FileDownloaderTests.Response
    static var provider: ((URLRequest) -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.provider?(request), let client else { return }
        let headers = response.headers.reduce(into: [String: String]()) { result, item in
            result[item.key] = item.value
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client.urlProtocol(self, didLoad: response.body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
