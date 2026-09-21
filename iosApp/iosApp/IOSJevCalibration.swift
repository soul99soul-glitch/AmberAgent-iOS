import Foundation

/// 一个置信分桶：桶内样本数、实际正确率、平均置信。
struct IOSJevCalibrationBucket: Equatable {
    /// 桶下界（含），上界为下一桶下界（末桶含 1.0）。
    var lowerBound: Double
    var count: Int
    var accuracy: Double
    var meanConfidence: Double
}

/// 校准度量：把（置信, 是否正确）样本分桶，输出每桶准确率与 ECE。
///
/// 用途：shadow/active 期积累真实观测后，逐用途画校准曲线、定
/// `IOSJevPolicy.*MinConfidence` 弃权线——独立评测（扑克/SVG/校准审计）
/// 证明供应商默认阈值不可信，必须自带金标准逐用例评测。
/// 纯函数，无网络、无存储、无线程状态。
enum IOSJevCalibration {
    /// 分桶校准表。samples 中置信非有限或越界 [0,1] 的条目被丢弃；
    /// bucketCount < 1 按 1 计。空桶不出现（count=0 的桶不返回）。
    static func buckets(
        _ samples: [(confidence: Double, correct: Bool)],
        bucketCount: Int = 10
    ) -> [IOSJevCalibrationBucket] {
        let lanes = max(1, bucketCount)
        var counts = [Int](repeating: 0, count: lanes)
        var corrects = [Int](repeating: 0, count: lanes)
        var confidenceSums = [Double](repeating: 0, count: lanes)
        for sample in samples {
            let confidence = sample.confidence
            guard confidence.isFinite, (0...1).contains(confidence) else { continue }
            // confidence == 1 落末桶；其余按下界对齐。
            let lane = min(Int(confidence * Double(lanes)), lanes - 1)
            counts[lane] += 1
            confidenceSums[lane] += confidence
            if sample.correct { corrects[lane] += 1 }
        }
        return (0..<lanes).compactMap { lane in
            guard counts[lane] > 0 else { return nil }
            return IOSJevCalibrationBucket(
                lowerBound: Double(lane) / Double(lanes),
                count: counts[lane],
                accuracy: Double(corrects[lane]) / Double(counts[lane]),
                meanConfidence: confidenceSums[lane] / Double(counts[lane])
            )
        }
    }

    /// 期望校准误差：Σ(桶占比 × |桶准确率 − 桶平均置信|)。
    /// 全部样本被丢弃时为 0（无数据不报错，由调用方区分"无数据"与"校准好"）。
    static func expectedCalibrationError(
        _ samples: [(confidence: Double, correct: Bool)],
        bucketCount: Int = 10
    ) -> Double {
        let table = buckets(samples, bucketCount: bucketCount)
        let total = table.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        return table.reduce(0.0) { partial, bucket in
            partial + (Double(bucket.count) / Double(total)) * abs(bucket.accuracy - bucket.meanConfidence)
        }
    }
}
