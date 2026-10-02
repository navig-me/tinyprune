import Testing
import Foundation
@testable import TinyPruneDomain

@Suite struct ManagedRootTests {
    @Test func testRejectsProtectedSystemLocationsAndDescendants() {
        for path in ["/Applications", "/Applications/TinyPrune", "/System/Library", "/usr/local"] {
            #expect(throws: ManagedRootValidationError.dangerousPath) { _ = try ManagedRoot(displayName: "Protected", path: path, bookmarkData: Data([1])) }
        }
    }

    @Test func testAcceptsUserManagedWorkspace() throws {
        let root = try ManagedRoot(
            displayName: "Projects",
            path: "/Users/example/Developer",
            bookmarkData: Data([1])
        )

        #expect(root.path == "/Users/example/Developer")
    }
}
