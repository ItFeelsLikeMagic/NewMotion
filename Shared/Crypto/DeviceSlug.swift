import CryptoKit
import Foundation

/// Two readable words for a peer, derived from its long-term identity key.
///
/// A phone cannot say its own name: since iOS 16 the system hands an app the
/// model back, so every iPhone calls itself "iPhone", and the Bluetooth
/// advertisement carries the app name.  The identity key is the one thing that
/// names the same physical device across pairings, so hashing it gives both
/// sides the same words with nothing sent over the air and nothing typed.
///
/// The words are for telling two saved phones apart, not for trust; a peer
/// that has never paired mints a new identity and so arrives with a new name.
public enum DeviceSlug {
    private static let domain = Data("newmotion-slug-v1".utf8)

    public static func name(forIdentityKey key: Data) -> String {
        var input = domain
        input.append(key)
        let digest = Array(SHA256.hash(data: input))
        let adjective = adjectives[index(digest[0], digest[1], within: adjectives.count)]
        let noun = nouns[index(digest[2], digest[3], within: nouns.count)]
        return "\(adjective)-\(noun)"
    }

    private static func index(_ high: UInt8, _ low: UInt8, within count: Int) -> Int {
        (Int(high) << 8 | Int(low)) % count
    }

    private static let adjectives = [
        "amber", "ancient", "arctic", "autumn", "azure", "balmy", "blazing", "bold",
        "brave", "breezy", "bright", "bronze", "calm", "candid", "cheery", "chilly",
        "civic", "clever", "cobalt", "cosmic", "crimson", "crisp", "curious", "dapper",
        "dawn", "deft", "dewy", "dizzy", "downy", "dusky", "eager", "early",
        "earnest", "easy", "ember", "fabled", "fair", "fancy", "feisty", "fern",
        "fiery", "fleet", "floral", "fluffy", "fond", "frosty", "gallant", "gentle",
        "giddy", "gilded", "glad", "gleeful", "golden", "grassy", "hardy", "hazel",
        "hearty", "hidden", "hollow", "honest", "humble", "indigo", "ivory", "jade",
        "jolly", "joyful", "keen", "kindly", "lively", "lofty", "lucky", "lunar",
        "mellow", "merry", "mighty", "mild", "minty", "misty", "modest", "mossy",
        "muted", "nimble", "noble", "olive", "opal", "orange", "patient", "peachy",
        "pearly", "plucky", "polar", "proud", "quick", "quiet", "rapid", "ready",
        "regal", "ripe", "rosy", "royal", "ruby", "rugged", "rustic", "sandy",
        "scarlet", "shady", "sharp", "silver", "sleek", "snowy", "solar", "spry",
        "stable", "steady", "stormy", "sunny", "sunset", "swift", "teal", "tender",
        "tidy", "timely", "tranquil", "trusty", "upbeat", "urban", "velvet", "vivid",
        "warm", "whimsy", "wild", "windy", "wintry", "wise", "witty", "zesty",
    ]

    private static let nouns = [
        "badger", "bison", "bluejay", "bobcat", "buffalo", "cattle", "chipmunk", "cobra",
        "condor", "coyote", "crane", "cricket", "dolphin", "donkey", "dragonfly", "eagle",
        "egret", "elk", "falcon", "ferret", "finch", "firefly", "flamingo", "fox",
        "gazelle", "gecko", "gibbon", "giraffe", "goose", "gopher", "grouse", "guppy",
        "hare", "hawk", "hedgehog", "heron", "hornet", "ibex", "ibis", "iguana",
        "impala", "jackal", "jaguar", "jay", "kestrel", "kingfisher", "kiwi", "koala",
        "lark", "lemur", "leopard", "lion", "llama", "lobster", "lynx", "macaw",
        "magpie", "mantis", "marlin", "marmot", "meerkat", "mink", "mole", "mongoose",
        "moose", "moth", "narwhal", "newt", "ocelot", "octopus", "opossum", "orca",
        "osprey", "otter", "owl", "panda", "pangolin", "panther", "parrot", "pelican",
        "penguin", "pheasant", "pigeon", "plover", "puffin", "puma", "quail", "rabbit",
        "raccoon", "ram", "raven", "reindeer", "robin", "salmon", "sardine", "seal",
        "serval", "shark", "sheep", "shrew", "skunk", "sloth", "sparrow", "squid",
        "squirrel", "stallion", "starling", "stingray", "stork", "swallow", "swan", "tapir",
        "terrier", "thrush", "tiger", "toucan", "trout", "turtle", "viper", "vulture",
        "walrus", "warbler", "weasel", "whale", "wombat", "woodpecker", "wren", "yak",
        "zebra",
    ]
}
