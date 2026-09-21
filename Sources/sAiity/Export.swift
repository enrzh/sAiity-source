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
            let prefix = seg.speaker.map { "\(SpeakerLabel.displayName(for: $0)): " } ?? ""
            var line = prefix + seg.text
            if let tr = seg.tr, !tr.isEmpty { line += "\n\(tr)" }
            // A turn break reads as a paragraph break — the silence was real,
            // the paragraph is how text spells it.
            return (seg.turn == true ? "\n" : "") + line
        }.joined(separator: "\n")
    }

    /// The Markdown a person reads.
    ///
    /// `localized` exists because this one function serves two audiences. The
    /// GUI's Save-as-Markdown writes a document for the user, in the user's
    /// language. `sAiity --export md` writes to stdout, where a script may be
    /// matching on `- Lines:` — so the CLI keeps stable English headers. Only
    /// the labels vary; every structural token is outside the localised span,
    /// and the transcript body is whatever was said either way.
    static func markdown(_ segments: [Segment], meta: SessionMeta,
                         localized: Bool = true) -> String {
        func t(_ key: String.LocalizationValue, _ english: String) -> String {
            localized ? String(localized: key) : english
        }
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let started = df.string(from: meta.startedAt)
        var out = "# " + t("Transcript — \(started)", "Transcript — \(started)") + "\n\n"
        out += "- " + t("Language", "Language") + ": `\(meta.locale)`\n"
        if let tr = meta.translateTo {
            out += "- " + t("Translated to", "Translated to") + ": `\(tr)`\n"
        }
        out += "- " + t("Lines: \(segments.count)", "Lines: \(segments.count)") + "\n\n---\n\n"
        for seg in segments {
            // A thematic break where ≥2 s of silence preceded the line — the
            // reader sees the floor change hands without anyone claiming to
            // know whose it became.
            if seg.turn == true { out += "---\n\n" }
            let speaker = seg.speaker.map { "**\(SpeakerLabel.displayName(for: $0)):** " } ?? ""
            out += "**\(clock(seg.t0))** \(speaker)\(seg.text)\n"
            if let tr = seg.tr, !tr.isEmpty { out += "> \(tr)\n" }
            out += "\n"
        }
        out += "\n_" + t("Transcribed on device by sAiity.",
                          "Transcribed on device by sAiity.") + "_\n"
        return out
    }

    /// `H:MM:SS` for headings, not the SRT form. Internal — the in-app
    /// transcript viewer stamps its rows with the same clock the Markdown
    /// export uses, so the two never disagree about a line's time.
    static func clock(_ s: Double) -> String {
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
            // A translated segment stays ONE bilingual cue, original over
            // translation — the same pairing txt and Markdown already write.
            // SRT used to be the only export that dropped the translation the
            // user paid a model load and per-sentence latency for. It cannot
            // go through cues(from:): the translation belongs to the whole
            // sentence and has no per-word timings to split along, so a split
            // would either repeat it under every part-cue or orphan it on one.
            if let tr = seg.tr, !tr.isEmpty {
                let speaker = seg.speaker.map { "\(SpeakerLabel.displayName(for: $0)): " } ?? ""
                out += "\(n)\n\(srtTime(seg.t0)) --> \(srtTime(seg.t1))\n\(speaker)\(seg.text)\n\(tr)\n\n"
                n += 1
                continue
            }
            for c in cues(from: seg) {
                let speaker = seg.speaker.map { "\(SpeakerLabel.displayName(for: $0)): " } ?? ""
                out += "\(n)\n\(srtTime(c.t0)) --> \(srtTime(c.t1))\n\(speaker)\(c.text)\n\n"
                n += 1
            }
        }
        return out
    }

    // MARK: - WebVTT

    /// WebVTT wants `HH:MM:SS.mmm` — period where SRT has its comma — and a
    /// file header. Cue identifiers are optional and add nothing here.
    private static func vttTime(_ s: Double) -> String {
        srtTime(s).replacingOccurrences(of: ",", with: ".")
    }

    /// Same cue logic as SRT, same bilingual rule: a translated segment is one
    /// two-line cue, an untranslated one splits along its word timings.
    static func vtt(_ segments: [Segment]) -> String {
        var out = "WEBVTT\n\n"
        for seg in segments {
            if let tr = seg.tr, !tr.isEmpty {
                let speaker = seg.speaker.map { "\(SpeakerLabel.displayName(for: $0)): " } ?? ""
                out += "\(vttTime(seg.t0)) --> \(vttTime(seg.t1))\n\(speaker)\(seg.text)\n\(tr)\n\n"
                continue
            }
            for c in cues(from: seg) {
                let speaker = seg.speaker.map { "\(SpeakerLabel.displayName(for: $0)): " } ?? ""
                out += "\(vttTime(c.t0)) --> \(vttTime(c.t1))\n\(speaker)\(c.text)\n\n"
            }
        }
        return out
    }

    // MARK: - Saving

    /// Write every saved session into one folder, in one format.
    ///
    /// Per-session export answers "give me this meeting"; this answers "give
    /// me everything", which is what someone leaving, archiving, or backing up
    /// actually needs. Filenames carry the date and the session id, so two
    /// meetings on one day cannot collide and the order is the order on disk.
    /// Returns the count written and the first failure, if any.
    @discardableResult
    static func writeLibrary(_ sessions: [SessionRef], format: String, to folder: URL) -> (written: Int, failed: Int) {
        let df = DateFormatter()
        // POSIX, like every other machine-facing formatter here: without it a
        // non-Gregorian regional calendar produces filenames that neither sort
        // nor match the dates shown in the app.
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd-HHmm"
        var written = 0, failed = 0
        for s in sessions {
            let segs = TranscriptStore.segments(of: s)
            let body: String
            switch format {
            case "srt": body = srt(segs)
            case "vtt": body = vtt(segs)
            case "md":  body = markdown(segs, meta: s.meta)
            default:    body = txt(segs)
            }
            let name = "sAiity-\(df.string(from: s.meta.startedAt))-\(s.id).\(format)"
            if write(body, named: name, in: folder) != nil { written += 1 } else { failed += 1 }
        }
        return (written, failed)
    }

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
