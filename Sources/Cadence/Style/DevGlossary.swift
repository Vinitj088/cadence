import Foundation

/// How developer tools and terms are usually misheard, and how they're written.
enum DevGlossary {
    private struct Entry {
        let written: String
        let spoken: [String]
        /// Only in terminals, editors and AI chats, where the dev meaning is near certain.
        let devOnly: Bool
    }

    private static let entries: [Entry] = [
        Entry(written: "Claude Code", spoken: ["cloud code", "clawed code", "clod code", "claude code"], devOnly: true),
        Entry(written: "Claude", spoken: ["clawed", "clod"], devOnly: true),
        Entry(written: "ChatGPT", spoken: ["chat gpt", "j gpt", "jgpt", "chad gpt", "chat g p t", "chat gbt", "chatgpt"], devOnly: false),
        Entry(written: "GPT", spoken: ["g p t", "gbt"], devOnly: true),
        Entry(written: "OpenAI", spoken: ["open ai", "open a i", "openai"], devOnly: false),
        Entry(written: "Anthropic", spoken: ["anthropic", "anthropics"], devOnly: false),
        Entry(written: "GitHub", spoken: ["git hub", "github", "get hub"], devOnly: false),
        Entry(written: "GitLab", spoken: ["git lab"], devOnly: false),
        Entry(written: "Copilot", spoken: ["co-pilot", "co pilot", "copilot"], devOnly: true),
        Entry(written: "TypeScript", spoken: ["type script", "typescript"], devOnly: false),
        Entry(written: "JavaScript", spoken: ["java script", "javascript"], devOnly: false),
        Entry(written: "Next.js", spoken: ["next js", "next dot js", "nextjs"], devOnly: false),
        Entry(written: "Node.js", spoken: ["node js", "node dot js", "nodejs"], devOnly: false),
        Entry(written: "React Native", spoken: ["react native"], devOnly: false),
        Entry(written: "Postgres", spoken: ["post gres", "postgres", "post grass", "postgre"], devOnly: false),
        Entry(written: "PostgreSQL", spoken: ["postgre sql", "postgres sql", "postgres q l"], devOnly: false),
        Entry(written: "SQLite", spoken: ["sequel lite", "sql lite", "sequel light", "s q lite"], devOnly: false),
        Entry(written: "MySQL", spoken: ["my sql", "my sequel"], devOnly: false),
        Entry(written: "OAuth", spoken: ["o auth", "oh auth", "oauth"], devOnly: false),
        Entry(written: "localhost", spoken: ["local host"], devOnly: true),
        Entry(written: "JSON", spoken: ["jason", "j son"], devOnly: true),
        Entry(written: "YAML", spoken: ["yaml", "yamel", "yammel"], devOnly: true),
        Entry(written: "regex", spoken: ["reg ex", "red x", "rejects"], devOnly: true),
        Entry(written: "API", spoken: ["a p i"], devOnly: false),
        Entry(written: "CLI", spoken: ["c l i"], devOnly: false),
        Entry(written: "LLM", spoken: ["l l m"], devOnly: false),
        Entry(written: "MCP", spoken: ["m c p"], devOnly: false),
        Entry(written: "npm", spoken: ["n p m"], devOnly: true),
        Entry(written: "pnpm", spoken: ["p n p m"], devOnly: true),
        Entry(written: "macOS", spoken: ["mac os", "macos", "mac o s"], devOnly: false),
        Entry(written: "iOS", spoken: ["i os", "i o s", "ios"], devOnly: false),
        Entry(written: "Xcode", spoken: ["x code", "xcode"], devOnly: false),
        Entry(written: "SwiftUI", spoken: ["swift ui", "swift u i"], devOnly: false),
        Entry(written: "VS Code", spoken: ["vs code", "v s code", "visual studio code"], devOnly: false),
        Entry(written: "Kubernetes", spoken: ["cooper netties", "kuber netes", "kubernetes"], devOnly: false),
        Entry(written: "Tailwind", spoken: ["tail wind"], devOnly: true),
        Entry(written: "Vercel", spoken: ["versel", "vercel", "ver cell"], devOnly: true),
        Entry(written: "Supabase", spoken: ["supa base", "super base", "supabase"], devOnly: true),
        Entry(written: "Redis", spoken: ["red is", "reddis"], devOnly: true),
        Entry(written: "Docker", spoken: ["docker"], devOnly: true),
        Entry(written: "Cursor", spoken: ["cursor"], devOnly: false),
        Entry(written: "PR", spoken: ["p r"], devOnly: true),
        Entry(written: "README", spoken: ["read me", "readme"], devOnly: true),
        Entry(written: "env", spoken: ["e n v"], devOnly: true),
    ]

    /// Built once: (regex, written, devOnly), longest spoken forms first.
    private static let compiled: [(NSRegularExpression, String, Bool)] = entries
        .flatMap { entry in entry.spoken.map { ($0, entry.written, entry.devOnly) } }
        .sorted { $0.0.count > $1.0.count }
        .compactMap { spoken, written, devOnly in
            let words = spoken.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?i)(?<![\w.])"# + words.joined(separator: #"[\s\-]+"#) + #"(?![\w])"#
            return (try? NSRegularExpression(pattern: pattern)).map { ($0, written, devOnly) }
        }

    static func apply(_ text: String, devContext: Bool) -> String {
        var t = text
        for (regex, written, devOnly) in compiled where devContext || !devOnly {
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: NSRegularExpression.escapedTemplate(for: written))
        }
        return t
    }
}
