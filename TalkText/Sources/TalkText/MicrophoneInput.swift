@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

protocol MicrophoneInputDriving: Sendable {
    var health: MicrophoneInputHealth { get }
    func open(deviceID: AudioDeviceID, sink: CapturedAudioSink) async throws
    func close() async
    func cancel()
}

/// Input-only AUHAL: binding an AVAudioEngine's shared input/output unit to a
/// Bluetooth microphone also binds playback and can leave its formats stale.
/// Device setup runs on this actor, never on the main/UI actor.
actor MicrophoneInput: MicrophoneInputDriving {
    nonisolated let health = MicrophoneInputHealth()
    private var unit: AudioUnit?
    private var context: MicrophoneInputContext?

    func open(deviceID: AudioDeviceID, sink: CapturedAudioSink) async throws {
        await close()
        try Task.checkCancellation()
        guard !health.isCancelled else { throw CancellationError() }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorderCreationError.inputDeviceUnusable
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw AudioRecorderCreationError.inputDeviceUnusable }
        unit = instance
        do {
            var enabled: UInt32 = 1
            try set(instance, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &enabled)
            enabled = 0
            try set(instance, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &enabled)
            var selectedID = deviceID
            try set(instance, property: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &selectedID)

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else {
                throw AudioRecorderCreationError.inputDeviceUnusable
            }
            var clientFormat = format.streamDescription.pointee
            try set(instance, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, value: &clientFormat)

            var maximumFrames: UInt32 = 4096
            try set(instance, property: kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, value: &maximumFrames)
            size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitGetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, &size))
            let context = try MicrophoneInputContext(unit: instance, format: format, capacity: maximumFrames, sink: sink, health: health)
            self.context = context
            var callback = AURenderCallbackStruct(
                inputProc: { reference, flags, timestamp, _, frames, _ in
                    return Unmanaged<MicrophoneInputContext>.fromOpaque(reference).takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try set(instance, property: kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, element: 0, value: &callback)
            try Task.checkCancellation()
            guard !health.isCancelled else { throw CancellationError() }
            try check(AudioUnitInitialize(instance))
            try check(AudioOutputUnitStart(instance))
            health.started()
            // Cancellation can arrive while CoreAudio synchronously opens HFP.
            try Task.checkCancellation()
            guard !health.isCancelled else { throw CancellationError() }
        } catch {
            await close()
            throw error
        }
    }

    func close() async {
        health.stopped()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        let previousContext = context
        context = nil
        // AudioOutputUnitStop stops callbacks before releasing their context.
        // Drain accepted buffers before closing the WAV, preserving key-up audio.
        await previousContext?.drain()
    }

    nonisolated func cancel() {
        health.cancel()
        Task { await close() }
    }

    private func set<T>(_ unit: AudioUnit, property: AudioUnitPropertyID, scope: AudioUnitScope, element: AudioUnitElement, value: inout T) throws {
        // An owned copy avoids a closure capture, which Swift 6.1 rejects as
        // sending the non-Sendable AudioUnit across an isolation boundary.
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        pointer.initialize(to: value)
        defer { pointer.deinitialize(count: 1); pointer.deallocate() }
        try check(AudioUnitSetProperty(unit, property, scope, element, pointer, UInt32(MemoryLayout<T>.size)))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

final class MicrophoneInputHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var cancelled = false
    private var renderFailed = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isRunning: Bool { lock.withLock { running && !renderFailed && !cancelled } }

    func started() { lock.withLock { running = true; renderFailed = false } }
    func stopped() { lock.withLock { running = false } }
    func cancel() { lock.withLock { cancelled = true; running = false } }
    func failed() { lock.withLock { renderFailed = true } }
}

/// Reuses a bounded buffer pool. The real-time callback only pulls input and
/// schedules its owned buffer; conversion and disk writes run on a serial queue.
private final class MicrophoneInputContext: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let unit: AudioUnit
    private let sink: CapturedAudioSink
    private let health: MicrophoneInputHealth
    private let writer = DispatchQueue(label: "com.joeblau.talktext.audio-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var available: [Slot]

    init(unit: AudioUnit, format: AVAudioFormat, capacity: UInt32, sink: CapturedAudioSink, health: MicrophoneInputHealth) throws {
        self.unit = unit
        self.sink = sink
        self.health = health
        available = try (0..<16).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioRecorderCreationError.inputDeviceUnusable
            }
            return Slot(buffer: buffer)
        }
    }

    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard !health.isCancelled else { return noErr }
        guard let slot = lock.withLock({ available.popLast() }) else {
            health.failed()
            return kAudioUnitErr_CannotDoInCurrentContext
        }
        guard frames <= slot.buffer.frameCapacity else {
            lock.withLock { available.append(slot) }
            health.failed()
            return kAudioUnitErr_TooManyFramesToProcess
        }
        slot.buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, slot.buffer.mutableAudioBufferList)
        guard status == noErr else {
            lock.withLock { available.append(slot) }
            health.failed()
            return status
        }
        writer.async { [self, slot] in
            sink.append(slot.buffer)
            lock.withLock { available.append(slot) }
        }
        return noErr
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }
}
