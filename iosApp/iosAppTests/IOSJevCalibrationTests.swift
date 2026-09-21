import XCTest
@testable import iosApp

// IOSJevCalibrationTests：分桶准确率与 ECE 的纯函数语义——桶归属（含 1.0 末桶）、
// 空桶剔除、越界/非有限样本丢弃、空输入、ECE 已知值。
// 该工具供 shadow 期真实观测数据定逐用途弃权线（A3）。

final class IOSJevCalibrationTests: XCTestCase {

    func testBucketsAssignByLowerBoundAndIncludeOneInLast() {
        let samples: [(Double, Bool)] = [
            (0.05, true), (0.09, false),   // 桶 0
            (0.45, true),                  // 桶 4
            (1.0, true),                   // 末桶（Int(1.0*10)=10 必须夹回 9）
        ]
        let table = IOSJevCalibration.buckets(samples)
        XCTAssertEqual(table.map(\.lowerBound), [0.0, 0.4, 0.9])
        XCTAssertEqual(table.map(\.count), [2, 1, 1])
        XCTAssertEqual(table[0].accuracy, 0.5, accuracy: 1e-9)
        XCTAssertEqual(table[0].meanConfidence, 0.07, accuracy: 1e-9)
        XCTAssertEqual(table[2].accuracy, 1.0, accuracy: 1e-9)
    }

    func testEmptyBucketsAreOmitted() {
        let samples: [(Double, Bool)] = [(0.15, true), (0.85, false)]
        let table = IOSJevCalibration.buckets(samples)
        XCTAssertEqual(table.map(\.lowerBound), [0.1, 0.8], "空桶不出现")
    }

    func testInvalidSamplesAreDropped() {
        let samples: [(Double, Bool)] = [
            (.nan, true), (.infinity, false), (-0.1, true), (1.1, false),
            (0.5, true),
        ]
        let table = IOSJevCalibration.buckets(samples)
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table[0].count, 1, "只有合法样本计入")
    }

    func testPerfectlyCalibratedHasZeroECE() {
        // 桶内平均置信 == 实际正确率 → ECE 0：0.75 置信 × 4 样本中 3 正确。
        let samples: [(Double, Bool)] = [(0.75, true), (0.75, true), (0.75, true), (0.75, false)]
        XCTAssertEqual(IOSJevCalibration.expectedCalibrationError(samples), 0, accuracy: 1e-9)
    }

    func testKnownECEValue() {
        // 10 桶下三个样本各占一桶：0.45 → 桶4（全对，差距 |1−0.45|），
        // 0.55 → 桶5（全对，差距 |1−0.55|），0.9 → 桶9（全错，差距 0.9）。
        // ECE = (0.55 + 0.45 + 0.9) / 3 = 0.6333…
        let samples: [(Double, Bool)] = [(0.45, true), (0.55, true), (0.9, false)]
        XCTAssertEqual(IOSJevCalibration.expectedCalibrationError(samples), 0.6333, accuracy: 1e-3)
    }

    func testEmptyInputYieldsEmptyTableAndZeroECE() {
        XCTAssertTrue(IOSJevCalibration.buckets([]).isEmpty)
        XCTAssertEqual(IOSJevCalibration.expectedCalibrationError([]), 0)
    }

    func testBucketCountBelowOneTreatedAsOne() {
        let samples: [(Double, Bool)] = [(0.2, true), (0.9, false)]
        let table = IOSJevCalibration.buckets(samples, bucketCount: 0)
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table[0].count, 2)
        XCTAssertEqual(table[0].accuracy, 0.5, accuracy: 1e-9)
    }
}
