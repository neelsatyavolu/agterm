import AgTermSessionKit
import AppKit

// Agent wrappers re-enter here (`agterm --agterm-exec claude …`) to add MCP servers, then exec
// the real CLI. This must run before any AppKit setup.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--agterm-exec" {
    AgentIntegration.exec(agent: arguments[2], args: Array(arguments.dropFirst(3)))
}
// The sessions helper is this executable too (SessionHelper launches it), so its shells keep
// agterm's privacy permissions after the app quits. It never creates NSApplication.
if arguments.count >= 2, arguments[1] == SessionHelperMain.flag {
    SessionHelperMain.run(arguments: arguments)
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
