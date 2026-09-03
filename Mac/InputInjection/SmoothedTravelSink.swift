import Foundation

/// Spreads one packet of cursor or scroll travel across the next few display
/// frames.
///
/// Bluetooth delivers a batch roughly every 30 ms, so the raw stream moves
/// about 30 times a second however fast the phone sends: packets that land in
/// the same connection event are posted microseconds apart and the screen draws
/// them as one jump.  Gliding the travel out over several frames trades up to
/// one packet of lag for motion the eye reads as continuous.
///
/// Cursor and scroll glide independently, because they are separate streams
/// that happen to share a link.  Anything that is not travel flushes both, so a
/// click still lands where the cursor was heading rather than behind it.
public final class SmoothedTravelSink: InputEventSink, @unchecked Sendable {
    /// One tick per frame on a 120 Hz display.  A 60 Hz display simply
    /// composites two ticks into one frame, which costs nothing.
    private static let tick: TimeInterval = 1.0 / 120
    /// Frames a fresh packet is spread over.  Four at 120 Hz is 33 ms, about
    /// one packet interval, which bounds the added lag at roughly that.
    private static let glideFrames = 4

    /// Travel waiting to be handed out over the next few frames.  Whole units
    /// go now and the fraction rides along, so nothing is lost to rounding.
    private struct Glide {
        var x = 0.0
        var y = 0.0
        var framesLeft = 0

        var isDrained: Bool { framesLeft == 0 && abs(x) < 0.5 && abs(y) < 0.5 }

        mutating func add(x deltaX: Double, y deltaY: Double, frames: Int) {
            x += deltaX
            y += deltaY
            framesLeft = frames
        }

        /// This frame's share.  Dividing by the frames left rather than taking
        /// a fixed fraction empties the buffer on a deadline instead of
        /// trailing an ever-smaller remainder behind the hand.
        mutating func step() -> (x: Double, y: Double) {
            guard framesLeft > 1 else { return take() }
            let share = Double(framesLeft)
            let stepX = (x / share).rounded()
            let stepY = (y / share).rounded()
            x -= stepX
            y -= stepY
            framesLeft -= 1
            return (stepX, stepY)
        }

        mutating func take() -> (x: Double, y: Double) {
            let wholeX = x.rounded()
            let wholeY = y.rounded()
            x -= wholeX
            y -= wholeY
            framesLeft = 0
            return (wholeX, wholeY)
        }

        mutating func clear() {
            x = 0
            y = 0
            framesLeft = 0
        }
    }

    private let wrapped: InputEventSink
    private let queue = DispatchQueue(label: "phoneremote.input.smoothing")
    private let lock = NSLock()
    private var pointer = Glide()
    private var scroll = Glide()
    private var timer: DispatchSourceTimer?
    private var cursorFlag = true
    private var scrollFlag = false
    private var minimumFlag = SmoothedTravelSink.defaultMinimumSmoothed

    /// A packet smaller than this is posted whole instead of glided.  Slow
    /// aiming sends a few points per packet, where one step is already too
    /// small to see stepping in, so smoothing there buys nothing and costs the
    /// glide's lag exactly where the hand is being careful.
    public static let defaultMinimumSmoothed = 8.0

    public init(
        wrapping sink: InputEventSink,
        cursor: Bool = true,
        scroll: Bool = false,
        minimumSmoothed: Double = SmoothedTravelSink.defaultMinimumSmoothed
    ) {
        self.wrapped = sink
        self.cursorFlag = cursor
        self.scrollFlag = scroll
        self.minimumFlag = max(0, minimumSmoothed)
    }

    /// Zero smooths every move, however small.
    public var minimumSmoothedDelta: Double {
        get { lock.withLock { minimumFlag } }
        set {
            lock.lock()
            minimumFlag = max(0, newValue)
            lock.unlock()
        }
    }

    public var smoothsCursor: Bool {
        get { lock.withLock { cursorFlag } }
        set {
            lock.lock()
            cursorFlag = newValue
            lock.unlock()
            // Turning it off must not strand travel mid-glide.
            if !newValue { flush() }
        }
    }

    /// Off by default.  Splitting one scroll into several smaller ones makes
    /// macOS and the app on screen accelerate it less, so the page moves a
    /// shorter distance for the same flick, and the momentum tail arrives as
    /// uneven steps.  The glide is not worth those two costs.
    public var smoothsScroll: Bool {
        get { lock.withLock { scrollFlag } }
        set {
            lock.lock()
            scrollFlag = newValue
            lock.unlock()
            if !newValue { flush() }
        }
    }

    public func waitForPostedInput() {
        wrapped.waitForPostedInput()
    }

    public func send(_ event: InjectedInputEvent) throws {
        switch event {
        case let .pointer(delta):
            guard smoothsCursor else {
                try wrapped.send(event)
                return
            }
            let magnitude = (delta.x * delta.x + delta.y * delta.y).squareRoot()
            guard magnitude >= minimumSmoothedDelta else {
                // Straight through, but never past travel already gliding, or
                // the cursor would jump backwards over its own path.
                flushPointer()
                try wrapped.send(event)
                return
            }
            lock.lock()
            pointer.add(x: delta.x, y: delta.y, frames: Self.glideFrames)
            lock.unlock()
            startTimerIfNeeded()
        case let .scroll(delta):
            guard smoothsScroll else {
                try wrapped.send(event)
                return
            }
            lock.lock()
            scroll.add(x: delta.x, y: delta.y, frames: Self.glideFrames)
            lock.unlock()
            startTimerIfNeeded()
        default:
            flush()
            try wrapped.send(event)
        }
    }

    /// Posts whatever is still gliding, right now, on the calling thread.
    public func flush() {
        lock.lock()
        let move = pointer.take()
        let wheel = scroll.take()
        lock.unlock()
        post(move: move, wheel: wheel)
    }

    private func flushPointer() {
        lock.lock()
        let move = pointer.take()
        lock.unlock()
        post(move: move, wheel: (0, 0))
    }

    private func post(move: (x: Double, y: Double), wheel: (x: Double, y: Double)) {
        if move.x != 0 || move.y != 0 {
            try? wrapped.send(.pointer(delta: MacPointerDelta(x: move.x, y: move.y)))
        }
        if wheel.x != 0 || wheel.y != 0 {
            try? wrapped.send(.scroll(delta: MacScrollDelta(x: wheel.x, y: wheel.y)))
        }
    }

    private func startTimerIfNeeded() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.step() }
            timer = source
            source.resume()
        }
    }

    private func step() {
        lock.lock()
        let move = pointer.step()
        let wheel = scroll.step()
        let drained = pointer.isDrained && scroll.isDrained
        lock.unlock()

        post(move: move, wheel: wheel)
        // Already on `queue`: the timer only fires there.
        if drained {
            timer?.cancel()
            timer = nil
        }
    }
}
