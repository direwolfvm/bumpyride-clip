import AppKit
import AVFoundation

/// Small, synthetic footage generated on demand. No camera files or GPS data ship.
@MainActor
enum SampleProject {
    static let duration = 70
    static func make() throws -> ClipProject {
        let json = """
        {"id":"bumpyride-clip-sample-v1","title":"Sample ride — synthetic footage",
        "startedAt":"2026-01-01T12:00:00Z","endedAt":"2026-01-01T12:01:10Z",
        "closeCallEvents":[{"id":"sample-close","timestamp":"2026-01-01T12:00:20Z","category":"vehicle"}],
        "otherEvents":[{"id":"sample-sync","timestamp":"2026-01-01T12:00:00Z","kind":"Video Sync","isCustom":true},
        {"id":"sample-blocked","timestamp":"2026-01-01T12:00:40Z","kind":"blocked-lane","isCustom":false},
        {"id":"sample-custom","timestamp":"2026-01-01T12:01:00Z","kind":"Pothole","isCustom":true}]}
        """
        var project = ClipProject(ride: try ClipDates.decoder().decode(RideData.self, from: Data(json.utf8)))
        project.demoVersion = 1
        return project
    }

    static func generate(at url: URL) async throws {
        let width = 640, height = 360, fps = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ClipError.message("Could not generate sample video.") }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<(duration * fps) {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? ClipError.message("Sample generation stopped.") }
                    try await Task.sleep(for: .milliseconds(5))
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let pixel = buffer else { throw ClipError.message("Could not allocate sample frame.") }
                CVPixelBufferLockBaseAddress(pixel, [])
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                    CVPixelBufferUnlockBaseAddress(pixel, [])
                    throw ClipError.message("Could not draw sample frame.")
                }
                draw(context, seconds: Double(frame) / Double(fps))
                CVPixelBufferUnlockBaseAddress(pixel, [])
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                    throw writer.error ?? ClipError.message("Could not write sample frame.")
                }
                if frame % fps == 0 { await Task.yield() }
            }
            input.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ClipError.message("Sample video did not finish.") }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func draw(_ context: CGContext, seconds: Double) {
        context.setFillColor(CGColor(red: 0.06, green: 0.14, blue: 0.23, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 0.11, green: 0.23, blue: 0.28, alpha: 1))
        context.fill(CGRect(x: 0, y: 75, width: 640, height: 145))
        context.setFillColor(CGColor(red: 0.3, green: 0.89, blue: 0.64, alpha: 1))
        context.fill(CGRect(x: 0, y: 92, width: 640, height: 3))
        for index in -1..<9 {
            let x = Double(index * 90) - (seconds * 65).truncatingRemainder(dividingBy: 90)
            context.fill(CGRect(x: x, y: 155, width: 45, height: 3))
        }
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(4)
        for x in [270, 345] { context.strokeEllipse(in: CGRect(x: x, y: 109, width: 37, height: 37)) }
        context.move(to: CGPoint(x: 289, y: 128)); context.addLine(to: CGPoint(x: 308, y: 163))
        context.addLine(to: CGPoint(x: 334, y: 128)); context.addLine(to: CGPoint(x: 289, y: 128))
        context.addLine(to: CGPoint(x: 347, y: 163)); context.addLine(to: CGPoint(x: 364, y: 128)); context.strokePath()
        let moments = [(20.0, "Close call"), (40.0, "Blocked lane"), (60.0, "Pothole")]
        let event = moments.first { abs($0.0 - seconds) < 1 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        func text(_ string: String, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = .white) {
            (string as NSString).draw(at: CGPoint(x: 28, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
        }
        text("BumpyRide Clip · sample ride", 306, 25)
        text("SYNTHETIC VIDEO · GENERATED ON THIS MAC", 277, 12, .lightGray)
        text(event.map { "Report recorded: \($0.1)" } ?? "Try trimming, calibration, and exporting a clip", 37, 19)
        text(String(format: "Recording %02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)), 242, 17)
        NSGraphicsContext.restoreGraphicsState()
    }
}
