import Foundation

enum DiagnosticsRedactor {
    private static let transcriptMarkers = [
        "sAiity chunk final=",
        "sAiity live translated:",
        "sAiity translated [",
    ]

    static func redact(_ message: String,
                       homeDirectory: String = NSHomeDirectory()) -> String {
        var value = message
        if !homeDirectory.isEmpty {
            value = value.replacingOccurrences(of: homeDirectory, with: "~")
        }

        for marker in transcriptMarkers {
            guard let range = value.range(of: marker) else { continue }
            return String(value[..<range.upperBound]) + "<redacted>"
        }
        return value
    }
}
