import AppKit

// Agent wrappers re-enter here (`agterm --agterm-exec claude …`) to add MCP servers, then exec
// the real CLI. This must run before any AppKit setup.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--agterm-exec" {
    AgentIntegration.exec(agent: arguments[2], args: Array(arguments.dropFirst(3)))
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
