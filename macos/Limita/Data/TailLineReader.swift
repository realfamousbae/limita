import Foundation

/// Yields the lines of a file from the last to the first, reading only as much as consumed.
///
/// Codex session transcripts grow to megabytes but the data we want is always appended at
/// the end, so reading forward would parse the whole history to reach it.
struct TailLineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle?
    private let chunkSize: Int
    /// Offset of the not-yet-read head of the file.
    private var offset: UInt64
    /// Bytes read but not yet split into complete lines; always a file prefix of what remains.
    private var pending: Data
    private var finished = false

    init(url: URL, chunkSize: Int = 64 * 1024) {
        self.chunkSize = Swift.max(chunkSize, 1)
        self.handle = try? FileHandle(forReadingFrom: url)
        self.pending = Data()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        self.offset = UInt64(size ?? 0)

        if handle == nil || offset == 0 {
            finished = true
        }
    }

    mutating func next() -> String? {
        guard let handle else { return nil }

        while true {
            // Emit a complete line if `pending` holds one.
            if let newline = pending.lastIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = pending[pending.index(after: newline)...]
                pending = pending[..<newline]
                if !lineBytes.isEmpty {
                    return String(decoding: lineBytes, as: UTF8.self)
                }
                continue // blank line (trailing newline, or \n\n) — skip it
            }

            if finished {
                defer { pending = Data() }
                try? handle.close()
                return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
            }

            readPreviousChunk(handle)
        }
    }

    /// Prepends the chunk before `offset`. Reading backwards can split a UTF-8 sequence,
    /// so chunks are stitched as bytes and only decoded once a whole line is isolated.
    private mutating func readPreviousChunk(_ handle: FileHandle) {
        let length = Swift.min(UInt64(chunkSize), offset)
        let start = offset - length

        do {
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(length)) ?? Data()
            pending = chunk + pending
        } catch {
            finished = true
            return
        }

        offset = start
        if offset == 0 { finished = true }
    }
}
