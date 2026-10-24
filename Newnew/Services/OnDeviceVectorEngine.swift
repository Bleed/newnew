import Foundation
import NaturalLanguage

/// Sentence vectors on the device, for bulk work (hundreds of articles per sync): Apple's
/// contextual embedding, mean-pooled over its token vectors and L2-normalised, or the older
/// sentence embedding where the contextual model's assets aren't on the device.
///
/// Never use FoundationModels here: generation is for one story at a time, on a tap.
actor OnDeviceVectorEngine {
  static let shared = OnDeviceVectorEngine()

  enum Kind: String, Sendable {
    case contextual, sentence, none
  }

  private var contextual: NLContextualEmbedding?
  private var sentence: NLEmbedding?
  private var preparing: Task<Void, Never>?
  private(set) var kind: Kind = .none

  var dimension: Int {
    switch kind {
    case .contextual: contextual?.dimension ?? 0
    case .sentence: sentence?.dimension ?? 0
    case .none: 0
    }
  }

  /// Loads the best model available, once.
  func prepare() async {
    if let preparing { return await preparing.value }
    let task = Task { await load() }
    preparing = task
    await task.value
  }

  private func load() async {
    if let model = NLContextualEmbedding(language: .english) {
      if !model.hasAvailableAssets { _ = try? await model.requestAssets() }
      if model.hasAvailableAssets, (try? model.load()) != nil {
        contextual = model
        kind = .contextual
        return
      }
    }
    if let model = NLEmbedding.sentenceEmbedding(for: .english) {
      sentence = model
      kind = .sentence
    }
  }

  /// One normalised vector per text (nil where the model couldn't read it).
  func embed(_ texts: [String]) async -> [[Float]?] {
    await prepare()
    return texts.map(embed)
  }

  private func embed(_ text: String) -> [Float]? {
    switch kind {
    case .contextual:
      guard let contextual, let result = try? contextual.embeddingResult(for: text, language: .english) else { return nil }
      var sum = [Double](repeating: 0, count: contextual.dimension)
      var count = 0.0
      result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
        for i in sum.indices { sum[i] += vector[i] }
        count += 1
        return true
      }
      guard count > 0 else { return nil }
      return Vec.normalized(sum.map { Float($0 / count) })
    case .sentence:
      return sentence?.vector(for: text).map { Vec.normalized($0.map(Float.init)) }
    case .none:
      return nil
    }
  }
}
