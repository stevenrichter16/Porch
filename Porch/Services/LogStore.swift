import Foundation
import os

/// A thread-safe in-memory ring buffer that captures structured log entries
/// so the LLM can read its own logs via a tool call and self-correct.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    struct Entry: Encodable, Sendable {
        var timestamp: String
        var level: String
        var category: String
        var message: String
    }

    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [Entry]
    private var writeIndex: Int = 0
    private var isFull: Bool = false

    init(capacity: Int = 200) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }

    func append(level: String, category: String, message: String) {
        let entry = Entry(
            timestamp: Self.formatter.string(from: Date()),
            level: level,
            category: category,
            message: message
        )

        lock.lock()
        if buffer.count < capacity {
            buffer.append(entry)
        } else {
            buffer[writeIndex] = entry
            isFull = true
        }
        writeIndex = (writeIndex + 1) % capacity
        lock.unlock()
    }

    func recentEntries(count: Int = 50, level: String? = nil, category: String? = nil) -> [Entry] {
        lock.lock()
        let snapshot = orderedSnapshot()
        lock.unlock()

        var filtered = snapshot
        if let level {
            filtered = filtered.filter { $0.level == level }
        }
        if let category {
            filtered = filtered.filter { $0.category == category }
        }

        return Array(filtered.suffix(min(count, filtered.count)))
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        writeIndex = 0
        isFull = false
        lock.unlock()
    }

    private func orderedSnapshot() -> [Entry] {
        if !isFull {
            return buffer
        }
        return Array(buffer[writeIndex...]) + Array(buffer[..<writeIndex])
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Dual-write logger that sends to both os.Logger and LogStore

/// Wraps `os.Logger` to write every log to both Apple's unified logging
/// and the in-memory `LogStore` ring buffer that the LLM can query.
struct PorchLogger: Sendable {
    let osLogger: Logger
    let category: String
    private let store: LogStore

    init(category: String, store: LogStore = .shared) {
        self.osLogger = Logger(subsystem: "steven.Porch", category: category)
        self.category = category
        self.store = store
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
        store.append(level: "debug", category: category, message: message)
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        store.append(level: "info", category: category, message: message)
    }

    func notice(_ message: String) {
        osLogger.notice("\(message, privacy: .public)")
        store.append(level: "notice", category: category, message: message)
    }

    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        store.append(level: "warning", category: category, message: message)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        store.append(level: "error", category: category, message: message)
    }

    func fault(_ message: String) {
        osLogger.fault("\(message, privacy: .public)")
        store.append(level: "fault", category: category, message: message)
    }
}
