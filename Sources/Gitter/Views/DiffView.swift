import SwiftUI

/// Callbacks a diff view uses to stage/unstage/discard hunks and line selections.
struct DiffActions {
    let primaryTitle: String
    let primary: (String) async -> Void
    let secondaryTitle: String?
    let secondary: ((String) async -> Void)?
    /// When true, line-selection patches are built for `apply --reverse` (unstaging).
    let reverseForSelection: Bool
}

struct DiffView: View {
    let files: [FileDiff]
    var actions: DiffActions? = nil
    var showFileHeaders = false
    @State private var selectedLines: Set<Int> = []
    @State private var settings = AppSettings.shared

    var body: some View {
        let _ = Perf.log("DiffView body files=\(files.count)")
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(files) { file in
                    Section {
                        if file.isBinary {
                            Text("Binary file changed").foregroundStyle(.secondary).padding()
                        } else if file.hunks.isEmpty {
                            Text(file.isNewFile ? "Empty file added" : (file.isDeletedFile ? "File deleted" : (file.headerLines.contains { $0.hasPrefix("old mode") } ? "File mode changed" : "No textual changes")))
                                .foregroundStyle(.secondary).padding()
                        }
                        ForEach(file.hunks) { hunk in
                            HunkHeaderView(file: file, hunk: hunk, actions: actions, selectedLines: $selectedLines)
                            ForEach(hunk.lines.filter { $0.kind != .hunkHeader }) { line in
                                DiffLineView(line: line, language: SyntaxHighlighter.language(for: file.displayPath), fontSize: settings.diffFontSize, highlight: settings.syntaxHighlighting, isSelected: selectedLines.contains(line.id), selectable: actions != nil && line.isChange)
                                    .onTapGesture {
                                        guard actions != nil, line.isChange else { return }
                                        if NSEvent.modifierFlags.contains(.shift), let anchor = selectedLines.max(), anchor != line.id {
                                            let range = min(anchor, line.id)...max(anchor, line.id)
                                            for l in hunk.lines where range.contains(l.id) && l.isChange { selectedLines.insert(l.id) }
                                        } else if selectedLines.contains(line.id) {
                                            selectedLines.remove(line.id)
                                        } else {
                                            selectedLines.insert(line.id)
                                        }
                                    }
                            }
                            Rectangle().fill(.quaternary).frame(height: 1).padding(.vertical, 6)
                        }
                    } header: {
                        if showFileHeaders {
                            HStack(spacing: 8) {
                                FileIcon(path: file.displayPath)
                                Text(file.displayPath).fontWeight(.semibold)
                                if let old = file.oldPath, let new = file.newPath, old != new {
                                    Text("(renamed from \(old))").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(DiffSummary.text(for: [file])).foregroundStyle(.secondary).font(.callout.monospaced())
                            }
                            .font(.callout)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .id(files.hashValue)
        .onChange(of: files) { _, _ in selectedLines.removeAll() }
    }
}

enum DiffSummary {
    static func text(for files: [FileDiff]) -> String {
        let chunks = files.reduce(0) { $0 + $1.hunks.count }
        let adds = files.reduce(0) { $0 + $1.additions }
        let dels = files.reduce(0) { $0 + $1.deletions }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        return "\(plural(chunks, "chunk")), \(plural(adds, "insertion")), \(plural(dels, "deletion"))"
    }
}

struct HunkHeaderView: View {
    let file: FileDiff
    let hunk: DiffHunk
    let actions: DiffActions?
    @Binding var selectedLines: Set<Int>

    private var selectedInHunk: Set<Int> { selectedLines.intersection(hunk.changeLineIDs) }

    var body: some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let actions {
                let selected = selectedInHunk
                if !selected.isEmpty {
                    Button("\(actions.primaryTitle) \(selected.count) Line\(selected.count == 1 ? "" : "s")") {
                        if let patch = file.patch(for: hunk, selectedLineIDs: selected, reverse: actions.reverseForSelection) {
                            Task { await actions.primary(patch); selectedLines.subtract(selected) }
                        }
                    }
                    if let secondaryTitle = actions.secondaryTitle, let secondary = actions.secondary {
                        Button("\(secondaryTitle) Lines", role: .destructive) {
                            if let patch = file.patch(for: hunk, selectedLineIDs: selected, reverse: true) {
                                Task { await secondary(patch); selectedLines.subtract(selected) }
                            }
                        }
                    }
                    Button("Clear") { selectedLines.subtract(selected) }
                } else {
                    if let secondaryTitle = actions.secondaryTitle, let secondary = actions.secondary {
                        Button("\(secondaryTitle) Chunk", role: .destructive) { Task { await secondary(file.patch(for: hunk)) } }
                    }
                    Button("\(actions.primaryTitle) Chunk") { Task { await actions.primary(file.patch(for: hunk)) } }
                }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 1) }
    }
}

struct DiffLineView: View {
    let line: DiffLine
    let language: SyntaxHighlighter.Language?
    let fontSize: Double
    let highlight: Bool
    let isSelected: Bool
    let selectable: Bool

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.3) }
        switch line.kind {
        case .addition: return Color(red: 0.86, green: 0.96, blue: 0.86)
        case .deletion: return Color(red: 0.99, green: 0.87, blue: 0.87)
        case .meta: return Color.gray.opacity(0.08)
        default: return .clear
        }
    }

    private var gutterOld: String {
        switch line.kind {
        case .deletion: "−\(line.oldNumber ?? 0)"
        case .context: line.oldNumber.map(String.init) ?? ""
        default: ""
        }
    }
    private var gutterNew: String {
        switch line.kind {
        case .addition: "+\(line.newNumber ?? 0)"
        case .context: line.newNumber.map(String.init) ?? ""
        default: ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(gutterOld)
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(line.kind == .deletion ? Color.red : Color.secondary)
                .padding(.trailing, 6)
            Rectangle().fill(.quaternary).frame(width: 1)
            Text(gutterNew)
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(line.kind == .addition ? Color.green : Color.secondary)
                .padding(.trailing, 6)
            Rectangle().fill(.quaternary).frame(width: 1)
            Text(highlight ? SyntaxHighlighter.highlight(line.text.replacingOccurrences(of: "\t", with: "    "), language: language) : AttributedString(line.text.replacingOccurrences(of: "\t", with: "    ")))
                .foregroundStyle(line.kind == .meta ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 2)
        .background(background)
        .background(alignment: .leading) {
            if line.kind != .context { Color.clear }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if selectable {
                Rectangle().fill(isSelected ? Color.accentColor : .clear).frame(width: 3)
            }
        }
        .textSelection(.enabled)
    }
}

/// File-type icon similar to Tower's colored document glyphs.
struct FileIcon: View {
    let path: String

    private var spec: (String, Color) {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": ("swift", .orange)
        case "rb", "erb": ("diamond.fill", .red)
        case "py": ("chevron.left.forwardslash.chevron.right", .blue)
        case "js", "jsx", "ts", "tsx", "mjs": ("curlybraces", .yellow)
        case "json", "yml", "yaml", "toml", "plist", "xml": ("list.bullet.indent", .gray)
        case "md", "markdown", "txt", "rst": ("doc.text", .secondary)
        case "html", "htm", "css", "scss": ("globe", .teal)
        case "png", "jpg", "jpeg", "gif", "svg", "pdf", "icns": ("photo", .purple)
        case "sh", "bash", "zsh": ("terminal", .green)
        case "go": ("g.circle", .cyan)
        case "rs": ("gearshape.2", .brown)
        case "c", "h", "cpp", "hpp", "m", "mm": ("c.square", .indigo)
        case "java", "kt": ("cup.and.saucer", .red)
        case "lock": ("lock.doc", .gray)
        default: ("doc", .secondary)
        }
    }

    var body: some View {
        Image(systemName: spec.0)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(spec.1)
            .frame(width: 20, height: 20)
            .background(spec.1.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Lightweight regex-based syntax coloring for common languages.
enum SyntaxHighlighter {
    enum Language { case cLike, swift, python, ruby, shell, json, yaml, markup, css, markdown, go, rust }

    static func language(for path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "js", "jsx", "ts", "tsx", "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "cs", "php", "scala", "dart", "groovy": .cLike
        case "go": .go
        case "rs": .rust
        case "py": .python
        case "rb", "rake", "gemspec", "erb": .ruby
        case "sh", "bash", "zsh", "fish", "makefile", "mk": .shell
        case "json": .json
        case "yml", "yaml", "toml", "ini", "cfg", "conf": .yaml
        case "html", "htm", "xml", "plist", "svg", "xaml", "vue": .markup
        case "css", "scss", "sass", "less": .css
        case "md", "markdown", "rst", "txt": .markdown
        default: path.hasSuffix("Makefile") || path.hasSuffix("Dockerfile") || path.hasSuffix("Gemfile") ? .shell : nil
        }
    }

    private static let keywordSets: [Language: Set<String>] = [
        .swift: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await", "init", "self", "Self", "true", "false", "nil", "private", "public", "internal", "fileprivate", "static", "final", "some", "any", "where", "as", "is", "defer", "do", "repeat", "typealias", "associatedtype", "override", "mutating", "inout", "actor", "nonisolated", "lazy", "weak", "unowned", "subscript", "operator", "precedencegroup", "super", "willSet", "didSet", "get", "set"],
        .cLike: ["function", "const", "let", "var", "if", "else", "return", "class", "interface", "enum", "import", "export", "from", "for", "in", "of", "while", "switch", "case", "default", "break", "continue", "throw", "try", "catch", "finally", "async", "await", "new", "this", "true", "false", "null", "undefined", "void", "int", "long", "float", "double", "char", "bool", "boolean", "string", "public", "private", "protected", "static", "final", "abstract", "extends", "implements", "package", "struct", "typedef", "namespace", "using", "template", "typename", "auto", "override", "virtual", "fun", "val", "when", "object", "data", "sealed", "type", "yield", "do", "goto", "sizeof", "delete", "instanceof", "typeof"],
        .go: ["func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default", "return", "package", "import", "break", "continue", "fallthrough", "select", "goto", "true", "false", "nil", "string", "int", "int64", "bool", "error", "byte"],
        .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "while", "loop", "if", "else", "match", "return", "use", "mod", "crate", "self", "Self", "super", "where", "as", "ref", "move", "async", "await", "dyn", "const", "static", "unsafe", "type", "true", "false", "Some", "None", "Ok", "Err", "String", "Vec", "Option", "Result", "Box"],
        .python: ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "for", "in", "while", "try", "except", "finally", "raise", "with", "lambda", "pass", "break", "continue", "and", "or", "not", "is", "None", "True", "False", "yield", "async", "await", "global", "nonlocal", "del", "assert", "self"],
        .ruby: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "return", "require", "include", "do", "while", "until", "for", "in", "begin", "rescue", "ensure", "yield", "self", "nil", "true", "false", "and", "or", "not", "then", "case", "when", "attr_accessor", "attr_reader", "private", "public", "lambda", "proc", "raise"],
        .shell: ["if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac", "in", "function", "return", "exit", "export", "local", "echo", "set", "unset", "source", "cd", "ls", "rm", "cp", "mv", "mkdir", "git", "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "WORKDIR", "ENTRYPOINT", "EXPOSE", "ARG", "gem", "source", "group"],
        .css: ["important", "media", "import", "keyframes", "font-face", "supports"],
    ]

    static let keyword = Color(red: 0.68, green: 0.18, blue: 0.60)
    static let typeName = Color(red: 0.10, green: 0.45, blue: 0.75)
    static let number = Color(red: 0.11, green: 0.33, blue: 0.80)
    static let string = Color(red: 0.77, green: 0.10, blue: 0.09)
    static let comment = Color(red: 0.42, green: 0.47, blue: 0.53)
    static let symbol = Color(red: 0.16, green: 0.55, blue: 0.75)

    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var keywordPatterns: [Language: String] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = regexCache[key] { return cached }
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        if let compiled { regexCache[key] = compiled }
        return compiled
    }

    private static func keywordPattern(for language: Language) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = keywordPatterns[language] { return cached }
        guard let keywords = keywordSets[language] else { return nil }
        let pattern = "\\b(" + keywords.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        keywordPatterns[language] = pattern
        return pattern
    }

    static func highlight(_ text: String, language: Language?) -> AttributedString {
        var result = AttributedString(text)
        guard let language, !text.isEmpty else { return result }
        let ns = text as NSString
        func color(_ range: NSRange, _ c: Color) {
            guard let r = Range(range, in: text), let ar = Range(r, in: result) else { return }
            result[ar].foregroundColor = c
        }
        func apply(_ pattern: String, _ c: Color, options: NSRegularExpression.Options = []) {
            guard let regex = regex(pattern, options: options) else { return }
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) { color(m.range, c) }
        }

        switch language {
        case .markdown:
            apply(#"^#{1,6} .*$"#, typeName)
            apply(#"\*\*[^*]+\*\*"#, keyword)
            apply(#"`[^`]+`"#, string)
            apply(#"\[[^\]]+\]\([^)]+\)"#, symbol)
            return result
        case .markup:
            apply(#"</?[A-Za-z][\w:.-]*"#, typeName)
            apply(#"\b[\w:-]+(?==)"#, keyword)
            apply(#""[^"]*"|'[^']*'"#, string)
            apply(#"<!--.*?-->"#, comment)
            return result
        case .json:
            apply(#""[^"\\]*(?:\\.[^"\\]*)*"(?=\s*:)"#, typeName)
            apply(#":\s*"[^"\\]*(?:\\.[^"\\]*)*""#, string)
            apply(#"\b(true|false|null)\b"#, keyword)
            apply(#"(?<=[:,\[\s])-?\d+(\.\d+)?([eE][+-]?\d+)?"#, number)
            return result
        case .yaml:
            apply(#"^\s*[\w.-]+(?=\s*[:=])"#, typeName, options: .anchorsMatchLines)
            apply(#""[^"]*"|'[^']*'"#, string)
            apply(#"#.*$"#, comment, options: .anchorsMatchLines)
            apply(#"\b(true|false|null|yes|no)\b"#, keyword)
            return result
        case .css:
            apply(#"[.#]?[\w-]+(?=\s*\{)"#, typeName)
            apply(#"[\w-]+(?=\s*:)"#, symbol)
            apply(#"#[0-9a-fA-F]{3,8}\b|\b\d+(\.\d+)?(px|em|rem|%|vh|vw|s|ms)?\b"#, number)
            apply(#"/\*.*?\*/"#, comment)
            return result
        default:
            break
        }

        if let pattern = keywordPattern(for: language) {
            apply(pattern, keyword)
        }
        apply(#"\b[A-Z][A-Za-z0-9_]*\b"#, typeName)
        if language == .ruby { apply(#"(?<![\w:]):[a-zA-Z_]\w*[?!]?|@\w+"#, symbol) }
        apply(#"\b\d+(\.\d+)?\b"#, number)
        apply(#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, string)
        switch language {
        case .python, .ruby, .shell, .yaml:
            apply(#"#.*$"#, comment)
        default:
            apply(#"//.*$"#, comment)
            apply(#"/\*.*?\*/"#, comment)
        }
        return result
    }
}
