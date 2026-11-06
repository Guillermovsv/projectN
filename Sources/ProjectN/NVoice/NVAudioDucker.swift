import CoreAudio
import AudioToolbox
import Foundation

/// Lowers whatever is playing (music, videos, calls…) while fn is held, then restores it.
/// macOS has no public per-app volume API, so this scales the default output device's volume.
enum AudioDucker {
    private static var saved: (device: AudioDeviceID, volume: Float32)?
    /// The volume we last turned things down to, and what it was before. If at the next dictation the
    /// output is still sitting at that lowered level, the restore didn't stick (Bluetooth headsets switching
    /// profiles reset it) — so we must not take the lowered level as the new "original", or each dictation
    /// would compound: 50% → 10% → 2% → silence.
    private static var lastTarget: (device: AudioDeviceID, volume: Float32)?
    private static var lastOriginal: Float32 = 0
    private static let crashKeyDevice = "duckedDeviceID"
    private static let crashKeyVolume = "duckedVolume"

    /// Turns the output down to `fraction` of its current level (e.g. 0.2 = 20%).
    static func duck(to fraction: Float) {
        guard saved == nil, let dev = defaultOutputDevice(), var vol = volume(of: dev) else { return }
        if let last = lastTarget, last.device == dev, abs(vol - last.volume) < 0.02 {
            Diagnostics.log("output still lowered from last dictation — restoring \(Int(lastOriginal * 100))% as the original")
            vol = lastOriginal
        }
        let target = max(0, min(1, vol * fraction))
        guard target < vol, setVolume(target, on: dev) else { return }
        saved = (dev, vol)
        lastTarget = (dev, target)
        lastOriginal = vol
        // Remember it on disk too: if NVoice dies mid-dictation, the next launch puts the volume back.
        NVoiceDefaults.store.set(Int(dev), forKey: crashKeyDevice)
        NVoiceDefaults.store.set(vol, forKey: crashKeyVolume)
    }

    /// Puts the volume back to where it was before `duck`.
    static func restore() {
        guard let s = saved else { return }
        saved = nil
        _ = setVolume(s.volume, on: s.device)
        NVoiceDefaults.store.removeObject(forKey: crashKeyDevice)
        NVoiceDefaults.store.removeObject(forKey: crashKeyVolume)
        // Make sure it sticks: re-apply if something (a headset profile switch) knocked it back down.
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard saved == nil, let cur = volume(of: s.device), cur < s.volume - 0.02 else { return }
                if setVolume(s.volume, on: s.device) { Diagnostics.log("volume restore didn't stick — re-applied \(Int(s.volume * 100))%") }
            }
        }
    }

    /// Call at launch: undoes a duck left behind by a crash.
    static func restoreAfterCrash() {
        let d = NVoiceDefaults.store
        guard d.object(forKey: crashKeyVolume) != nil else { return }
        let dev = AudioDeviceID(d.integer(forKey: crashKeyDevice))
        let vol = d.float(forKey: crashKeyVolume)
        if setVolume(vol, on: dev) { Diagnostics.log("restored output volume left lowered by a previous session") }
        d.removeObject(forKey: crashKeyDevice)
        d.removeObject(forKey: crashKeyVolume)
    }

    // MARK: CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return err == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of dev: AudioDeviceID) -> Float32? {
        var addr = volumeAddress
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr ? vol : nil
    }

    @discardableResult
    private static func setVolume(_ v: Float32, on dev: AudioDeviceID) -> Bool {
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var vol = v
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol) == noErr
    }
}
