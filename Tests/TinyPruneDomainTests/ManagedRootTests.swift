#if canImport(XCTest)
import XCTest
@testable import TinyPruneDomain

final class ManagedRootTests: XCTestCase {
    func testRejectsProtectedSystemLocationsAndDescendants() {
        for path in ["/Applications", "/Applications/TinyPrune", "/System/Library", "/usr/local"] {
            XCTAssertThrowsError(try ManagedRoot(displayName: "Protected", path: path, bookmarkData: Data([1]))) {
                XCTAssertEqual($0 as? ManagedRootValidationError, .dangerousPath)
            }
        }
    }

    func testAcceptsUserManagedWorkspace() throws {
        let root = try ManagedRoot(
            displayName: "Projects",
            path: "/Users/example/Developer",
            bookmarkData: Data([1])
        )

        XCTAssertEqual(root.path, "/Users/example/Developer")
    }
}
#endif
