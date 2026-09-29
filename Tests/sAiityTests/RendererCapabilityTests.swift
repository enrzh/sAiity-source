import SwiftUI
import Testing

@testable import sAiity

/// Probes whether `ImageRenderer` can render anything in this process at all.
///
/// The first attempt at design review produced SwiftUI's "view not supported
/// here" placeholder — the yellow field with the prohibition sign — for every
/// settings pane. That distinguishes two very different problems, and the fix
/// is different for each:
///
///   - if a trivial view also renders as the placeholder, `ImageRenderer`
///     cannot work without a full app context, and the answer is Screen
///     Recording permission plus a live window;
///   - if a trivial view renders, the problem is the specific hierarchy
///     (a sidebar `List` plus window chrome), and leaf views can still be
///     rendered individually.
///
/// Worth knowing which, because "grant a permission" and "restructure the
/// review harness" are very different asks.
@Suite("Renderer capability")
struct RendererCapabilityTests {
    @Test("A trivial view renders to real pixels", .timeLimit(.minutes(2)))
    @MainActor
    func trivialViewRenders() throws {
        let view = VStack(spacing: 8) {
            Text("sAiity").font(.largeTitle.bold())
            Text("renderer probe").foregroundStyle(.secondary)
            HStack {
                Image(systemName: "captions.bubble")
                Image(systemName: "mic")
                Image(systemName: "shippingbox")
            }
            .font(.title2)
        }
        .padding(24)
        .frame(width: 320, height: 140)
        .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image at all")
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saiity-renderer-probe.png")
        try png.write(to: url)
        print("PROBE wrote \(url.path) (\(png.count) bytes)")

        // A real render has many distinct pixel values; SwiftUI's unsupported
        // placeholder is two flat colours and a fixed symbol, so it is nearly
        // uniform. Count distinct values rather than trusting the byte count.
        var distinct = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = UInt32(c.redComponent * 255)
                    let g = UInt32(c.greenComponent * 255)
                    let b = UInt32(c.blueComponent * 255)
                    distinct.insert(r << 16 | g << 8 | b)
                }
            }
        }
        print("PROBE distinct sampled colours: \(distinct.count)")
        #expect(distinct.count > 8,
                "only \(distinct.count) distinct colours — this is the placeholder, not a real render")
    }
}
