// Minimal XCTest stand-in for machines with only Command Line Tools (no Xcode, no XCTest.framework).
// Supports the subset used by ios/Recall/Tests: XCTestCase, setUp, sync/async/throwing tests, XCTAssert*.
// It is NOT XCTest; passing here is evidence, not a substitute for running the suite in Xcode.
import Foundation

public var __failures = 0

open class XCTestCase {
    public required init() {}
    open func setUp() {}
    open func tearDown() {}
}

func __fail(_ msg: String, _ file: StaticString, _ line: UInt) {
    __failures += 1
    print("  FAIL \(file):\(line): \(msg)")
}
public func XCTFail(_ m: String = "", file: StaticString = #filePath, line: UInt = #line) { __fail(m, file, line) }
public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !e() { __fail("XCTAssertTrue failed \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() { __fail("XCTAssertFalse failed \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { __fail("\(x) != \(y) \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if abs(x - y) > accuracy { __fail("\(x) !~ \(y) \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try e() { __fail("expected nil, got \(v) \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try e() == nil { __fail("expected non-nil \(m())", file, line) } } catch { __fail("threw \(error)", file, line) }
}
