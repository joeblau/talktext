import Foundation

protocol ActiveRecordingSnapshotting: Sendable {
    /// Copies the audio currently flushed by the recorder into a standalone WAV
    /// file. An active AVAudioRecorder can leave RIFF length fields stale until
    /// it is stopped, so implementations must finalize those fields in the copy.
    func createSnapshot(from sourceURL: URL, at destinationURL: URL) async -> Bool
}

struct ActiveWAVRecordingSnapshotter: ActiveRecordingSnapshotting {
    func createSnapshot(from sourceURL: URL, at destinationURL: URL) async -> Bool {
        let worker = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  var data = try? Data(contentsOf: sourceURL),
                  Self.finalizeActiveWAV(&data),
                  !Task.isCancelled else {
                return false
            }

            do {
                try data.write(to: destinationURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Produces a self-contained PCM WAV using only complete audio frames. The
    /// recorder remains untouched, so preview generation never pauses the mic.
    static func finalizeActiveWAV(_ data: inout Data) -> Bool {
        let riff = Data("RIFF".utf8)
        let wave = Data("WAVE".utf8)
        let formatChunk = Data("fmt ".utf8)
        let audioChunk = Data("data".utf8)

        guard data.count >= 44,
              data.subdata(in: 0..<4) == riff,
              data.subdata(in: 8..<12) == wave else {
            return false
        }

        var blockAlignment: Int?
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = data.subdata(in: offset..<(offset + 4))
            let declaredSize = Int(readLittleEndianUInt32(from: data, at: offset + 4))
            let contentsOffset = offset + 8

            if identifier == formatChunk {
                guard declaredSize >= 16, contentsOffset + 16 <= data.count else {
                    return false
                }
                blockAlignment = Int(readLittleEndianUInt16(from: data, at: contentsOffset + 12))
            } else if identifier == audioChunk {
                guard let blockAlignment, blockAlignment > 0 else {
                    return false
                }
                let availableBytes = data.count - contentsOffset
                let completeAudioBytes = availableBytes - (availableBytes % blockAlignment)
                guard completeAudioBytes > 0,
                      completeAudioBytes <= Int(UInt32.max),
                      contentsOffset + completeAudioBytes - 8 <= Int(UInt32.max) else {
                    return false
                }

                data.removeSubrange((contentsOffset + completeAudioBytes)..<data.count)
                writeLittleEndianUInt32(UInt32(completeAudioBytes), to: &data, at: offset + 4)
                writeLittleEndianUInt32(UInt32(data.count - 8), to: &data, at: 4)
                return true
            }

            let paddedSize = declaredSize + (declaredSize % 2)
            guard contentsOffset + paddedSize > offset,
                  contentsOffset + paddedSize <= data.count else {
                return false
            }
            offset = contentsOffset + paddedSize
        }

        return false
    }

    private static func readLittleEndianUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLittleEndianUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeLittleEndianUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
