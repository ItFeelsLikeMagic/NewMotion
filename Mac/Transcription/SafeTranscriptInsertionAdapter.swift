import Foundation

/// Keeps Speech insertion on the existing SAFE-001/SAFE-002 policy path.
extension SafeInputInjector: SafeTranscriptInsertionSink {
    @discardableResult
    public func insertTranscript(_ text: String) -> Bool {
        submit(.text(text)) == .applied
    }
}
