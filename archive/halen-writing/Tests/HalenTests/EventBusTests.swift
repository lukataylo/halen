import XCTest
@testable import Halen

final class EventBusDropAccountingTests: XCTestCase {
    func testNoDropsWhenSubscriberDrains() async {
        let bus = EventBus()
        let stream = bus.subscribe()

        // Drain in a child task — fast enough that nothing should accumulate
        // in the 64-slot buffer.
        let drained: Task<Int, Never> = Task {
            var n = 0
            for await _ in stream {
                n += 1
                if n >= 10 { break }
            }
            return n
        }

        let event = Event.appFocused(.init(
            appBundleId: "test.app",
            appName: "Test",
            timestamp: Date()
        ))
        for _ in 0..<10 { bus.publish(event) }

        _ = await drained.value
        XCTAssertEqual(bus.totalDrops, 0)
    }

    func testSlowSubscriberAccumulatesDrops() async {
        let bus = EventBus()
        // Subscribe but never iterate — the stream's buffer fills, then
        // every subsequent publish drops the oldest.
        let stream = bus.subscribe()

        let event = Event.appFocused(.init(
            appBundleId: "test.app",
            appName: "Test",
            timestamp: Date()
        ))
        // Buffer is bufferingNewest(64) — 64 events fit, the 65th onward drop.
        for _ in 0..<200 { bus.publish(event) }

        // 200 publishes with a 64-capacity buffer and no draining ⇒ exactly
        // 200 - 64 = 136 drops. `>=` rather than `==` because AsyncStream's
        // internal capacity-vs-watermark behavior isn't a guaranteed-public
        // contract; the lower bound is what we care about.
        XCTAssertGreaterThanOrEqual(bus.totalDrops, 200 - 64)

        // Keep the stream alive so the publish loop above sees a live
        // continuation; without this ARC could release `stream` mid-test
        // and onTermination would clear the drop counter.
        _ = stream
    }
}
