import Foundation
import XCTest
@testable import TestUtils

final class TemporaryDbBuilderTests: XCTestCase {
    func testCreatesAndRemovesIsolatedTemporaryDirectory() throws {
        var databases: TemporaryTestDatabases? = TemporaryDbBuilder.build()
        let rootURL = try XCTUnwrap(databases?.rootURL)

        XCTAssertEqual(rootURL.deletingLastPathComponent(), FileManager.default.temporaryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
        XCTAssertTrue(databases?.dataDB.path.hasPrefix(rootURL.path) == true)
        XCTAssertTrue(databases?.fsCacheDbRoot.path.hasPrefix(rootURL.path) == true)

        databases = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }
}
