import XCTest
@testable import Clearway

final class ShellEnvironmentTests: XCTestCase {

    func testPathAlwaysContainsTheBaselineDirectories() {
        let components = ShellEnvironment.path.split(separator: ":").map(String.init)

        for directory in ShellPathValidation.baseline.split(separator: ":").map(String.init) {
            XCTAssertTrue(components.contains(directory), "\(directory) must always be on the PATH")
        }
    }

    func testProcessEnvironmentCarriesTheResolvedPath() {
        XCTAssertEqual(ShellEnvironment.processEnvironment["PATH"], ShellEnvironment.path)
    }

    /// A cached snapshot would freeze a degraded PATH for the process lifetime and defeat
    /// the background recovery, so the dictionary must be built on each read.
    ///
    /// Proving that needs an observable that changes between two reads, and the process environment
    /// is the only one — hence the `setenv` this suite otherwise avoids. It adds a bespoke key rather
    /// than touching `PATH`, so a subprocess a concurrent test spawns inherits one extra variable and
    /// nothing it depends on.
    func testProcessEnvironmentIsComputedOnEachRead() {
        unsetenv("CLEARWAY_TEST_MARKER")
        XCTAssertNil(ShellEnvironment.processEnvironment["CLEARWAY_TEST_MARKER"])

        setenv("CLEARWAY_TEST_MARKER", "present", 1)
        defer { unsetenv("CLEARWAY_TEST_MARKER") }

        XCTAssertEqual(ShellEnvironment.processEnvironment["CLEARWAY_TEST_MARKER"], "present")
    }
}
