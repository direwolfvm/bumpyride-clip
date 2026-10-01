import Testing
import AVFoundation
import Foundation
@testable import ClipCore

@MainActor
struct MediaEngineTests {
    @Test func generatedSampleSupportsReviewExportAndMetadataOnlyReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.mp4")
        try await SampleProject.generate(at: url)
        let source = try await SourceMedia.load(url)
        #expect(abs(source.record.duration - Double(SampleProject.duration)) < 0.11)
        #expect(source.record.size < 5_000_000)
        var project = try SampleProject.make()
        project.sources = [source.record]
        project.edits["sample-custom"] = ClipEdit(before: 4, after: 3, selected: true, reviewed: true)
        let data = try ClipDates.encoder().encode(project)
        #expect(data.count < 10_000)
        #expect(!String(decoding: data, as: UTF8.self).contains(directory.path))
        let reopened = try ClipDates.decoder().decode(ClipProject.self, from: data)
        #expect(reopened.demoVersion == 1)
        #expect(reopened.edits == project.edits)
        for report in reopened.ride.events {
            let plan = try ClipTimeline.resolve(report, edit: reopened.edits[report.id] ?? ClipEdit(), videoStart: try #require(reopened.videoStart), sources: reopened.sources)
            #expect(plan.available)
        }
        let composition = try await MediaEngine.compose(parts: [ClipPart(sourceID: source.record.id, offset: 19, duration: 2)], sources: [source.record.id: source])
        let output = directory.appendingPathComponent("sample-clip.mp4")
        try await MediaEngine.export(composition, to: output) { _ in }
        let exported = try await SourceMedia.load(output)
        #expect(abs(exported.record.duration - 2) < 0.1)
    }
    private func fixture(at url: URL, width: Int, height: Int, fps: Int, blue: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(fps * 3) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<height { for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = 255; bytes[offset + 1] = blue ? 0 : 255; bytes[offset + 2] = 0; bytes[offset + 3] = blue ? 255 : 0
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error! }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        #expect(writer.status == .completed)
    }
    @Test func exportsAcrossDifferentFileSizesAndFrameRates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let redURL = directory.appendingPathComponent("red.mov"), blueURL = directory.appendingPathComponent("blue.mov")
        try await fixture(at: redURL, width: 320, height: 180, fps: 24, blue: false)
        try await fixture(at: blueURL, width: 240, height: 320, fps: 30, blue: true)
        let red = try await SourceMedia.load(redURL), blue = try await SourceMedia.load(blueURL)
        let composition = try await MediaEngine.compose(parts: [ClipPart(sourceID: red.record.id, offset: 2, duration: 1), ClipPart(sourceID: blue.record.id, offset: 0, duration: 1)], sources: [red.record.id: red, blue.record.id: blue])
        let output = directory.appendingPathComponent("clip.mp4")
        try await MediaEngine.export(composition, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 2) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        let generator = AVAssetImageGenerator(asset: asset)
        for (time, isBlue) in [(0.5, false), (1.5, true)] {
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(result.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            #expect(isBlue ? pixel[2] > pixel[0] : pixel[0] > pixel[2])
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: redURL.path)
        #expect(throws: (any Error).self) { try red.verifyUnchanged() }
    }
    // External test footage is opt-in and is never a SwiftPM or Xcode resource.
    @Test func sampleCameraBoundaryPreservesAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["BUMPYRIDE_SAMPLE_VIDEO_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        let first = try await SourceMedia.load(directory.appendingPathComponent("20260902_114922.MOV"))
        let second = try await SourceMedia.load(directory.appendingPathComponent("20260902_120600.MOV"))
        #expect(first.record.duration == 996.5)
        let clip = try await MediaEngine.compose(parts: [ClipPart(sourceID: first.record.id, offset: first.record.duration - 1, duration: 1), ClipPart(sourceID: second.record.id, offset: 0, duration: 1)], sources: [first.record.id: first, second.record.id: second])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bumpyride-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await MediaEngine.export(clip, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(try await audio.load(.timeRange).duration.seconds > 1.9)
    }
}
