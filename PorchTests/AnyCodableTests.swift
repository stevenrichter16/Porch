@testable import Porch
import XCTest

final class AnyCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testEncodeString() throws {
        let value = AnyCodable("hello")
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "\"hello\"")
    }

    func testEncodeInt() throws {
        let value = AnyCodable(42)
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "42")
    }

    func testEncodeBool() throws {
        let value = AnyCodable(true)
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "true")
    }

    func testEncodeDouble() throws {
        let value = AnyCodable(3.14)
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("3.14"))
    }

    func testEncodeArray() throws {
        let value = AnyCodable([1, 2, 3])
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, "[1,2,3]")
    }

    func testEncodeDictionary() throws {
        let value = AnyCodable(["key": "value"])
        let data = try encoder.encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(decoded?["key"], "value")
    }

    func testDecodeString() throws {
        let data = Data("\"hello\"".utf8)
        let value = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(value.value as? String, "hello")
    }

    func testDecodeInt() throws {
        let data = Data("42".utf8)
        let value = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(value.value as? Int, 42)
    }

    func testDecodeBool() throws {
        let data = Data("true".utf8)
        let value = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(value.value as? Bool, true)
    }

    func testDecodeNull() throws {
        let data = Data("null".utf8)
        let value = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertTrue(value.value is NSNull)
    }

    func testDecodeNestedObject() throws {
        let json = """
        {"name": "test", "count": 5, "tags": ["a", "b"]}
        """
        let value = try decoder.decode(AnyCodable.self, from: Data(json.utf8))
        let dict = value.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["name"] as? String, "test")
        XCTAssertEqual(dict?["count"] as? Int, 5)
    }

    func testRoundTrip() throws {
        let original = AnyCodable(["key": "value", "num": 42] as [String: Any])
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
