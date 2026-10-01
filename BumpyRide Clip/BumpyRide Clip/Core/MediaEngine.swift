import AVFoundation
import Foundation

@MainActor
final class SourceMedia {
    var record: SourceRecord
    let url: URL
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    let videoRange: CMTimeRange
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let frameRate: Float
    var displaySize: CGSize { CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size }

    private init(record: SourceRecord, url: URL, asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?,
                 videoRange: CMTimeRange, naturalSize: CGSize, transform: CGAffineTransform, frameRate: Float) {
        self.record = record; self.url = url; self.asset = asset; self.video = video; self.audio = audio
        self.videoRange = videoRange; self.naturalSize = naturalSize; self.transform = transform; self.frameRate = frameRate
    }
    static func load(_ url: URL) async throws -> SourceMedia {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ClipError.message("Choose a video file.") }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipError.message("macOS cannot play \(url.lastPathComponent). Convert it to a supported MOV or MP4 and relink it.")
        }
        let range = try await video.load(.timeRange)
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let fps = try await video.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let record = SourceRecord(name: url.lastPathComponent, size: Int64(values.fileSize ?? 0), duration: range.duration.seconds,
                                  mtimeMs: values.contentModificationDate.map { $0.timeIntervalSince1970 * 1000 })
        try record.validate()
        return SourceMedia(record: record, url: url, asset: asset, video: video, audio: audio,
                           videoRange: range, naturalSize: size, transform: transform, frameRate: fps)
    }
    func verifyUnchanged() throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let modified = values.contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }
        guard Int64(values.fileSize ?? -1) == record.size, modified == record.mtimeMs else {
            throw ClipError.message("\(record.name) changed or moved. Relink the original video before continuing.")
        }
    }
}

@MainActor
struct ComposedClip {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        return item
    }
}

@MainActor
enum MediaEngine {
    static func compose(parts: [ClipPart], sources: [UUID: SourceMedia]) async throws -> ComposedClip {
        guard let firstPart = parts.first, let first = sources[firstPart.sourceID] else {
            throw ClipError.message("Relink the source videos first.")
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipError.message("Could not create a video composition.")
        }
        let hasAudio = parts.contains { sources[$0.sourceID]?.audio != nil }
        let audioTrack = hasAudio ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let size = CGSize(width: max(2, floor(first.displaySize.width / 2) * 2), height: max(2, floor(first.displaySize.height / 2) * 2))
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        let fps = first.frameRate.isFinite && first.frameRate > 0 ? Double(first.frameRate) : 30
        videoComposition.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for part in parts {
            try Task.checkCancellation()
            guard let source = sources[part.sourceID] else { throw ClipError.message("A source video is missing.") }
            try source.verifyUnchanged()
            guard part.offset.isFinite, part.duration.isFinite, part.offset >= 0, part.duration > 0,
                  part.offset + part.duration <= source.record.duration + 0.01 else { throw ClipError.message("Invalid clip range.") }
            let duration = CMTime(seconds: part.duration, preferredTimescale: 60_000)
            let start = source.videoRange.start + CMTime(seconds: part.offset, preferredTimescale: 60_000)
            let range = CMTimeRange(start: start, duration: duration)
            try videoTrack.insertTimeRange(range, of: source.video, at: cursor)
            if let audio = source.audio, let audioTrack {
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if overlap.isValid && overlap.duration.seconds > 0 {
                    try audioTrack.insertTimeRange(overlap, of: audio, at: cursor + overlap.start - range.start)
                }
            }
            let bounds = CGRect(origin: .zero, size: source.naturalSize).applying(source.transform).standardized
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let normalized = source.transform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - bounds.width * scale) / 2,
                                               y: (size.height - bounds.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(normalized, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            instruction.layerInstructions = [layer]
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instructions.append(instruction)
            cursor = cursor + duration
        }
        videoComposition.instructions = instructions
        return ComposedClip(asset: composition, videoComposition: videoComposition)
    }

    static func export(_ clip: ComposedClip, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: clip.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipError.message("macOS could not create an MP4 export session.")
        }
        session.videoComposition = clip.videoComposition
        session.shouldOptimizeForNetworkUse = true
        let observer = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let stateProgress) = state { progress(stateProgress.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        do {
            try await session.export(to: url, as: .mp4)
            try Task.checkCancellation()
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
