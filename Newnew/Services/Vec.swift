import Accelerate
import Foundation

/// Vector math on `[Float]`, with Accelerate.
nonisolated enum Vec {
  static func normalized(_ v: [Float]) -> [Float] {
    let length = sqrt(vDSP.sumOfSquares(v))
    return length > 0 ? vDSP.divide(v, length) : v
  }

  /// Cosine similarity of two normalised vectors.
  static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    return vDSP.dot(a, b)
  }

  static func mean(_ vectors: [[Float]]) -> [Float]? {
    guard let first = vectors.first else { return nil }
    var sum = [Float](repeating: 0, count: first.count)
    for v in vectors where v.count == sum.count { vDSP.add(sum, v, result: &sum) }
    return vDSP.divide(sum, Float(vectors.count))
  }

  /// Mean-pooled sentence vectors all lean the same way (any two headlines score ~0.9), so
  /// they're compared after taking away the corpus mean and normalising again.
  static func centred(_ v: [Float], mean: [Float]?) -> [Float] {
    guard let mean, mean.count == v.count else { return v }
    return normalized(vDSP.subtract(v, mean))
  }

  static func data(_ v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }

  static func vector(_ data: Data?) -> [Float]? {
    guard let data, !data.isEmpty else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  /// Several vectors of `dimension` stored one after another.
  static func vectors(_ data: Data?, dimension: Int) -> [[Float]] {
    guard let flat = vector(data), dimension > 0 else { return [] }
    return stride(from: 0, to: flat.count - dimension + 1, by: dimension).map { Array(flat[$0..<$0 + dimension]) }
  }
}
