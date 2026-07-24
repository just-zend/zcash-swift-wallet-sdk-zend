//
//  DataHexEncodedTests.swift
//  ZcashLightClientKit
//
//  Tests for the internal `Data(hexEncoded:)` initializer used by the Ironwood migration
//  broadcast composites to turn the crate's hex `MigrationPreparedDelivery.txid` into bytes.
//

import XCTest
@testable import ZcashLightClientKit

final class DataHexEncodedTests: XCTestCase {
    func testDecodesLowercaseHex() {
        let data = Data(hexEncoded: "deadbeef")
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testDecodesUppercaseHex() {
        let data = Data(hexEncoded: "DEADBEEF")
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testDecodesEmptyStringToEmptyData() {
        let data = Data(hexEncoded: "")
        XCTAssertEqual(data, Data())
    }

    func testReturnsNilForOddLengthString() {
        XCTAssertNil(Data(hexEncoded: "abc"))
    }

    func testReturnsNilForNonHexCharacters() {
        XCTAssertNil(Data(hexEncoded: "zz"))
        XCTAssertNil(Data(hexEncoded: "12g4"))
    }

    func testRoundTripsWithHexEncodedString() {
        let bytes = Data([0x00, 0x01, 0x5c, 0xf9, 0xff])
        let decoded = Data(hexEncoded: bytes.hexEncodedString())
        XCTAssertEqual(decoded, bytes)
    }
}
