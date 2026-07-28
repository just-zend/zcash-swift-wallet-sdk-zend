//
//  WitnessesFixVersionGateTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

class WitnessesFixVersionGateTests: XCTestCase {
    private struct VersionCase {
        let recorded: String
        let current: String
        let shouldRun: Bool
        let note: String
    }

    func testRunsWhenNoVersionIsRecorded() {
        XCTAssertTrue(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: nil, currentVersion: "2.9.0"))
    }

    func testVersionPairsAreComparedNumerically() {
        let cases: [VersionCase] = [
            // Plain upgrades keep running the fix.
            VersionCase(recorded: "2.9.0", current: "3.0.0", shouldRun: true, note: "major bump"),
            VersionCase(recorded: "2.9.0", current: "2.9.1", shouldRun: true, note: "patch bump"),
            // Single→double-digit boundaries are the regression this pins:
            // lexicographic String comparison orders "2.10.0" before "2.9.0".
            VersionCase(recorded: "2.9.0", current: "2.10.0", shouldRun: true, note: "minor single→double digit"),
            VersionCase(recorded: "2.9.9", current: "2.10.0", shouldRun: true, note: "minor boundary from patch"),
            VersionCase(recorded: "2.4.9", current: "2.4.10", shouldRun: true, note: "patch single→double digit"),
            // Same version runs only once.
            VersionCase(recorded: "2.10.0", current: "2.10.0", shouldRun: false, note: "same version"),
            // Downgrades do not re-run the fix.
            VersionCase(recorded: "2.10.0", current: "2.9.0", shouldRun: false, note: "downgrade"),
            VersionCase(recorded: "3.0.0", current: "2.99.0", shouldRun: false, note: "downgrade across major"),
            // Missing components count as zero.
            VersionCase(recorded: "3.8", current: "3.8.0", shouldRun: false, note: "3.8 equals 3.8.0"),
            VersionCase(recorded: "3.8", current: "3.9", shouldRun: true, note: "two-component upgrade"),
            VersionCase(recorded: "3.8.1", current: "3.9", shouldRun: true, note: "two-component upgrade from patch")
        ]

        for testCase in cases {
            XCTAssertEqual(
                SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: testCase.recorded, currentVersion: testCase.current),
                testCase.shouldRun,
                "(\(testCase.recorded) → \(testCase.current)) expected shouldRun == \(testCase.shouldRun) — \(testCase.note)"
            )
        }
    }

    func testUnorderableVersionsRunTheFixOncePerVersionString() {
        // Versions that cannot be parsed numerically cannot be ordered; the gate
        // must fail open (run the fix) rather than risk skipping a repair…
        XCTAssertTrue(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: "unknown", currentVersion: "3.9.0"))
        XCTAssertTrue(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: "3.9.0", currentVersion: "unknown"))
        XCTAssertTrue(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: "2.9.0-beta", currentVersion: "2.9.0"))
        // …but an identical recorded string means this exact version already ran.
        XCTAssertFalse(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: "unknown", currentVersion: "unknown"))
        XCTAssertFalse(SDKSynchronizer.shouldRunWitnessesFix(lastRecordedVersion: "", currentVersion: ""))
    }
}
