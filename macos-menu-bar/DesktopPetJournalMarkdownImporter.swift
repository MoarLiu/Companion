import Foundation

enum PetJournalMarkdownImporter {
    static func document(fromMarkdown markdown: String, fallbackTitle: String) -> PetJournalDocument {
        var title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [PetJournalOutlineItem] = []

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let headingLevel = min(line.prefix { $0 == "#" }.count, 6)
                let text = line.drop { $0 == "#" }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if title.isEmpty || title == fallbackTitle {
                    title = text
                }
                items.append(PetJournalOutlineItem(text: text, level: max(headingLevel - 1, 0)))
                continue
            }

            let markerPattern = #"^(\s*)([-*+]|\d+\.)\s+(.*)$"#
            if let range = rawLine.range(of: markerPattern, options: .regularExpression) {
                let matched = String(rawLine[range])
                let leadingSpaces = matched.prefix { $0 == " " || $0 == "\t" }
                let level = min(max(leadingSpaces.reduce(0) { result, character in
                    result + (character == "\t" ? 2 : 1)
                } / 2, 0), 5)
                let stripped = matched.replacingOccurrences(of: markerPattern, with: "$3", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    items.append(PetJournalOutlineItem(text: stripped, level: level))
                }
                continue
            }

            items.append(PetJournalOutlineItem(text: line, level: 0))
        }

        if items.isEmpty {
            items = [PetJournalOutlineItem(text: title.isEmpty ? "导入的 Markdown" : title, level: 0)]
        }

        if title.isEmpty {
            title = derivedTitle(from: items)
        }

        return PetJournalDocument(
            title: title,
            items: items,
            hasCustomTitle: true
        )
    }

    private static func derivedTitle(from items: [PetJournalOutlineItem]) -> String {
        let firstText = items
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstText, !firstText.isEmpty else {
            return "Untitled"
        }

        if firstText.count <= 28 {
            return firstText
        }

        let index = firstText.index(firstText.startIndex, offsetBy: 28)
        return "\(firstText[..<index])..."
    }
}
