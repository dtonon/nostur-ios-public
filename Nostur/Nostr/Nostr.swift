//
//  Nostr.swift
//  Nostur
//
//  Created by Fabian Lachman on 09/01/2023.
//

import SwiftUI
import Foundation
import secp256k1

// NIP-20: ["OK", <event_id>, <true|false>, <message>]
// Example: ["OK", "b1a649ebe8b435ec71d3784793f3bbf4b93e64e17568a741aecd4c7ddeafce30", true, ""]
struct CommandResult: Decodable {
    let values: [Any]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let _ = try container.decode(String.self) // ok
        let id = try container.decode(String.self) // id
        let success = try container.decode(Bool.self) // success
        let message = try container.decode(String.self) // message
        
        values = [id, success, message]
    }
    
    var id:String { values[safe: 0] as? String ?? "NOSTUR.ERROR" }
    var success:Bool { values[safe: 1] as? Bool ?? false }
    var message:String { values[safe: 2] as? String ?? "" }
}

struct NMessage: Decodable {
    let values: [Any]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let type = try container.decode(String.self)
        let subscription = try container.decode(String.self)
        if let event = try? container.decode(NEvent.self) {
            values = [type, subscription, event]
        }
        else {
            values = [type, subscription]
        }
    }
    
    var type:String { values[safe: 0] as? String ?? "NOSTUR.ERROR" }
    var subscription:String { values[safe: 1] as? String ?? "NOSTUR.ERROR" }
    var event:NEvent? { values[safe: 2] as? NEvent }
}

public struct NTimestamp: Codable {
    public let timestamp: Int

    public init(date: Date) {
        self = .init(timestamp: Int(date.timeIntervalSince1970))
    }

    public init(timestamp: Int) {
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try timestamp = container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(timestamp)
    }
}

public enum NEventKind: Codable, Equatable {
    case setMetadata
    case textNote
    case recommendServer
    case contactList
    case directMessage
    case delete
    case repost
    case reaction
    case report
    case zapRequest
    case zapNote
    case highlight
    case relayList
    case nwcInfo
    case nwcRequest
    case nwcResponse
    case ncMessage
    case badgeDefinition
    case badgeAward
    case profileBadges
    case article
    case community
    case custom(Int)

    init(id: Int) {
        switch id {
        case     0: self = .setMetadata
        case     1: self = .textNote
        case     2: self = .recommendServer
        case     3: self = .contactList
        case     4: self = .directMessage
        case     5: self = .delete
        case     6: self = .repost
        case     7: self = .reaction
        case  1984: self = .report
        case  9734: self = .zapRequest
        case  9735: self = .zapNote
        case  9802: self = .highlight
        case 10002: self = .relayList
        case 13194: self = .nwcInfo
        case 23194: self = .nwcRequest
        case 23195: self = .nwcResponse
        case 24133: self = .ncMessage
        case 30009: self = .badgeDefinition
        case     8: self = .badgeAward
        case 30008: self = .profileBadges
        case 30023: self = .article
        case 34550: self = .community
        default   : self = .custom(id)
        }
    }

    var id: Int {
        switch self {
        case .setMetadata:          return 0
        case .textNote:             return 1
        case .recommendServer:      return 2
        case .contactList:          return 3
        case .directMessage:        return 4
        case .delete:               return 5
        case .repost:               return 6
        case .reaction:             return 7
        case .report:               return 1984
        case .zapRequest:           return 9734
        case .zapNote:              return 9735
        case .highlight:            return 9802
        case .relayList:            return 10002
        case .nwcInfo:              return 13194
        case .nwcRequest:           return 23194
        case .nwcResponse:          return 23195
        case .ncMessage:            return 24133
        case .badgeDefinition:      return 30009
        case .badgeAward:           return 8
        case .profileBadges:        return 30008
        case .article:              return 30023
        case .community:            return 34550
        case .custom(let customId): return customId
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        self.init(id: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        try container.encode(self.id)
    }
}

public struct NostrTag: Codable {
    let tag: [String]
    var type: String { tag.first ?? "" }
    var id: String { tag[1] }
    var pubkey: String { tag[1] }
    var value: String { tag[1] }
    
    public init(_ tag:[String]) {
        self.tag = tag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        tag = try container.decode([String].self)

        guard !tag.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: .init(), debugDescription: "missing tag"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: tag)
    }
}

struct NSerializableEvent: Encodable {
    let id = 0
    let publicKey: String
    let createdAt: NTimestamp
    let kind: NEventKind
    let tags: [NostrTag]
    let content: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(id)
        try container.encode(publicKey)
        try container.encode(createdAt)
        try container.encode(kind)
        try container.encode(tags)
        try container.encode(content)
    }
}

struct NEvent: Codable {
    
    public var id: String
    public var publicKey: String
    public var createdAt: NTimestamp
    public var kind: NEventKind
    public var tags: [NostrTag]
    public var content: String
    public var signature: String

    enum CodingKeys: String, CodingKey {
        case id
        case publicKey = "pubkey"
        case createdAt = "created_at"
        case kind
        case tags
        case content
        case signature = "sig"
    }
    
    enum EventError : Error {
        case InvalidId
        case InvalidSignature
        case EOSE
    }

    init(content:NSetMetadata) {
        self.createdAt = NTimestamp.init(date: Date())
        self.kind = .setMetadata
        self.content = try! content.encodedString()
        self.id = ""
        self.tags = []
        self.publicKey = ""
        self.signature = ""
    }

    init(content:String) {
        self.kind = .textNote
        self.createdAt = NTimestamp.init(date: Date())
        self.content = content
        self.id = ""
        self.tags = []
        self.publicKey = ""
        self.signature = ""
    }
    
    mutating func withId() -> NEvent {

        let serializableEvent = NSerializableEvent(publicKey: self.publicKey, createdAt: self.createdAt, kind:self.kind, tags: self.tags, content: self.content)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let serializedEvent = try! encoder.encode(serializableEvent)
        let sha256Serialized = SHA256.hash(data: serializedEvent)

        self.id = String(bytes:sha256Serialized.bytes)
        
        return self
    }

    mutating func sign(_ keys:NKeys) throws -> NEvent {

        let serializableEvent = NSerializableEvent(publicKey: keys.publicKeyHex(), createdAt: self.createdAt, kind:self.kind, tags: self.tags, content: self.content)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let serializedEvent = try! encoder.encode(serializableEvent)
        let sha256Serialized = SHA256.hash(data: serializedEvent)

        let sig = try! keys.signature(for: sha256Serialized)


        guard keys.publicKey.schnorr.isValidSignature(sig, for: sha256Serialized) else {
            throw "Signing failed"
        }

        self.id = String(bytes:sha256Serialized.bytes)
        self.publicKey = keys.publicKeyHex()
        self.signature = String(bytes:sig.rawRepresentation.bytes)

        return self
    }

    func verified() throws -> Bool {
        L.og.debug("✍️ VERIFYING SIG ✍️")
        let serializableEvent = NSerializableEvent(publicKey: self.publicKey, createdAt: self.createdAt, kind:self.kind, tags: self.tags, content: self.content)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let serializedEvent = try! encoder.encode(serializableEvent)
        let sha256Serialized = SHA256.hash(data: serializedEvent)

        guard self.id == String(bytes:sha256Serialized.bytes) else {
            throw "🔴🔴 Invalid ID 🔴🔴"
        }

        let xOnlyKey = try secp256k1.Signing.XonlyKey(rawRepresentation: self.publicKey.bytes, keyParity: 1)
        let pubKey = secp256k1.Signing.PublicKey(xonlyKey: xOnlyKey)

        // signature from this event
        let schnorrSignature = try secp256k1.Signing.SchnorrSignature(rawRepresentation: self.signature.bytes)

        // public and signature from this event is valid?
        guard pubKey.schnorr.isValidSignature(schnorrSignature, for: sha256Serialized) else {
            throw "Invalid signature"
        }

        return true
    }

    func eventJson(_ outputFormatting:JSONEncoder.OutputFormatting? = nil) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting ?? .withoutEscapingSlashes
        let finalMessage = try! encoder.encode(self)

        return String(data: finalMessage, encoding: .utf8)!
    }

    func wrappedEventJson() -> String {
        return NRelayMessage.event(self)
    }
    
    
    func bolt11() -> String? {
        tags.first(where: { $0.type == "bolt11" })?.tag[safe: 1]
    }
    
    func pTags() -> [String] {
        tags.filter { $0.type == "p" } .map { $0.pubkey }
    }
    
    func eTags() -> [String] {
        tags.filter { $0.type == "e" } .map { $0.id }
    }
    
    func firstA() -> String? {
        tags.first(where: { $0.type == "a" })?.value
    }
    
    func firstP() -> String? {
        tags.first(where: { $0.type == "p" })?.pubkey
    }
    
    func firstE() -> String? {
        tags.first(where: { $0.type == "e" })?.id
    }
    
    func lastP() -> String? {
        tags.last(where: { $0.type == "p" })?.pubkey
    }
    
    func lastE() -> String? {
        tags.last(where: { $0.type == "e" })?.id
    }
    
    func tagNamed(_ type:String) -> String? {
        tags.first(where: { $0.type == type })?.value
    }
}

class TagSerializer {
    
    static public var shared = TagSerializer()
    let encoder = JSONEncoder()
    
    init() {
        encoder.outputFormatting = .withoutEscapingSlashes
    }
    
    func encode(tags:[NostrTag]) -> String? {
        if let tagsSerialized = try? encoder.encode(tags) {
            return String(data: tagsSerialized, encoding: .utf8)
        }
        return nil
    }
}

struct TagsHelpers {
    var tags:[NostrTag]
    
    init(_ tags:[NostrTag]) {
        self.tags = tags
    }
    
    func reactingToPubkey() -> String? {
        return pTags().last?.pubkey ?? nil
    }
    
    func reactingToEventId() -> String? {
        return eTags().last?.id ?? nil
    }
    
    func eTags() -> [NostrTag] {
        return tags.filter { $0.type == "e" }
    }
    
    func pTags() -> [NostrTag] {
        return tags.filter { $0.type == "p" }
    }

    func noEtags() -> Bool {
        return eTags().isEmpty
    }

    func oneEtag() -> Bool {
        return eTags().count == 1
    }

    func twoEtags() -> Bool {
        return eTags().count == 2
    }

    func manyEtags() -> Bool {
        return eTags().count > 2
    }
    
    
    // E TAGS
    func replyToEtag() -> NostrTag? {
        if noEtags() {
            return nil
        }
        // PREFERRED NEW METHOD
        // NIP-10: Those marked with "reply" denote the id of the reply event being responded to.
        let replyEtags = tags.filter { $0.type == "e" && $0.tag.count == 4 && $0.tag[3] == "reply" }
        if (!replyEtags.isEmpty) {
            return replyEtags.first
        }

        // OLD METHOD NIP-10:
        // One "e" tag = REPLY
        if oneEtag() && (eTags().first?.tag[safe: 3] == nil) {
            return eTags().first
        }
        
        // OLD METHOD NIP-10: 
        // Two "e" tags: FIRST = ROOT, LAST = REPLY
        // Many "e" tags: SAME
        if (twoEtags() || manyEtags()) {
            return eTags().last
        }
        return nil
    }
    
    func replyToRootEtag() -> NostrTag? {
        if noEtags() {
            return nil
        }
        let rootEtag = tags.filter { $0.type == "e" && $0.tag.count == 4 && $0.tag[3] == "root" }.first
        // PREFERRED NEW METHOD
        if (rootEtag != nil) {
            return rootEtag
        }

        // OLD METHOD
        if oneEtag() && (eTags().first?.tag[safe: 3] == nil) {
            return eTags().first

        }
        if (twoEtags() || manyEtags()) && (eTags().first?.tag[safe: 3] == nil) {
            return eTags().first

        }
        return nil
    }
    
    func mentionEtags() -> [NostrTag]? {
        if noEtags() {
            return nil
        }
        // PREFERRED NEW METHOD
        let mentionEtags = tags.filter { $0.type == "e" && $0.tag.count == 4 && $0.tag[3] == "mention" }
        if !mentionEtags.isEmpty {
            return mentionEtags
        }

        // OLD METHOD
        if (!manyEtags()) { return nil }
        let etags = eTags()
        let etagsSlice = etags[1..<etags.count-1]
        return Array(etagsSlice)
    }
    
    func newerMentionEtags() -> [NostrTag]? {
        if noEtags() {
            return nil
        }
        // PREFERRED NEW METHOD
        let mentionEtags = tags.filter { $0.type == "e" && $0.tag.count == 4 && $0.tag[3] == "mention" }
        if !mentionEtags.isEmpty {
            return mentionEtags
        }
        return nil
    }
}

struct NRelayMessage {
    var message: String
    var event:NEvent

    init(event:NEvent) {
        self.event = event
        self.message = "[\"EVENT\",\(event.eventJson())]"
    }

    static func event(_ event:NEvent) -> String {
        return "[\"EVENT\",\(event.eventJson())]"
    }
}

public struct NSetMetadata: Codable {

    public var name: String?
    public var display_name: String?
    public var about: String?
    public var picture: String?
    public var banner: String?
    public var nip05: String? = nil
    public var lud16: String? = nil
    public var lud06: String? = nil

    enum CodingKeys: String, CodingKey {
        case name
        case display_name
        case about
        case picture
        case banner
        case nip05
        case lud16
        case lud06
    }

    public func encodedString() throws -> String {
        let encoder = JSONEncoder()
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
