import Foundation

/// Where a project's memory lives. agterm always runs its own copy of the memory server; for a
/// folder agmux knows, it keeps reading and writing agmux's store (~/.agmux/projects/<id>) in
/// place, so memory carries on whether or not agmux is still installed and nothing is copied.
public struct ProjectMemory: Equatable, Sendable {
    public let project: AgmuxProject
    /// Holds memory.json and handoffs.json.
    public let dataDir: String
    /// Where the server writes its MEMORY.md / SESSIONS.md copies: nil for agmux's projects
    /// (the repo's .agmux folder, as agmux does), else the store's own folder, so agterm doesn't
    /// leave untracked files in every repo an agent starts in.
    public let projectionDir: String?

    public init(project: AgmuxProject, dataDir: String, projectionDir: String? = nil) {
        self.project = project
        self.dataDir = dataDir
        self.projectionDir = projectionDir
    }

    public var store: String { dataDir + "/memory.json" }
    public var handoffStore: String { dataDir + "/handoffs.json" }

    public func env(sessionID: String) -> [String: String] {
        project.memoryEnv(dataDir: dataDir, sessionID: sessionID, projectionDir: projectionDir)
    }

    /// The memory for an agent started in `cwd`: agmux's project and store for folders in
    /// agmux's database, else the git repo's own store in `agtermProjectsDir`. If both stores
    /// exist (agterm ran without agmux for a while), the one written last is the one in use.
    public static func resolve(cwd: String, agmuxProjects: [AgmuxProject], home: String, agtermProjectsDir: String,
                               isRepoRoot: (String) -> Bool, modified: (String) -> Date?) -> ProjectMemory? {
        let own = AgmuxProject.standalone(cwd, isRepoRoot: isRepoRoot)
            .map { ProjectMemory(project: $0, dataDir: agtermProjectsDir + "/" + $0.id, projectionDir: agtermProjectsDir + "/" + $0.id) }
        guard let agmux = AgmuxProject.match(cwd, in: agmuxProjects)
            .map({ ProjectMemory(project: $0, dataDir: "\(home)/.agmux/projects/\($0.id)") }) else { return own }
        guard let own, let ownDate = modified(own.store) else { return agmux }
        guard let agmuxDate = modified(agmux.store) else { return own }
        return ownDate > agmuxDate ? own : agmux
    }
}
