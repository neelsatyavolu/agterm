import Foundation

/// Installing a moved repo's dependencies on the cloud machine. Move to Cloud leaves
/// `node_modules`, virtualenvs and the like on the Mac (they are big, and Mac builds don't run on
/// Linux), so the cloud tab installs them before its agent resumes, as cloud agents' setup
/// scripts do. Each install is skipped while its lockfile is unchanged and its output is there.
public enum CloudSetup {
    /// One install: what to run in the repo, the files whose change makes it run again, and the
    /// folder it fills (nil: only the files decide).
    public struct Step: Equatable {
        public let name: String
        public let command: String
        public let inputs: [String]
        public let output: String?

        public init(name: String, command: String, inputs: [String], output: String?) {
            self.name = name
            self.command = command
            self.inputs = inputs
            self.output = output
        }
    }

    /// The repo's own setup script, used instead of the steps agterm knows.
    public static let customScript = ".agterm/cloud-setup.sh"

    /// The installs for a repo whose top level holds `files` (and `customScript` if it exists).
    public static func steps(files: Set<String>) -> [Step] {
        if files.contains(customScript) {
            return [Step(name: customScript, command: "sh \(customScript)", inputs: [customScript], output: nil)]
        }
        var steps: [Step] = []
        // One JavaScript package manager: the lockfile says which.
        if files.contains("package-lock.json") {
            steps.append(Step(name: "npm ci", command: "npm ci", inputs: ["package-lock.json"], output: "node_modules"))
        } else if files.contains("pnpm-lock.yaml") {
            steps.append(Step(name: "pnpm install", command: "npx --yes pnpm install --frozen-lockfile", inputs: ["pnpm-lock.yaml"], output: "node_modules"))
        } else if files.contains("yarn.lock") {
            steps.append(Step(name: "yarn install", command: "npx --yes yarn install --frozen-lockfile", inputs: ["yarn.lock"], output: "node_modules"))
        } else if let lock = ["bun.lock", "bun.lockb"].first(where: files.contains) {
            steps.append(Step(name: "bun install", command: "npx --yes bun install --frozen-lockfile", inputs: [lock], output: "node_modules"))
        }
        if files.contains("requirements.txt") {
            steps.append(Step(name: "pip install", command: "python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt",
                              inputs: ["requirements.txt"], output: ".venv"))
        }
        return steps
    }

    /// A POSIX sh script that runs `steps` in `folder`, each only when its inputs changed since it
    /// last succeeded there or its output is missing. Failures are reported and passed over, so
    /// the agent still starts. Nil when there is nothing to install.
    public static func script(folder: String, steps: [Step]) -> String? {
        guard !steps.isEmpty else { return nil }
        var lines = ["cd \(quoted(folder)) || exit 0", "state=\"$HOME/.agterm/setup\"", "mkdir -p \"$state\""]
        for (index, step) in steps.enumerated() {
            let marker = "\"$state/$(printf %s \(quoted(folder + "#" + step.name)) | cksum | cut -d' ' -f1)\""
            let key = "$(cat \(step.inputs.map(quoted).joined(separator: " ")) 2>/dev/null | cksum)"
            let present = step.output.map { "[ -e \(quoted($0)) ] && " } ?? ""
            lines += [
                "key\(index)=\"\(key)\"",
                "if ! { \(present)[ \"$(cat \(marker) 2>/dev/null)\" = \"$key\(index)\" ]; }; then",
                "  echo \(quoted("agterm: installing dependencies (\(step.name))…"))",
                "  if \(step.command); then printf %s \"$key\(index)\" > \(marker)",
                "  else echo \(quoted("agterm: \(step.name) failed; the agent continues without it.")); fi",
                "fi",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` as one sh word.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// How big a move is, so a large one asks first.
public enum CloudCopySize {
    /// Moves past this many bytes ask before anything stops.
    public static let askAbove: Int64 = 1 << 30

    /// "3.2 GB", "450 MB".
    public static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Minutes the copy takes at `bytesPerSecond`, at least 1.
    public static func minutes(_ bytes: Int64, bytesPerSecond: Int64 = 20 << 20) -> Int {
        max(1, Int((Double(bytes) / Double(bytesPerSecond) / 60).rounded(.up)))
    }
}
