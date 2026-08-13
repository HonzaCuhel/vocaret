import AVFoundation
import CoreAudio
import Foundation

/// Records everything the Mac plays (the "Them" side of a meeting) using a
/// Core Audio process tap — no virtual-driver install needed. macOS 14.4+.
///
/// Flow: create a global tap (all processes) → wrap it in a private aggregate
/// device → attach an IO proc that writes the tap's buffers to a WAV file.
/// The first start triggers the one-time "System Audio Recording" permission.
@available(macOS 14.4, *)
public final class SystemAudioTap {
    public private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "com.jancuhel.justsayit.systemtap")

    public init() {}

    public func start(writingTo url: URL) throws {
        guard !isRunning else { return }

        // 1. Tap over all system audio, mixed down to stereo.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "JustSayIt System Audio Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else {
            throw AudioCaptureError.tapCreationFailed(status)
        }
        tapID = newTapID

        do {
            // 2. The tap's stream format (typically 48 kHz stereo Float32).
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
            guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
                throw AudioCaptureError.formatUnsupported
            }
            format = tapFormat

            // 3. Private aggregate device that contains only the tap.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "JustSayIt Tap Device",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    ],
                ],
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr else {
                throw AudioCaptureError.aggregateCreationFailed(status)
            }
            aggregateID = newAggregateID

            // 4. WAV sink in the tap's native format.
            file = try AVAudioFile(
                forWriting: url,
                settings: tapFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            // 5. IO proc pulling tap buffers.
            status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.write(bufferList: inInputData)
            }
            guard status == noErr, ioProcID != nil else {
                throw AudioCaptureError.ioProcFailed(status)
            }

            status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else {
                throw AudioCaptureError.ioProcFailed(status)
            }
            isRunning = true
        } catch {
            cleanup()
            throw error
        }
    }

    public func stop() {
        guard isRunning else {
            cleanup()
            return
        }
        isRunning = false
        cleanup()
    }

    private func write(bufferList: UnsafePointer<AudioBufferList>) {
        guard let format, let file else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ) else { return }
        do {
            try file.write(from: buffer)
        } catch {
            Log.error("System tap write failed: \(error.localizedDescription)")
        }
    }

    private func cleanup() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Close the file on the IO queue so no in-flight write races the close.
        ioQueue.sync {}
        file = nil
        format = nil
    }
}
