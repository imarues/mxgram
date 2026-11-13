// MTProto codec for "Delete My Messages".
// The only searched peer is the one captured from Telegram's authenticated
// request in the currently displayed chat. Never use a global dialog search.
import Foundation
import tgapiC

@objc(MxPurgeCodec)
final class MxPurgeCodec: NSObject {
    // A MTProto gzip_packed object is [constructor][TL bytes], NOT
    // [constructor][raw gzip]. The TL bytes include a 1- or 4-byte length
    // prefix and up to 3 bytes of padding. Passing those bytes to zlib
    // made search responses from busy chats consistently fail to parse.
    private static func unpack(_ ns: NSData) -> Data? {
        var current = ns as Data
        let maximumResponseSize = 32 * 1024 * 1024
        guard current.count >= 4 && current.count <= maximumResponseSize else { return nil }
        for _ in 0..<3 {
            let reader = BufferReader(Buffer(data: current))
            guard let constructor = reader.readInt32() else { return nil }
            if constructor != Int32(bitPattern: 0x3072CFA1) {
                return current
            }
            guard let packed = parseBytes(reader)?.makeData(),
                  !packed.isEmpty && packed.count <= maximumResponseSize else {
                return nil
            }
            guard let decompressed: Data = packed.withUnsafeBytes({ bytes -> Data? in
                guard let base = bytes.baseAddress else { return nil }
                return decompressGzip(base, packed.count) as Data?
            }), decompressed.count >= 4,
                decompressed.count <= maximumResponseSize else {
                return nil
            }
            current = decompressed
        }
        // More than three wrappers is not a normal Telegram response.
        return nil
    }

    // Diagnostic only: display the *constructor*, not chat ids, usernames,
    // message contents, or response bytes. Never use this as a delete fallback.
    @objc(searchResponseDiagnostic:)
    static func searchResponseDiagnostic(_ data: NSData) -> NSString {
        let raw = data as Data
        let wireReader = BufferReader(Buffer(data: raw))
        let wireId = wireReader.readInt32()
        guard let body = unpack(data) else {
            let id = wireId.map { String(format: "0x%08X", UInt32(bitPattern: $0)) } ?? "none"
            return "invalid TL/gzip payload (wire=\(id), bytes=\(raw.count))" as NSString
        }
        let reader = BufferReader(Buffer(data: body))
        guard let constructor = reader.readInt32() else {
            return "empty decompressed response" as NSString
        }
        let hex = String(format: "0x%08X", UInt32(bitPattern: constructor))
        let recognized: Set<Int32> = [494135274, 1595959062, -948520370, 1951620897]
        if !recognized.contains(constructor) {
            return "unexpected Telegram response constructor \(hex)" as NSString
        }
        if constructor == 1951620897 {
            return "messagesNotModified (unexpected for hash=0)" as NSString
        }
        return "known \(hex) response, but nested Telegram API fields could not be parsed" as NSString
    }

    private static func readPeer(_ data: Data) -> Api.InputPeer? {
        let r = BufferReader(Buffer(data: data))
        guard let sign = r.readInt32() else { return nil }
        return Api.parse(r, signature: sign) as? Api.InputPeer
    }

    private static func key(_ peer: Api.InputPeer) -> String? {
        switch peer {
        case let .inputPeerUser(x): return "0:\(x.userId)"
        case let .inputPeerChat(x): return "1:\(x.chatId)"
        case let .inputPeerChannel(x): return "2:\(x.channelId)"
        default: return nil
        }
    }

    private static func peerInfo(_ peer: Api.InputPeer) -> NSDictionary? {
        guard let k = key(peer) else { return nil }
        let b = Buffer()
        peer.serialize(b, true)
        return ["key": k, "peerData": b.makeData() as NSData]
    }

    // Capture a typed peer only for API methods whose first argument is known.
    // Reject unknown constructors and wrappers rather than guess an offset.
    @objc(peerFromRequest:)
    static func peerFromRequest(_ ns: NSData) -> NSDictionary? {
        let r = BufferReader(Buffer(data: ns as Data))
        guard let method = r.readInt32() else { return nil }
        let peerFirst: Set<Int32> = [
            1143203525, // messages.getHistory
            238054714, // messages.readHistory
            -871347913 // channels.readHistory uses InputChannel, rejected below
        ]
        let flagsFirst: Set<Int32> = [
            703497338, // messages.search
            -17526942, // messages.sendMessage
            53536639 // messages.sendMedia
        ]
        if flagsFirst.contains(method) {
            guard r.readInt32() != nil else { return nil }
        } else if !peerFirst.contains(method) {
            return nil
        }
        guard let sig = r.readInt32(),
              let peer = Api.parse(r, signature: sig) as? Api.InputPeer else { return nil }
        return peerInfo(peer)
    }

    // Recover only the actual ChatLocation.peer's Postbox PeerId. The
    // namespace makes a user id, basic-group id and channel id distinct.
    private static func numeric(_ obj: Any, depth: Int = 0) -> Int64? {
        if depth > 8 { return nil }
        if let n = obj as? NSNumber { return n.int64Value }
        if let n = obj as? Int64 { return n }
        if let n = obj as? Int32 { return Int64(n) }
        if let n = obj as? Int { return Int64(n) }
        if let n = obj as? UInt32 { return Int64(n) }
        if let n = obj as? UInt64, n <= UInt64(Int64.max) { return Int64(n) }
        // Newer Postbox PeerId.Id/Namespace wrap their scalar in a private
        // single-field struct. The previous name-only walker silently lost
        // every chat and account ID in such builds.
        let children = Array(Mirror(reflecting: obj).children)
        for child in children where ["rawValue", "_rawValue", "_internalValue",
                                      "_internalId", "_value", "value",
                                      "id", "namespace"].contains(child.label ?? "") {
            if let result = numeric(child.value, depth: depth + 1) { return result }
        }
        if children.count == 1 {
            return numeric(children[0].value, depth: depth + 1)
        }
        return nil
    }
    private static func peerIdKey(_ obj: Any, depth: Int = 0) -> String? {
        if depth > 9 { return nil }
        let mirror = Mirror(reflecting: obj)
        if let ns = mirror.children.first(where: { $0.label == "namespace" }),
           let id = mirror.children.first(where: { $0.label == "id" }),
           let namespace = numeric(ns.value), let peer = numeric(id.value),
           (0...2).contains(namespace), peer > 0 {
            return "\(namespace):\(peer)"
        }
        // Some PeerId implementations expose only CustomStringConvertible
        // rather than the two stored members. Accept only an entire typed
        // namespace:id value, never a substring of a controller description.
        let exact = String(describing: obj)
        if exact.range(of: "^[012]:[1-9][0-9]*$", options: .regularExpression) != nil {
            return exact
        }
        for child in mirror.children {
            if let found = peerIdKey(child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    // Only the chatLocation.peer enum case is an ordinary chat.
    // A reply thread has a peer too, but must never be treated as a full chat.
    private static func locationKey(_ location: Any, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        let mirror = Mirror(reflecting: location)
        if mirror.displayStyle == .optional, let child = mirror.children.first {
            return locationKey(child.value, depth: depth + 1)
        }
        guard mirror.displayStyle == .enum,
              let selected = mirror.children.first,
              selected.label == "peer" else { return nil }
        return peerIdKey(selected.value)
    }

    // Do not walk controller.context or any messages to guess a chat id.
    @objc(chatKeyForController:)
    static func chatKeyForController(_ controller: AnyObject) -> NSString? {
        var mirror: Mirror? = Mirror(reflecting: controller)
        while let m = mirror {
            for item in m.children where item.label == "chatLocation" {
                return locationKey(item.value) as NSString?
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    // Read the account's own PeerId from the chat controller's AccountContext.
    // Refuse to rely on the global saved user id (multi-account unsafe).
    private static func accountPeerId(_ account: Any, depth: Int = 0) -> NSNumber? {
        guard depth <= 5 else { return nil }
        for child in Mirror(reflecting: account).children {
            if child.label == "peerId",
               let k = peerIdKey(child.value), k.hasPrefix("0:"),
               let id = Int64(k.dropFirst(2)), id > 0 {
                return NSNumber(value: id)
            }
        }
        // AccountContext.account and peerId are sometimes wrapped in Optionals.
        let mirror = Mirror(reflecting: account)
        if mirror.displayStyle == .optional || mirror.displayStyle == .enum {
            for child in mirror.children {
                if let result = accountPeerId(child.value, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    @objc(accountIdForContext:)
    static func accountIdForContext(_ context: AnyObject) -> NSNumber? {
        var mirror: Mirror? = Mirror(reflecting: context)
        while let m = mirror {
            for child in m.children where child.label == "account" {
                if let result = accountPeerId(child.value) { return result }
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    // ChatControllerImpl.context is a Swift stored property on VoidGram.
    // Objective-C KVC does not reliably expose it. Reflect the specific
    // controller.context -> context.account -> account.peerId path instead.
    @objc(accountIdForController:)
    static func accountIdForController(_ controller: AnyObject) -> NSNumber? {
        var mirror: Mirror? = Mirror(reflecting: controller)
        while let m = mirror {
            for item in m.children where item.label == "context" {
                let context = item.value
                var cm: Mirror? = Mirror(reflecting: context)
                while let current = cm {
                    for field in current.children where field.label == "account" {
                        if let id = accountPeerId(field.value) { return id }
                    }
                    cm = cm?.superclassMirror
                }
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    @objc(makeSelfCheck)
    static func makeSelfCheck() -> NSData {
        let call = Api.functions.users.getUsers(id: [.inputUserSelf])
        return call.1.makeData() as NSData
    }

    @objc(selfIdFromResponse:)
    static func selfIdFromResponse(_ data: NSData) -> NSNumber? {
        guard let bytes = unpack(data) else { return nil }
        let r = BufferReader(Buffer(data: bytes))
        guard r.readInt32() == 481674261,
              let users = Api.parseVector(r, elementSignature: 0, elementType: Api.User.self) else {
            return nil
        }
        for u in users {
            if case let .user(d) = u, (d.flags & (1 << 10)) != 0 {
                return NSNumber(value: d.id)
            }
        }
        // users.getUsers(inputUserSelf) returns exactly the active account.
        if users.count == 1, case let .user(d) = users[0] {
            return NSNumber(value: d.id)
        }
        return nil
    }

    @objc(makeSearchForPeer:offset:limit:)
    static func makeSearchForPeer(_ peerBytes: NSData, offset: Int32, limit: Int32) -> NSData? {
        guard let peer = readPeer(peerBytes as Data),
              key(peer) != nil else { return nil }
        let call = Api.functions.messages.search(
            flags: 1, peer: peer, q: "", fromId: .inputPeerSelf,
            savedPeerId: nil, savedReaction: nil, topMsgId: nil,
            filter: .inputMessagesFilterEmpty, minDate: 0, maxDate: 0,
            offsetId: offset, addOffset: 0, limit: limit,
            maxId: 0, minId: 0, hash: 0
        )
        return call.1.makeData() as NSData
    }

    @objc(searchResult:)
    static func searchResult(_ data: NSData) -> NSDictionary? {
        guard let bytes = unpack(data) else { return nil }
        let r = BufferReader(Buffer(data: bytes))
        guard let sign = r.readInt32(),
              let response = Api.parse(r, signature: sign) as? Api.messages.Messages else { return nil }
        let messages: [Api.Message]
        switch response {
        case let .messages(d): messages = d.messages
        case let .messagesSlice(d): messages = d.messages
        case let .channelMessages(d): messages = d.messages
        default: return nil
        }
        var ids: [NSNumber] = []
        for message in messages {
            if case let .message(d) = message, d.id > 0 {
                ids.append(NSNumber(value: d.id))
            }
        }
        return ["ids": ids, "returned": messages.count]
    }

    @objc(makeDeleteForPeer:ids:)
    static func makeDeleteForPeer(_ peerBytes: NSData, ids: [NSNumber]) -> NSData? {
        guard let peer = readPeer(peerBytes as Data),
              key(peer) != nil, !ids.isEmpty, ids.count <= 100 else { return nil }
        let unique = Array(Set(ids.compactMap { $0.int32Value > 0 ? $0.int32Value : nil }))
        guard !unique.isEmpty else { return nil }
        switch peer {
        case let .inputPeerChannel(d):
            let channel = Api.InputChannel.inputChannel(
                Api.InputChannel.Cons_inputChannel(channelId: d.channelId, accessHash: d.accessHash))
            return Api.functions.channels.deleteMessages(channel: channel, id: unique).1.makeData() as NSData
        case .inputPeerUser, .inputPeerChat:
            // revoke=1 means delete for everyone for this account-owned message.
            return Api.functions.messages.deleteMessages(flags: 1, id: unique).1.makeData() as NSData
        default: return nil
        }
    }

    @objc(deleteSucceeded:)
    static func deleteSucceeded(_ data: NSData) -> Bool {
        guard let bytes = unpack(data) else { return false }
        let r = BufferReader(Buffer(data: bytes))
        guard let sig = r.readInt32() else { return false }
        return Api.parse(r, signature: sig) is Api.messages.AffectedMessages
    }
}
