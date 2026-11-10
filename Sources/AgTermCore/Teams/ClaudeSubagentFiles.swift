import Foundation

extension ClaudeTranscript {
    /// The transcripts of a session's subagents and workflow agents, next to its own
    /// `<project>/<session>.jsonl`: every `.jsonl` under `<project>/<session>/subagents`,
    /// including `subagents/workflows/<run>/`.
    public static func subagentFiles(of transcript: URL) -> [URL] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" { files.append(file) }
        return files.sorted { $0.path < $1.path }
    }
}
