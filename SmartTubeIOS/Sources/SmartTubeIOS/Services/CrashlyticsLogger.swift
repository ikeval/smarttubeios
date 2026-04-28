import Foundation
import os
import FirebaseCrashlytics
import SmartTubeIOSCore

/// Logs to `os.Logger` and forwards `.notice` and `.error` entries to Firebase
/// Crashlytics as breadcrumbs so they appear in crash reports.
/// `.debug` entries are only written to `os.log` — too verbose for crash reports.
struct CrashlyticsLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(subsystem: String = appSubsystem, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func notice(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
        Crashlytics.crashlytics().log("[\(category)] \(msg)")
    }

    func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        Crashlytics.crashlytics().log("[ERR][\(category)] \(msg)")
    }

    func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        // Not forwarded — too verbose for crash reports
    }

    /// Records a non-fatal error in Crashlytics with additional key-value context.
    /// Use this for surfaced errors the user sees (e.g. player errors) so they
    /// appear as non-fatal issues in the Firebase console.
    func recordNonFatal(_ error: Error, userInfo: [String: String] = [:]) {
        let nsError = error as NSError
        let msg = "[\(category)] \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
        logger.error("\(msg, privacy: .public)")
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log(msg)
        for (key, value) in userInfo {
            crashlytics.setCustomValue(value, forKey: key)
        }
        crashlytics.record(error: error)
    }
}
