import Foundation

/// 下载前编码预检：判断源是否为 iOS 不支持的 10-bit H.264（High 10 / High 4:2:2 / High 4:4:4）
enum CodecProbe {
    struct Verdict {
        var supported: Bool
        var detail: String
        var codec: String?
        static func ok(_ detail: String, codec: String? = nil) -> Verdict {
            Verdict(supported: true, detail: detail, codec: codec)
        }
        static func reject(_ detail: String, codec: String? = nil) -> Verdict {
            Verdict(supported: false, detail: detail, codec: codec)
        }
        static func unknown(_ detail: String) -> Verdict {
            Verdict(supported: true, detail: detail, codec: nil)
        }
    }

    /// 不支持的 profile_idc：110 High10 / 122 High422 / 244 High444
    private static let unsupportedProfiles: Set<UInt8> = [110, 122, 244]

    // MARK: - 远程探测（下载前）

    /// codecsHint 来自主播放列表的 CODECS 属性；为空时再抓首段 SPS
    static func probe(playlistURL: URL, codecsHint: String?) async -> Verdict {
        if let hint = codecsHint, !hint.isEmpty {
            let lowered = hint.lowercased()
            if lowered.contains("avc1.6e") {
                return .reject("H.264 High 10（10-bit）", codec: hint)
            }
            if lowered.contains("avc1.7a") || lowered.contains("avc1.f4") {
                return .reject("H.264 高位深（10-bit 以上）", codec: hint)
            }
            if lowered.contains("avc1.") {
                return .ok("H.264 8-bit", codec: hint)
            }
        }

        // 无 CODECS：拉取播放列表 → 首个分片头部 → SPS
        guard let playlist = try? await PlaylistParser.load(playlistURL) else {
            return .unknown("无法解析播放列表")
        }
        guard let first = playlist.segments.first else {
            return .unknown("播放列表里没有分片")
        }
        if playlist.isEncrypted {
            if let key = playlist.key, key.method.uppercased() == "AES-128",
               let verdict = await probeEncrypted(playlist: playlist,
                                                  segmentURL: first.url,
                                                  keyURI: key.uri,
                                                  iv: key.iv,
                                                  mediaSequence: playlist.mediaSequence) {
                return verdict
            }
            return .unknown("加密源无法预判编码")
        }

        var request = URLRequest(url: first.url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        for (key, value) in RequestSettings.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
            return .unknown("首段拉取失败")
        }

        if let profile = videoProfile(fromTS: data) {
            return verdict(for: profile)
        }
        // fMP4 源：init 段里的 avcC
        if let initURL = playlist.initSegment,
           let (initData, _) = try? await URLSession.shared.data(from: initURL),
           let profile = videoProfile(fromAVCC: initData) {
            return verdict(for: profile)
        }
        return .unknown("无法识别编码（已下载片段不足以解析）")
    }

    // MARK: - 加密源探测（AES-128）

    /// 拉 KEY → 解密首段 → 解析 SPS。IV 缺失时按 HLS 规范用媒体序列号推导
    private static func probeEncrypted(playlist: ParsedMediaPlaylist,
                                       segmentURL: URL,
                                       keyURI: URL,
                                       iv: Data?,
                                       mediaSequence: Int) async -> Verdict? {
        var keyRequest = URLRequest(url: keyURI)
        keyRequest.timeoutInterval = 8
        for (name, value) in RequestSettings.headers {
            keyRequest.setValue(value, forHTTPHeaderField: name)
        }
        guard let (keyData, keyResponse) = try? await URLSession.shared.data(for: keyRequest),
              let keyHTTP = keyResponse as? HTTPURLResponse,
              (200..<300).contains(keyHTTP.statusCode),
              keyData.count == 16 else {
            DiagnosticsLog.write("[编码预检] KEY 获取失败 \(keyURI.lastPathComponent)")
            return nil
        }

        var segmentRequest = URLRequest(url: segmentURL)
        segmentRequest.timeoutInterval = 10
        segmentRequest.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        for (name, value) in RequestSettings.headers {
            segmentRequest.setValue(value, forHTTPHeaderField: name)
        }
        guard let (cipher, response) = try? await URLSession.shared.data(for: segmentRequest),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
            DiagnosticsLog.write("[编码预检] 加密首段拉取失败")
            return nil
        }

        let ivData = iv ?? derivedIV(mediaSequence: mediaSequence)
        // CBC 要求整块对齐
        let aligned = cipher.count - (cipher.count % 16)
        guard aligned > 0,
              let plain = MediaCrypto.decrypt(data: cipher.prefix(aligned), key: keyData, iv: ivData),
              let profile = videoProfile(fromTS: plain) else {
            DiagnosticsLog.write("[编码预检] 解密后仍无法解析 SPS（可能为 SAMPLE-AES）")
            return nil
        }
        return verdict(for: profile)
    }

    /// IV 缺失时：媒体序列号作为 128 位大端整数
    private static func derivedIV(mediaSequence: Int) -> Data {
        var bytes = Data(repeating: 0, count: 16)
        var sequence = UInt64(max(0, mediaSequence)).bigEndian
        withUnsafeBytes(of: &sequence) { buffer in
            for index in 0..<8 {
                bytes[8 + index] = buffer[index]
            }
        }
        return bytes
    }

    // MARK: - 本地探测（转换前）

    static func probeLocal(dir: URL) -> Verdict {
        for index in 0..<3 {
            let url = dir.appendingPathComponent(LocalHLS.fileName(index: index))
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let demuxer = TSDemuxer()
            var consumed = 0
            while consumed < 2 << 20 {
                guard let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
                demuxer.consume(chunk)
                consumed += chunk.count
                if let info = demuxer.videoInfo() {
                    return verdict(for: info.profileLevel.0, size: "\(info.width)x\(info.height)")
                }
            }
        }
        return .unknown("本地分片无法解析编码")
    }

    // MARK: - 解析

    private static func verdict(for profile: UInt8, size: String? = nil) -> Verdict {
        let name = profileName(profile)
        let suffix = size.map { " \($0)" } ?? ""
        if unsupportedProfiles.contains(profile) {
            return .reject("H.264 \(name)（10-bit）\(suffix)", codec: "profile=\(profile)")
        }
        return .ok("H.264 \(name)\(suffix)", codec: "profile=\(profile)")
    }

    private static func profileName(_ profile: UInt8) -> String {
        switch profile {
        case 66: return "Baseline"
        case 77: return "Main"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4"
        default: return "profile \(profile)"
        }
    }

    /// 从 TS 字节流中取首个视频 SPS 的 profile_idc
    private static func videoProfile(fromTS data: Data) -> UInt8? {
        let demuxer = TSDemuxer()
        demuxer.consume(data)
        return demuxer.videoInfo()?.profileLevel.0
    }

    /// 从 fMP4 init 段中取 avcC 的 profile_idc（avcC 前 5 字节为 version/profile/compat/level/…）
    private static func videoProfile(fromAVCC data: Data) -> UInt8? {
        guard let range = data.range(of: Data("avcC".utf8)), range.count == 4 else { return nil }
        let offset = data.distance(from: data.startIndex, to: range.upperBound)
        guard offset + 5 <= data.count else { return nil }
        return data[data.startIndex + offset + 1]
    }
}
