import XCTest
@testable import VocaretCore

final class MicRecorderActivityTests: XCTestCase {
    func testActivitySnapshotKeepsOnlyRequestedTail() {
        var activity = RecordingActivity(sampleRate: 100, maximumTailSeconds: 2)
        activity.append(Array(repeating: 0.2, count: 300))

        let snapshot = activity.snapshot(tailSeconds: 1)

        XCTAssertEqual(snapshot.sampleCount, 300)
        XCTAssertEqual(snapshot.sampleRate, 100)
        XCTAssertEqual(snapshot.tail.count, 100)
        XCTAssertEqual(snapshot.tail, Array(repeating: 0.2, count: 100))
        XCTAssertEqual(snapshot.peakEnergy, 0.2, accuracy: 0.001)
    }

    func testActivityStorageStaysBoundedAcrossLongRecordings() {
        var activity = RecordingActivity(sampleRate: 100, maximumTailSeconds: 2)
        for value in 0..<20 {
            activity.append(Array(repeating: Float(value), count: 100))
        }

        let snapshot = activity.snapshot(tailSeconds: 10)

        XCTAssertEqual(snapshot.sampleCount, 2_000)
        XCTAssertEqual(snapshot.tail.count, 200)
        XCTAssertEqual(snapshot.tail.first, 18)
        XCTAssertEqual(snapshot.tail.last, 19)
    }
}
