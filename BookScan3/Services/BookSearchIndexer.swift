import Foundation

/// Fast in-memory tokenized search index for books and OCR page contents.
/// Replaces repeated full O(N*M) page scans with precomputed token matching.
struct BookSearchIndexer: Sendable {
    private var tokenToBookIDs: [String: Set<UUID>] = [:]
    private var bookTitles: [UUID: String] = [:]

    mutating func index(books: [Book]) {
        tokenToBookIDs.removeAll(keepingCapacity: true)
        bookTitles.removeAll(keepingCapacity: true)
        for book in books {
            index(book: book)
        }
    }

    mutating func index(book: Book) {
        bookTitles[book.id] = book.title
        var terms: Set<String> = []
        terms.formUnion(tokenize(book.title))
        for page in book.pages where !page.text.isEmpty {
            terms.formUnion(tokenize(page.text))
        }
        for term in terms {
            tokenToBookIDs[term, default: []].insert(book.id)
        }
    }

    func search(query: String, in books: [Book]) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return books }

        let queryTokens = tokenize(trimmed)
        guard !queryTokens.isEmpty else {
            return books.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }

        var matchingIDs: Set<UUID>?
        for token in queryTokens {
            var tokenMatches: Set<UUID> = []
            for (indexedTerm, ids) in tokenToBookIDs where indexedTerm.contains(token) {
                tokenMatches.formUnion(ids)
            }
            if let current = matchingIDs {
                matchingIDs = current.intersection(tokenMatches)
            } else {
                matchingIDs = tokenMatches
            }
        }

        let candidates = matchingIDs ?? []
        return books.filter { candidates.contains($0.id) }
    }

    private func tokenize(_ text: String) -> Set<String> {
        let clean = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        return Set(clean)
    }
}
