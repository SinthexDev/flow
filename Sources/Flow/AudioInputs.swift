import AVFoundation
import CoreAudio
import Foundation

extension Notification.Name {
    static let flowMicrophonesChanged = Notification.Name("flow.microphonesChanged")
}

enum AudioInputs {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Leer heißt Systemstandard.
    static let systemDefault = ""

    static func startWatching() {
        _ = watch
    }

    static func devices() -> [Device] {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        var seen = Set<String>()
        var list: [Device] = []
        for device in found {
            let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(device.uniqueID).inserted else { continue }
            list.append(Device(id: device.uniqueID, name: name))
        }
        if let fallback = AVCaptureDevice.default(for: .audio) {
            let name = fallback.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(fallback.uniqueID).inserted {
                list.append(Device(id: fallback.uniqueID, name: name))
            }
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return list
    }

    static func systemDefaultName() -> String? {
        let name = AVCaptureDevice.default(for: .audio)?
            .localizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// Gewähltes Gerät, sonst das Systemmikrofon. Ein getrenntes Gerät fällt auf den Standard zurück.
    static func captureDevice(uid: String) -> AVCaptureDevice? {
        if !uid.isEmpty, let chosen = AVCaptureDevice(uniqueID: uid) {
            return chosen
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private static let watch: Void = {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let notify: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .flowMicrophonesChanged, object: nil)
        }
        AudioObjectAddPropertyListenerBlock(system, &devices, .main, notify)
        AudioObjectAddPropertyListenerBlock(system, &defaultInput, .main, notify)
    }()
}
