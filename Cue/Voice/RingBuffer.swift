import Foundation

/// Fixed-capacity FIFO ring buffer for audio sample types. All push / pop
/// operations are O(k) in the number of elements moved — no shifting of
/// the remaining contents, unlike `Array.removeFirst(k)` which is O(n).
///
/// Three sites in this app drain the head of a buffer on every audio tick:
///   - `WakeWordEngine.rolling` — 32 000-sample sliding window
///   - `CueAudioDevice.inputRing` — admQueue mic chunking (480-frame drain)
///   - `CueAudioDevice.playoutBacklog` — render-thread playout drain
///
/// All three previously used `Array.removeFirst(k)` which memmoves the
/// remaining elements down each call — millions of bytes per second of
/// audio. This struct replaces that with a `head` pointer that just
/// advances modulo capacity.
///
/// **Thread-safety**: none. Callers (each of the three above runs on a
/// single dedicated thread/queue) provide their own synchronization.
///
/// **Overflow**: `pushBack` overwrites the oldest element when full —
/// sliding-window semantics. The `WakeWordEngine.rolling` use site relies
/// on this. Callers who need to *prevent* overflow should check
/// `isFull` before pushing.
struct RingBuffer<T> {
    @usableFromInline var storage: [T]
    @usableFromInline var head: Int = 0
    @usableFromInline var occupancy: Int = 0

    init(capacity: Int, fill: T) {
        precondition(capacity > 0, "RingBuffer capacity must be > 0")
        storage = Array(repeating: fill, count: capacity)
    }

    @inlinable var capacity: Int { storage.count }
    @inlinable var count: Int { occupancy }
    @inlinable var isEmpty: Bool { occupancy == 0 }
    @inlinable var isFull: Bool { occupancy == storage.count }

    /// Push one element. Drops the oldest if full (sliding window).
    @inlinable
    mutating func pushBack(_ element: T) {
        let cap = storage.count
        let tail = (head + occupancy) % cap
        storage[tail] = element
        if occupancy == cap {
            head = (head + 1) % cap
        } else {
            occupancy += 1
        }
    }

    /// Push a batch. Drops oldest as needed (sliding window). Uses bulk
    /// memcpy under the hood — a scalar pushBack-per-element loop is ~3×
    /// slower than `Array.append(contentsOf:)`.
    @inlinable
    mutating func pushBack(_ src: UnsafeBufferPointer<T>) {
        let cap = storage.count
        let n = src.count
        if n == 0 { return }
        // Batch larger than capacity → only the trailing `cap` elements
        // would have survived overwrites anyway.
        if n >= cap {
            storage.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress! + (n - cap), count: cap)
            }
            head = 0
            occupancy = cap
            return
        }
        // Advance head to drop oldest elements that this push will overwrite.
        let toDrop = Swift.max(0, occupancy + n - cap)
        head = (head + toDrop) % cap
        occupancy = Swift.min(cap, occupancy + n)
        let tail = (head + occupancy - n) % cap
        let firstChunk = Swift.min(n, cap - tail)
        storage.withUnsafeMutableBufferPointer { dst in
            (dst.baseAddress! + tail).update(from: src.baseAddress!, count: firstChunk)
            if n > firstChunk {
                dst.baseAddress!.update(
                    from: src.baseAddress! + firstChunk,
                    count: n - firstChunk
                )
            }
        }
    }

    /// Pop the first `desired` elements into `dest`. Returns the actual
    /// count copied (may be less than `desired` if the buffer underflows).
    /// Performs at most two contiguous memcpys when `T` is trivially
    /// copyable; otherwise falls back to a loop.
    @inlinable
    @discardableResult
    mutating func popFront(into dest: UnsafeMutablePointer<T>, count desired: Int) -> Int {
        let cap = storage.count
        let avail = Swift.min(desired, occupancy)
        if avail == 0 { return 0 }

        let firstChunk = Swift.min(avail, cap - head)
        storage.withUnsafeBufferPointer { ptr in
            dest.update(from: ptr.baseAddress! + head, count: firstChunk)
            if avail > firstChunk {
                dest.advanced(by: firstChunk).update(
                    from: ptr.baseAddress!,
                    count: avail - firstChunk
                )
            }
        }
        head = (head + avail) % cap
        occupancy -= avail
        return avail
    }

    /// Drop the first `desired` elements without copying. Returns dropped count.
    @inlinable
    @discardableResult
    mutating func removeFirst(_ desired: Int) -> Int {
        let avail = Swift.min(desired, occupancy)
        head = (head + avail) % storage.count
        occupancy -= avail
        return avail
    }

    /// Reset to empty (keeps storage capacity).
    @inlinable
    mutating func removeAll() {
        head = 0
        occupancy = 0
    }

    /// Random access by FIFO position (0 = oldest, count-1 = newest).
    /// Caller guarantees `i < count`.
    @inlinable
    subscript(i: Int) -> T {
        storage[(head + i) % storage.count]
    }

    /// Allocates an Array<T> with the current contents in head-to-tail
    /// order. Uses bulk memcpy via `Array(unsafeUninitializedCapacity:)`.
    /// Use only from non-realtime call sites (e.g., handing the wake-word
    /// window to Whisper inference).
    func snapshot() -> [T] {
        let cap = storage.count
        let n = occupancy
        if n == 0 { return [] }
        return [T](unsafeUninitializedCapacity: n) { dst, initializedCount in
            let firstChunk = Swift.min(n, cap - head)
            storage.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + head, count: firstChunk)
                if n > firstChunk {
                    dst.baseAddress!.advanced(by: firstChunk).update(
                        from: src.baseAddress!,
                        count: n - firstChunk
                    )
                }
            }
            initializedCount = n
        }
    }
}
