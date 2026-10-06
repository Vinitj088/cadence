import Foundation

/// Turns spoken code into code, for terminals and editors:
/// "git commit dash m" → "git commit -m", "dash dash force" → "--force",
/// "src slash app dot tsx" → "src/app.tsx", "camel case user id" → "userId".
enum CodeFormatter {
    static func format(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        words = applyCasing(words)
        words = applySymbols(words)
        return words.joined(separator: " ")
            .replacingOccurrences(of: #"\s+([,.;:!?])(\s|$)"#, with: "$1$2", options: .regularExpression)
    }

    // MARK: - Casing

    private enum Casing { case camel, pascal, snake, kebab, screaming }

    /// Words that end a casing run: "camel case user id for the form" → "userId for the form".
    private static let runBreakers: Set<String> = [
        "to", "and", "in", "the", "for", "with", "please", "from", "then", "on", "of", "at", "as", "into", "is", "a", "an", "or", "but", "so",
        // Spoken symbols end the run so "snake case max retry dot py" keeps its extension.
        "dot", "slash", "dash", "underscore", "colon", "equals", "pipe",
    ]

    private static func applyCasing(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            let pair = i + 1 < words.count ? (bare(words[i]) + " " + bare(words[i + 1])) : ""
            let casing: Casing? = switch pair {
            case "camel case": .camel
            case "pascal case": .pascal
            case "snake case": .snake
            case "kebab case": .kebab
            case "screaming snake", "constant case": .screaming
            default: nil
            }
            guard let casing else {
                out.append(words[i])
                i += 1
                continue
            }
            // Collect the run: up to 5 words, stopping at punctuation or a connective.
            var run: [String] = []
            var trailing = ""
            var j = i + 2
            while j < words.count, run.count < 5, !runBreakers.contains(bare(words[j])) {
                let word = words[j]
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                if !core.isEmpty { run.append(core.lowercased()) }
                j += 1
                if word != core, let last = word.last, ",.;:!?".contains(last) {
                    trailing = String(last)
                    break
                }
            }
            guard !run.isEmpty else {
                out.append(words[i])
                i += 1
                continue
            }
            out.append(join(run, casing) + trailing)
            i = j
        }
        return out
    }

    private static func join(_ parts: [String], _ casing: Casing) -> String {
        switch casing {
        case .camel: parts[0] + parts.dropFirst().map(\.capitalized).joined()
        case .pascal: parts.map(\.capitalized).joined()
        case .snake: parts.joined(separator: "_")
        case .kebab: parts.joined(separator: "-")
        case .screaming: parts.joined(separator: "_").uppercased()
        }
    }

    // MARK: - Symbols

    private enum Glue { case both, right, spaced }

    private static let symbols: [String: (String, Glue)] = [
        "slash": ("/", .both), "backslash": ("\\", .both), "underscore": ("_", .both), "tilde": ("~", .right),
        "dash": ("-", .right), "hyphen": ("-", .right), "equals": ("=", .both), "colon": (":", .both),
        "pipe": ("|", .spaced), "ampersand": ("&", .spaced), "asterisk": ("*", .right), "hash": ("#", .right),
    ]

    private static let fileExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "mjs", "json", "md", "py", "swift", "go", "rs", "rb", "java", "kt", "c", "h", "cpp", "cs",
        "html", "css", "scss", "yml", "yaml", "toml", "env", "lock", "sh", "zsh", "txt", "csv", "sql", "xml", "plist", "log",
        "io", "com", "dev", "org", "net", "ai", "app", "gitignore", "config", "local", "png", "svg", "pdf", "vue", "php",
    ]

    private static func applySymbols(_ words: [String]) -> [String] {
        var tokens = words
        // Two-word spoken symbols.
        var merged: [String] = []
        var i = 0
        while i < tokens.count {
            let next = i + 1 < tokens.count ? bare(tokens[i + 1]) : ""
            switch (bare(tokens[i]), next) {
            case ("back", "slash"): merged.append("backslash"); i += 2
            case ("dash", "dash"), ("double", "dash"): merged.append("--"); i += 2
            case ("at", "sign"): merged.append("@"); i += 2
            case ("dollar", "sign"): merged.append("$"); i += 2
            default: merged.append(tokens[i]); i += 1
            }
        }
        tokens = merged

        var out: [String] = []
        var glueNext = false
        for (index, token) in tokens.enumerated() {
            let key = bare(token)
            let next = index + 1 < tokens.count ? bare(tokens[index + 1]) : ""
            var symbol: String?
            var glue: Glue = .spaced

            let previous = out.last.map(bare) ?? ""
            if token == "--" || token == "$" {
                symbol = token
                glue = .right
            } else if token == "@" {
                // "name at sign example dot com" → "name@example.com"; "email at sign…" keeps its space.
                symbol = "@"
                glue = detached.contains(previous) || previous.isEmpty ? .right : .both
            } else if key == "dot", !next.isEmpty, fileExtensions.contains(next) || next.count <= 2 {
                // Only before an extension-like word, so "connect the dots" is left alone.
                symbol = "."
                glue = detached.contains(previous) || previous.isEmpty ? .right : .both
            } else if let (s, g) = symbols[key], key != "dash" || isFlagLike(next) {
                symbol = s
                glue = g
            }

            if let symbol {
                let trailing = token.last.map { ",.;:!?".contains($0) && token.count > 1 ? String($0) : "" } ?? ""
                switch glue {
                case .both:
                    if let last = out.popLast() { out.append(last + symbol + trailing) } else { out.append(symbol + trailing) }
                    glueNext = true
                case .right:
                    if glueNext, let last = out.popLast() { out.append(last + symbol + trailing) } else { out.append(symbol + trailing) }
                    glueNext = true
                case .spaced:
                    out.append(symbol + trailing)
                    glueNext = false
                }
                continue
            }

            if glueNext, let last = out.popLast() {
                out.append(last + token)
            } else {
                out.append(token)
            }
            glueNext = false
        }
        return out
    }

    /// "dash m", "dash v", "dash rf": a flag. "dash off a note" is prose.
    private static func isFlagLike(_ next: String) -> Bool {
        let longFlags: Set<String> = ["force", "help", "version", "verbose", "all", "global", "save", "dev", "watch", "name", "message", "recursive", "port", "rf", "la"]
        let shortWords: Set<String> = ["in", "on", "to", "up", "it", "of", "at", "by", "or", "an", "as", "is", "so", "we", "me", "my", "no", "off", "out", "the", "and"]
        return longFlags.contains(next) || (!next.isEmpty && next.count <= 2 && !shortWords.contains(next))
    }

    /// Words a following "." or "@" shouldn't attach to: "cat dot env" → "cat .env", not "cat.env".
    private static let detached: Set<String> = [
        "cat", "open", "ls", "cd", "vim", "vi", "nano", "code", "touch", "rm", "mv", "cp", "source", "edit", "read", "check",
        "run", "in", "the", "to", "at", "from", "and", "or", "a", "an", "my", "our", "your", "with", "file", "me", "email", "is",
    ]

    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
