import Foundation

/// Port of `qrc/corpus/loader.py` + `qrc/corpus/index.py`.
final class PhonemeCorpus {
    let ayahsInOrder: [PhonemeAyahEntry]
    let globalWords: [PhonemeGlobalWordEntry]
    /// Concatenation of every global word's phoneme text, NO separator --
    /// the model's alphabet has no space/word-boundary token, so the raw
    /// ASR stream is never space-delimited either.
    let corpusText: String
    /// `corpusText`'s Unicode *scalars* (codepoints), matching Python
    /// string indexing -- see `PhonemeScalars.swift`. All char-offset math
    /// (`charOffsets`, the locator's search, the aligner's DP) operates in
    /// this scalar index space, never Swift `Character`/grapheme space.
    let corpusScalars: [Unicode.Scalar]
    /// charOffsets[i] = start scalar offset of globalWords[i] in corpusScalars.
    let charOffsets: [Int]

    init(ayahsInOrder: [PhonemeAyahEntry], globalWords: [PhonemeGlobalWordEntry], corpusText: String, charOffsets: [Int]) {
        self.ayahsInOrder = ayahsInOrder
        self.globalWords = globalWords
        self.corpusText = corpusText
        self.corpusScalars = corpusText.phonemeScalars
        self.charOffsets = charOffsets
    }

    func wordAt(_ globalWordIdx: Int) -> PhonemeGlobalWordEntry? {
        guard globalWordIdx >= 0, globalWordIdx < globalWords.count else { return nil }
        return globalWords[globalWordIdx]
    }

    /// Map a char offset in `corpusText` back to the nearest global word
    /// index -- port of `bisect.bisect_right(char_offsets, offset) - 1`.
    func globalWordIdx(forCharOffset offset: Int) -> Int {
        var lo = 0
        var hi = charOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if charOffsets[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let i = lo - 1
        return max(0, min(i, globalWords.count - 1))
    }

    var corpusCharCount: Int { corpusScalars.count }
}

// MARK: - JSON shapes

private struct RawAyahEntry: Decodable {
    let aya_text: String
    let aya_phoneme: String
    let aya_phonemes_list: [String]
}

private struct RawWordSpan: Decodable {
    let text: String?
    let phoneme_text: String
    let isolated_phoneme_text: String?
    let continued_phoneme_text: String?
}

private struct RawMapEntry: Decodable {
    let words: [RawWordSpan]
    let continues_previous: Bool
}

enum PhonemeCorpusError: Error {
    case badAyahKey(String)
    case missingBundleResources
}

extension PhonemeCorpus {
    /// Build the corpus from the two bundled JSON resources -- port of
    /// `build_corpus`. `word_text_map.json` is indexed by *original* corpus
    /// phoneme-word position (one slot per ayah's `aya_phonemes_list`
    /// entry, in ayahs-in-order traversal), not by `global_word_idx` (which
    /// is reassigned fresh per real written word and shifts as soon as an
    /// earlier ayah contains a split).
    static func build(orderedPhonemesURL: URL, wordTextMapURL: URL) throws -> PhonemeCorpus {
        let ayahsData = try Data(contentsOf: orderedPhonemesURL)
        let rawAyahs = try JSONDecoder().decode([String: RawAyahEntry].self, from: ayahsData)

        var ayahs: [PhonemeAyahEntry] = []
        ayahs.reserveCapacity(rawAyahs.count)
        for (key, value) in rawAyahs {
            let parts = key.split(separator: ":")
            guard parts.count == 2, let surah = Int(parts[0]), let ayah = Int(parts[1]) else {
                throw PhonemeCorpusError.badAyahKey(key)
            }
            ayahs.append(PhonemeAyahEntry(
                ref: PhonemeAyahRef(surah: surah, ayah: ayah),
                ayaText: value.aya_text,
                ayaPhoneme: value.aya_phoneme,
                words: value.aya_phonemes_list
            ))
        }
        ayahs.sort { ($0.ref.surah, $0.ref.ayah) < ($1.ref.surah, $1.ref.ayah) }

        let mapData = try Data(contentsOf: wordTextMapURL)
        let wordTextMap = try JSONDecoder().decode([RawMapEntry].self, from: mapData)

        var globalWords: [PhonemeGlobalWordEntry] = []
        var corpusParts: [String] = []
        var charOffsets: [Int] = []
        var cursor = 0
        var originalGwi = 0

        for ayah in ayahs {
            var localIdx = 0
            for wordPhonemes in ayah.words {
                let entry: RawMapEntry? = originalGwi < wordTextMap.count ? wordTextMap[originalGwi] : nil
                originalGwi += 1

                let subWords: [RawWordSpan] = entry?.words ?? [RawWordSpan(text: nil, phoneme_text: wordPhonemes, isolated_phoneme_text: nil, continued_phoneme_text: nil)]
                let continuesPrevious = entry?.continues_previous ?? false

                for (subIdx, subWord) in subWords.enumerated() {
                    let gwi = globalWords.count
                    let phonemeText = subWord.phoneme_text
                    globalWords.append(PhonemeGlobalWordEntry(
                        globalWordIdx: gwi,
                        surah: ayah.ref.surah,
                        ayah: ayah.ref.ayah,
                        localWordIdx: localIdx,
                        phonemeText: phonemeText,
                        wordText: subWord.text,
                        isolatedPhonemeText: subWord.isolated_phoneme_text,
                        continuedPhonemeText: subWord.continued_phoneme_text,
                        // Only the *first* row of a split unit carries the
                        // original entry's own continues_previous (a
                        // muqatta'at split) - every row after the first is
                        // a fresh real word.
                        wordTextContinuesPrevious: subIdx == 0 ? continuesPrevious : false
                    ))
                    charOffsets.append(cursor)
                    corpusParts.append(phonemeText)
                    cursor += phonemeText.phonemeScalars.count
                    localIdx += 1
                }
            }
        }

        let corpusText = corpusParts.joined()
        return PhonemeCorpus(ayahsInOrder: ayahs, globalWords: globalWords, corpusText: corpusText, charOffsets: charOffsets)
    }

    /// Convenience for the two real call sites (`RecitationSession`, and
    /// tests that want the real corpus): resolve both JSON resources from
    /// `Bundle.main` and build.
    static func loadFromBundle() throws -> PhonemeCorpus {
        guard let ayahsURL = Bundle.main.url(forResource: "ordered_quran_phonemes", withExtension: "json"),
              let mapURL = Bundle.main.url(forResource: "word_text_map", withExtension: "json") else {
            throw PhonemeCorpusError.missingBundleResources
        }
        return try build(orderedPhonemesURL: ayahsURL, wordTextMapURL: mapURL)
    }
}
