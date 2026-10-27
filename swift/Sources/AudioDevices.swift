import AVFoundation
import CoreAudio

/// Устройство звука, как его видит Core Audio. Номер устройства живёт до отключения,
/// поэтому между запусками его ищем заново по UID — номерам доверять нельзя.
struct AudioDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    let transport: UInt32
    let hasInput: Bool

    /// Своё ответвление, виртуальные карты (BlackHole, Zoom) и микрофон айфона в микрофоны не годятся:
    /// ответвление выглядит как обычный вход, и однажды запись ушла сама в себя.
    var isMic: Bool {
        hasInput && ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                      kAudioDeviceTransportTypeContinuityCaptureWired,
                      kAudioDeviceTransportTypeContinuityCaptureWireless].contains(transport)
            && !name.hasPrefix(SystemTap.name) && !name.contains("BlackHole")
    }
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var streams = Self.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize)
            return AudioDevice(id: id, name: string(id, kAudioObjectPropertyName), uid: string(id, kAudioDevicePropertyDeviceUID),
                               transport: property(id, kAudioDevicePropertyTransportType, UInt32(0)), hasInput: streamsSize > 0)
        }
    }

    /// Внешний или блютус-микрофон впереди встроенного.
    static func bestMic() -> AudioDevice? {
        let mics = all().filter(\.isMic)
        return mics.first { $0.transport != kAudioDeviceTransportTypeBuiltIn } ?? mics.first
    }

    static func defaultOutput() -> AudioDevice? {
        let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        return all().first { $0.id == id }
    }

    static func sampleRate(_ id: AudioObjectID) -> Double {
        property(id, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        property(id, selector, Unmanaged<CFString>?.none)?.takeRetainedValue() as String? ?? ""
    }
}

/// Ответвление системного звука (process tap): копия того, что слышит пользователь,
/// выход при этом не переключается. Без разрешения «Запись звука системы» и без
/// `NSAudioCaptureUsageDescription` в Info.plist — тишина без единой ошибки.
final class SystemTap {
    static let name = "LT-System"
    let tapID: AudioObjectID
    let deviceID: AudioObjectID

    init() throws {
        guard let output = AudioDevices.defaultOutput() else { throw TranscriptionError("Не понял, куда идёт звук") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = Self.name
        description.isPrivate = true  // устройство видно только нам и исчезает вместе с процессом
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TranscriptionError("Ответвление звука не создано: код \(status)") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.name,
            kAudioAggregateDeviceUIDKey: "pro.ainvest.livetranscriber.system.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            // идентификатор ответвления в верхнем регистре, иначе устройство без входных потоков
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString.uppercased()]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw TranscriptionError("Устройство с ответвлением не создано: код \(status)")
        }
        tapID = tap
        deviceID = device
        Log.info("Ответвление звука готово (выход «\(output.name)», \(Int(AudioDevices.sampleRate(device))) Гц)")
    }

    /// Порядок важен: сначала устройство, потом само ответвление.
    func destroy() {
        AudioHardwareDestroyAggregateDevice(deviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// Звук с одного устройства, на ходу сведённый в моно 16 кГц.
/// Колбэк получает отсчёты, момент первого из них и пиковую громкость куска до округления.
final class DeviceStream {
    enum Take {
        case firstChannel  // микрофон: левый канал, как `pan=mono|c0=c0` в ffmpeg
        case lastBufferMix  // ответвление: его потоки идут после потоков устройства вывода
    }

    static let rate = 16000.0
    private let device: AudioObjectID
    private let take: Take
    private let queue: DispatchQueue
    private let onSamples: ([Int16], UInt64, Float) -> Void
    private let input: AVAudioFormat
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private var procID: AudioDeviceIOProcID?

    init(device: AudioObjectID, take: Take, queue: DispatchQueue, onSamples: @escaping ([Int16], UInt64, Float) -> Void) throws {
        let rate = AudioDevices.sampleRate(device)
        guard rate > 0, let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw TranscriptionError("Устройство не отдаёт формат звука")
        }
        self.device = device
        self.take = take
        self.queue = queue
        self.onSamples = onSamples
        self.input = input
        self.converter = converter
    }

    func start() throws {
        let take = take
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, list, time, _, _ in
            // Буферы живут только внутри вызова: копируем моно и уходим с потока звука
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let buffer = take == .firstChannel ? buffers.first : buffers.last,
                  let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let floats = data.assumingMemoryBound(to: Float.self)
            var mono = [Float](repeating: 0, count: frames)
            var peak: Float = 0
            for frame in 0..<frames {
                var value: Float = 0
                if take == .firstChannel {
                    value = floats[frame * channels]
                } else {
                    for channel in 0..<channels { value += floats[frame * channels + channel] }
                    value /= Float(channels)
                }
                mono[frame] = value
                peak = max(peak, abs(value))
            }
            let nanos = AudioConvertHostTimeToNanos(time.pointee.mHostTime)
            self?.queue.async { self?.convert(mono, nanos, peak) }
        }
        guard status == noErr else { throw TranscriptionError("Устройство не открылось: код \(status)") }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else { throw TranscriptionError("Устройство не запустилось: код \(status)") }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    private func convert(_ mono: [Float], _ nanos: UInt64, _ peak: Float) {
        guard !mono.isEmpty, let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
        source.frameLength = source.frameCapacity
        mono.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * Self.rate / input.sampleRate) + 64
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var fed = false
        // .noDataNow, а не конец потока: преобразователь держит хвост фильтра до следующего куска
        converter.convert(to: target, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        let samples = Array(UnsafeBufferPointer(start: target.int16ChannelData![0], count: Int(target.frameLength)))
        onSamples(samples, nanos, peak)
    }
}
