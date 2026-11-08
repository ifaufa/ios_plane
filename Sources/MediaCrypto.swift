import Foundation
import CommonCrypto

/// AES-128-CBC 解密（HLS AES-128 使用 CBC + PKCS7）
enum MediaCrypto {
    static func decrypt(data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16 else { return nil }
        var outLength = 0
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outPtr = outBytes.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return data.withUnsafeBytes { inBytes -> CCCryptorStatus in
                guard let inPtr = inBytes.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
                return key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                inPtr, data.count,
                                outPtr, out.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength..<out.count)
        return out
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
