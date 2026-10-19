import CoreAudio
import Foundation

/// An audio input on this Mac.
public struct Microphone: Equatable, Sendable, Identifiable {
    public enum Transport: Sendable, Equatable {
        case builtIn, usb, bluetooth, virtual, other
    }

    public var id: UInt32
    /// Stable across restarts and reconnections; what Preferences keeps.
    public var uid: String
    public var name: String
    public var transport: Transport

    public init(id: UInt32, uid: String, name: String, transport: Transport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    /// The device to listen with. A chosen one wins while it's connected. Otherwise the
    /// default, unless that's a Bluetooth headset: opening a headset's microphone switches it
    /// from stereo to its mono call mode, so everything it plays drops in quality and it
    /// reconnects each time the microphone opens or closes. Then the Mac's own microphone, or
    /// a USB one. Nil means the system default.
    public static func pick(from inputs: [Microphone], defaultID: UInt32?, preferred: String) -> Microphone? {
        if !preferred.isEmpty, let chosen = inputs.first(where: { $0.uid == preferred }) { return chosen }
        let current = inputs.first { $0.id == defaultID }
        guard current?.transport == .bluetooth else { return current }
        return inputs.first { $0.transport == .builtIn } ?? inputs.first { $0.transport == .usb } ?? current
    }
}

/// Core Audio's input devices.
public enum Microphones {
    public static func all() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: id, uid: uid, name: name, transport: transport(id))
        }
    }

    public static func defaultID() -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// The device Dante should listen with now, from `Preferences.microphone`.
    public static func chosen(preferred: String) -> Microphone? {
        Microphone.pick(from: all(), defaultID: defaultID(), preferred: preferred)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transport(_ id: AudioDeviceID) -> Microphone.Transport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .virtual
        default: return .other
        }
    }
}
