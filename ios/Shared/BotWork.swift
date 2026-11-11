import ActivityKit
import Foundation

/// The Live Activity a bot runs while it works on a message: on the lock screen and in the Dynamic Island.
/// Shared by the app (starts and ends it) and the widget extension (draws it). The server ends it by push.
struct BotWorkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "working" or "answered"
        var status: String
        /// The start of the answer once it has landed.
        var text: String
        /// Unix seconds when the message was sent (the timer counts from it).
        var startedAt: Double
        /// How many cards wait on you across all bots (older pushes have none).
        var needs: Int? = nil
    }

    var agentId: String
    var agentName: String
    /// The bot's color (hex), for the face drawn when the build carries no picture of this bot.
    var agentColor: String? = nil
}
