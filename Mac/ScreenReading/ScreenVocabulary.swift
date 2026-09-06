import Foundation

#if os(macOS)
import AppKit
import ApplicationServices
#endif

/// Supplies the boost phrases for the utterance about to start. Implementations
/// must always call back; an empty list means no boosting for that utterance.
public protocol SpeechContextProviding: Sendable {
    func speechContext(completion: @escaping @Sendable ([String]) -> Void)
}

/// Answers whether a word is missing from the dictionaries the user has. A word
/// no dictionary knows is jargon, which is the only way to spot lowercase
/// jargon without shipping a word list of our own.
public protocol WordDictionary: Sendable {
    func isUnknown(_ word: String) -> Bool
}

/// Picks the words worth boosting out of whatever text is on screen. Names,
/// acronyms and product jargon are what the recogniser mishears; ordinary
/// English it already knows. The phrases are sent to the local recogniser and
/// nowhere else, and like field text they are never logged.
public enum ScreenVocabulary {
    /// The recogniser applies one strength to the whole list, so every extra
    /// phrase pulls ordinary speech a little further toward screen furniture.
    /// A short list of real names beats a long list of everything.
    public static let maximumPhrases = 40
    /// Under three characters a boost matches too much. The upper bound keeps
    /// a whole base64 blob out while leaving room for keys and ids like
    /// `4B8P47VZGT`, which are worth being able to dictate.
    static let lengthRange = 3...24

    /// Capitalised because a sentence or a menu started, not because they name
    /// anything. Boosting these is what makes a long list misfire.
    static let ordinary: Set<String> = [
        "a", "add", "all", "an", "and", "any", "are", "as", "at", "back", "be", "but", "by",
        "cancel", "close", "copy", "cut", "delete", "do", "done", "edit", "file", "find",
        "for", "from", "go", "have", "help", "her", "hide", "his", "how", "i", "if", "in",
        "is", "it", "its", "item", "list", "menu", "more", "my", "name", "new", "next", "no",
        "not", "of", "off", "ok", "on", "open", "or", "our", "out", "paste", "print", "redo",
        "remove", "reply", "save", "search", "send", "settings", "share", "she", "show", "so",
        "some", "text", "than", "that", "the", "their", "them", "then", "there", "these",
        "they", "this", "those", "title", "to", "today", "tomorrow", "undo", "untitled", "up",
        "us", "view", "was", "we", "were", "what", "when", "where", "which", "who", "why",
        "will", "window", "with", "yes", "yesterday", "you", "your"
    ]

    /// One entry per distinct word, most repeated on screen first. Repeats
    /// inside a single window rank a word; they are not sightings, which is
    /// what the cache counts.
    public static func phrases(in texts: [String], dictionary: WordDictionary) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var index = 0
        for text in texts {
            for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let word = String(token)
                guard isCandidate(word, dictionary: dictionary) else { continue }
                counts[word, default: 0] += 1
                if firstSeen[word] == nil {
                    firstSeen[word] = index
                    index += 1
                }
            }
        }
        return counts.keys.sorted {
            counts[$0] == counts[$1]
                ? firstSeen[$0]! < firstSeen[$1]!
                : counts[$0]! > counts[$1]!
        }
    }

    /// A capital marks a name, an acronym, an identifier or a key like
    /// `4B8P47VZGT`, all of which are worth being able to dictate. Everything
    /// lowercase is ordinary English unless no dictionary has heard of it.
    static func isCandidate(_ token: String, dictionary: WordDictionary) -> Bool {
        guard lengthRange.contains(token.count),
              token.contains(where: { $0.isLetter }),
              !ordinary.contains(token.lowercased()) else {
            return false
        }
        return token.contains(where: { $0.isUppercase }) || dictionary.isUnknown(token)
    }
}

/// Told what was actually said, so words that get used earn their keep.
public protocol SpokenVocabularySink: Sendable {
    func heard(_ transcript: String)
}

/// Remembers the words a screen has shown recently, so a name that has scrolled
/// out of view is still boosted while it is still being talked about. Seeing a
/// word on screen only refreshes its short lease. Saying it is the hit.
public final class VocabularyCache: SpokenVocabularySink, @unchecked Sendable {
/// A word that is only on screen is furniture, so a sighting buys this much
    /// and no more, however often the window is walked.
    public static let defaultLifetime: TimeInterval = 600
    /// Every time a word is actually spoken it adds this much on top of what is
    /// left, so the vocabulary you really use accumulates a long lease.
    public static let defaultHitExtension: TimeInterval = 3 * 3_600
    /// Only the top `maximumPhrases` are ever sent, so the rest are held here
    /// to earn hits and climb.
    public static let defaultCapacity = 400

    public struct Statistics: Equatable, Sendable {
        public var entries = 0
        /// Words credited because they were spoken, not merely seen.
        public var hits = 0
        /// Words a walk filed for the first time.
        public var added = 0
    }

    private struct Entry {
        /// How many times this word has been spoken.
        var hits: Int
        var expires: Date
        /// Where the word came in the walk that last saw it, to break ties
        /// between words with equal hits.
        var rank: Int
    }

    private let lifetime: TimeInterval
    private let hitExtension: TimeInterval
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var statistics = Statistics()

    public init(
        lifetime: TimeInterval = VocabularyCache.defaultLifetime,
        hitExtension: TimeInterval = VocabularyCache.defaultHitExtension,
        capacity: Int = VocabularyCache.defaultCapacity
    ) {
        self.lifetime = lifetime
        self.hitExtension = hitExtension
        self.capacity = capacity
    }

    /// What is worth boosting right now, without recording a sighting. This is
    /// what an utterance is given, so it never waits on a walk.
    public func current(now: Date = Date()) -> [String] {
        lock.withLock {
            entries = entries.filter { $0.value.expires > now }
            statistics.entries = entries.count
            return Array(ranked().prefix(ScreenVocabulary.maximumPhrases))
        }
    }

    public var stats: Statistics { lock.withLock { statistics } }

    /// Files what this walk saw and answers with the list to boost: everything
    /// still alive, most-spoken first, capped at what one boost strength can
    /// usefully carry. A sighting only renews the short lease.
    public func admit(_ words: [String], now: Date = Date()) -> [String] {
        lock.withLock {
            entries = entries.filter { $0.value.expires > now }
            let expiry = now.addingTimeInterval(lifetime)
            for (rank, word) in words.enumerated() {
                if var entry = entries[word] {
                    entry.expires = max(entry.expires, expiry)
                    entry.rank = rank
                    entries[word] = entry
                } else {
                    entries[word] = Entry(hits: 0, expires: expiry, rank: rank)
                    statistics.added += 1
                }
            }
            if entries.count > capacity {
                for word in ranked().dropFirst(capacity) { entries.removeValue(forKey: word) }
            }
            statistics.entries = entries.count
            return Array(ranked().prefix(ScreenVocabulary.maximumPhrases))
        }
    }

    /// Credits every cached word the speaker actually used. Matching ignores
    /// case, because the recogniser writes a name however it was said.
    public func heard(_ transcript: String) {
        let spoken = Set(
            transcript
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { $0.lowercased() }
        )
        guard !spoken.isEmpty else { return }
        lock.withLock {
            let now = Date()
            for (word, var entry) in entries where spoken.contains(word.lowercased()) {
                entry.hits += 1
                entry.expires = max(entry.expires, now).addingTimeInterval(hitExtension)
                entries[word] = entry
                statistics.hits += 1
            }
        }
    }

    /// Most-spoken first, then whichever is furthest from expiring, then
    /// where it sat in its last walk. The same history always ranks the same.
    private func ranked() -> [String] {
        entries.keys.sorted {
            let left = entries[$0]!, right = entries[$1]!
            if left.hits != right.hits { return left.hits > right.hits }
            if left.expires != right.expires { return left.expires > right.expires }
            return left.rank < right.rank
        }
    }
}

#if os(macOS)
/// The dictionaries the user already has, asked backwards: a word the spell
/// checker cannot place is jargon. Answers are memoised because one window
/// repeats the same words many times over.
public final class SystemWordDictionary: WordDictionary, @unchecked Sendable {
    private static let memoCapacity = 4_000

    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private let lock = NSLock()
    private var memo: [String: Bool] = [:]

    public init() {}

    public func isUnknown(_ word: String) -> Bool {
        if let unknown = lock.withLock({ memo[word] }) { return unknown }
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: checker.language(),
            wrap: false,
            inSpellDocumentWithTag: tag,
            wordCount: nil
        )
        let unknown = misspelled.length > 0
        lock.withLock {
            if memo.count >= Self.memoCapacity { memo.removeAll(keepingCapacity: true) }
            memo[word] = unknown
        }
        return unknown
    }
}

/// What one walk of the front window cost. Counts and milliseconds only, which
/// is all that may reach a log or the debug snapshot.
public struct ScreenVocabularyWalk: Equatable, Sendable {
    /// Bundle id of the app that was walked. An identifier, like the ones
    /// `/focus` already reports, never a word of what was read.
    public var app = "none"
    public var milliseconds = 0
    public var nodes = 0
    public var phrases = 0
    /// True when the walk ran out of node budget, so the list is a partial
    /// view of the window rather than all of it.
    public var truncated = false
}

/// Reads the front window over Accessibility, the permission the app already
/// holds in order to type. Nothing is written back through this path, and the
/// walk is bounded so a deep or sleepy window costs the boost, not the words.
public final class AXScreenVocabularyReader: SpeechContextProviding, @unchecked Sendable {
    private static let messagingTimeout: Float = 0.25
    /// Wide enough for a normal window, small enough to finish inside the gap
    /// between the button going down and the first spoken word.
    static let maximumNodes = 600
    static let maximumDepth = 12

    /// Accessibility messaging is its own IPC and does not need the main
    /// thread. Keeping the walk off it means a window that answers slowly, or
    /// not at all, costs the boost instead of stalling typing.
    private let queue = DispatchQueue(label: "phoneremote.vocabulary")
    private let lock = NSLock()
    private var enabled: Bool
    private var walking = false
    private var walk = ScreenVocabularyWalk()
    private let cache: VocabularyCache
    private let dictionary: WordDictionary
    private let isSecureInputActive: @Sendable () -> Bool

    public init(
        isEnabled: Bool = true,
        cache: VocabularyCache = VocabularyCache(),
        dictionary: WordDictionary = SystemWordDictionary(),
        isSecureInputActive: @escaping @Sendable () -> Bool = SecureInput.isActive
    ) {
        self.enabled = isEnabled
        self.cache = cache
        self.dictionary = dictionary
        self.isSecureInputActive = isSecureInputActive
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// The cost of the most recent walk, for the debug snapshot.
    public var lastWalk: ScreenVocabularyWalk { lock.withLock { walk } }

    /// Answers at once with what the cache already knows, then starts a walk
    /// for next time. The utterance never waits: an empty cache costs this
    /// press its boost and pays it back on the following one.
    public func speechContext(completion: @escaping @Sendable ([String]) -> Void) {
        guard isEnabled, !isSecureInputActive() else {
            completion([])
            return
        }
        completion(cache.current())
        refresh()
    }

    /// Wakes the tree and seeds the cache, so the first press has something to
    /// send and the debug snapshot has a number before anyone has spoken.
    public func warmUp() {
        refresh()
    }

    /// One walk at a time. A window still answering from the last press is
    /// left to finish rather than queueing another walk behind it.
    private func refresh() {
        guard isEnabled, !isSecureInputActive() else { return }
        let started: Bool = lock.withLock {
            if walking { return false }
            walking = true
            return true
        }
        guard started else { return }
        queue.async {
            _ = self.measuredPhrases()
            self.lock.withLock { self.walking = false }
        }
    }

    /// One walk on demand, for `debug-mac.sh`. Reports what it cost and the
    /// app that was measured, never a word of what it read.
    /// `bundleID` measures a named app wherever it sits; without it the walk
    /// follows keyboard focus, which is what a real press does. Accessibility
    /// reads any running app, so nothing has to be brought to the front.
    public func probe(bundleID: String? = nil) -> [String: String] {
        let phrases = measuredPhrases(bundleID: bundleID)
        let walk = lastWalk
        let stats = cache.stats
        return [
            "app": walk.app,
            "ms": String(walk.milliseconds),
            "nodes": String(walk.nodes),
            "truncated": walk.truncated ? "yes" : "no",
            "words": String(phrases.count),
            "cached": String(stats.entries),
            "cacheHits": String(stats.hits),
            "cacheAdded": String(stats.added),
            "enabled": isEnabled ? "yes" : "no"
        ]
    }

    private func measuredPhrases(bundleID: String? = nil) -> [String] {
        let started = DispatchTime.now().uptimeNanoseconds
        var budget = Self.maximumNodes
        var app = "none"
        let texts = windowText(bundleID: bundleID, budget: &budget, app: &app)
        let phrases = cache.admit(ScreenVocabulary.phrases(in: texts, dictionary: dictionary))
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        lock.withLock {
            walk = ScreenVocabularyWalk(
                app: app,
                milliseconds: Int(elapsed / 1_000_000),
                nodes: Self.maximumNodes - budget,
                phrases: phrases.count,
                truncated: budget == 0
            )
        }
        return phrases
    }

    private func windowText(bundleID: String?, budget: inout Int, app: inout String) -> [String] {
        guard let application = Self.application(bundleID: bundleID) else { return [] }
        var pid: pid_t = 0
        if AXUIElementGetPid(application, &pid) == .success {
            app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
            guard !Self.isOwnProcess(pid) else {
                app = "self"
                return []
            }
        }
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        // Chromium, and so every Electron app, builds its tree only once a
        // client asks for it by name. Same wake as the focused-field read.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let window: AXUIElement? = copy(kAXFocusedWindowAttribute, from: application)
        var texts: [String] = []
        collect(from: window ?? application, depth: 0, budget: &budget, into: &texts)
        return texts
    }

    private func collect(
        from element: AXUIElement,
        depth: Int,
        budget: inout Int,
        into texts: inout [String]
    ) {
        guard budget > 0, depth <= Self.maximumDepth else { return }
        budget -= 1
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text: String = copy(attribute, from: element), !text.isEmpty {
                texts.append(text)
            }
        }
        guard let children: [AXUIElement] = copy(kAXChildrenAttribute, from: element) else { return }
        for child in children {
            collect(from: child, depth: depth + 1, budget: &budget, into: &texts)
        }
    }

    /// A named app if one is given, otherwise whichever has keyboard focus.
    /// Accessibility reaches a running app wherever it sits, so measuring one
    /// never means activating it.
    /// Never read ourselves. Accessibility answers a same-process request by
    /// running AppKit's accessibility path right here on the walk queue, which
    /// drives a SwiftUI update off the main thread and traps on the first
    /// main-actor property it touches. It is our own process that matters, not
    /// our bundle id: a second copy of this app is someone else's window, and
    /// our own menu bar has nothing worth boosting anyway.
    static func isOwnProcess(_ pid: pid_t) -> Bool {
        pid == ProcessInfo.processInfo.processIdentifier
    }

    static func application(bundleID: String?) -> AXUIElement? {
        guard let bundleID else { return focusedApplication() }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        return AXUIElementCreateApplication(running.processIdentifier)
    }

    /// Asked through Accessibility rather than NSWorkspace, because this runs
    /// off the main thread and Accessibility has no such rule.
    static func focusedApplication() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &raw
        ) == .success, let application = raw else { return nil }
        return (application as! AXUIElement)
    }

    private func copy<T>(_ attribute: String, from element: AXUIElement) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? T
    }
}
#endif
