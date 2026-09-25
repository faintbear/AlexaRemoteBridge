import COpus
import Foundation

final class OpusRecorder {
    private let decoder: OpaquePointer
    private let destination: URL?
    private var pcm = Data()
    private(set) var decodedFrames = 0

    init(path: String?) throws {
        var error: Int32 = 0
        guard let decoder = opus_decoder_create(16_000, 1, &error), error == OPUS_OK else {
            throw RecorderError.decoder(error)
        }
        self.decoder = decoder
        destination = path.map { URL(fileURLWithPath: $0) }
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    func start() {
        pcm.removeAll(keepingCapacity: true)
        decodedFrames = 0
        _ = opus_decoder_init(decoder, 16_000, 1)
    }

    func appendFrame(_ bytes: UnsafePointer<UInt8>, count: Int) -> [Int16]? {
        guard count == 80 else { return nil }
        var samples = [Int16](repeating: 0, count: 320)
        let decoded = samples.withUnsafeMutableBufferPointer { output in
            opus_decode(decoder, bytes, Int32(count), output.baseAddress!, 320, 0)
        }
        guard decoded > 0 else {
            fputs("opus_decode_failed code=\(decoded)\n", stderr)
            return nil
        }
        if destination != nil {
            samples.withUnsafeBufferPointer { buffer in
                pcm.append(contentsOf: UnsafeRawBufferPointer(start: buffer.baseAddress, count: Int(decoded) * 2))
            }
        }
        decodedFrames += 1
        return Array(samples.prefix(Int(decoded)))
    }

    func finish() throws {
        guard let destination, !pcm.isEmpty else { return }
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLE(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt32(16_000))
        wav.appendLE(UInt32(32_000))
        wav.appendLE(UInt16(2))
        wav.appendLE(UInt16(16))
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLE(UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: destination, options: .atomic)
        print("wav_saved path=\(destination.path) samples=\(pcm.count / 2) decoded_frames=\(decodedFrames)")
        fflush(stdout)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private enum RecorderError: Error {
    case decoder(Int32)
}
