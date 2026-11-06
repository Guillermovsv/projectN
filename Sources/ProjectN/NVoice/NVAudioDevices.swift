import CoreAudio
import Foundation

/// Microphone selection. Opening a Bluetooth headset's mic (AirPods…) flips it from music mode (A2DP)
/// to call mode (HFP): whatever you're listening to cuts out and drops to phone quality, twice per
/// dictation. So by default NVoice records with the built-in mic whenever the default input is Bluetooth.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum AudioDevices {
    static let automatic = "auto"      // built-in mic when the default input is Bluetooth
    static let systemDefault = "system"

    static func inputDevices() -> [AudioInputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device).filter { inputChannels($0.id) > 0 && $0.transport != kAudioDeviceTransportTypeVirtual && $0.transport != kAudioDeviceTransportTypeAggregate }
    }

    static func defaultInput() -> AudioInputDevice? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return device(dev)
    }

    /// The device to record from for a setting value, or nil to leave the system default.
    static func resolve(_ choice: String) -> AudioInputDevice? {
        switch choice {
        case systemDefault:
            return nil
        case automatic:
            guard let def = defaultInput(), def.isBluetooth else { return nil }
            return inputDevices().first { $0.isBuiltIn } ?? inputDevices().first { !$0.isBluetooth }
        default:
            // A specific mic; if it's unplugged, fall back to automatic.
            return inputDevices().first { $0.uid == choice } ?? resolve(automatic)
        }
    }

    // MARK: CoreAudio helpers

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        var addr = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport)
    }

    private static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
