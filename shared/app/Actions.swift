// What the app's commands ask of the shell: the Mac's menu bar and an
// iPad's keyboard (apple/host's PlaygroundCommands: File › New Project ⌘N,
// Project › Run ⌘R). The commands live in the scene, the state they act on
// in the shell's views, so a command counts its request here and the view
// that answers it (PlaygroundRoot, the ProjectView open) watches the count;
// the views say back what can be asked (a project is open).

import Observation

@MainActor @Observable
public final class PlaygroundActions {
    public static let shared = PlaygroundActions()

    /// Whether the host makes projects (New Project).
    public internal(set) var canMakeProjects = false
    /// Whether a project is open (Run).
    public internal(set) var projectOpen = false

    /// Each command's requests, counted.
    private(set) var newProjectRequests = 0
    private(set) var runRequests = 0

    public func newProject() { newProjectRequests += 1 }
    public func run() { runRequests += 1 }
}
