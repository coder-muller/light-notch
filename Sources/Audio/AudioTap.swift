import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class AudioTap {
    var onLevels: (([Float]?) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "LightNotch.AudioTap", qos: .userInteractive)
    private let control = DispatchQueue(label: "LightNotch.AudioTap.control", qos: .userInitiated)
    private var analyzer: Analyzer?

    func start(_ done: @escaping (Bool) -> Void) {
        let deliver = onLevels
        control.async { [self] in
            let ok = startTap(deliver)
            DispatchQueue.main.async { done(ok) }
        }
    }

    func stop() {
        control.async { [self] in stopTap() }
    }

    private func startTap(_ deliver: (([Float]?) -> Void)?) -> Bool {
        let processes = Self.spotifyProcessObjects()
        guard !processes.isEmpty else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "LightNotch"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return fail() }

        var subDevices: [[String: Any]] = []
        if let output = Self.defaultOutputUID() { subDevices = [[kAudioSubDeviceUIDKey: output]] }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LightNotch Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        if let main = subDevices.first?[kAudioSubDeviceUIDKey] { aggregate[kAudioAggregateDeviceMainSubDeviceKey] = main }
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return fail() }

        guard let format = Self.tapFormat(tapID), format.mSampleRate > 0 else { return fail() }
        let analyzer = Analyzer(sampleRate: Float(format.mSampleRate))
        queue.sync { self.analyzer = analyzer }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            analyzer.consume(input) { levels in DispatchQueue.main.async { deliver?(levels) } }
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else { return fail() }
        return true
    }

    private func stopTap() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync { analyzer = nil }
    }

    private func fail() -> Bool {
        stopTap()
        return false
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func spotifyProcessObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { string($0, kAudioProcessPropertyBundleID)?.hasPrefix("com.spotify.client") == true }
    }

    private static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

private final class Analyzer {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    private static let silenceDB: Float = -100
    private static let range: Float = 30

    private let fft: FFTSetup
    private let hop: Int
    private let bands: [Range<Int>]
    private var window = [Float](repeating: 0, count: Analyzer.size)
    private var samples = [Float](repeating: 0, count: Analyzer.size)
    private var windowed = [Float](repeating: 0, count: Analyzer.size)
    private var real = [Float](repeating: 0, count: Analyzer.size / 2)
    private var imag = [Float](repeating: 0, count: Analyzer.size / 2)
    private var power = [Float](repeating: 0, count: Analyzer.size / 2)
    private var write = 0
    private var sinceLast = 0
    private var peaks = [Float](repeating: -60, count: 4)
    private var levels = [Float](repeating: 0, count: 4)
    private var silentFrames = 0

    init(sampleRate: Float) {
        fft = vDSP_create_fftsetup(Analyzer.log2n, FFTRadix(kFFTRadix2))!
        hop = max(Analyzer.size / 2, Int(sampleRate / 30))
        vDSP_hann_window(&window, vDSP_Length(Analyzer.size), Int32(vDSP_HANN_NORM))
        let binWidth = sampleRate / Float(Analyzer.size)
        let half = Analyzer.size / 2
        func bin(_ hz: Float) -> Int { min(half, max(1, Int((hz / binWidth).rounded()))) }
        let edges: [Float] = [40, 250, 1_000, 4_000, 12_000]
        bands = (0..<4).map { bin(edges[$0])..<max(bin(edges[$0]) + 1, bin(edges[$0 + 1])) }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func consume(_ list: UnsafePointer<AudioBufferList>, emit: ([Float]?) -> Void) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let left = data.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        for i in 0..<frames {
            let sample: Float
            if channels >= 2 {
                sample = (left[i * channels] + left[i * channels + 1]) * 0.5
            } else if let right {
                sample = (left[i] + right[i]) * 0.5
            } else {
                sample = left[i]
            }
            samples[write] = sample
            write = (write + 1) & (Analyzer.size - 1)
            sinceLast += 1
            if sinceLast >= hop {
                sinceLast = 0
                emit(analyze())
            }
        }
    }

    private func analyze() -> [Float]? {
        let n = Analyzer.size
        for i in 0..<n { windowed[i] = samples[(write + i) & (n - 1)] * window[i] }

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, Analyzer.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        var silent = true
        for (b, bins) in bands.enumerated() {
            var mean: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + bins.lowerBound, 1, &mean, vDSP_Length(bins.count))
            }
            let db = 10 * log10(mean + 1e-12)
            if db > Analyzer.silenceDB { silent = false }
            peaks[b] = max(db, peaks[b] - 0.1)
            let level = min(1, max(0, (db - (peaks[b] - Analyzer.range)) / Analyzer.range))
            levels[b] = max(level, levels[b] * 0.8)
        }

        silentFrames = silent ? silentFrames + 1 : 0
        return silentFrames > 45 ? nil : levels
    }
}
