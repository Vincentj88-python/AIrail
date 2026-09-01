import XCTest
@testable import AIrail

final class AIrailTests: XCTestCase {

    // MARK: Snapshot math

    func testPercentClamp() {
        XCTAssertEqual(UsageSnapshot.clampPercent(-12), 0)
        XCTAssertEqual(UsageSnapshot.clampPercent(150), 100)
        XCTAssertEqual(UsageSnapshot.clampPercent(0), 0)
        XCTAssertEqual(UsageSnapshot.clampPercent(62), 62)
        XCTAssertEqual(UsageSnapshot.clampPercent(100), 100)
    }

    func testWeeklyPercentMath() {
        XCTAssertEqual(UsageSnapshot.percent(used: 1240, limit: 2000), 62)
        XCTAssertEqual(UsageSnapshot.percent(used: 0, limit: 2000), 0)
        XCTAssertEqual(UsageSnapshot.percent(used: 500, limit: 100), 100) // clamped
        XCTAssertNil(UsageSnapshot.percent(used: 10, limit: 0))
        XCTAssertNil(UsageSnapshot.percent(used: nil, limit: 100))
        XCTAssertNil(UsageSnapshot.percent(used: 10, limit: nil))
    }

    func testLastUpdatedString() {
        let now = Date()
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now, now: now), "just now")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-30), now: now), "30s ago")
        XCTAssertEqual(UsageFormatting.lastUpdatedString(now.addingTimeInterval(-300), now: now), "5m ago")
    }

    // MARK: Provider registry

    @MainActor
    func testProviderRegistryIdsUnique() {
        let providers = ProviderManager.makeProviders()
        let ids = providers.map { $0.id }
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, ids.count, "provider ids must be unique")
        XCTAssertEqual(Set(ids), Set(AppSettings.allProviderIds))
    }

    // MARK: Mock data

    @MainActor
    func testMockSnapshotsAreDemoWithSevenDayHistory() async {
        for provider in ProviderManager.makeProviders() {
            let snapshot = await provider.fetchUsage()
            XCTAssertEqual(snapshot.providerId, provider.id)
            XCTAssertEqual(snapshot.weeklyHistory.count, 7)
            XCTAssertEqual(snapshot.status, .demo, "v1 never pretends live numbers")
            if let percent = snapshot.sessionPercent {
                XCTAssertTrue((0...100).contains(percent))
            }
            if let weekly = snapshot.weeklyPercent {
                XCTAssertTrue((0...100).contains(weekly))
            }
        }
    }

    // MARK: Brand icons

    func testBrandIconPathsParseWithinViewBox() {
        XCTAssertEqual(BrandIcons.all.count, 5)
        for data in BrandIcons.all {
            let path = SVGPathParser.parse(data)
            XCTAssertFalse(path.isEmpty, "brand icon must produce a non-empty path")
            let box = path.boundingRect
            XCTAssertTrue(box.minX >= -0.5 && box.minY >= -0.5, "path escapes the 24×24 viewBox")
            XCTAssertTrue(box.maxX <= 24.5 && box.maxY <= 24.5, "path escapes the 24×24 viewBox")
            XCTAssertTrue(box.width > 10 && box.height > 10, "icon suspiciously small — parser likely bailed early")
        }
    }

    @MainActor
    func testRandomWalkIsSlowAndBounded() {
        let walk = RandomWalk(start: 50, maxStep: 2)
        var previous = walk.value
        for _ in 0..<100 {
            let next = walk.step()
            XCTAssertLessThanOrEqual(abs(next - previous), 2.0001, "walk must drift, not jump")
            XCTAssertTrue((1...97).contains(next))
            previous = next
        }
    }
}
