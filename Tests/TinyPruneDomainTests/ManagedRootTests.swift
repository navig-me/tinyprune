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

    @Test func testLibraryRootIsRejectedButSpecificCachesAreAllowed() throws {
        #expect(throws: ManagedRootValidationError.dangerousPath) {
            _ = try ManagedRoot(displayName: "Library", path: "/Users/example/Library", bookmarkData: Data([1]))
        }
        for path in ["/Users/example/Library/Caches/pip", "/Users/example/Library/Caches/Homebrew/downloads", "/Users/example/Library/Developer/Xcode/DerivedData"] {
            let root = try ManagedRoot(displayName: "Cache", path: path, bookmarkData: Data([1]))
            #expect(root.path == path)
        }
    }
}
