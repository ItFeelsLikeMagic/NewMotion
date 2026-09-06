import Foundation
#if canImport(PhoneRemoteShared)
import PhoneRemoteShared
#endif

public enum MacPairingOfferState: Equatable {
    case idle
    case active(expiresAt: Date)
    case cancelled
    case expired
}

/// Owns the Mac-facing QR offer lifecycle. The offer store retains the
/// ephemeral private key; this controller exposes only the safe QR text and
/// expiry state to UI code.
public final class MacPairingOfferController {
    public private(set) var state: MacPairingOfferState = .idle
    public private(set) var activeQRText: String?
    public private(set) var activeExpiry: Date?
    public var activePairingID: UUID? { store.activePairingID }

    public var onStateChange: ((MacPairingOfferState) -> Void)?
    public var onOfferReady: ((String, Date) -> Void)?

    private let store: OneTimePairingOfferStore
    private let clock: PairingClock

    public init(
        store: OneTimePairingOfferStore? = nil,
        clock: PairingClock = SystemPairingClock()
    ) {
        self.clock = clock
        self.store = store ?? OneTimePairingOfferStore(clock: clock)
    }

    @discardableResult
    public func issue(displayName: String, lifetime: TimeInterval = PairingToken.maximumLifetime) throws -> PairingOffer {
        let offer = try store.issue(displayName: displayName, lifetime: lifetime)
        activeQRText = offer.qrText
        activeExpiry = offer.token.expiresAt
        transition(to: .active(expiresAt: offer.token.expiresAt))
        if let activeQRText { onOfferReady?(activeQRText, offer.token.expiresAt) }
        return offer
    }

    public func cancel() {
        store.cancel()
        activeQRText = nil
        activeExpiry = nil
        transition(to: .cancelled)
    }

    /// Tick from the Mac UI/run loop. Expiry clears the offer and private key.
    public func tick() {
        guard case .active = state, let expiry = activeExpiry else { return }
        guard clock.now >= expiry else { return }
        store.cancel()
        activeQRText = nil
        activeExpiry = nil
        transition(to: .expired)
    }

    /// This method is primarily useful to the Mac-side BLE pairing coordinator
    /// and attack/replay tests. Consumption is atomic in the underlying store.
    public func consume(encodedToken: String) throws -> PairingOffer {
        let offer = try store.consume(encodedToken: encodedToken)
        activeQRText = nil
        activeExpiry = nil
        transition(to: .idle)
        return offer
    }

    /// Consumes the currently displayed offer by its pairing identifier after
    /// the phone presents a client hello. The QR secret remains local to the
    /// Mac; the underlying store still enforces one-time use and expiry.
    public func consume(pairingID: UUID) throws -> PairingOffer {
        let offer = try store.consume(pairingID: pairingID)
        activeQRText = nil
        activeExpiry = nil
        transition(to: .idle)
        return offer
    }

    private func transition(to next: MacPairingOfferState) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}

#if canImport(CoreImage) && canImport(CoreGraphics)
import CoreImage
import CoreGraphics

public enum PairingQRCodeError: Error, Equatable {
    case unsupportedFilter
    case invalidOutput
    case renderFailed
}

/// QR rendering is kept separate from offer generation so the state machine
/// remains unit-testable without a display or Core Image context.
public struct MacPairingQRCodeRenderer {
    public let context: CIContext

    public init(context: CIContext = CIContext(options: nil)) {
        self.context = context
    }

    public func render(text: String, scale: Int = 8) throws -> CGImage {
        guard !text.isEmpty, scale > 0, scale <= 32 else { throw PairingQRCodeError.invalidOutput }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw PairingQRCodeError.unsupportedFilter
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw PairingQRCodeError.invalidOutput }
        let extent = image.extent.integral
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let output = context.createCGImage(scaled, from: extent.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))) else {
            throw PairingQRCodeError.renderFailed
        }
        return output
    }
}
#endif
