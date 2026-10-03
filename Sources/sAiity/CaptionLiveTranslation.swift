import Foundation

/// Coalesces revisable subtitle text, retaining one decode and one newest request.
@MainActor
final class CaptionLiveTranslation {
    struct Pacing {
        private(set) var samples = 0
        private(set) var decodeSeconds = 0.0

        mutating func record(seconds: Double) {
            guard seconds.isFinite, seconds >= 0 else { return }
            decodeSeconds = samples == 0 ? seconds : decodeSeconds * 0.75 + seconds * 0.25
            samples = min(3, samples + 1)
        }

        func delay(base: Duration, resourceLimited: Bool) -> Duration {
            var wait = resourceLimited ? max(base, .milliseconds(1500)) : base
            if samples >= 3, decodeSeconds > 1 { wait = max(wait, .seconds(min(2, decodeSeconds))) }
            return wait
        }
    }

    nonisolated static var systemResourceLimited: Bool {
        let system = ProcessInfo.processInfo
        return system.isLowPowerModeEnabled || system.thermalState == .serious || system.thermalState == .critical
    }
    struct Request: Equatable, Sendable {
        let text: String
        let sentenceID: Int
        let sessionGeneration: Int
        let translatorGeneration: Int
        let source: String
        let target: String
        let engine: TranslationEngine
    }

    private let delay: Duration
    private let resourceLimited: () -> Bool
    private var pacing = Pacing()
    private var pacingEngine: TranslationEngine?
    private let isCurrent: (Request) -> Bool
    private let translate: (Request) async -> String?
    private let display: (String, Request) -> Void
    private var pending: Request?
    private var lastSubmitted: Request?
    private var task: Task<Void, Never>?
    var isBusy: Bool { task != nil }

    init(delay: Duration = .milliseconds(400),
         resourceLimited: @escaping () -> Bool = { CaptionLiveTranslation.systemResourceLimited },
         isCurrent: @escaping (Request) -> Bool,
         translate: @escaping (Request) async -> String?,
         display: @escaping (String, Request) -> Void) {
        self.delay = delay
        self.resourceLimited = resourceLimited
        self.isCurrent = isCurrent
        self.translate = translate
        self.display = display
    }

    func submit(_ request: Request) {
        guard request != lastSubmitted else { return }
        if pacingEngine != request.engine {
            pacing = Pacing()
            pacingEngine = request.engine
        }
        lastSubmitted = request
        pending = request
        if task == nil { start() }
    }

    /// Cancellation drains native work before another request can take its slot.
    func invalidate() {
        pending = nil
        lastSubmitted = nil
        task?.cancel()
    }

    func stop() async {
        invalidate()
        await task?.value
    }

    private func start() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                if self.pending != nil { self.start() }
            }
            while self.pending != nil, !Task.isCancelled {
                // A fixed window, rather than resetting on each word: continuous
                // speech must produce updates instead of starving a debounce.
                let wait = self.pacing.delay(base: self.delay, resourceLimited: self.resourceLimited())
                let components = wait.components
                Diagnostics.recordTiming(operation: "captions.translation.preview-delay",
                                         seconds: Double(components.seconds) + Double(components.attoseconds) / 1e18,
                                         cold: false)
                do { try await Task.sleep(for: wait) }
                catch { return }
                guard let request = self.pending else { return }
                self.pending = nil
                guard self.isCurrent(request) else { continue }
                let began = ContinuousClock.now
                let output = await self.translate(request)
                guard !Task.isCancelled else { return }
                let elapsed = began.duration(to: .now).components
                if self.pacingEngine == request.engine {
                    self.pacing.record(seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                }
                if let output, self.isCurrent(request) { self.display(output, request) }
            }
        }
    }
}
