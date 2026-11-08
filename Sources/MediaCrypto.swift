import Foundation
import CommonCrypto

/// AES-128-CBC 解密（HLS AES-128 使用 CBC + PKCS7）
enum MediaCrypto {
    static func decrypt(data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16, !data.isEmpty else { return nil }
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var outLength = 0
        let inputCount = data.count
        let keyCount = key.count

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            data.withUnsafeBytes { inBytes -> CCCryptorStatus in
                key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                        guard let outPtr = outBytes.baseAddress,
                              let inPtr = inBytes.baseAddress,
                              let keyPtr = keyBytes.baseAddress,
                              let ivPtr = ivBytes.baseAddress else {
                            return CCCryptorStatus(kCCMemoryFailure)
                        }
                        return CCCrypt(CCOperation(kCCDecrypt),
                                       CCAlgorithm(kCCAlgorithmAES),
                                       CCOptions(kCCOptionPKCS7Padding),
                                       keyPtr, keyCount,
                                       ivPtr,
                                       inPtr, inputCount,
                                       outPtr, capacity,
                                       &outLength)
                    }
                }
            }
        }

        guard status == kCCSuccess, outLength > 0, outLength <= capacity else { return nil }
        output.removeSubrange(outLength..<capacity)
        return output
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
