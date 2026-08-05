import AppKit
import Foundation

enum Clipboard {
    /// `clearContents()` is not tidiness — it is what takes ownership of the
    /// pasteboard. Without it `setString` returns false and silently writes
    /// nothing.
    @discardableResult
    static func copy(_ string: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(string, forType: .string)
    }
}

enum Export {
    // MARK: - Plain text / Markdown

    static func txt(_ segments: [Segment]) -> String {
        segments.map { seg in
            let line = seg.text
            if let tr = seg.tr, !tr.isEmpty { return "\(line)\n\(tr)" }
            return line
        }.joined(separator: "\n")
    }

    static func markdown(_ segments: [Segment], meta: SessionMeta) -> String {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        var out = "# Transcript — \(df.string(from: meta.startedAt))\n\n"
        out += "- Language: `\(meta.locale)`\n"
        if let t = meta.translateTo { out += "- Translated to: `\(t)`\n" }
        out += "- Lines: \(segments.count)\n\n---\n\n"
        for seg in segments {
            out += "**\(clock(seg.t0))** \(seg.text)\n"
            if let tr = seg.tr, !tr.isEmpty { out += "> \(tr)\n" }
            out += "\n"
        }
        out += "\n_Transcribed on device by sAiity._\n"
        return out
    }

    /// `H:MM:SS` for headings, not the SRT form.
    private static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    // MARK: - SRT

    /// SRT wants `HH:MM:SS,mmm` — comma, not period, and always three decimals.
    private static func srtTime(_ s: Double) -> String {
        let clamped = max(0, s)
        let total = Int(clamped)
        let ms = Int(((clamped - Double(total)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      total / 3600, (total % 3600) / 60, total % 60, min(ms, 999))
    }

    /// A single final can run 15 seconds over four sentences, which is unreadable
    /// as one cue. Split on sentence ends, long pauses, or length — using the
    /// per-word timings the engine gave us.
    static func cues(from seg: Segment,
                     maxChars: Int = 84, maxDur: Double = 6.0, gap: Double = 0.6)
        -> [(t0: Double, t1: Double, text: String)] {
        guard let ws = seg.words, !ws.isEmpty else {
            return [(seg.t0, seg.t1, seg.text)]
        }
        var out: [(Double, Double, String)] = []
        var cur: [TimedWord] = []

        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let t = cur.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append((f.start, l.end, t)) }
            cur = []
        }

        for w in ws {
            if let last = cur.last {
                let chars = cur.map(\.text).joined().count + w.text.count
                let dur = w.end - cur[0].start
                let sentenceEnd = last.text.hasSuffix(".") || last.text.hasSuffix("?")
                    || last.text.hasSuffix("!")
                if sentenceEnd || (w.start - last.end >= gap) || chars > maxChars || dur > maxDur {
                    flush()
                }
            }
            cur.append(w)
        }
        flush()
        return out.map { ($0.0, $0.1, $0.2) }
    }

    static func srt(_ segments: [Segment]) -> String {
        var out = ""
        var n = 1                       // renumber from 1; never reuse Segment.i
        for seg in segments {
            for c in cues(from: seg) {
                out += "\(n)\n\(srtTime(c.t0)) --> \(srtTime(c.t1))\n\(c.text)\n\n"
                n += 1
            }
        }
        return out
    }

    // MARK: - Saving

    /// Writes next to the session so an export is always findable again.
    @discardableResult
    static func write(_ contents: String, named name: String, in dir: URL) -> URL? {
        let url = dir.appendingPathComponent(name)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            return url
        } catch {
            NSLog("sAiity export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
