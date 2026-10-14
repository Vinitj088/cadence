import ApplicationServices
import Foundation

/// What Cadence knows about the codebase the user is working in: file paths and the names of
/// types and functions, so "the dictation controller" can become `DictationController` and
/// "at dictation controller" can become `@Sources/Cadence/App/DictationController.swift`.
struct ProjectSnapshot: Sendable {
    let root: URL
    let name: String
    let branch: String?
    /// Repo-relative paths of tracked files.
    let files: [String]
    /// Compound identifiers declared in the code (DictationController, max_retry_count).
    let symbols: [String]
    /// Recently changed files: the likeliest to be talked about.
    let recentFiles: [String]
    let built: Date
}

actor ProjectIndex {
    static let shared = ProjectIndex()

    private var cache: [URL: ProjectSnapshot] = [:]
    private var building: Set<URL> = []

    /// The cached index for `root`, refreshing it in the background when it's older than 10 minutes.
    func snapshot(for root: URL) -> ProjectSnapshot? {
        let cached = cache[root]
        if (cached == nil || Date().timeIntervalSince(cached!.built) > 600), !building.contains(root) {
            building.insert(root)
            Task.detached(priority: .utility) {
                let snapshot = Self.build(root)
                await self.store(snapshot, for: root)
            }
        }
        return cached
    }

    private func store(_ snapshot: ProjectSnapshot?, for root: URL) {
        building.remove(root)
        if let snapshot { cache[root] = snapshot }
    }

    // MARK: - Finding the project

    /// The repository behind the focused window: the folder macOS reports for it, or a folder
    /// named in its title ("cadence — claude", "DictationController.swift — cadence").
    static func root(pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window: AXUIElement = app.attribute(kAXFocusedWindowAttribute) else { return nil }
        if let document: String = window.attribute(kAXDocumentAttribute), let url = URL(string: document), url.isFileURL,
           let root = gitRoot(from: url) {
            return root
        }
        guard let title: String = window.attribute(kAXTitleAttribute) else { return nil }
        // Terminal titles can carry the tab's tty ("… — ttys005"): its foreground process knows the folder.
        if let tty = title.range(of: #"ttys\d+"#, options: .regularExpression).map({ String(title[$0]) }),
           let cwd = foregroundDirectory(tty: tty), let root = gitRoot(from: cwd) {
            return root
        }
        let candidates = title.components(separatedBy: CharacterSet(charactersIn: "—–-|:"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 60 && !$0.contains("×") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parents = ["Documents", "Developer", "Projects", "projects", "code", "Code", "src", "dev", "Desktop", "Documents/worktrees", ""]
            .map { $0.isEmpty ? home : home.appending(path: $0) }
        for name in candidates {
            if name.hasPrefix("~/") || name.hasPrefix("/") {
                let path = name.hasPrefix("~/") ? home.appending(path: String(name.dropFirst(2))) : URL(fileURLWithPath: name)
                if let root = gitRoot(from: path) { return root }
                continue
            }
            for parent in parents {
                let url = parent.appending(path: name, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return url }
            }
        }
        return nil
    }

    /// The working directory of the foreground process on a terminal tty (e.g. the running `claude`).
    static func foregroundDirectory(tty: String) -> URL? {
        guard let output = run(["ps", "-t", tty, "-o", "pid=,stat=,comm="], timeout: 1) else { return nil }
        let rows = output.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true) }.filter { $0.count >= 3 }
        // Prefer the foreground job ("+" in its state), then anything that looks like an agent.
        let foreground = rows.filter { $0[1].contains("+") }
        let pick = foreground.last { $0[2].contains("claude") || $0[2].contains("node") || $0[2].contains("codex") } ?? foreground.last ?? rows.last
        guard let pick, let pid = Int32(pick[0]) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func gitRoot(from url: URL) -> URL? {
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        while dir.path.count > 1, dir.path != home {
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Indexing

    private static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "rs", "kt", "java", "rb", "cs", "cpp", "h", "m", "php", "vue", "svelte",
    ]

    private static func build(_ root: URL) -> ProjectSnapshot? {
        guard let output = run(["git", "-C", root.path, "ls-files"], timeout: 5) else { return nil }
        let files = output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(".") && !$0.contains("/node_modules/") }.prefix(20_000)

        // Declarations: class/struct/func/def/interface/type/const …  name
        let pattern = #"\b(?:class|struct|enum|protocol|actor|extension|func|interface|type|def|fn|function|const|let|var|val|object|trait|impl)\s+([A-Za-z_][A-Za-z0-9_]{3,})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var symbols = Set<String>()
        var scanned = 0
        for file in files where codeExtensions.contains((file as NSString).pathExtension.lowercased()) {
            guard scanned < 2_500, symbols.count < 6_000 else { break }
            let url = root.appending(path: file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? Int ?? 0) < 400_000,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            scanned += 1
            let ns = text as NSString
            regex?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let name = ns.substring(with: match.range(at: 1))
                // Only compound names are worth snapping to: DictationController, max_retry, useAuth.
                if isCompound(name) { symbols.insert(name) }
            }
        }

        let branch = (try? String(contentsOf: root.appending(path: ".git/HEAD"), encoding: .utf8))
            .flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let recent = run(["git", "-C", root.path, "log", "--name-only", "--pretty=format:", "-n", "30"], timeout: 3)?
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
        var seenRecent = Set<String>()
        let recentFiles = recent.filter { seenRecent.insert($0).inserted }.prefix(60)

        logger.notice("project index: \(root.lastPathComponent, privacy: .public) \(files.count, privacy: .public) files, \(symbols.count, privacy: .public) symbols")
        return ProjectSnapshot(
            root: root, name: root.lastPathComponent, branch: branch, files: Array(files),
            symbols: Array(symbols), recentFiles: Array(recentFiles), built: .now
        )
    }

    static func isCompound(_ name: String) -> Bool {
        if name.contains("_") { return name.split(separator: "_").filter { !$0.isEmpty }.count >= 2 }
        let chars = Array(name)
        return chars.dropFirst().contains(where: \.isUppercase) && chars.contains(where: \.isLowercase)
    }

    static func run(_ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Kill a git that hangs (huge repo, network filesystem) rather than wait forever.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
