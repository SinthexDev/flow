import AVFoundation
import CoreMedia
import Foundation

enum RecorderError: LocalizedError {
    case noInput
    case convert

    var errorDescription: String? {
        switch self {
        case .noInput: return L10n.s("audio.noInput")
        case .convert: return L10n.s("audio.convert")
        }
    }
}

/// Nimmt über AVCaptureSession auf. Die Input-Node von AVAudioEngine meldet 0 Hz,
/// sobald ein Bluetooth-Headset wie AirPods die Ausgabe übernimmt, und der Tap
/// bekommt dann keine Samples. Die Capture-Session öffnet das gewählte Mikrofon direkt.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "flow.audio.session")
    private let audioQueue = DispatchQueue(label: "flow.audio.capture")
    private static let sessionKey = DispatchSpecificKey<UInt8>()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let lock = NSLock()
    private var pcm = Data()
    private var limitReached = false
    private var capturing = false
    private var startError: Error?
    private(set) var isRecording = false
    var onLimit: (() -> Void)?
    var onLevel: ((CGFloat) -> Void)?

    override init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        super.init()
        sessionQueue.setSpecific(key: Self.sessionKey, value: 1)
    }

    func start(inputUID: String) throws {
        let finished = runOnSessionQueue {
            self.startError = nil
            do {
                try self.configureAndStart(inputUID: inputUID)
            } catch {
                self.startError = error
            }
        }
        if !finished {
            throw RecorderError.noInput
        }
        if let startError {
            throw startError
        }
    }

    /// Stoppt die Session und behält das PCM, damit ein letzter Live-Tick es noch lesen kann.
    func freeze() {
        _ = runOnSessionQueue {
            self.lock.lock()
            self.capturing = false
            self.lock.unlock()
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        audioQueue.sync {}
        isRecording = false
        converter = nil
        sourceFormat = nil
    }

    func stop() -> Data? {
        freeze()
        return takeWAV()
    }

    func pcmByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pcm.count
    }

    /// Kopie ab `byteOffset` (16 kHz, mono, Int16). Stoppt die Aufnahme nicht.
    func snapshotPCM(from byteOffset: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let start = min(max(0, byteOffset), pcm.count)
        guard start < pcm.count else { return Data() }
        return pcm.subdata(in: start..<pcm.count)
    }

    func wavIfUseful(_ pcm: Data, minimumBytes: Int = 8_000) -> Data? {
        guard pcm.count >= minimumBytes else { return nil }
        return wavData(from: pcm)
    }

    func discardBuffer() {
        lock.lock()
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func takeWAV() -> Data? {
        lock.lock()
        let captured = pcm
        pcm.removeAll(keepingCapacity: false)
        lock.unlock()
        // Unter 0,25 Sekunden ist kein sinnvolles Diktat.
        return wavIfUseful(captured)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let on = capturing
        lock.unlock()
        guard on, let buffer = pcmBuffer(from: sampleBuffer) else { return }
        consume(buffer)
    }

    private func configureAndStart(inputUID: String) throws {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        if !session.outputs.contains(where: { $0 === output }) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw RecorderError.noInput
            }
            session.addOutput(output)
        }
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard let device = AudioInputs.captureDevice(uid: inputUID) else {
            session.commitConfiguration()
            throw RecorderError.noInput
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw RecorderError.noInput
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.noInput
        }
        session.addInput(input)
        session.commitConfiguration()

        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        limitReached = false
        capturing = true
        lock.unlock()
        converter = nil
        sourceFormat = nil

        session.startRunning()
        guard session.isRunning else {
            lock.lock()
            capturing = false
            lock.unlock()
            throw RecorderError.noInput
        }
        isRecording = true
    }

    /// startRunning darf nicht auf dem Hauptthread laufen, sonst kann die Session
    /// auf genau diesen Thread warten. Vom Hauptthread aus wird die Runloop gepumpt.
    private func runOnSessionQueue(_ work: @escaping () -> Void) -> Bool {
        if DispatchQueue.getSpecific(key: Self.sessionKey) != nil {
            work()
            return true
        }
        let done = DispatchSemaphore(value: 0)
        sessionQueue.async {
            work()
            done.signal()
        }
        if !Thread.isMainThread {
            done.wait()
            return true
        }
        let deadline = Date().addingTimeInterval(8)
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            if Date() > deadline { return false }
            RunLoop.current.run(mode: .common, before: Date(timeIntervalSinceNow: 0.02))
        }
        return true
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = stream.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcm
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0, buffer.frameLength > 0 else { return }
        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channels = output.int16ChannelData else { return }
        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        let byteCount = frames * MemoryLayout<Int16>.size
        let chunk = Data(bytes: channels[0], count: byteCount)

        var sum: Float = 0
        let samples = channels[0]
        for index in 0..<frames {
            let sample = Float(samples[index]) / 32768
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        let level = CGFloat(max(0, min(1, (decibels + 55) / 45)))
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
        }

        lock.lock()
        pcm.append(chunk)
        let tooLong = pcm.count > 9_600_000
        let shouldNotify = tooLong && !limitReached
        if shouldNotify { limitReached = true }
        lock.unlock()
        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onLimit?()
            }
        }
    }

    private func wavData(from pcm: Data) -> Data {
        var data = Data()
        let dataSize = UInt32(pcm.count)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendLE(UInt32(36) + dataSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(16_000))
        data.appendLE(UInt32(32_000))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.appendLE(dataSize)
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
