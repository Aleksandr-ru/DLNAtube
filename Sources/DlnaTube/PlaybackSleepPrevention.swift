import Foundation

final class PlaybackSleepPrevention {
    static let preferenceKey = "preventSleepDuringPlayback"

    private var activity: NSObjectProtocol?
    private let beginActivity: () -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void

    init(
        beginActivity: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "DLNAtube video playback"
            )
        },
        endActivity: @escaping (NSObjectProtocol) -> Void = {
            ProcessInfo.processInfo.endActivity($0)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func update(enabled: Bool, playing: Bool) {
        if enabled && playing {
            if activity == nil { activity = beginActivity() }
        } else if let activity {
            endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        if let activity { endActivity(activity) }
    }
}
