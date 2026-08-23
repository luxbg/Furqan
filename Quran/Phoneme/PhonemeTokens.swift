import Foundation

/// Symbol table for the phoneme ASR model - port of `qrc/asr/tokens.py`.
struct PhonemeTokenTable {
    let idToSymbol: [Int: String]
    let symbolToId: [String: Int]
    let blankId: Int

    /// `tokens.txt` is `"<symbol> <id>"` per line, one entry per line (the
    /// symbol may itself contain spaces in principle, so split on the last
    /// space only, matching the Python loader's `rsplit(" ", 1)`).
    static func load(from url: URL) throws -> PhonemeTokenTable {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var idToSymbol: [Int: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let spaceIndex = line.lastIndex(of: " ") else { continue }
            let symbol = String(line[line.startIndex..<spaceIndex])
            guard let id = Int(line[line.index(after: spaceIndex)...]) else { continue }
            idToSymbol[id] = symbol
        }
        var symbolToId: [String: Int] = [:]
        for (id, symbol) in idToSymbol { symbolToId[symbol] = id }
        guard let blankId = symbolToId["<blank>"] else {
            throw PhonemeTokenTableError.noBlankSymbol
        }
        return PhonemeTokenTable(idToSymbol: idToSymbol, symbolToId: symbolToId, blankId: blankId)
    }
}

enum PhonemeTokenTableError: Error {
    case noBlankSymbol
}
