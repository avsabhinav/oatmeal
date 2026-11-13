import Foundation

// 16 kHz mono 16-bit PCM WAV writer.
// - Incremental: samples are appended to the file as they arrive.
// - Thread-safe: append() may be called from any thread (audio callbacks);
//   all file I/O happens on an internal serial queue.
// - Crash-tolerant: the RIFF/data sizes in the header are patched about once
//   per second, so a killed process still leaves a playable file.
final class WavWriter {
    let path: String
    let sampleRate: UInt32
    private let fd: Int32
    private let q: DispatchQueue
    private var dataBytes: UInt32 = 0
    private var lastPatch = CFAbsoluteTimeGetCurrent()
    private var closed = false
    private var _peak: Int = 0
    private var _rmsSumSq: Double = 0
    private var _sampleCount = 0

    init(path: String, sampleRate: UInt32 = 16000) throws {
        self.path = path
        self.sampleRate = sampleRate
        self.q = DispatchQueue(label: "wav.\((path as NSString).lastPathComponent)")
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: "WavWriter", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "open failed: \(path)"])
        }
        writeHeader()
    }

    /// Number of 16-bit samples written so far (thread-safe).
    var samplesWritten: Int { q.sync { Int(dataBytes / 2) } }

    /// Duration written so far, seconds.
    var durationSeconds: Double { Double(samplesWritten) / Double(sampleRate) }

    /// Peak absolute 16-bit sample value of everything appended (0 = silent).
    var peakAmplitude: Int { q.sync { _peak } }

    /// Sum of squared 16-bit sample values of everything appended.
    var rmsNumerator: Double { q.sync { _rmsSumSq } }

    /// RMS amplitude normalized to 0...1 (32768 full scale); 0.0 when nothing was written.
    var rmsAmplitude: Double {
        let count = q.sync { _sampleCount }
        guard count > 0 else { return 0.0 }
        return sqrt(rmsNumerator / Double(count)) / 32768.0
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        q.async { [self] in
            guard !closed else { return }
            // Level tracking on the same 16-bit scale that is written.
            var bufPeak = 0
            var bufSumSq = 0.0
            for s in samples {
                let a = abs(Int(s))
                if a > bufPeak { bufPeak = a }
                let d = Double(s)
                bufSumSq += d * d
            }
            if bufPeak > _peak { _peak = bufPeak }
            _rmsSumSq += bufSumSq
            _sampleCount += samples.count
            samples.withUnsafeBytes { p in
                var off = 0
                while off < p.count {
                    let n = write(fd, p.baseAddress!.advanced(by: off), p.count - off)
                    if n <= 0 { break }
                    off += n
                }
                dataBytes = min(dataBytes &+ UInt32(off), 0xFFFF_FFFF - 36)
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPatch > 1.0 { patchSizes(); lastPatch = now }
        }
    }

    /// Flush pending writes, finalize the header and close. Idempotent.
    func close() {
        q.sync {
            guard !closed else { return }
            closed = true
            patchSizes()
            fsync(fd)
            Darwin.close(fd)
        }
    }

    // MARK: header

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    private func writeHeader() {
        var h = [UInt8]()
        h += Array("RIFF".utf8); h += Self.le32(36)
        h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); h += Self.le32(16)
        h += Self.le16(1)                 // PCM
        h += Self.le16(1)                 // mono
        h += Self.le32(sampleRate)
        h += Self.le32(sampleRate * 2)    // byte rate
        h += Self.le16(2)                 // block align
        h += Self.le16(16)                // bits per sample
        h += Array("data".utf8); h += Self.le32(0)
        precondition(h.count == 44)
        h.withUnsafeBytes { _ = pwrite(fd, $0.baseAddress!, 44, 0) }
        lseek(fd, 44, SEEK_SET)
    }

    private func patchSizes() {
        Self.le32(36 + dataBytes).withUnsafeBytes { _ = pwrite(fd, $0.baseAddress!, 4, 4) }
        Self.le32(dataBytes).withUnsafeBytes { _ = pwrite(fd, $0.baseAddress!, 4, 40) }
    }
}
