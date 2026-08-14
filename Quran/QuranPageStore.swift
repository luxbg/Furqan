import Foundation

struct QuranPageStore {
    let pageCount = 604

    func svgURL(for page: Int) -> URL? {
        guard (1...pageCount).contains(page) else {
            return nil
        }

        let filename = String(format: "%03d", page)
        return Bundle.main.url(forResource: filename, withExtension: "svg")
            ?? Bundle.main.url(forResource: filename, withExtension: "svg", subdirectory: "MushafPages")
    }
}
