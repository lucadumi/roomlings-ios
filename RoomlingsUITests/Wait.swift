import Foundation

/// Shared runners render the room in software, so a loaded machine stretches every
/// transition. These budgets are only spent when something is genuinely broken, so they
/// buy reliability without slowing a healthy run.
enum Wait {
    /// A native control appearing, changing label, or finishing a sheet transition.
    static let control: TimeInterval = 45
    /// Anything that has to travel through the bundled web renderer.
    static let room: TimeInterval = 90
    /// How long a room control gets to report its new state before it is tapped again.
    static let flip: TimeInterval = 20
}
