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
            var line = seg.text
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
            out += "**\(clock(seg.t0))** \(seg.text)\n"
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

    /// Split one final into subtitle cues.
    ///
    /// Word timings are the good case: the engine said when each word was
    /// spoken, so a break lands where the speaker actually paused. Not every
    /// final has them — the streaming backends time a final from the audio
    /// clock and report no per-word times at all, and an old transcript has
    /// none — and the answer for those used to be the whole final as one cue.
    /// A final can span 15 seconds and four sentences, so that is a cue no
    /// player can read, no editor will accept and no viewer can keep up with.
    /// Hence the second pass: split on text boundaries and interpolate the
    /// times across the span the engine *did* measure. Proportional timing is
    /// an estimate, and pretending otherwise would be the same kind of lie in
    /// the other direction — but it is a much smaller one than a 15-second cue.
    static func cues(from seg: Segment,
                     maxChars: Int = 84, maxDur: Double = 6.0, gap: Double = 0.6)
        -> [(t0: Double, t1: Double, text: String)] {
        if let ws = seg.words, !ws.isEmpty {
            return timedCues(from: ws, maxChars: maxChars, maxDur: maxDur, gap: gap)
        }
        return interpolatedCues(from: seg, maxChars: maxChars, maxDur: maxDur)
    }

    /// The word-timed path: break after a sentence end, after a pause, or when
    /// the cue gets too long or too slow to read.
    private static func timedCues(from ws: [TimedWord],
                                  maxChars: Int, maxDur: Double, gap: Double)
        -> [(t0: Double, t1: Double, text: String)] {
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

    /// Marks a reader would choose to break after: the end of a sentence.
    /// Non-Latin scripts are here because Whisper emits them, and a Chinese or
    /// Japanese transcript has no spaces to fall back on.
    private static let sentenceMarks: Set<Character> = [
        ".", "!", "?", "…", "।", "。", "！", "？", "؟",
    ]
    /// A weaker break, but still a real one: a clause end.
    private static let clauseMarks: Set<Character> = [
        ",", ";", ":", "，", "、", "；", "：", "—", "–",
    ]
    /// Punctuation belonging to the sentence that just ended, not the next one:
    /// a closing quote or bracket takes the break with it.
    private static let closingMarks: Set<Character> = [
        "\"", "'", "”", "’", "»", "›", ")", "]", "」", "』",
    ]

    private struct Piece {
        let text: String
        /// 2 ends a sentence, 1 ends a clause, 0 is only a word boundary.
        let quality: Int
        /// Whether whitespace separated this piece from the previous one, which
        /// is what decides if the two need a space when they are rejoined.
        ///
        /// Only whitespace sets it. A break at a full stop does not, which is
        /// why "One. Two" rejoins with a space and a Chinese sentence rejoins
        /// with nothing between its clauses.
        let spaced: Bool
    }

    /// Cut text at its own boundaries, then at the character budget for whatever
    /// its script does not mark.
    private static func pieces(of text: String, budget: Int) -> [Piece] {
        let chars = Array(text)
        var out: [Piece] = []
        var current = ""
        var spaced = false
        var pendingSpace = false

        func flush(quality: Int) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(Piece(text: trimmed, quality: quality, spaced: spaced)) }
            current = ""
            spaced = pendingSpace
            pendingSpace = false
        }

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                // Set first: the piece that follows a space is the piece that
                // needs the space put back when the cue is rejoined. Flushing
                // first lost it, and "The first sentence" came back as
                // "Thefirst sentence".
                pendingSpace = true
                flush(quality: 0)
                i += 1
                continue
            }
            current.append(ch)
            i += 1
            let sentence = sentenceMarks.contains(ch)
            if sentence {
                // A run of marks and a closing quote belong to the sentence that
                // just ended; breaking between them would open a cue with `”`.
                while i < chars.count,
                      sentenceMarks.contains(chars[i]) || closingMarks.contains(chars[i]) {
                    current.append(chars[i])
                    i += 1
                }
            }
            if current.count >= budget { flush(quality: 0) }
            else if sentence { flush(quality: 2) }
            else if clauseMarks.contains(ch) { flush(quality: 1) }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(Piece(text: current.trimmingCharacters(in: .whitespacesAndNewlines),
                             quality: 0, spaced: spaced))
        }
        return out
    }

    private static func join(_ pieces: [Piece]) -> String {
        var out = ""
        for p in pieces {
            if out.isEmpty { out = p.text }
            else {
                out += p.spaced ? " " : ""
                out += p.text
            }
        }
        return out
    }

    /// Group pieces into cues, preferring a sentence or clause end over a plain
    /// word boundary.
    ///
    /// The budget is tested *before* a piece joins the current cue, not after:
    /// testing after let every cue overshoot by a whole word, which on a
    /// narrow budget is how an 84-character limit quietly became 90.
    private static func groups(_ pieces: [Piece], budget: Int) -> [String] {
        var out: [String] = []
        var current: [Piece] = []
        var width = 0
        // Where each kind of break last offered itself, as a count of pieces in
        // the current cue. A cue forced to end mid-clause should end at the
        // last clause mark rather than at the last space.
        var marked = 0
        var word = 0

        func cut(at count: Int) {
            let text = join(Array(current[..<count]))
            if !text.isEmpty { out.append(text) }
            current = Array(current[count...])
            width = current.reduce(0) { $0 + $1.text.count + 1 }
            marked = current.lastIndex { $0.quality > 0 }.map { $0 + 1 } ?? 0
            word = current.isEmpty ? 0 : current.count
        }

        for piece in pieces {
            if !current.isEmpty, width + piece.text.count + 1 > budget {
                cut(at: marked > 0 ? marked : word)
            }
            current.append(piece)
            width += piece.text.count + 1
            if piece.quality > 0 { marked = current.count } else { word = current.count }
        }
        if !current.isEmpty {
            let text = join(current)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    /// The no-word-timings path: split the text, then spread the segment's own
    /// measured span across the pieces in proportion to their length.
    private static func interpolatedCues(from seg: Segment, maxChars: Int, maxDur: Double)
        -> [(t0: Double, t1: Double, text: String)] {
        let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let span = max(0, seg.t1 - seg.t0)
        // No span of its own, or nothing to divide: there is no timing to
        // interpolate, and one cue is the only answer a player can show.
        guard span > 0, text.count > 1 else { return [(seg.t0, seg.t1, text)] }

        // Characters per second, measured from this segment rather than assumed
        // (the caption overlay's own unhurried-speech figure is 14/second). It
        // turns the reading-time limit into a character budget: a segment of
        // short sentences spread over 15 seconds speaks far slower than that,
        // and a cue sized by characters alone would then claim ten seconds of
        // screen time for six words.
        let rate = Double(text.count) / span
        let budget = max(12, min(maxChars, Int((maxDur * rate).rounded(.down))))

        let grouped = groups(pieces(of: text, budget: budget), budget: budget)
        // Weights are the cue texts themselves, not the original string. The
        // characters dropped as break separators would otherwise be time no cue
        // accounts for, and the last cue would be handed all of it — a final
        // split into four cues ended with one claiming 6.8 seconds of screen
        // time because three preceding breaks had eaten their share.
        let total = Double(grouped.reduce(0) { $0 + $1.count })
        var consumed = 0
        var cursor = seg.t0
        var out: [(Double, Double, String)] = []
        for (index, text) in grouped.enumerated() {
            let t0 = max(cursor, seg.t0 + span * (Double(consumed) / total))
            consumed += text.count
            let isLast = index == grouped.count - 1
            let computed = isLast ? seg.t1 : seg.t0 + span * (Double(consumed) / total)
            // Never a zero-length cue, and never one that starts before the
            // previous ended: some players drop the first, and the second is
            // rejected outright.
            let t1 = max(t0 + 0.001, computed)
            out.append((t0, t1, text))
            cursor = t1
        }
        return out
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
                out += "\(n)\n\(srtTime(seg.t0)) --> \(srtTime(seg.t1))\n\(seg.text)\n\(tr)\n\n"
                n += 1
                continue
            }
            for c in cues(from: seg) {
                out += "\(n)\n\(srtTime(c.t0)) --> \(srtTime(c.t1))\n\(c.text)\n\n"
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
                out += "\(vttTime(seg.t0)) --> \(vttTime(seg.t1))\n\(seg.text)\n\(tr)\n\n"
                continue
            }
            for c in cues(from: seg) {
                out += "\(vttTime(c.t0)) --> \(vttTime(c.t1))\n\(c.text)\n\n"
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
