import Foundation

/// The phoneme pipeline is a direct port of Python code that treats strings
/// as sequences of Unicode *codepoints* (Python 3's `len`/indexing/`in`).
/// Swift's default `String`/`Character` view is extended-grapheme-cluster
/// based instead - a harakah like fatha (U+064E) *combines* with its base
/// letter into a single Swift `Character` (e.g. "بَ" is one `Character` but
/// two Python characters). Since the whole point of this pipeline is
/// catching a single wrong diacritic as its own edit-distance unit, every
/// phoneme string must be handled as `[Unicode.Scalar]`, never
/// `[Character]`/`.count`, throughout the DP aligner, normalizer, and
/// locator.
extension StringProtocol {
    var phonemeScalars: [Unicode.Scalar] { Array(unicodeScalars) }
}

extension Sequence where Element == Unicode.Scalar {
    var scalarString: String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: self)
        return String(view)
    }
}
