import Foundation

// mr-capture — spike: system audio (process tap) + mic (AVAudioEngine, raw) -> 16 kHz mono WAVs.
// Usage: mr-capture --out <dir>
// Runs until SIGINT/SIGTERM, then finalizes the WAVs and exits 0.

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("mr-capture: " + msg + "\n").utf8))
    exit(code)
}
func log(_ msg: String) { FileHandle.standardError.write(Data((msg + "\n").utf8)) }

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())
var outArg: String?
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--out" {
        guard i + 1 < args.count else { die("usage: mr-capture --out <dir>", 2) }
        outArg = (args[i + 1] as NSString).expandingTildeInPath
        i += 2
    } else {
        die("usage: mr-capture --out <dir>", 2)
    }
}
guard let outDir = outArg else { die("usage: mr-capture --out <dir>", 2) }
do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
} catch { die("cannot create \(outDir): \(error)", 2) }

// MARK: - Start capture

// Mic first (TCC prompt, if any, happens here), then the system tap.
//
// These do NOT start at the same time: the mic begins writing as soon as
// engine.start() returns, while the tap then runs five blocking Core Audio
// calls before its first buffer arrives. Measured first-sample deltas run
// from 0.09 s to 10.5 s. `captureStart` is the common t=0 the per-stream
// timings below are reported against.
let captureStart = CFAbsoluteTimeGetCurrent()
func sinceStart() -> Double { (CFAbsoluteTimeGetCurrent() - captureStart) * 1000 }

let mic: MicCapture
do { mic = try MicCapture(outPath: outDir + "/mic.wav") } catch { die("\(error)") }
do { try mic.start() } catch {
    mic.writer.close()
    die("mic: \(error)")
}
log("mic: \(mic.deviceName) @ \(mic.nativeSampleRate) Hz x\(mic.nativeChannels)")
log(String(format: "timing: mic.start() returned at +%.0f ms", sinceStart()))

let systemWriter: WavWriter
do { systemWriter = try WavWriter(path: outDir + "/system.wav") } catch { die("\(error)") }
let system = SystemTapCapture(writer: systemWriter)
let tapStartBegan = sinceStart()
do { try system.start() } catch { die("system tap: \(error)") }
log("system: \(system.deviceName) @ \(system.nativeSampleRate) Hz x\(system.nativeChannels)")
log(String(format: "timing: system.start() began at +%.0f ms, returned at +%.0f ms",
           tapStartBegan, sinceStart()))
for (label, ms) in system.startStepMillis {
    log(String(format: "timing:   %@ %.0f ms", label, ms))
}
log("recording to \(outDir) — Ctrl-C to stop")

// MARK: - Stop on SIGINT / SIGTERM

func machToSeconds(_ t: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(t) * Double(info.numer) / Double(info.denom) / 1_000_000_000.0
}

func writeMeta(_ dir: String) {
    let sw = mic.writer.samplesWritten
    let ow = systemWriter.samplesWritten
    let firstMicHost = mic.firstSampleHostTime                 // mach UInt64
    let firstSysHost = system.firstSampleHostTime              // mach UInt64
    let meta: [String: Any] = [
        "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
        "aec": false,
        "started_at": ISO8601DateFormatter().string(from: Date()),
        "duration_seconds": max(mic.writer.durationSeconds, systemWriter.durationSeconds),
        "mic": [
            "device_name": mic.deviceName,
            "native_sample_rate": mic.nativeSampleRate,
            "native_channels": mic.nativeChannels,
            "first_sample_seconds": (firstMicHost != nil) ? machToSeconds(firstMicHost!) : 0,
            "samples_written": sw,
            "peak": mic.writer.peakAmplitude,
            "rms": mic.writer.rmsAmplitude,
        ],
        "system": [
            "device_name": system.deviceName,
            "native_sample_rate": system.nativeSampleRate,
            "native_channels": system.nativeChannels,
            "first_sample_seconds": (firstSysHost != nil) ? machToSeconds(firstSysHost!) : 0,
            "samples_written": ow,
            "peak": systemWriter.peakAmplitude,
            "rms": systemWriter.rmsAmplitude,
        ],
    ]
    let url = URL(fileURLWithPath: dir + "/meta.json")
    guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url)
}

func shutdown() -> Never {
    log("stopping…")
    mic.stop()
    mic.writer.close()
    system.stop()
    systemWriter.close()
    writeMeta(outDir)
    log(String(format: "mic.wav: %.1f s", mic.writer.durationSeconds))
    log(String(format: "system.wav: %.1f s (%d callbacks, %d empty)",
               systemWriter.durationSeconds, system.callbackCount, system.emptyCallbackCount))
    log(String(format: "mic level: peak %d rms %.4f",
               mic.writer.peakAmplitude, mic.writer.rmsAmplitude))
    log(String(format: "system level: peak %d rms %.4f",
               systemWriter.peakAmplitude, systemWriter.rmsAmplitude))
    // A digitally-silent stream with data written is the signature of a
    // denied microphone: make it impossible to miss.
    if mic.writer.peakAmplitude == 0 && mic.writer.samplesWritten > 0 {
        log("warning: mic track is SILENT (all samples zero) — check Microphone permission for Oatmeal in System Settings, Privacy and Security")
    }
    if systemWriter.peakAmplitude == 0 && systemWriter.samplesWritten > 0 {
        log("warning: system track is SILENT (all samples zero) — check the system audio recording permission in System Settings, Privacy and Security")
    }
    // The first-sample gap is what shifts every Them timestamp; state it
    // outright rather than leaving it to be derived from meta.json.
    if let m = mic.firstSampleHostTime, let s = system.firstSampleHostTime {
        let gap = machToSeconds(s) - machToSeconds(m)
        log(String(format: "timing: first sample gap %+.3f s (%@ started later)",
                   gap, gap >= 0 ? "system" : "mic"))
    } else {
        log("timing: first sample gap unavailable (a stream delivered no audio)")
    }
    log("meta.json written")
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler { shutdown() }
sigterm.setEventHandler { shutdown() }
sigint.resume()
sigterm.resume()

dispatchMain()
