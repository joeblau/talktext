import Foundation

/// The bundle identifier is declared once in the canonical `Info.plist`. Read it
/// from the running bundle so logging subsystems and the default paste target
/// cannot drift from the assembled artifact. The literal is the fallback for
/// contexts without a host bundle, such as the test runner.
enum AppIdentity {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.joeblau.talktext"
}
