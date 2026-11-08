import Foundation

/// 把分片目录里的 TS 直接重封装为 MP4（无解码、无重编码）
enum TSRemuxPipeline {
    struct PipelineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func remux(state: SegmentJobState,
                      dir: URL,
                      destination: URL,
                      progress: ((Double) -> Void)? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(state: state, dir: dir, destination: destination, progress: progress)
        }.value
    }

    private static func run(state: SegmentJobState,
                            dir: URL,
                            destination: URL,
                            progress: ((Double) -> Void)?) throws {
        let demuxer = TSDemuxer()
        var writer: MP4Writer?
        var videoInfo: TSDemuxer.VideoInfo?
        var audioInfo: TSDemuxer.AudioInfo?
        var pendingAudio: [Data] = []
        var lastDTS: Int64 = -1
        var framesWritten = 0
        var failure: String?

        demuxer.onInfo = { video, audio in
            if let video { videoInfo = video }
            if let audio { audioInfo = audio }
        }

        demuxer.onVideoFrame = { data, pts, dts, isKey in
            guard failure == nil, let info = videoInfo else { return }
            if writer == nil {
                do {
                    let newWriter = try MP4Writer(url: destination, video: info, audio: audioInfo)
                    for audioData in pendingAudio { try newWriter.appendAudio(audioData) }
                    pendingAudio.removeAll()
                    writer = newWriter
                } catch {
                    failure = error.localizedDescription
                    return
                }
            }
            var useDTS = dts >= 0 ? dts : pts
            if useDTS <= lastDTS { useDTS = lastDTS + 3003 } // 保证单调，避免 stts 为 0
            lastDTS = useDTS
            do {
                try writer?.appendVideo(data, pts: pts >= 0 ? pts : useDTS, dts: useDTS, isKey: isKey)
                framesWritten += 1
            } catch {
                failure = error.localizedDescription
            }
        }

        demuxer.onAudioFrame = { data, _ in
            guard failure == nil else { return }
            if let writer {
                try? writer.appendAudio(data)
            } else {
                pendingAudio.append(data)
            }
        }

        let fm = FileManager.default
        let total = max(1, state.segmentURLs.count)
        for index in state.durations.indices {
            if failure != nil { break }
            let fileURL = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard fm.fileExists(atPath: fileURL.path) else {
                throw PipelineError(message: "缺少分片 \(index + 1)")
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                demuxer.consume(chunk)
                if failure != nil { break }
            }
            try? handle.close()
            progress?(Double(index + 1) / Double(total))
        }

        demuxer.finish()

        if let failure {
            writer?.abort()
            throw PipelineError(message: "转封装失败：\(failure)")
        }
        guard let writer else {
            throw PipelineError(message: "转封装失败：没有解析出视频轨道（可能不是 H.264 编码）")
        }
        guard framesWritten > 0 else {
            writer.abort()
            throw PipelineError(message: "转封装失败：没有写入任何视频帧")
        }
        do {
            try writer.finish()
        } catch {
            writer.abort()
            throw PipelineError(message: "写入 MP4 失败：\(error.localizedDescription)")
        }
    }
}
