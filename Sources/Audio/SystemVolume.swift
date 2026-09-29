import AudioToolbox
import CoreAudio

final class SystemVolume {
    var onChange: (() -> Void)?
    var onExternalChange: ((Int) -> Void)?

    private var ownChangeUntil: CFAbsoluteTime = 0
    private var lastShownLevel: Int?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &SystemVolume.defaultDeviceAddress,
                                            .main, listener)
        attach()
    }

    deinit {
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &SystemVolume.defaultDeviceAddress, .main, deviceListener)
        }
        detach()
    }

    var level: Int? {
        guard device != kAudioObjectUnknown,
              AudioObjectHasProperty(device, &SystemVolume.volumeAddress) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &SystemVolume.volumeAddress, 0, nil, &size, &value) == noErr else { return nil }
        return Int((value * 100).rounded())
    }

    var isMuted: Bool {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &SystemVolume.muteAddress) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &SystemVolume.muteAddress, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    var isSilent: Bool { isMuted || level == 0 }

    func setLevel(_ level: Int) {
        guard device != kAudioObjectUnknown else { return }
        ownChangeUntil = CFAbsoluteTimeGetCurrent() + 0.4
        lastShownLevel = min(100, max(0, level))
        var value = Float32(min(100, max(0, level))) / 100
        AudioObjectSetPropertyData(device, &SystemVolume.volumeAddress, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
        if level > 0, isMuted {
            var off: UInt32 = 0
            AudioObjectSetPropertyData(device, &SystemVolume.muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
    }

    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &SystemVolume.defaultDeviceAddress,
                                   0, nil, &size, &id)
        device = id
        lastShownLevel = shownLevel
        if device != kAudioObjectUnknown {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.valueChanged() }
            valueListener = listener
            AudioObjectAddPropertyListenerBlock(device, &SystemVolume.volumeAddress, .main, listener)
            AudioObjectAddPropertyListenerBlock(device, &SystemVolume.muteAddress, .main, listener)
        }
        onChange?()
    }

    private var shownLevel: Int? { level.map { isMuted ? 0 : $0 } }

    private func valueChanged() {
        onChange?()
        guard let shown = shownLevel, shown != lastShownLevel else { return }
        lastShownLevel = shown
        if CFAbsoluteTimeGetCurrent() > ownChangeUntil { onExternalChange?(shown) }
    }

    private func detach() {
        guard device != kAudioObjectUnknown, let valueListener else { return }
        AudioObjectRemovePropertyListenerBlock(device, &SystemVolume.volumeAddress, .main, valueListener)
        AudioObjectRemovePropertyListenerBlock(device, &SystemVolume.muteAddress, .main, valueListener)
        self.valueListener = nil
    }
}
