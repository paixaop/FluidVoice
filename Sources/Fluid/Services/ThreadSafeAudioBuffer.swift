import Foundation

/// A thread-safe wrapper around a float array to prevent data races between
/// the audio engine (background thread) and the ASR service (main thread).
final nonisolated class ThreadSafeAudioBuffer {
    private struct TimedPacket {
        let start: UInt64
        let end: UInt64
        let samples: Range<Int>
    }

    private var buffer: [Float] = []
    private let lock = NSLock()
    private var tracksHostTime = false
    private var recentPackets: [TimedPacket] = []

    func startTrackingHostTime() {
        self.lock.withLock { self.tracksHostTime = true }
    }

    /// Appends new samples to the buffer in a thread-safe manner
    func append(_ newSamples: [Float], startHostTime: UInt64 = 0, endHostTime: UInt64 = 0) {
        self.lock.lock()
        defer { lock.unlock() }
        let start = self.buffer.count
        self.buffer.append(contentsOf: newSamples)
        if self.tracksHostTime, !newSamples.isEmpty, startHostTime > 0, endHostTime > startHostTime {
            if self.recentPackets.count == 512 { self.recentPackets.removeFirst(256) }
            self.recentPackets.append(.init(start: startHostTime, end: endHostTime, samples: start..<self.buffer.count))
        }
    }

    /// Find where a screen capture falls within PCM already delivered by the audio device.
    func count(throughHostTime time: UInt64) -> Int {
        self.lock.withLock {
            guard let last = self.recentPackets.last, time > 0, time < last.end else { return self.buffer.count }
            for packet in self.recentPackets.reversed() {
                if time >= packet.end { return packet.samples.upperBound }
                if time >= packet.start {
                    let fraction = Double(time - packet.start) / Double(packet.end - packet.start)
                    return packet.samples.lowerBound + Int(fraction * Double(packet.samples.count))
                }
            }
            return self.recentPackets.first?.samples.lowerBound ?? self.buffer.count
        }
    }

    /// Give the device a bounded chance to deliver the packet containing the screenshot time.
    func waitForPacket(throughHostTime time: UInt64) async {
        guard time > 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(120)
        while ContinuousClock.now < deadline {
            if self.lock.withLock({ (self.recentPackets.last?.end ?? 0) >= time }) { return }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
    }

    /// Clears the buffer, optionally keeping capacity to optimize for reuse
    func clear(keepingCapacity: Bool = false) {
        self.lock.lock()
        defer { lock.unlock() }
        self.buffer.removeAll(keepingCapacity: keepingCapacity)
        self.recentPackets.removeAll(keepingCapacity: keepingCapacity)
        self.tracksHostTime = false
    }

    /// Returns the current number of samples
    var isEmpty: Bool {
        self.lock.withLock { self.buffer.isEmpty }
    }

    var count: Int {
        self.lock.lock()
        defer { lock.unlock() }
        return self.buffer.count
    }

    /// Returns a copy of the prefix of the buffer (thread-safe)
    func getPrefix(_ length: Int) -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        let safeLength = min(length, buffer.count)
        return Array(self.buffer[0..<safeLength])
    }

    /// Returns an exact range when enough samples are available.
    func getRange(startingAt start: Int, count: Int) -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        guard start >= 0,
              count > 0,
              start <= self.buffer.count,
              count <= self.buffer.count - start
        else {
            return []
        }
        return Array(self.buffer[start..<(start + count)])
    }

    /// Returns a copy of the entire buffer
    func getAll() -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        return self.buffer
    }
}
