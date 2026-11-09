import Foundation

/// Every slash command an agent offers in a folder: its built-ins, then the skills, custom
/// commands and plugin commands it reads from disk, the way its own `/` menu finds them.
/// Reads files, so build it off the main thread.
public enum SlashCatalog {
    /// Where the agents keep their settings; agterm's account folders link these same items.
    public struct Homes: Sendable {
        public var user: URL
        public var claude: URL
        public var codex: URL
        public var grok: URL

        public init(user: URL, claude: URL, codex: URL, grok: URL) {
            self.user = user
            self.claude = claude
            self.codex = codex
            self.grok = grok
        }
    }

    public static func commands(for agent: TimelineFeed.Agent, cwd: String, homes: Homes) -> [SlashCommand] {
        let found: [SlashCommand] = switch agent {
        case .claude: claude(cwd: cwd, homes: homes)
        case .codex: files(in: homes.codex.appendingPathComponent("prompts"), prefix: "prompts:")
        case .grok: grok(cwd: cwd, homes: homes)
        case .agl: []
        }
        return unique(SlashBuiltins.list(agent) + found)
    }

    // MARK: Per agent

    /// Project skills and commands (this folder up to the repo root), yours, then enabled plugins'.
    static func claude(cwd: String, homes: Homes) -> [SlashCommand] {
        let project = folders(from: cwd, homes: homes).flatMap { dir in
            skillsAndCommands(dir.appendingPathComponent(".claude"))
        }
        return project + skillsAndCommands(homes.claude) + plugins(cwd: cwd, homes: homes)
    }

    /// Grok reads its own folders, `.agents/` and Claude's, nearest first.
    static func grok(cwd: String, homes: Homes) -> [SlashCommand] {
        let project = folders(from: cwd, homes: homes).flatMap { dir in
            [".grok", ".agents", ".claude"].flatMap { skillsAndCommands(dir.appendingPathComponent($0)) }
        }
        return project + skillsAndCommands(homes.grok) + skillsAndCommands(homes.claude)
    }

    // MARK: Claude plugins

    /// Commands and skills of the plugins your settings turn on, installed for you or for this
    /// project, named `plugin:command`.
    static func plugins(cwd: String, homes: Homes) -> [SlashCommand] {
        let installed = homes.claude.appendingPathComponent("plugins/installed_plugins.json")
        guard let object = json(installed), let plugins = object["plugins"] as? [String: [[String: Any]]] else { return [] }
        let enabled = enabledPlugins(cwd: cwd, homes: homes)
        return plugins.keys.sorted().flatMap { key -> [SlashCommand] in
            guard enabled[key] == true,
                  let install = plugins[key]?.first(where: { applies($0, cwd: cwd) }),
                  let path = install["installPath"] as? String else { return [] }
            let name = String(key.split(separator: "@").first ?? Substring(key))
            let root = URL(fileURLWithPath: path)
            return (skills(in: root.appendingPathComponent("skills")) + files(in: root.appendingPathComponent("commands")))
                .map { SlashCommand("\(name):\($0.name)", "(\(name)) \($0.about)".trimmingCharacters(in: .whitespaces)) }
        }
    }

    /// `enabledPlugins` from your settings, then the project's, which win.
    private static func enabledPlugins(cwd: String, homes: Homes) -> [String: Bool] {
        var enabled: [String: Bool] = [:]
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        for url in [homes.claude.appendingPathComponent("settings.json"), project.appendingPathComponent("settings.json"),
                    project.appendingPathComponent("settings.local.json")] {
            for (key, value) in json(url)?["enabledPlugins"] as? [String: Bool] ?? [:] { enabled[key] = value }
        }
        return enabled
    }

    /// An install for you everywhere, or for this folder or one above it.
    private static func applies(_ install: [String: Any], cwd: String) -> Bool {
        guard let scope = install["scope"] as? String, scope != "user" else { return true }
        guard let project = install["projectPath"] as? String else { return false }
        return cwd == project || cwd.hasPrefix(project.hasSuffix("/") ? project : project + "/")
    }

    // MARK: Reading folders

    /// The folder and those above it, up to the repo root (the folder holding `.git`), never your
    /// home folder itself, whose `.claude` holds your own settings.
    static func folders(from cwd: String, homes: Homes) -> [URL] {
        guard !cwd.isEmpty else { return [] }
        let home = homes.user.standardizedFileURL.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        var out: [URL] = []
        while dir.path != home, dir.path != "/" {
            out.append(dir)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { break }
            dir.deleteLastPathComponent()
        }
        return out
    }

    private static func skillsAndCommands(_ root: URL) -> [SlashCommand] {
        skills(in: root.appendingPathComponent("skills")) + files(in: root.appendingPathComponent("commands"))
    }

    /// `<dir>/<skill>/SKILL.md`, named by its frontmatter or its folder; hidden when it says
    /// `user-invocable: false`.
    static func skills(in dir: URL) -> [SlashCommand] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { folder in
            guard !folder.hasPrefix("."),
                  let text = try? String(contentsOf: dir.appendingPathComponent(folder).appendingPathComponent("SKILL.md"), encoding: .utf8)
            else { return nil }
            let fields = Frontmatter.fields(text)
            guard fields["user-invocable"]?.lowercased() != "false" else { return nil }
            return SlashCommand(fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder, fields["description"] ?? "")
        }
    }

    /// Markdown commands: `<dir>/<name>.md`, and `<dir>/<group>/<name>.md` as `group:name`.
    /// Described by their frontmatter, else their first line.
    static func files(in dir: URL, prefix: String = "") -> [SlashCommand] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().flatMap { name -> [SlashCommand] in
            guard !name.hasPrefix(".") else { return [] }
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return prefix.isEmpty ? files(in: url, prefix: "\(name):") : []
            }
            guard url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let about = Frontmatter.fields(text)["description"] ?? Frontmatter.firstLine(text)
            return [SlashCommand(prefix + url.deletingPathExtension().lastPathComponent, about)]
        }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The first of each name: built-ins win, then the nearest folder.
    private static func unique(_ commands: [SlashCommand]) -> [SlashCommand] {
        var seen = Set<String>()
        return commands.filter { seen.insert($0.name).inserted }
    }
}

/// The few YAML frontmatter fields a skill or command needs: `key: value` lines between the
/// opening `---` and the next, with `>` / `|` blocks folded onto one line.
enum Frontmatter {
    static func fields(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let open = key, line.first?.isWhitespace == true {
                let more = line.trimmingCharacters(in: .whitespaces)
                fields[open] = [fields[open] ?? "", more].filter { !$0.isEmpty }.joined(separator: " ")
                continue
            }
            key = nil
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ""].contains(value) {
                key = name
                value = ""
            }
            fields[name] = unquote(value)
        }
        return fields
    }

    /// The body's first non-empty line, without a leading `#`.
    static func firstLine(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(end + 1)...]
        }
        let line = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
