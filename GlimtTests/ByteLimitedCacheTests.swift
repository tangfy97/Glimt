import XCTest
@testable import Glimt

final class ByteLimitedCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedFirst() {
        var cache = ByteLimitedCache<String, Int>(budget: 30)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)
        cache.insert(3, for: "c", cost: 10)
        _ = cache.value(for: "a")
        cache.insert(4, for: "d", cost: 10)
        cache.evict(toFit: cache.budget, keeping: [])
        XCTAssertNotNil(cache.value(for: "a"), "recently used survives")
        XCTAssertNil(cache.value(for: "b"), "least recently used goes first")
        XCTAssertEqual(cache.totalCost, 30)
    }

    func testPinnedEntriesAreNeverEvicted() {
        var cache = ByteLimitedCache<String, Int>(budget: 10)
        cache.insert(1, for: "current", cost: 50)
        cache.insert(2, for: "other", cost: 5)
        cache.evict(toFit: 0, keeping: ["current"])
        XCTAssertTrue(cache.contains("current"))
        XCTAssertFalse(cache.contains("other"))
    }

    func testReplacingAnEntryKeepsCostAccurate() {
        var cache = ByteLimitedCache<String, Int>(budget: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "a", cost: 10)
        XCTAssertEqual(cache.totalCost, 10)
        cache.removeAll { _ in true }
        XCTAssertEqual(cache.totalCost, 0)
    }
}
