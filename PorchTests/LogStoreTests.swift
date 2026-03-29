@testable import Porch
import XCTest

final class LogStoreTests: XCTestCase {

    func testAppendAndRetrieve() {
        let store = LogStore(capacity: 10)
        store.append(level: "info", category: "Test", message: "hello")

        let entries = store.recentEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].level, "info")
        XCTAssertEqual(entries[0].category, "Test")
        XCTAssertEqual(entries[0].message, "hello")
    }

    func testCapacityOverflow() {
        let store = LogStore(capacity: 3)
        store.append(level: "info", category: "A", message: "1")
        store.append(level: "info", category: "A", message: "2")
        store.append(level: "info", category: "A", message: "3")
        store.append(level: "info", category: "A", message: "4") // overwrites "1"

        let entries = store.recentEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.message), ["2", "3", "4"])
    }

    func testFilterByLevel() {
        let store = LogStore(capacity: 10)
        store.append(level: "info", category: "A", message: "info msg")
        store.append(level: "error", category: "A", message: "error msg")
        store.append(level: "info", category: "A", message: "info msg 2")

        let errors = store.recentEntries(level: "error")
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].message, "error msg")
    }

    func testFilterByCategory() {
        let store = LogStore(capacity: 10)
        store.append(level: "info", category: "API", message: "api call")
        store.append(level: "info", category: "Chat", message: "chat msg")

        let apiEntries = store.recentEntries(category: "API")
        XCTAssertEqual(apiEntries.count, 1)
        XCTAssertEqual(apiEntries[0].message, "api call")
    }

    func testCountLimit() {
        let store = LogStore(capacity: 100)
        for i in 0..<50 {
            store.append(level: "info", category: "A", message: "\(i)")
        }

        let limited = store.recentEntries(count: 5)
        XCTAssertEqual(limited.count, 5)
        XCTAssertEqual(limited.last?.message, "49")
    }

    func testClear() {
        let store = LogStore(capacity: 10)
        store.append(level: "info", category: "A", message: "msg")
        store.clear()

        XCTAssertEqual(store.recentEntries().count, 0)
    }

    func testTimestampIsISO8601() {
        let store = LogStore(capacity: 10)
        store.append(level: "info", category: "A", message: "msg")

        let entries = store.recentEntries()
        let timestamp = entries[0].timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: timestamp))
    }
}
