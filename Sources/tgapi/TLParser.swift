import Foundation
import tgapiC
import os

@objc(TLParser)
class TLParser: NSObject {
    @objc static var sharedContext: Any?

    // Message ids saved from deletion, each with the conversation it was
    // deleted from.
    //
    // Message ids are not unique on their own: channel and supergroup numbering
    // restarts at 1 per peer. A bare set of ids therefore put the trash icon on
    // every message that happened to share a number with something deleted
    // somewhere else — a message plainly still there, flagged as revoked.
    //
    // updateDeleteChannelMessages names its channel. updateDeleteMessages does
    // not, and does not need to: it covers private chats and basic groups,
    // whose ids all come from one per-account sequence. Those are stored under
    // cloudScope and match any non-channel message.
    private static let deletedQueue = DispatchQueue(label: "com.kira.deletedIds",
                                                    attributes: .concurrent)
    private static let cloudScope: Int64 = 0
    /// Every scope a given id was deleted from.
    ///
    /// A set, not one value. The pencil badge had the same shape of bug and the
    /// same symptom: one slot per bare id means the second chat to delete a
    /// message of that number takes the slot from the first, and the first
    /// chat's marker vanishes. Channels number from 1, so ids collide constantly.
    private static var _deletedIds = [Int32: Set<Int64>]()
    private static let udKey = "MxDeletedMsgIds"
    private static var _loaded = false
    private static var protectedChannelIds = Set<Int64>()

    /// Called from ObjC (Hooks.xm) before zeroing message IDs in anti-revoke.
    /// `peer` is cloudScope for the account-wide id sequence, or a channel's
    /// peer key as peerKey(_:) encodes it.
    @objc static func addDeletedId(_ id: Int32, peer: Int64) {
        guard id != 0 else { return }
        deletedQueue.async(flags: .barrier) {
            _deletedIds[id, default: []].insert(peer)
            // Written from the in-memory map rather than read back and appended
            // to. Casting the stored dictionary to the new shape would fail
            // outright on a 1.4.3 file — every id in it having one scope, not a
            // list — and the ?? [:] would then quietly discard the lot.
            // Keep growth bounded, in memory as well as on disk — trimming only
            // the copy being written would let the map itself grow without end.
            // Dropping the numerically smallest ids loses the oldest of the
            // account-wide sequence first, which is the right end to lose.
            if _deletedIds.count > 1000 {
                for key in _deletedIds.keys.sorted().prefix(_deletedIds.count - 1000) {
                    _deletedIds.removeValue(forKey: key)
                }
            }

            var saved = [String: [NSNumber]]()
            for (key, scopes) in _deletedIds {
                saved[String(key)] = scopes.map { NSNumber(value: $0) }
            }
            UserDefaults.standard.set(saved, forKey: udKey)
        }
    }

    /// Whether a message was revoked — the id must have been deleted from *this*
    /// conversation, not merely from somewhere.
    private static func isDeletedMessage(id: Int32, peer: Int64) -> Bool {
        return deletedQueue.sync {
            guard let scopes = _deletedIds[id] else { return false }
            if scopes.contains(peer) { return true }
            // Anything that is not a channel shares the account-wide range, so a
            // cloudScope entry answers for all of them.
            return scopes.contains(cloudScope) && peer > -1_000_000_000_000
        }
    }

    /// Load persisted deleted IDs from UserDefaults into memory (call once at startup).
    @objc static func loadPersistedIds() {
        deletedQueue.async(flags: .barrier) {
            guard !_loaded else { return }
            _loaded = true
            // Entries written before ids carried a peer cannot say which chat
            // they came from, and keeping them means keeping the false marker
            // they cause. Dropped, once.
            guard let stored = UserDefaults.standard.dictionary(forKey: udKey) else {
                return
            }
            for (key, value) in stored {
                guard let id = Int32(key) else { continue }
                if let scopes = value as? [NSNumber] {
                    _deletedIds[id] = Set(scopes.map { $0.int64Value })
                } else if let single = value as? NSNumber {
                    // 1.4.3 stored one scope per id. Same data, narrower shape.
                    _deletedIds[id] = [single.int64Value]
                }
            }
            if _deletedIds.isEmpty {
                UserDefaults.standard.removeObject(forKey: udKey)
            }
            diag("anti-revoke loaded \(_deletedIds.count) deleted ids")
        }
        loadEditHistory()
        installApiLogger()
    }

    // MARK: - Anti-Edit

    /// Every text version of a message we have seen, oldest first. Element 0 is
    /// the original, which is what Anti-Edit restores.
    ///
    /// Writes take a barrier synchronously rather than asynchronously: a single
    /// pass over a response records an original and then reads it back, so the
    /// ordering has to be deterministic.
    private static let editQueue = DispatchQueue(label: "com.kira.editHistory",
                                                 attributes: .concurrent)

    /// What identifies a message: the conversation together with the number.
    ///
    /// A message id on its own does not. Channel and supergroup numbering
    /// restarts at 1 for every peer, so id 7 exists in every channel you are in.
    ///
    /// 1.4.3 fixed the *lookup* by remembering one peer per id and refusing a
    /// hit from anywhere else. That stopped the false pencils and started
    /// disappearing ones: the store still held a single slot per bare id, so the
    /// moment another chat produced a message with the same number it took the
    /// slot over, resetting the versions and reassigning the peer. Coming back
    /// to the first chat, the lookup then failed its own peer check and the
    /// pencil was gone — measured as id=9 in one channel answering 2 versions
    /// and 0 versions on different passes.
    ///
    /// Both chats can be tracked at once now, because the peer is part of the
    /// key rather than a note beside it.
    private struct EditKey: Hashable {
        let peer: Int64
        let id: Int32

        /// Round-trips through the defaults dictionary, which takes only strings
        /// as keys.
        var storageKey: String { "\(peer):\(id)" }

        init(peer: Int64, id: Int32) {
            self.peer = peer
            self.id = id
        }

        init?(storageKey: String) {
            let parts = storageKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let peer = Int64(parts[0]),
                  let id = Int32(parts[1]) else { return nil }
            self.peer = peer
            self.id = id
        }
    }

    private static var _editHistory = [EditKey: [String]]()
    private static var _editOrder = [EditKey]()   // insertion order, for trimming
    private static var _editLoaded = false
    private static var _editPersistScheduled = false

    /// New key: the old one held the id-keyed layout this replaces, and reading
    /// it back under the new shape would misfile every entry.
    private static let editUdKey = "MxEditHistoryByPeer"

    /// The 1.4.3 pair, read once to carry existing history across and never
    /// written again.
    private static let legacyEditUdKey = "MxEditHistory"
    private static let legacyEditPeersUdKey = "MxEditHistoryPeers"

    private static let maxTrackedMessages = 2000
    private static let maxVersionsPerMessage = 20


    private static var isAntiEditEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "MxAntiEdit")
    }

    // MARK: - Custom Stars balance (display only)

    /// The number the user typed in the Kira menu, or nil when the feature is
    /// off. Purely cosmetic: the server keeps its own count, so anything that
    /// actually spends stars still fails exactly as it would have.
    private static var customStarsBalance: Int64? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "MxCustomStarsEnabled") else { return nil }
        let value = defaults.object(forKey: "MxCustomStarsValue") as? NSNumber
        guard let amount = value?.int64Value, amount >= 0 else { return nil }
        return amount
    }

    private static var isCustomStarsEnabled: Bool {
        return customStarsBalance != nil
    }

    /// Replaces the balance in a starsStatus, keeping every other field.
    /// Returns nil when the feature is off or the value already matches, so the
    /// caller can skip re-serialising an unchanged reply.
    private static func fakeStarsStatus(_ status: Api.payments.StarsStatus) -> Api.payments.StarsStatus? {
        guard let amount = customStarsBalance else { return nil }
        guard case let .starsStatus(data) = status else { return nil }
        if case let .starsAmount(current) = data.balance,
           current.amount == amount, current.nanos == 0 {
            return nil
        }
        let balance = Api.StarsAmount.starsAmount(Api.StarsAmount.Cons_starsAmount(amount: amount, nanos: 0))
        diag("stars balance -> \(amount)")
        return Api.payments.StarsStatus.starsStatus(Api.payments.StarsStatus.Cons_starsStatus(
            flags: data.flags,
            balance: balance,
            subscriptions: data.subscriptions,
            subscriptionsNextOffset: data.subscriptionsNextOffset,
            subscriptionsMissingBalance: data.subscriptionsMissingBalance,
            history: data.history,
            nextOffset: data.nextOffset,
            chats: data.chats,
            users: data.users))
    }

    /// The push counterpart of the above. Without it the faked number survives
    /// only until the next balance update lands and overwrites it.
    private static func fakeStarsBalanceUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        guard let amount = customStarsBalance else { return (update, false) }
        guard case let .updateStarsBalance(data) = update else { return (update, false) }
        if case let .starsAmount(current) = data.balance,
           current.amount == amount, current.nanos == 0 {
            return (update, false)
        }
        let balance = Api.StarsAmount.starsAmount(Api.StarsAmount.Cons_starsAmount(amount: amount, nanos: 0))
        return (Api.Update.updateStarsBalance(Api.Update.Cons_updateStarsBalance(balance: balance)), true)
    }

    /// Mirrors the mxDiag() macro in Logger.h. os_log with an explicit
    /// {public} annotation, because both NSLog and unannotated os_log redact
    /// string arguments to "<private>" before they reach the device syslog.
    private static let diagLog = OSLog(subsystem: "com.ikiraplus.kira", category: "diag")

    /// Swift-side master switch for diagnostic logging. Must be kept in step
    /// with MX_DIAG in Logger.h, which a Swift file cannot see. Left on, the
    /// signature tracing below takes a queue hop for every message parsed.
    private static let diagEnabled = false

    private static func diag(_ message: String) {
        guard diagEnabled else { return }
        os_log("[MxDiag] %{public}@", log: diagLog, type: .default, message)
    }

    /// Reports each distinct TL constructor reaching the rewriter, once each and
    /// capped, so a device log shows what actually flows through without
    /// drowning in per-message noise. Diagnostic only.
    private static var seenSignatures = Set<Int32>()
    private static let signatureQueue = DispatchQueue(label: "com.kira.diagSignatures")

    private static func diagSignature(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard seenSignatures.count < 60, seenSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-in 0x%08X", UInt32(bitPattern: signature)))
        }
    }

    /// Routes the generated API layer's own "type constructor not found"
    /// complaints to the device log. That logger ships as a no-op, so a schema
    /// that has fallen behind the server fails silently: the container returns
    /// nil and every feature downstream simply never runs.
    ///
    /// Deduplicated — one unknown constructor inside a frequently received
    /// container would otherwise repeat without end.
    private static var loggedApiMessages = Set<String>()

    private static func installApiLogger() {
        guard diagEnabled else { return }
        setTelegramApiLogger { message in
            signatureQueue.sync {
                guard loggedApiMessages.count < 60,
                      loggedApiMessages.insert(message).inserted else { return }
                diag("api-layer: \(message)")
            }
        }
    }

    private static var unparsedSignatures = Set<Int32>()

    private static func diagUnparsed(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard unparsedSignatures.count < 40, unparsedSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-UNPARSED 0x%08X", UInt32(bitPattern: signature)))
        }
    }

    private static func loadEditHistory() {
        editQueue.async(flags: .barrier) {
            guard !_editLoaded else { return }
            _editLoaded = true
            if let saved = UserDefaults.standard.dictionary(forKey: editUdKey) as? [String: [String]] {
                for (key, versions) in saved {
                    guard let editKey = EditKey(storageKey: key), !versions.isEmpty else { continue }
                    _editHistory[editKey] = versions
                    _editOrder.append(editKey)
                }
                let multi = _editHistory.values.filter { $0.count > 1 }.count
                diag("anti-edit loaded \(_editOrder.count) entries, \(multi) with an edit")
                return
            }

            // Nothing under the new key: carry across whatever 1.4.3 left, then
            // let the next flush write it in the new shape. An entry with no
            // peer came from a build that tracked bare ids and cannot be placed
            // in any conversation, so it is dropped rather than guessed at.
            var dropped = 0
            let savedPeers = (UserDefaults.standard.dictionary(forKey: legacyEditPeersUdKey) as? [String: NSNumber]) ?? [:]
            guard let legacy = UserDefaults.standard.dictionary(forKey: legacyEditUdKey) as? [String: [String]] else { return }
            for (key, versions) in legacy {
                guard let id = Int32(key), !versions.isEmpty else { continue }
                guard let peer = savedPeers[key]?.int64Value, peer != 0 else {
                    dropped += 1
                    continue
                }
                let editKey = EditKey(peer: peer, id: id)
                _editHistory[editKey] = versions
                _editOrder.append(editKey)
            }
            diag("anti-edit migrated \(_editOrder.count) entries from 1.4.3, dropped \(dropped) without a peer")
        }
    }

    /// Writes the whole map out. Must be called with the barrier held.
    private static func writeEditHistoryLocked() {
        var out = [String: [String]]()
        var multi = 0
        for key in _editOrder {
            if let versions = _editHistory[key] {
                out[key.storageKey] = versions
                if versions.count > 1 { multi += 1 }
            }
        }
        UserDefaults.standard.set(out, forKey: editUdKey)
        diag("anti-edit persisted \(out.count) entries, \(multi) with an edit")
    }

    /// Coalesced write-back, for recording originals. Must be called with the
    /// barrier held.
    ///
    /// An original is recorded for *every* message that passes through, so
    /// persisting each one eagerly would mean a UserDefaults write per message.
    /// Losing a few of those to a kill costs nothing: the message is still on
    /// the server and will be recorded again next time it is seen.
    private static func scheduleEditPersistLocked() {
        guard !_editPersistScheduled else { return }
        _editPersistScheduled = true
        editQueue.asyncAfter(deadline: .now() + 5.0, flags: .barrier) {
            _editPersistScheduled = false
            writeEditHistoryLocked()
        }
    }

    /// Remember a message's text the first time we see it. Later sightings are
    /// ignored, so the stored element 0 always stays the pre-edit original.
    ///
    /// A sighting from a *different* conversation under the same id is simply a
    /// different message, and now gets an entry of its own — the two no longer
    /// compete for one slot.
    ///
    /// Nothing is tracked without a peer. An entry that cannot say which chat it
    /// belongs to cannot be checked against the next message of the same number,
    /// which is the whole point.
    private static func recordOriginalText(_ text: String, forId id: Int32, peer: Int64) {
        guard id != 0, peer != 0, !text.isEmpty else { return }
        let key = EditKey(peer: peer, id: id)
        editQueue.sync(flags: .barrier) {
            guard _editHistory[key] == nil else { return }
            _editHistory[key] = [text]
            _editOrder.append(key)
            while _editOrder.count > maxTrackedMessages {
                let oldest = _editOrder.removeFirst()
                _editHistory.removeValue(forKey: oldest)
            }
            scheduleEditPersistLocked()
        }
    }

    /// The conversation a message belongs to, as one number.
    ///
    /// Bot-API encoding: users stay positive, basic groups go negative, and
    /// channels are pushed past the group range, so the three id namespaces
    /// cannot collide with one another.
    private static func peerKey(_ peer: Api.Peer) -> Int64 {
        switch peer {
        case let .peerUser(data): return data.userId
        case let .peerChat(data): return -data.chatId
        case let .peerChannel(data): return -(1_000_000_000_000 + data.channelId)
        }
    }

    private static func appendEditedText(_ text: String, forId id: Int32, peer: Int64) {
        guard id != 0, peer != 0 else { return }
        let key = EditKey(peer: peer, id: id)
        editQueue.sync(flags: .barrier) {
            guard var versions = _editHistory[key] else { return }
            guard versions.last != text else { return }
            versions.append(text)
            if versions.count > maxVersionsPerMessage {
                // Drop the middle, never element 0 — that is the original.
                versions.removeSubrange(1..<(versions.count - maxVersionsPerMessage + 1))
            }
            _editHistory[key] = versions
            // Written now, not in five seconds. An edit is the one thing here
            // that cannot be recovered by seeing the message again — the server
            // only ever serves the latest text, so a version lost to the app
            // being killed is lost for good. Recording originals stays batched;
            // this is rare enough to pay for immediately.
            writeEditHistoryLocked()
        }
    }

    /// The recorded original for this message in this conversation. Another
    /// chat's message of the same number lives under its own key and cannot be
    /// returned here by accident.
    private static func originalText(forId id: Int32, peer: Int64) -> String? {
        guard peer != 0 else { return nil }
        let key = EditKey(peer: peer, id: id)
        return editQueue.sync { _editHistory[key]?.first }
    }

    /// Every recorded version of a message, oldest first — element 0 is the
    /// original. Returns nil when only the original is on file, so the UI side
    /// can use a non-nil answer as "this message is worth a pencil badge".
    ///
    /// The peer is required, and a mismatch answers nil. Ids repeat across
    /// chats, and answering on the id alone is what put a badge on one chat's
    /// message showing another chat's history when tapped. A caller that cannot
    /// work out which conversation it is looking at gets no badge, which is the
    /// safe way to be wrong.
    @objc static func editHistory(forId id: NSNumber, peer: NSNumber?) -> [String]? {
        guard let peer = peer, peer.int64Value != 0 else { return nil }
        let key = EditKey(peer: peer.int64Value, id: id.int32Value)
        let versions = editQueue.sync { _editHistory[key] }
        guard let versions = versions, versions.count > 1 else { return nil }
        return versions
    }

    /// Records the text of a message arriving live, before anyone can edit it.
    ///
    /// Without this Anti-Edit only ever worked for messages that happened to be
    /// pulled from history *before* being edited. A message received and then
    /// edited in the same session had no stored original, so the edit tracker
    /// filed the already-edited text as the original and had nothing to restore.
    ///
    /// Outgoing messages are skipped for the same reason the tracker skips
    /// them: rewriting your own edits breaks editing your own messages.
    private static func recordIncomingOriginal(_ apiMsg: Api.Message) {
        guard case let .message(data) = apiMsg else { return }
        recordShortFormOriginal(id: data.id, flags: data.flags, text: data.message,
                                peer: peerKey(data.peerId))
    }

    /// Same job for the compact update forms. Telegram does not wrap a plain
    /// one-to-one or group text message in a full Message object — it sends
    /// updateShortMessage / updateShortChatMessage, which carry the text inline.
    /// Those are the ones an ordinary conversation actually arrives as, so
    /// missing them meant Anti-Edit never recorded anything in the very case it
    /// exists for. `out` sits at flags bit 1 in every one of these forms.
    private static func recordShortFormOriginal(id: Int32, flags: Int32, text: String, peer: Int64) {
        guard isAntiEditEnabled else { return }
        guard id != 0, !text.isEmpty else { return }
        guard (Int(flags) & Int(1 << 1)) == 0 else { return }
        diag("anti-edit RECORD id=\(id) peer=\(peer) \(text.count) chars")
        recordOriginalText(text, forId: id, peer: peer)
    }

    /// Files what a message currently says. First sighting becomes the original;
    /// any later text that differs is appended as another version.
    ///
    /// The message is never rewritten. The bubble goes on showing exactly what
    /// the server sent — the edited text — and the earlier versions stay
    /// reachable through the pencil badge. Substituting the original into the
    /// bubble instead, as this used to, meant the reader could see that an edit
    /// had happened but never what it said.
    private static func trackMessageVersions(_ apiMsg: Api.Message) {
        guard isAntiEditEnabled else { return }
        guard case let .message(data) = apiMsg else { return }
        guard data.id != 0, !data.message.isEmpty else { return }

        // Your own messages are your own edits; there is no earlier version
        // worth keeping, and touching them risks breaking your ability to edit.
        guard (Int(data.flags) & Int(1 << 1)) == 0 else { return }

        let peer = peerKey(data.peerId)
        guard let original = originalText(forId: data.id, peer: peer) else {
            recordOriginalText(data.message, forId: data.id, peer: peer)
            return
        }
        guard original != data.message else { return }

        // An edit always carries edit_date. Everything else that re-delivers a
        // whole Message — a reaction landing, a view count ticking over, a
        // history refetch — leaves it unset, and treating those as edits is
        // what put a pencil on messages nobody had edited.
        guard data.editDate != nil else {
            diag("anti-edit SKIP id=\(data.id) — text differs but no edit_date")
            return
        }

        appendEditedText(data.message, forId: data.id, peer: peer)
        diag("anti-edit VERSION id=\(data.id) peer=\(peer) — \(original.count) chars -> \(data.message.count) chars")

        // The badge is drawn during -layout, and an edit arriving while the chat
        // is already on screen triggers no layout pass of its own. Without this
        // nudge the pencil only turned up after leaving and reopening the app.
        NotificationCenter.default.post(
            name: NSNotification.Name("MxMessageEditedRealtime"),
            object: nil,
            userInfo: ["ids": [NSNumber(value: data.id)]]
        )
    }

    /// Applied to every batch of loaded messages. Records only; the batch is
    /// handed back untouched, so this never marks the response as modified.
    private static func trackVersions(in msgs: [Api.Message]) {
        guard isAntiEditEnabled else { return }
        msgs.forEach(trackMessageVersions)
    }

    /// Applies every message-level rewrite to a batch arriving from the network,
    /// along with the chat list it came with.
    ///
    /// stripTTLMessage's own change flag used to be discarded at each call site:
    /// a batch was rebuilt only when Anti-Edit, the deleted indicator or the
    /// chat rewrite had fired, so a history load whose *only* change was TTL
    /// stripping was computed and then thrown away.
    private static func patchMessageBatch(_ msgs: [Api.Message], chats: [Api.Chat])
            -> (messages: [Api.Message], chats: [Api.Chat], changed: Bool) {
        trackVersions(in: msgs)

        let (newChats, changedChats) = stripNoForwardsFromChats(chats)

        var changedTTL = false
        let final = msgs.map { msg -> Api.Message in
            let (stripped, didStrip) = stripTTLMessage(msg)
            if didStrip { changedTTL = true }
            return stripped
        }
        return (final, newChats, changedChats || changedTTL)
    }

    /// Dynamically extracts message.id.id from a ChatMessageItem using string description parsing.
    /// This is safer than Mirror because it bypasses computed properties and layout differences.
    @objc static func getMessageId(from item: Any) -> NSNumber? {
        let description = String(describing: item)
        
        let pattern = "MessageId\\(peerId: [^,]+, namespace: [^,]+, id: (\\d+)\\)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsRange = NSRange(description.startIndex..<description.endIndex, in: description)
            if let match = regex.firstMatch(in: description, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: description), let id = Int32(description[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        // NEW PATTERN: Matches "id: 0:id(rawValue: 8310923053):0_11639"
        let rawValuePattern = "rawValue: \\d+\\):\\d+_(\\d+)"
        if let regex = try? NSRegularExpression(pattern: rawValuePattern, options: []) {
            let nsRange = NSRange(description.startIndex..<description.endIndex, in: description)
            if let match = regex.firstMatch(in: description, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: description), let id = Int32(description[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        let fallbackPattern = "messageId: (\\d+)"
        if let regex = try? NSRegularExpression(pattern: fallbackPattern, options: []) {
            let nsRange = NSRange(description.startIndex..<description.endIndex, in: description)
            if let match = regex.firstMatch(in: description, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: description), let id = Int32(description[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        // Also try standard mirror reflection
        let mirror = Mirror(reflecting: item)
        for child in mirror.children {
            if child.label == "message" || child.label == "firstMessage" || child.label == "content" {
                if child.label == "content" {
                    let contentMirror = Mirror(reflecting: child.value)
                    for cChild in contentMirror.children {
                        if cChild.label == "firstMessage" || cChild.label == "message" {
                            if let id = extractId(fromMessage: cChild.value) { return id }
                        }
                    }
                }
                if let id = extractId(fromMessage: child.value) { return id }
            }
        }
        
        // Safe shallow dump. Limits depth to 5 to completely avoid the infinite recursion lag,
        // but goes deep enough to print the MessageId which is usually at depth 1 to 4.
        var dumpStr = ""
        dump(item, to: &dumpStr, maxDepth: 5, maxItems: 200)
        
        let dumpPattern = "MessageId.*?id: (\\d+)"
        if let regex = try? NSRegularExpression(pattern: dumpPattern, options: [.dotMatchesLineSeparators]) {
            let nsRange = NSRange(dumpStr.startIndex..<dumpStr.endIndex, in: dumpStr)
            if let match = regex.firstMatch(in: dumpStr, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: dumpStr), let id = Int32(dumpStr[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        let dumpRawValuePattern = "rawValue: \\d+\\):\\d+_(\\d+)"
        if let regex = try? NSRegularExpression(pattern: dumpRawValuePattern, options: []) {
            let nsRange = NSRange(dumpStr.startIndex..<dumpStr.endIndex, in: dumpStr)
            if let match = regex.firstMatch(in: dumpStr, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: dumpStr), let id = Int32(dumpStr[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        return nil
    }

    private static func extractId(fromMessage msg: Any) -> NSNumber? {
        let msgMirror = Mirror(reflecting: msg)
        for msgChild in msgMirror.children {
            if msgChild.label == "id" {
                let idMirror = Mirror(reflecting: msgChild.value)
                for idChild in idMirror.children {
                    if idChild.label == "id", let idVal = idChild.value as? Int32 {
                        return NSNumber(value: idVal)
                    }
                }
            }
        }
        return nil
    }

    /// The conversation a rendered message belongs to, in the same encoding
    /// peerKey(_:) produces from the wire.
    ///
    /// Recording the peer alongside each tracked id was only half the fix: the
    /// badge asked for history by message id alone, so a message in one chat
    /// still lit up for an entry belonging to another, and tapping it showed
    /// that other chat's text.
    ///
    /// A first attempt read the peer out of the node's printed description and
    /// missed forty times out of forty. A one-shot structural probe settled it:
    /// the node's `item` is an `Optional<ChatMessageItemImpl>`, and nothing on
    /// it prints a MessageId at all. Everything below works off the declared
    /// shape in release-12.9.2 instead of a guess at the printed form.

    /// Unwraps a Postbox PeerId.Namespace / PeerId.Id, which each wrap a single
    /// stored `rawValue`. Older builds stored the numbers directly, so a plain
    /// integer is accepted as well.
    private static func rawNumber(_ value: Any) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int32 { return Int64(v) }
        if let v = value as? UInt32 { return Int64(v) }
        for child in Mirror(reflecting: value).children where child.label == "rawValue" {
            if let v = child.value as? Int64 { return v }
            if let v = child.value as? Int32 { return Int64(v) }
            if let v = child.value as? UInt32 { return Int64(v) }
        }
        return nil
    }

    /// Reflection stops dead at an Optional: its only child is labelled "some".
    /// The node's `item` is an `Optional<ChatMessageItem>`, so every lookup that
    /// went straight for "message" saw nothing and gave up.
    private static func unwrapOptional(_ value: Any) -> Any {
        var current = value
        while true {
            let mirror = Mirror(reflecting: current)
            guard mirror.displayStyle == .optional,
                  let inner = mirror.children.first?.value else { return current }
            current = inner
        }
    }

    /// A Postbox PeerId, as the key peerKey(_:) produces from the wire.
    ///
    /// A MessageId also has `namespace` and `id` children, so a value carrying a
    /// `peerId` is descended into rather than read directly — otherwise a
    /// MessageId would be misread as the peer it belongs to.
    private static func peerKey(fromPeerId value: Any) -> Int64? {
        var namespace: Int64?
        var identifier: Int64?
        for child in Mirror(reflecting: unwrapOptional(value)).children {
            switch child.label {
            case "peerId": return peerKey(fromPeerId: child.value)
            case "namespace": namespace = rawNumber(child.value)
            case "id": identifier = rawNumber(child.value)
            default: break
            }
        }
        guard let namespace = namespace, let identifier = identifier else { return nil }
        // TelegramCore SyncCore_Namespaces.swift: 0 user, 1 group, 2 channel.
        switch namespace {
        case 0: return identifier
        case 1: return -identifier
        case 2: return -(1_000_000_000_000 + identifier)
        default: return nil
        }
    }

    /// Depth-limited walk down to the first MessageId, following only the labels
    /// that lead to one. Left unbounded this would reflect over the whole item —
    /// context, controller interaction, closures and all.
    private static func findPeerKey(in value: Any, depth: Int) -> Int64? {
        guard depth <= 6 else { return nil }
        let mirror = Mirror(reflecting: unwrapOptional(value))
        var children = [(label: String, value: Any)]()
        var peerIdValue: Any?
        var hasNamespace = false
        var hasId = false
        for child in mirror.children {
            let label = child.label ?? ""
            switch label {
            case "peerId": peerIdValue = child.value
            case "namespace": hasNamespace = true
            case "id": hasId = true
            default: break
            }
            children.append((label, child.value))
        }
        // The signature of a MessageId: a peer, a namespace and a number.
        if let peerIdValue = peerIdValue, hasNamespace, hasId {
            return peerKey(fromPeerId: peerIdValue)
        }
        let followable: Set<String> = ["content", "message", "firstMessage", "some", "id", ""]
        for child in children where followable.contains(child.label) || child.label.hasPrefix(".") {
            if let key = findPeerKey(in: child.value, depth: depth + 1) { return key }
        }
        return nil
    }

    /// ChatMessageItemImpl carries the chat it is being drawn in as
    /// `chatLocation`, a ChatLocation whose .peer case holds the PeerId
    /// (AccountContext.swift). That is the shortest honest answer to "which
    /// conversation is this message in"; the MessageId walk is the fallback for
    /// item shapes that do not have it.
    private static func peerKey(fromItem wrapped: Any) -> Int64? {
        let item = unwrapOptional(wrapped)
        for child in Mirror(reflecting: item).children where child.label == "chatLocation" {
            for inner in Mirror(reflecting: unwrapOptional(child.value)).children
            where inner.label == "peer" {
                if let key = peerKey(fromPeerId: inner.value) { return key }
            }
        }
        return findPeerKey(in: item, depth: 0)
    }

    /// Capped so a failing extraction cannot flood the log from -layout.
    private static var peerKeyReports = 0

    @objc static func getMessagePeerKeyFromNode(_ node: Any) -> NSNumber? {
        var currentMirror: Mirror? = Mirror(reflecting: node)
        var foundItem: Any?
        while let mirror = currentMirror {
            for child in mirror.children where child.label == "item" {
                if let key = peerKey(fromItem: child.value) {
                    reportPeerKey(key)
                    return NSNumber(value: key)
                }
                if foundItem == nil { foundItem = child.value }
            }
            currentMirror = mirror.superclassMirror
        }
        // No dump() anywhere on this path. The previous attempt fell back to
        // dumping the item when reflection missed, and the probe measured that
        // dump at 103 KB — produced per message node, on the main thread,
        // during layout. That is what made the app hang on opening a chat.
        probePeerShape(item: foundItem, node: node)
        reportPeerKey(nil, node: node)
        return nil
    }

    private static var peerShapeProbed = false

    /// One-shot structural probe: the labels reflection can see. Cheap by
    /// construction — labels only, no dump, diagnostic builds only.
    private static func probePeerShape(item: Any?, node: Any) {
        guard diagEnabled else { return }
        var shouldRun = false
        signatureQueue.sync {
            if !peerShapeProbed { peerShapeProbed = true; shouldRun = true }
        }
        guard shouldRun else { return }

        guard let wrapped = item else {
            diag("peer-probe: no 'item' child on \(type(of: node))")
            return
        }
        let item = unwrapOptional(wrapped)
        let labels = Mirror(reflecting: item).children.compactMap { $0.label }
        diag("peer-probe: item is \(type(of: item)); children = \(labels.prefix(24).joined(separator: ","))")
        for child in Mirror(reflecting: item).children
        where child.label == "chatLocation" || child.label == "content" {
            let inner = Mirror(reflecting: unwrapOptional(child.value))
            let innerLabels = inner.children.compactMap { $0.label }
            diag("peer-probe: \(child.label ?? "?") is \(type(of: child.value)); cases = \(innerLabels.prefix(8).joined(separator: ","))")
        }
    }

    /// Successes were capped at eight, which is enough to prove extraction works
    /// at all and useless for a symptom that comes and goes. Failures are what
    /// matter now — a nil key makes the edit-history lookup answer nil, which is
    /// indistinguishable from a message that was never edited — so they are
    /// counted separately, allowed further, and say which node they came from.
    private static func reportPeerKey(_ key: Int64?, node: Any? = nil) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            if let key = key {
                guard peerKeyReports < 8 else { return }
                peerKeyReports += 1
                diag("node peer-key \(key)")
            } else {
                guard peerKeyFailureReports < 40 else { return }
                peerKeyFailureReports += 1
                let kind = node.map { String(describing: type(of: $0)) } ?? "?"
                diag("node peer-key NOT FOUND on \(kind)")
            }
        }
    }

    private static var peerKeyFailureReports = 0

    /// Dynamically extracts message ID from a ChatMessageBubbleItemNode
    @objc static func getMessageIdFromNode(_ node: Any) -> NSNumber? {
        var currentMirror: Mirror? = Mirror(reflecting: node)
        while let mirror = currentMirror {
            for child in mirror.children {
                if child.label == "item" {
                    if let id = getMessageId(from: child.value) {
                        return id
                    }
                }
            }
            currentMirror = mirror.superclassMirror
        }
        
        // If reflection completely fails to find 'item', try parsing the node's string description.
        // This is 100% safe (unlike dump) and might reveal the message ID if the node implements CustomStringConvertible.
        let nodeDesc = String(describing: node)
        let pattern = "MessageId\\(peerId: [^,]+, namespace: [^,]+, id: (\\d+)\\)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsRange = NSRange(nodeDesc.startIndex..<nodeDesc.endIndex, in: nodeDesc)
            if let match = regex.firstMatch(in: nodeDesc, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: nodeDesc), let id = Int32(nodeDesc[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        let fallbackPattern = "messageId: (\\d+)"
        if let regex = try? NSRegularExpression(pattern: fallbackPattern, options: []) {
            let nsRange = NSRange(nodeDesc.startIndex..<nodeDesc.endIndex, in: nodeDesc)
            if let match = regex.firstMatch(in: nodeDesc, options: [], range: nsRange) {
                if let idRange = Range(match.range(at: 1), in: nodeDesc), let id = Int32(nodeDesc[idRange]) {
                    return NSNumber(value: id)
                }
            }
        }
        
        return nil
    }

    @objc static func getDebugDumpFromNode(_ node: Any) -> NSString {
        var currentMirror: Mirror? = Mirror(reflecting: node)
        while let mirror = currentMirror {
            for child in mirror.children {
                if child.label == "item" {
                    let item = child.value
                    var dumpStr = ""
                    dump(item, to: &dumpStr, maxDepth: 5, maxItems: 200)
                    return NSString(string: dumpStr)
                }
            }
            currentMirror = mirror.superclassMirror
        }
        return NSString(string: "ITEM NOT FOUND IN MIRROR")
    }

    /// Diagnostic only — reports what a node actually exposes that might carry a
    /// peer, so a failing profile lookup can be read off a device log instead of
    /// guessed at. No feature depends on this.
    @objc static func debugPeerCandidates(_ node: Any) -> NSString {
        var out = [String]()

        var currentMirror: Mirror? = Mirror(reflecting: node)
        var depth = 0
        while let mirror = currentMirror, depth < 3 {
            let labels = mirror.children.compactMap { $0.label }
            if !labels.isEmpty {
                out.append("L\(depth):[\(labels.joined(separator: ","))]")
            }
            for child in mirror.children {
                guard let label = child.label,
                      label.lowercased().contains("peer") else { continue }
                out.append("\(label)=\(String(describing: child.value).prefix(140))")
            }
            currentMirror = mirror.superclassMirror
            depth += 1
        }

        if let obj = node as? NSObject {
            for key in ["peer", "peerId"] where obj.responds(to: NSSelectorFromString(key)) {
                let value = obj.value(forKey: key)
                out.append("kvc.\(key)=\(String(describing: value).prefix(140))")
            }
        }

        return NSString(string: out.isEmpty ? "(no peer-ish members)" : out.joined(separator: " | "))
    }

    @objc static func getPeerIdFromNode(_ node: Any) -> NSNumber? {
        // Try to sniff sharedContext from any node that might have it
        if sharedContext == nil, let obj = node as? NSObject {
            if obj.responds(to: NSSelectorFromString("context")), let ctx = obj.value(forKey: "context") {
                sharedContext = ctx
            }
        }

        // Try KVC first
        if let obj = node as? NSObject {
            for key in ["peer", "peerId", "_peer", "_peerId", "id"] {
                if obj.responds(to: NSSelectorFromString(key)), let val = obj.value(forKey: key) {
                    if let pid = extractId(fromPeer: val) { return pid }
                    if let pid = extractId(fromPeerId: val) { return pid }
                }
            }
        }

        // Try Mirror
        var currentMirror: Mirror? = Mirror(reflecting: node)
        while let mirror = currentMirror {
            for child in mirror.children {
                let label = child.label ?? ""
                if ["peer", "_peer", "peerId", "_peerId", "id"].contains(label) {
                    if let pid = extractId(fromPeer: child.value) { return pid }
                    if let pid = extractId(fromPeerId: child.value) { return pid }
                } else if label == "state" {
                    let stateMirror = Mirror(reflecting: child.value)
                    for stateChild in stateMirror.children {
                        if stateChild.label == "peer" || stateChild.label == "peerId" {
                            if let pid = extractId(fromPeer: stateChild.value) { return pid }
                        }
                    }
                }
            }
            currentMirror = mirror.superclassMirror
        }
        
        // NUCLEAR FALLBACK: Regex on full object description
        let fullDesc = String(describing: node)
        if let pid = extractId(fromPeer: fullDesc) { return pid }
        
        return nil
    }

    private static func extractId(fromPeer peer: Any) -> NSNumber? {
        // Reflection first: it addresses the peer's actual `id`, whereas the
        // description regex below can just as easily latch onto some unrelated
        // number that happens to sit after an "id:" in the dumped text.
        if let pid = findIdByReflection(peer, depth: 0) { return pid }

        if let obj = peer as? NSObject {
            if obj.responds(to: NSSelectorFromString("id")), let pid = obj.value(forKey: "id") {
                return extractId(fromPeerId: pid)
            }
        }

        let desc = String(describing: peer)
        if let range = desc.range(of: "(id|userId|channelId):\\s*(-?\\d+)", options: .regularExpression) {
            let match = desc[range]
            if let idRange = match.range(of: "-?\\d+", options: .regularExpression) {
                if let idVal = Int64(match[idRange]) { return NSNumber(value: idVal) }
            }
        }

        return nil
    }

    /// Walks a peer value down to its `id`, unwrapping containers on the way.
    ///
    /// PeerInfoHeaderNode holds `peer: EnginePeer?` — an Optional around an enum
    /// around the concrete TelegramUser. Reflecting that yields a child labelled
    /// after the enum case ("user"), never "id", so a single-level search comes
    /// back empty and the caller reads the peer as absent. Unwrap Optionals and
    /// enum payloads until the value carrying `id: PeerId` surfaces.
    private static func findIdByReflection(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 6 else { return nil }

        let mirror = Mirror(reflecting: value)

        for child in mirror.children where child.label == "id" {
            if let pid = extractId(fromPeerId: child.value) { return pid }
        }

        switch mirror.displayStyle {
        case .optional, .enum:
            for child in mirror.children {
                if let pid = findIdByReflection(child.value, depth: depth + 1) { return pid }
            }
        default:
            break
        }

        return nil
    }

    private static func extractId(fromPeerId pid: Any) -> NSNumber? {
        if let idVal = pid as? Int64 { return NSNumber(value: idVal) }
        if let idVal = pid as? Int32 { return NSNumber(value: Int64(idVal)) }

        // Postbox's PeerId reflects as `namespace` + `id`, where `id` is an Id
        // struct wrapping `rawValue: Int64`. Walk to that Int64 first; the
        // description forms below are only fallbacks.
        let pidMirror = Mirror(reflecting: pid)
        for pidChild in pidMirror.children {
            guard pidChild.label == "id" || pidChild.label == "_value" || pidChild.label == "value" else { continue }
            if let idVal = pidChild.value as? Int64 { return NSNumber(value: idVal) }
            if let idVal = pidChild.value as? Int32 { return NSNumber(value: Int64(idVal)) }
            for inner in Mirror(reflecting: pidChild.value).children where inner.label == "rawValue" {
                if let idVal = inner.value as? Int64 { return NSNumber(value: idVal) }
                if let idVal = inner.value as? Int32 { return NSNumber(value: Int64(idVal)) }
            }
        }

        let desc = String(describing: pid)

        // PeerId.description is "<namespace>:<id>" (Postbox/Sources/Peer.swift).
        // Grabbing the first number would return the namespace — and CloudUser's
        // namespace is 0, so every user peer would read as "no peer at all".
        if let idPart = firstCapture(in: desc, pattern: "^\\s*(?:PeerId\\()?\\d+:(-?\\d+)\\)?\\s*$"),
           let idVal = Int64(idPart) {
            return NSNumber(value: idVal)
        }

        if let range = desc.range(of: "-?\\d+", options: .regularExpression) {
            if let idVal = Int64(desc[range]) {
                return NSNumber(value: idVal)
            }
        }

        return nil
    }

    /// Best-effort name and username for a profile header, used when adding a
    /// Ghost Exception so the list has something readable to show.
    ///
    /// Reads the node's textual description rather than typed properties:
    /// PeerInfoScreen's internals are Swift-only and shift between Telegram
    /// builds. Building a description is expensive, so this is only ever called
    /// on a tap — never from layout.
    @objc static func getPeerDisplayInfoFromNode(_ node: Any) -> [String: String] {
        var result = [String: String]()

        // TelegramUser is a plain Swift class, so String(describing:) prints
        // nothing but its type name — scraping text for "firstName:" finds
        // nothing at all. Reflect over the real stored properties instead.
        guard let fields = findPeerFieldsByReflection(node, depth: 0) else { return result }

        if let username = fields["username"], !username.isEmpty {
            result["username"] = username
        }

        let name = ["firstName", "lastName"]
            .compactMap { fields[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !name.isEmpty {
            result["name"] = name
        } else if let title = fields["title"], !title.isEmpty {
            result["name"] = title
        }

        return result
    }

    /// Finds the concrete peer under a node and returns its name-ish fields.
    ///
    /// Mirrors the unwrapping in findIdByReflection: the peer sits behind an
    /// Optional and an enum case before its stored properties are reachable.
    private static func findPeerFieldsByReflection(_ value: Any, depth: Int) -> [String: String]? {
        guard depth < 6 else { return nil }

        let wanted: Set<String> = ["firstName", "lastName", "username", "title"]
        let mirror = Mirror(reflecting: value)

        var found = [String: String]()
        var hasId = false

        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == "id" { hasId = true }
            guard wanted.contains(label) else { continue }
            // Values are Optional<String>; unwrap before stringifying, or every
            // one of them reads back as "Optional(\"…\")".
            if let text = unwrapString(child.value) {
                found[label] = text
            }
        }

        // `id` alongside a name field means this really is the peer, not some
        // outer container that happens to expose a "title".
        if hasId && !found.isEmpty {
            return found
        }

        // Descend only along the peer path. Following every member instead would
        // walk the whole display-node tree — thousands of objects deep.
        switch mirror.displayStyle {
        case .optional, .enum:
            for child in mirror.children {
                if let nested = findPeerFieldsByReflection(child.value, depth: depth + 1) {
                    return nested
                }
            }
        default:
            for child in mirror.children {
                guard let label = child.label,
                      label == "peer" || label == "_peer" else { continue }
                if let nested = findPeerFieldsByReflection(child.value, depth: depth + 1) {
                    return nested
                }
            }
        }

        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func unwrapString(_ value: Any) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional, let child = mirror.children.first else { return nil }
        return unwrapString(child.value)
    }

    @objc static func getCurrentUserId() -> NSNumber? {
        if let context = sharedContext, let id = findOwnPeerId(context, depth: 0) {
            // Cached the moment it resolves, so the answer survives a launch
            // where the context has not been handed over yet.
            UserDefaults.standard.set(id.int64Value, forKey: "MxLastKnownUserId")
            return id
        }
        let savedId = UserDefaults.standard.integer(forKey: "MxLastKnownUserId")
        if savedId != 0 { return NSNumber(value: Int64(savedId)) }
        // Once, not on every profile node that asks — this is called from
        // -layout, which runs often enough to bury the rest of the log.
        if !warnedUnresolvedOwnId {
            warnedUnresolvedOwnId = true
            diag("own-id UNRESOLVED — waiting to learn it from a users vector")
        }
        return nil
    }

    private static var warnedUnresolvedOwnId = false

    /// Learns your own user id from the wire.
    ///
    /// Reflecting over the shared context turned out to be a dead end — on this
    /// host the context never reaches the tweak at all, so both it and the
    /// cached value stayed empty and every profile looked like a stranger's.
    /// Every users vector the server sends marks you with `self` at flags bit
    /// 10, which needs no cooperation from the app.
    private static func noteOwnUser(in users: [Api.User]) {
        guard UserDefaults.standard.integer(forKey: "MxLastKnownUserId") == 0 else { return }
        for user in users {
            guard case let .user(data) = user else { continue }
            guard (Int(data.flags) & Int(1 << 10)) != 0 else { continue }
            UserDefaults.standard.set(data.id, forKey: "MxLastKnownUserId")
            diag("own-id LEARNED \(data.id) from the self flag")
            return
        }
    }

    /// True once the id above is on file. Used to keep the response parser
    /// running until it has been learned, and no longer after that.
    private static var isOwnIdKnown: Bool {
        return UserDefaults.standard.integer(forKey: "MxLastKnownUserId") != 0
    }

    /// Pulls the users vector out of whatever just parsed, without having to
    /// name every container that carries one. Api types are enums wrapping a
    /// Cons_ object, so the array sits exactly two levels down.
    private static func noteUsersAnywhere(_ result: Any) {
        for child in Mirror(reflecting: result).children {
            if let users = child.value as? [Api.User] {
                noteOwnUser(in: users)
                notePeerNames(in: users)
            }
            for sub in Mirror(reflecting: child.value).children {
                if let users = sub.value as? [Api.User] {
                    noteOwnUser(in: users)
                    notePeerNames(in: users)
                }
            }
        }
    }

    // MARK: - Peer names

    /// id -> ["name": …, "username": …], learned from any users vector that
    /// passes through.
    ///
    /// Ghost Exceptions used to read the name by reflecting over the profile
    /// header node. That works only while the host app hands the tweak a peer
    /// object it can walk, which on this fork it does not — so entries were
    /// filed with no name and the list showed a bare numeric ID. The wire
    /// carries the same two fields and needs no cooperation from the app.
    private static let peerNameQueue = DispatchQueue(label: "com.kira.peerNames",
                                                     attributes: .concurrent)
    private static var _peerNames = [Int64: [String: String]]()

    private static func notePeerNames(in users: [Api.User]) {
        var batch = [Int64: [String: String]]()
        for user in users {
            guard case let .user(data) = user else { continue }
            var info = [String: String]()
            let name = [data.firstName, data.lastName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !name.isEmpty { info["name"] = name }
            if let username = data.username, !username.isEmpty {
                info["username"] = username
            } else if let extra = data.usernames {
                // Accounts that moved to collectible usernames leave the plain
                // field empty and list them here instead.
                for case let .username(entry) in extra where !entry.username.isEmpty {
                    info["username"] = entry.username
                    break
                }
            }
            guard !info.isEmpty else { continue }
            batch[data.id] = info
        }
        guard !batch.isEmpty else { return }
        peerNameQueue.async(flags: .barrier) {
            for (id, info) in batch { _peerNames[id] = info }
            // Nothing here is worth persisting — the name is copied into the
            // exception entry the moment one is created, and the cache refills
            // from the next response. Drop it wholesale rather than grow
            // without bound.
            if _peerNames.count > 2000 { _peerNames.removeAll(keepingCapacity: true) }
        }
    }

    @objc static func cachedPeerInfo(forId id: NSNumber) -> [String: String]? {
        var result: [String: String]?
        peerNameQueue.sync { result = _peerNames[id.int64Value] }
        return result
    }

    /// Finds account.peerId inside the shared context.
    ///
    /// The previous version stepped exactly two levels, context.account then
    /// .peerId, and gave up the moment either was wrapped — in an Optional, or
    /// behind one more holder object. Returning nil there meant the tweak could
    /// not tell your own profile from anyone else's, which is how the Ghost
    /// Exception eye ended up offered on yourself.
    private static func findOwnPeerId(_ value: Any, depth: Int) -> NSNumber? {
        guard depth < 5 else { return nil }
        let mirror = Mirror(reflecting: value)

        for child in mirror.children where child.label == "peerId" {
            if let id = extractId(fromPeerId: child.value) { return id }
        }

        for child in mirror.children {
            // Only follow the account chain, plus the wrappers that can sit in
            // the middle of it. Descending everywhere would happily return some
            // unrelated peerId from elsewhere in the context.
            let followable = (child.label == "account") || (child.label == "context")
                || (child.label == "some") || (child.label == nil)
            guard followable || mirror.displayStyle == .optional else { continue }
            if let id = findOwnPeerId(child.value, depth: depth + 1) { return id }
        }
        return nil
    }

    /// A caller with no peer gets `false`: showing the marker on the wrong
    /// message is worse than not showing it on the right one.
    @objc static func isDeleted(_ msgId: NSNumber, peer: NSNumber?) -> Bool {
        guard let peer = peer, peer.int64Value != 0 else { return false }
        return isDeletedMessage(id: msgId.int32Value, peer: peer.int64Value)
    }

    // A revoked message used to get a 🗑️ glued onto the front of its text. That
    // rewrite is gone: the bubble already carries a red trash icon drawn next to
    // the timestamp, so the prefix was a second marker for the same fact — and a
    // costly one. It never shifted the entity offsets that came with the message,
    // so every bold run, link, mention and custom emoji on a revoked message
    // landed three UTF-16 units to the left of where it belonged.
    //
    // `_deletedIds` is still recorded; it is what the icon asks about.
    // IDs of messages that originally had a self-destruct timer (one-time media ttlSeconds)
    private static var selfDestructingMessageIds = Set<Int32>()

    @objc static func isMessageSelfDestructing(_ msgId: NSNumber) -> Bool {
        return selfDestructingMessageIds.contains(msgId.int32Value)
    }

    // IDs of messages in chats with auto-delete (ttlPeriod)
    private static var autoDeleteMessageIds = Set<Int32>()

    @objc static func isMessageAutoDelete(_ msgId: NSNumber) -> Bool {
        return autoDeleteMessageIds.contains(msgId.int32Value)
    }

    /// Bounded so an ordinary photo-heavy chat cannot flood the log.
    private static var ttlMediaReports = 0

    /// Reports what the server actually said about a piece of media, which is
    /// the one thing that decides whether the marker can be restored on a later
    /// load. Diagnostic only.
    private static func diagTTLMedia(_ kind: String, id: Int32, ttlSeconds: Int32?, flags: Int32) {
        guard diagEnabled else { return }
        var report = false
        signatureQueue.sync {
            if ttlMediaReports < 24 { ttlMediaReports += 1; report = true }
        }
        guard report else { return }
        let known = selfDestructingMessageIds.contains(id)
        diag("ttl-media: \(kind) id=\(id) ttl=\(ttlSeconds.map(String.init) ?? "nil") "
             + "bit2=\((Int(flags) & (1 << 2)) != 0) alreadyKnown=\(known)")
    }

    private static func stripTTLMedia(_ media: Api.MessageMedia, messageId: Int32) -> Api.MessageMedia {
        guard UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct") else { return media }
        switch media {
        case let .messageMediaPhoto(data):
            diagTTLMedia("photo", id: messageId, ttlSeconds: data.ttlSeconds, flags: data.flags)
            if data.ttlSeconds != nil || (Int(data.flags) & Int(1 << 2)) != 0 {
                selfDestructingMessageIds.insert(messageId)
            }
            // Clear ttlSeconds (bit 2) and spoiler (bit 3) and media_unread (bit 5) just in case
            return .messageMediaPhoto(Api.MessageMedia.Cons_messageMediaPhoto(flags: data.flags & ~(1 << 2) & ~(1 << 3) & ~(1 << 5), photo: data.photo, ttlSeconds: nil, video: data.video))
        case let .messageMediaDocument(data):
            diagTTLMedia("document", id: messageId, ttlSeconds: data.ttlSeconds, flags: data.flags)
            if data.ttlSeconds != nil || (Int(data.flags) & Int(1 << 2)) != 0 {
                selfDestructingMessageIds.insert(messageId)
            }
            // Clear ttlSeconds (bit 2) and spoiler (bit 3) and video stuff
            return .messageMediaDocument(Api.MessageMedia.Cons_messageMediaDocument(flags: data.flags & ~(1 << 2) & ~(1 << 3), document: data.document, altDocuments: data.altDocuments, videoCover: data.videoCover, videoTimestamp: data.videoTimestamp, ttlSeconds: nil))
        default:
            return media
        }
    }

    private static func stripNoForwards(_ chat: Api.Chat) -> (Api.Chat, Bool) {
        guard UserDefaults.standard.bool(forKey: "disableForwardRestriction") ||
              UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct") ||
              UserDefaults.standard.bool(forKey: "MxAntiAutoDelete") else { return (chat, false) }
              
        switch chat {
        case let .channel(data):
            // Bit 16 is standard, bit 27 is used in neutralizedPayload, bit 5 is restricted
            // Bit 27: copyProtectionEnabled
            let mask: Int32 = ~( (1 << 16) | (1 << 27) | (1 << 5) )
            
            let newFlags = data.flags & mask
            let newFlags2 = data.flags2 & mask
            
            if newFlags == data.flags && newFlags2 == data.flags2 {
                return (chat, false)
            }

            return (.channel(Api.Chat.Cons_channel(
                flags: newFlags,
                flags2: newFlags2,
                id: data.id, accessHash: data.accessHash, title: data.title,
                username: data.username, photo: data.photo, date: data.date,
                restrictionReason: data.restrictionReason, adminRights: data.adminRights,
                bannedRights: data.bannedRights, defaultBannedRights: data.defaultBannedRights,
                participantsCount: data.participantsCount, usernames: data.usernames,
                storiesMaxId: data.storiesMaxId, color: data.color, profileColor: data.profileColor,
                emojiStatus: data.emojiStatus, level: data.level, subscriptionUntilDate: data.subscriptionUntilDate,
                botVerificationIcon: data.botVerificationIcon, sendPaidMessagesStars: data.sendPaidMessagesStars,
                linkedMonoforumId: data.linkedMonoforumId,
                linkedCommunityId: data.linkedCommunityId
            )), true)
        case let .chat(data):
            // Bit 14/16/25 are used for restrictions
            let mask: Int32 = ~( (1 << 14) | (1 << 16) | (1 << 25) )
            let newFlags = data.flags & mask
            if newFlags == data.flags {
                return (chat, false)
            }
            return (.chat(Api.Chat.Cons_chat(
                flags: newFlags,
                id: data.id, title: data.title, photo: data.photo,
                participantsCount: data.participantsCount, date: data.date, version: data.version,
                migratedTo: data.migratedTo, adminRights: data.adminRights,
                defaultBannedRights: data.defaultBannedRights
            )), true)
        default:
            return (chat, false)
        }
    }

    private static func stripNoForwardsFromChats(_ chats: [Api.Chat]) -> ([Api.Chat], Bool) {
        var modified = false
        let newChats = chats.map { chat -> Api.Chat in
            let (stripped, changed) = stripNoForwards(chat)
            if changed {
                modified = true
            }
            return stripped
        }
        return (newChats, modified)
    }
    
    private static func stripNoForwardsFromFullChat(_ chatFull: Api.ChatFull) -> (Api.ChatFull, Bool) {
        guard UserDefaults.standard.bool(forKey: "disableForwardRestriction") ||
              UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct") ||
              UserDefaults.standard.bool(forKey: "MxAntiAutoDelete") else { return (chatFull, false) }
              
        switch chatFull {
        case let .channelFull(data):
            // Bit 10 is noforwards in some versions, clearing multiple bits for safety
            let mask: Int32 = ~( (1 << 10) | (1 << 27) | (1 << 16) | (1 << 26) )
            let newFlags = data.flags & mask
            let newFlags2 = data.flags2 & mask
            
            if newFlags == data.flags && newFlags2 == data.flags2 {
                return (chatFull, false)
            }
            
            return (.channelFull(Api.ChatFull.Cons_channelFull(
                flags: newFlags, flags2: newFlags2, id: data.id, about: data.about,
                participantsCount: data.participantsCount, adminsCount: data.adminsCount,
                kickedCount: data.kickedCount, bannedCount: data.bannedCount, onlineCount: data.onlineCount,
                readInboxMaxId: data.readInboxMaxId, readOutboxMaxId: data.readOutboxMaxId,
                unreadCount: data.unreadCount, chatPhoto: data.chatPhoto, notifySettings: data.notifySettings,
                exportedInvite: data.exportedInvite, botInfo: data.botInfo, migratedFromChatId: data.migratedFromChatId,
                migratedFromMaxId: data.migratedFromMaxId, pinnedMsgId: data.pinnedMsgId, stickerset: data.stickerset,
                availableMinId: data.availableMinId, folderId: data.folderId, linkedChatId: data.linkedChatId,
                location: data.location, slowmodeSeconds: data.slowmodeSeconds, slowmodeNextSendDate: data.slowmodeNextSendDate,
                statsDc: data.statsDc, pts: data.pts, call: data.call, ttlPeriod: data.ttlPeriod,
                pendingSuggestions: data.pendingSuggestions, groupcallDefaultJoinAs: data.groupcallDefaultJoinAs,
                themeEmoticon: data.themeEmoticon, requestsPending: data.requestsPending,
                recentRequesters: data.recentRequesters, defaultSendAs: data.defaultSendAs,
                availableReactions: data.availableReactions, reactionsLimit: data.reactionsLimit,
                stories: data.stories, wallpaper: data.wallpaper, boostsApplied: data.boostsApplied,
                boostsUnrestrict: data.boostsUnrestrict, emojiset: data.emojiset,
                botVerification: data.botVerification, stargiftsCount: data.stargiftsCount,
                sendPaidMessagesStars: data.sendPaidMessagesStars, mainTab: data.mainTab,
                guardBotId: data.guardBotId
            )), true)
        case let .chatFull(data):
            let mask: Int32 = ~( (1 << 10) | (1 << 27) | (1 << 16) | (1 << 26) )
            let newFlags = data.flags & mask
            if newFlags == data.flags {
                return (chatFull, false)
            }
            return (.chatFull(Api.ChatFull.Cons_chatFull(
                flags: newFlags, id: data.id, about: data.about, participants: data.participants,
                chatPhoto: data.chatPhoto, notifySettings: data.notifySettings, exportedInvite: data.exportedInvite,
                botInfo: data.botInfo, pinnedMsgId: data.pinnedMsgId, folderId: data.folderId, call: data.call,
                ttlPeriod: data.ttlPeriod, groupcallDefaultJoinAs: data.groupcallDefaultJoinAs,
                themeEmoticon: data.themeEmoticon, requestsPending: data.requestsPending,
                recentRequesters: data.recentRequesters, availableReactions: data.availableReactions,
                reactionsLimit: data.reactionsLimit
            )), true)
        default:
            // communityFull, new in 12.9, carries no forwarding restriction.
            return (chatFull, false)
        }
    }

    private static func shiftEntities(_ entities: [Api.MessageEntity]?, by offset: Int32) -> [Api.MessageEntity] {
        guard let entities = entities else { return [] }
        return entities.map { entity in
            switch entity {
            case let .messageEntityUnknown(d): return .messageEntityUnknown(Api.MessageEntity.Cons_messageEntityUnknown(offset: d.offset + offset, length: d.length))
            case let .messageEntityMention(d): return .messageEntityMention(Api.MessageEntity.Cons_messageEntityMention(offset: d.offset + offset, length: d.length))
            case let .messageEntityHashtag(d): return .messageEntityHashtag(Api.MessageEntity.Cons_messageEntityHashtag(offset: d.offset + offset, length: d.length))
            case let .messageEntityBotCommand(d): return .messageEntityBotCommand(Api.MessageEntity.Cons_messageEntityBotCommand(offset: d.offset + offset, length: d.length))
            case let .messageEntityUrl(d): return .messageEntityUrl(Api.MessageEntity.Cons_messageEntityUrl(offset: d.offset + offset, length: d.length))
            case let .messageEntityEmail(d): return .messageEntityEmail(Api.MessageEntity.Cons_messageEntityEmail(offset: d.offset + offset, length: d.length))
            case let .messageEntityBold(d): return .messageEntityBold(Api.MessageEntity.Cons_messageEntityBold(offset: d.offset + offset, length: d.length))
            case let .messageEntityItalic(d): return .messageEntityItalic(Api.MessageEntity.Cons_messageEntityItalic(offset: d.offset + offset, length: d.length))
            case let .messageEntityCode(d): return .messageEntityCode(Api.MessageEntity.Cons_messageEntityCode(offset: d.offset + offset, length: d.length))
            case let .messageEntityPre(d): return .messageEntityPre(Api.MessageEntity.Cons_messageEntityPre(offset: d.offset + offset, length: d.length, language: d.language))
            case let .messageEntityTextUrl(d): return .messageEntityTextUrl(Api.MessageEntity.Cons_messageEntityTextUrl(offset: d.offset + offset, length: d.length, url: d.url))
            case let .messageEntityMentionName(d): return .messageEntityMentionName(Api.MessageEntity.Cons_messageEntityMentionName(offset: d.offset + offset, length: d.length, userId: d.userId))
            case let .messageEntityPhone(d): return .messageEntityPhone(Api.MessageEntity.Cons_messageEntityPhone(offset: d.offset + offset, length: d.length))
            case let .messageEntityCashtag(d): return .messageEntityCashtag(Api.MessageEntity.Cons_messageEntityCashtag(offset: d.offset + offset, length: d.length))
            case let .messageEntityUnderline(d): return .messageEntityUnderline(Api.MessageEntity.Cons_messageEntityUnderline(offset: d.offset + offset, length: d.length))
            case let .messageEntityStrike(d): return .messageEntityStrike(Api.MessageEntity.Cons_messageEntityStrike(offset: d.offset + offset, length: d.length))
            case let .messageEntityBlockquote(d): return .messageEntityBlockquote(Api.MessageEntity.Cons_messageEntityBlockquote(flags: d.flags, offset: d.offset + offset, length: d.length))
            case let .messageEntityBankCard(d): return .messageEntityBankCard(Api.MessageEntity.Cons_messageEntityBankCard(offset: d.offset + offset, length: d.length))
            case let .messageEntitySpoiler(d): return .messageEntitySpoiler(Api.MessageEntity.Cons_messageEntitySpoiler(offset: d.offset + offset, length: d.length))
            case let .messageEntityCustomEmoji(d): return .messageEntityCustomEmoji(Api.MessageEntity.Cons_messageEntityCustomEmoji(offset: d.offset + offset, length: d.length, documentId: d.documentId))
            default: return entity
            }
        }
    }

    private static func applyTTLIndicator(message: String, entities: [Api.MessageEntity]?, shouldApply: Bool) -> (String, [Api.MessageEntity]?) {
        var newMessageText = message
        var newEntities = entities ?? []

        // Hide Disappearing Label: keep intercepting the media, just don't
        // prepend the marker text to it.
        if UserDefaults.standard.bool(forKey: "MxHideDisappearingLabel") {
            return (message, entities)
        }

        if shouldApply {
            let marker = "dissapearing message "
            if !newMessageText.contains("dissapearing message") {
                 // Remove ⏱️ emoji if it was added in previous turns
                 if newMessageText.hasPrefix("⏱️ ") {
                     newMessageText.removeFirst(3)
                 }

                 let markerLen = Int32(marker.count)
                 newEntities = shiftEntities(newEntities, by: markerLen)
                 
                 // Add italic and spoiler entities for the marker
                 let markerTextLen = Int32(marker.count - 1)
                 newEntities.insert(.messageEntityItalic(Api.MessageEntity.Cons_messageEntityItalic(offset: 0, length: markerTextLen)), at: 0)
                 newEntities.insert(.messageEntitySpoiler(Api.MessageEntity.Cons_messageEntitySpoiler(offset: 0, length: markerTextLen)), at: 0)
                 
                 newMessageText = marker + newMessageText
            }
        }
        return (newMessageText, newEntities)
    }

    private static func stripTTLMessage(_ apiMsg: Api.Message) -> (Api.Message, Bool) {
        guard UserDefaults.standard.bool(forKey: "disableForwardRestriction") || 
              UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct") else { return (apiMsg, false) }
        guard case let .message(data) = apiMsg else {
            return (apiMsg, false)
        }
        
        var isDestructing = false
        if data.ttlPeriod != nil || (Int(data.flags) & Int(1 << 25)) != 0 {
            isDestructing = true
            selfDestructingMessageIds.insert(data.id)
        }

        let newMedia = data.media.map { stripTTLMedia($0, messageId: data.id) }
        
        let isMediaDestructing = selfDestructingMessageIds.contains(data.id)
        let shouldStripFlags = isDestructing || isMediaDestructing
        
        let (newMessageText, newEntities) = applyTTLIndicator(message: data.message, entities: data.entities, shouldApply: shouldStripFlags)

        if shouldStripFlags {
            diag("ttl: id=\(data.id) ttlPeriod=\(isDestructing) knownMedia=\(isMediaDestructing) "
                 + "markerAdded=\(newMessageText != data.message)")
        }

        var newFlags = shouldStripFlags ? (data.flags & ~(1 << 25) & ~(1 << 5)) : data.flags
        var newFlags2 = data.flags2
        
        // Strip noforwards if requested
        if UserDefaults.standard.bool(forKey: "disableForwardRestriction") || 
           UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct") {
            // Bit 14 is standard, bit 26 is used in neutralizePayload
            let mask: Int32 = ~( (1 << 14) | (1 << 26) )
            newFlags &= mask
            newFlags2 &= mask
        }
        
        // Set entities flag (bit 7) if we have entities
        if (newEntities?.count ?? 0) > 0 {
            newFlags |= (1 << 7)
        }
        
        let resultMsg = Api.Message.message(Api.Message.Cons_message(
            flags: newFlags, flags2: newFlags2, id: data.id, fromId: data.fromId,
            fromBoostsApplied: data.fromBoostsApplied, fromRank: data.fromRank, peerId: data.peerId,
            savedPeerId: data.savedPeerId, fwdFrom: data.fwdFrom,
            viaBotId: data.viaBotId, viaBusinessBotId: data.viaBusinessBotId,
            guestchatViaFrom: data.guestchatViaFrom,
            replyTo: data.replyTo, date: data.date,
            message: newMessageText,
            media: newMedia, replyMarkup: data.replyMarkup, entities: newEntities,
            views: data.views, forwards: data.forwards, replies: data.replies,
            editDate: data.editDate, postAuthor: data.postAuthor, groupedId: data.groupedId,
            reactions: data.reactions, restrictionReason: data.restrictionReason,
            ttlPeriod: shouldStripFlags ? nil : data.ttlPeriod, quickReplyShortcutId: data.quickReplyShortcutId,
            effect: data.effect, factcheck: data.factcheck,
            reportDeliveryUntilDate: data.reportDeliveryUntilDate,
            paidMessageStars: data.paidMessageStars,
            suggestedPost: data.suggestedPost, scheduleRepeatPeriod: data.scheduleRepeatPeriod,
            summaryFromLanguage: data.summaryFromLanguage,
            richMessage: data.richMessage
        ))
        
        let modified = (newFlags != data.flags) || (newMessageText != data.message) || (newEntities?.count != data.entities?.count) || (newFlags2 != data.flags2)
        
        return (resultMsg, modified)
    }

    private static func stripTTLUpdates(_ updates: [Api.Update]) -> ([Api.Update], Bool) {
        var modified = false
        let result = updates.map { update -> Api.Update in
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                modified = true
            }
            return stripped
        }
        return (result, modified)
    }

    private static func stripTTLUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        switch update {
        case let .updateNewMessage(data):
            recordIncomingOriginal(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewMessage(Api.Update.Cons_updateNewMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        case let .updateNewChannelMessage(data):
            recordIncomingOriginal(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewChannelMessage(Api.Update.Cons_updateNewChannelMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        // Edits are recorded and then passed through untouched. The reader sees
        // the edit as Telegram intended; the pencil badge is what surfaces the
        // versions that came before it.
        case let .updateEditMessage(data):
            // Logged before the flag check: silence here otherwise cannot be
            // told apart from "the update never arrived".
            diag("updateEditMessage seen, antiEdit=\(isAntiEditEnabled)")
            trackMessageVersions(data.message)
            return (update, false)
        case let .updateEditChannelMessage(data):
            diag("updateEditChannelMessage seen, antiEdit=\(isAntiEditEnabled)")
            trackMessageVersions(data.message)
            return (update, false)
        case let .updateDeleteMessages(data):
            guard let kept = neutralizeDeletions(data.messages, peer: cloudScope) else { return (update, false) }
            return (.updateDeleteMessages(Api.Update.Cons_updateDeleteMessages(
                messages: kept, pts: data.pts, ptsCount: data.ptsCount)), true)
        case let .updateDeleteChannelMessages(data):
            let channelPeer = -(1_000_000_000_000 + data.channelId)
            guard let kept = neutralizeDeletions(data.messages, peer: channelPeer) else { return (update, false) }
            return (.updateDeleteChannelMessages(Api.Update.Cons_updateDeleteChannelMessages(
                channelId: data.channelId, messages: kept,
                pts: data.pts, ptsCount: data.ptsCount)), true)
        case .updateStarsBalance:
            return fakeStarsBalanceUpdate(update)
        default:
            return (update, false)
        }
    }

    /// Anti-Revoke, applied to a parsed deletion instead of raw bytes.
    ///
    /// The byte scanner in Hooks.xm only ever sees the push stream. A deletion
    /// in a channel or supergroup normally reaches the client inside
    /// updates.getChannelDifference — an RPC reply, gzipped, so the scanner
    /// sweeps compressed bytes and finds nothing. That is the whole reason
    /// Anti-Revoke held in private chats and not in groups or channels.
    ///
    /// Returns the replacement id list, or nil when nothing needs changing.
    /// Ids are zeroed rather than dropped, exactly as the byte path does: the
    /// count, pts and pts_count stay as the server sent them, and message 0
    /// exists nowhere, so Telegram applies the deletion to nothing.
    private static func neutralizeDeletions(_ ids: [Int32], peer: Int64) -> [Int32]? {
        let defaults = UserDefaults.standard
        let antiRevoke = defaults.bool(forKey: "MxAntiRevoke")
        let antiSelfDestruct = defaults.bool(forKey: "MxAntiSelfDestruct")
        guard antiRevoke || antiSelfDestruct else { return nil }

        let live = ids.filter { $0 != 0 }
        guard !live.isEmpty else { return nil }
        live.forEach { addDeletedId($0, peer: peer) }

        let kept = ids.map { id -> Int32 in
            if id == 0 { return 0 }
            if antiRevoke { return 0 }
            return selfDestructingMessageIds.contains(id) ? 0 : id
        }
        guard kept != ids else { return nil }

        if antiRevoke {
            let saved = live.map { NSNumber(value: $0) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("MxMessageDeletedRealtime"),
                    object: nil, userInfo: ["ids": saved])
            }
        }
        diag("anti-revoke: neutralised \(live.count) deletion(s) in the parsed path")
        return kept
    }

    @objc static func stripAntiSelfDestruct(_ data: NSData) -> NSData? {
        let isAntiSelfDestruct = UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct")
        let isNoForwardsBypass = UserDefaults.standard.bool(forKey: "disableForwardRestriction")
        
        // The last clause keeps the parser running while your own user id is
        // still unknown, so it can be picked off a users vector. It stops
        // applying the moment the id is learned, which takes a few seconds.
        let isAntiRevoke = UserDefaults.standard.bool(forKey: "MxAntiRevoke")
        guard isAntiSelfDestruct || isNoForwardsBypass || isAntiEditEnabled
                || isCustomStarsEnabled || isAntiRevoke || !isOwnIdKnown else { return nil }
        let buffer = Buffer(data: data as Data)
        let reader = BufferReader(buffer)
        guard let signature = reader.readInt32() else { return nil }

        diagSignature(signature)

        if signature == 0x73f1f8dc { // msg_container
            guard let count = reader.readInt32() else { return nil }
            let outBuf = Buffer()
            outBuf.appendInt32(0x73f1f8dc)
            outBuf.appendInt32(count)
            
            var modifiedContainer = false
            for _ in 0..<count {
                guard let msg_id = reader.readInt64(),
                      let seqno = reader.readInt32(),
                      let bytes = reader.readInt32() else { return nil }
                
                guard let bodyBuffer = reader.readBuffer(Int(bytes)) else { return nil }
                let bodyData = bodyBuffer.makeData() as NSData
                
                var newBodyData = bodyData
                if let stripped = stripAntiSelfDestruct(newBodyData) {
                    newBodyData = stripped
                    modifiedContainer = true
                }
                
                outBuf.appendInt64(msg_id)
                outBuf.appendInt32(seqno)
                outBuf.appendInt32(Int32(newBodyData.length))
                outBuf.appendBytes(newBodyData.bytes, length: UInt(newBodyData.length))
            }
            
            return modifiedContainer ? (outBuf.makeData() as NSData) : nil
        }
        // Do not reset the reader, because Api.parse(reader, signature:) expects the reader to be at offset 4
        guard let result = Api.parse(reader, signature: signature) else {
            // A constructor the bundled API layer cannot decode. Worth knowing:
            // if edit updates land here, the layer is out of step with the
            // server and no amount of downstream logic will ever see them.
            diagUnparsed(signature)
            return nil
        }
        
        noteUsersAnywhere(result)

        var modified = false
        var newResult: Any = result

        // Stars balance. Handled by type rather than by request, so every reply
        // that carries one — the balance screen, the transaction list, the gift
        // sheets — reads back the same number.
        if let status = result as? Api.payments.StarsStatus,
           let faked = fakeStarsStatus(status) {
            return serializeBoxed(faked)
        }

        if let updates = result as? Api.Updates {
            switch updates {
            case let .updates(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updates(Api.Updates.Cons_updates(updates: stripped, users: data.users, chats: newChats, date: data.date, seq: data.seq))
                    modified = true
                }
            case let .updateShort(data):
                let (stripped, changed) = stripTTLUpdate(data.update)
                if changed {
                    newResult = Api.Updates.updateShort(Api.Updates.Cons_updateShort(update: stripped, date: data.date))
                    modified = true
                }
            case let .updateShortMessage(data):
                // A private chat is identified by the other user, which is what
                // userId holds here and what peerUser carries in the full form.
                recordShortFormOriginal(id: data.id, flags: data.flags, text: data.message,
                                        peer: data.userId)
                var isDestructing = false
                if data.ttlPeriod != nil || (Int(data.flags) & Int(1 << 25)) != 0 {
                    isDestructing = true
                    selfDestructingMessageIds.insert(data.id)
                }
                var newFlags = data.flags
                if isDestructing {
                    newFlags &= ~(1 << 25)
                    newFlags &= ~(1 << 5)
                }

                // Only clear noforwards flags if they are actually set —
                // unconditionally clearing them on every message caused
                // pересериализацию обычных сообщений и ломало rich notifications.
                let hasNoForwards = (Int(data.flags) & (1 << 14)) != 0 || (Int(data.flags) & (1 << 26)) != 0
                if hasNoForwards && (UserDefaults.standard.bool(forKey: "disableForwardRestriction") ||
                   UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct")) {
                    newFlags &= ~(1 << 14)
                    newFlags &= ~(1 << 26)
                }

                let (newMessageText, newEntities) = applyTTLIndicator(message: data.message, entities: data.entities, shouldApply: isDestructing)

                if newFlags != data.flags || newMessageText != data.message || (newEntities?.count ?? 0) != (data.entities?.count ?? 0) {
                    if (newEntities?.count ?? 0) > 0 {
                        newFlags |= (1 << 7)
                    }
                    newResult = Api.Updates.updateShortMessage(Api.Updates.Cons_updateShortMessage(flags: newFlags, id: data.id, userId: data.userId, message: newMessageText, pts: data.pts, ptsCount: data.ptsCount, date: data.date, fwdFrom: data.fwdFrom, viaBotId: data.viaBotId, replyTo: data.replyTo, entities: newEntities, ttlPeriod: isDestructing ? nil : data.ttlPeriod))
                    modified = true
                }
            case let .updateShortChatMessage(data):
                recordShortFormOriginal(id: data.id, flags: data.flags, text: data.message,
                                        peer: -data.chatId)
                var isDestructing = false
                if data.ttlPeriod != nil || (Int(data.flags) & Int(1 << 25)) != 0 {
                    isDestructing = true
                    selfDestructingMessageIds.insert(data.id)
                }
                var newFlags = data.flags
                if isDestructing {
                    newFlags &= ~(1 << 25)
                    newFlags &= ~(1 << 5)
                }

                // Only clear noforwards flags if they are actually set
                let hasNoForwardsChatMsg = (Int(data.flags) & (1 << 14)) != 0 || (Int(data.flags) & (1 << 26)) != 0
                if hasNoForwardsChatMsg && (UserDefaults.standard.bool(forKey: "disableForwardRestriction") ||
                   UserDefaults.standard.bool(forKey: "MxAntiSelfDestruct")) {
                    newFlags &= ~(1 << 14)
                    newFlags &= ~(1 << 26)
                }
                
                let (newMessageText, newEntities) = applyTTLIndicator(message: data.message, entities: data.entities, shouldApply: isDestructing)
                
                if newFlags != data.flags || newMessageText != data.message || (newEntities?.count ?? 0) != (data.entities?.count ?? 0) {
                    if (newEntities?.count ?? 0) > 0 {
                        newFlags |= (1 << 7)
                    }
                    newResult = Api.Updates.updateShortChatMessage(Api.Updates.Cons_updateShortChatMessage(flags: newFlags, id: data.id, fromId: data.fromId, chatId: data.chatId, message: newMessageText, pts: data.pts, ptsCount: data.ptsCount, date: data.date, fwdFrom: data.fwdFrom, viaBotId: data.viaBotId, replyTo: data.replyTo, entities: newEntities, ttlPeriod: isDestructing ? nil : data.ttlPeriod))
                    modified = true
                }
            case let .updateShortSentMessage(data):
                let newMedia = data.media.map { stripTTLMedia($0, messageId: data.id) }
                let isMediaDestructing = selfDestructingMessageIds.contains(data.id) || data.ttlPeriod != nil || (Int(data.flags) & Int(1 << 25)) != 0
                let newFlags = isMediaDestructing ? (data.flags & ~(1 << 25) & ~(1 << 5)) : data.flags
                
                if newFlags != data.flags || isMediaDestructing {
                    newResult = Api.Updates.updateShortSentMessage(Api.Updates.Cons_updateShortSentMessage(flags: newFlags, id: data.id, pts: data.pts, ptsCount: data.ptsCount, date: data.date, media: newMedia, entities: data.entities, ttlPeriod: isMediaDestructing ? nil : data.ttlPeriod))
                    modified = true
                }
            case let .updatesCombined(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updatesCombined(Api.Updates.Cons_updatesCombined(updates: stripped, users: data.users, chats: newChats, date: data.date, seqStart: data.seqStart, seq: data.seq))
                    modified = true
                }
            default:
                break
            }
        } else if let msgs = result as? Api.messages.Messages {
            switch msgs {
            case let .messages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messages(Api.messages.Messages.Cons_messages(messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .messagesSlice(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messagesSlice(Api.messages.Messages.Cons_messagesSlice(flags: data.flags, count: data.count, nextRate: data.nextRate, offsetIdOffset: data.offsetIdOffset, searchFlood: data.searchFlood, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelMessages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.channelMessages(Api.messages.Messages.Cons_channelMessages(flags: data.flags, pts: data.pts, count: data.count, offsetIdOffset: data.offsetIdOffset, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.Difference {
            // updates.getDifference is how the client catches up after a cold
            // start or a spell in the background, and the server answers it with
            // the *current* state: edited text, TTL flags intact. Leaving it
            // unpatched let it overwrite everything the live-update path had
            // already fixed, which is why the pencil and the intercepted
            // one-time media only survived until the app was reopened.
            switch difference {
            case let .difference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.difference(Api.updates.Difference.Cons_difference(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, state: data.state))
                    modified = true
                }
            case let .differenceSlice(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.differenceSlice(Api.updates.Difference.Cons_differenceSlice(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, intermediateState: data.intermediateState))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.ChannelDifference {
            // The channel-level counterpart of the block above, and the one that
            // actually carries traffic for channels and supergroups: opening one
            // fetches its difference rather than replaying the account update
            // stream. Without a case here, a channel's new messages arrived
            // unpatched and its deletions went through untouched — which is why
            // the one-time marker vanished on re-entering a chat and Anti-Revoke
            // looked like it only worked in private chats.
            switch difference {
            case let .channelDifference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    diag("channelDifference patched — \(p.messages.count) message(s), \(otherUpdates.count) update(s)")
                    newResult = Api.updates.ChannelDifference.channelDifference(Api.updates.ChannelDifference.Cons_channelDifference(flags: data.flags, pts: data.pts, timeout: data.timeout, newMessages: p.messages, otherUpdates: otherUpdates, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelDifferenceTooLong(data):
                // Sent when the client has fallen too far behind to be caught up
                // update by update; it carries the tail of the history instead.
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    diag("channelDifferenceTooLong patched — \(p.messages.count) message(s)")
                    newResult = Api.updates.ChannelDifference.channelDifferenceTooLong(Api.updates.ChannelDifference.Cons_channelDifferenceTooLong(flags: data.flags, timeout: data.timeout, dialog: data.dialog, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let chatFull = result as? Api.messages.ChatFull {
            switch chatFull {
            case let .chatFull(data):
                let (newFullChat, changedFull) = stripNoForwardsFromFullChat(data.fullChat)
                let (newChats, changedChats) = stripNoForwardsFromChats(data.chats)
                if changedFull || changedChats {
                    newResult = Api.messages.ChatFull.chatFull(Api.messages.ChatFull.Cons_chatFull(fullChat: newFullChat, chats: newChats, users: data.users))
                    modified = true
                }
            }
        } else if let chats = result as? Api.messages.Chats {
            switch chats {
            case let .chats(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chats(Api.messages.Chats.Cons_chats(chats: newChats))
                    modified = true
                }
            case let .chatsSlice(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chatsSlice(Api.messages.Chats.Cons_chatsSlice(count: data.count, chats: newChats))
                    modified = true
                }
            }
        } else if let update = result as? Api.Update {
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let message = result as? Api.Message {
            let (stripped, changed) = stripTTLMessage(message)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let discussion = result as? Api.messages.DiscussionMessage {
            switch discussion {
            case let .discussionMessage(data):
                let (newChats, changedChats) = stripNoForwardsFromChats(data.chats)
                var changedMsgs = false
                let newMessages = data.messages.map { msg -> Api.Message in
                    let (stripped, changed) = stripTTLMessage(msg)
                    if changed { changedMsgs = true }
                    return stripped
                }
                if changedChats || changedMsgs {
                    newResult = Api.messages.DiscussionMessage.discussionMessage(Api.messages.DiscussionMessage.Cons_discussionMessage(flags: data.flags, messages: newMessages, maxId: data.maxId, readInboxMaxId: data.readInboxMaxId, readOutboxMaxId: data.readOutboxMaxId, unreadCount: data.unreadCount, chats: newChats, users: data.users))
                    modified = true
                }
            }
        } else if let peerDialogs = result as? Api.messages.PeerDialogs {
            switch peerDialogs {
            case let .peerDialogs(data):
                let (newChats, changedChats) = stripNoForwardsFromChats(data.chats)
                var changedMsgs = false
                let newMessages = data.messages.map { msg -> Api.Message in
                    let (stripped, changed) = stripTTLMessage(msg)
                    if changed { changedMsgs = true }
                    return stripped
                }
                if changedChats || changedMsgs {
                    newResult = Api.messages.PeerDialogs.peerDialogs(Api.messages.PeerDialogs.Cons_peerDialogs(dialogs: data.dialogs, messages: newMessages, chats: newChats, users: data.users, state: data.state))
                    modified = true
                }
            }
        }
        
        if modified {
            let outBuf = Buffer()
            Api.serializeObject(newResult, buffer: outBuf, boxed: true)
            return outBuf.makeData() as NSData
        }
        return nil
    }

    /// users.getFullUser, users.getUsers, contacts.resolveUsername — the three
    /// replies that carry a name for a peer you just opened.
    private static let peerLookupFunctions: Set<Int32> = [-1240508136, 227648840, 1918565308]

    /// Parses a reply purely to file the names in it.
    ///
    /// stripAntiSelfDestruct refuses to parse at all unless a rewriting feature
    /// is on, which is the right default — it runs on every response. These
    /// three replies are rare enough to always be worth reading, and without
    /// them a Ghost Exception added while every rewrite feature is off would
    /// still be filed nameless.
    private static func harvestPeerNames(_ data: NSData) {
        let reader = BufferReader(Buffer(data: data as Data))
        guard let signature = reader.readInt32() else { return }

        // users.getUsers answers with a bare Vector<User>, which Api.parse has
        // no entry for — it only knows named constructors. Read the vector
        // directly instead of losing every name that arrives this way.
        if signature == 481674261 {
            guard let users = Api.parseVector(reader, elementSignature: 0,
                                              elementType: Api.User.self) else { return }
            noteOwnUser(in: users)
            notePeerNames(in: users)
            return
        }

        guard let result = Api.parse(reader, signature: signature) else { return }
        noteUsersAnywhere(result)
    }

    /// One-shot so the log opens with the layer already in force, rather than
    /// leaving it to be inferred from what did or did not get patched.
    private static var reportedLayer = false

    @objc static func handleResponse(_ data: NSData, functionID: NSNumber) -> NSData? {
        if diagEnabled, !reportedLayer {
            reportedLayer = true
            MxApiCompat.diagReportCurrentLayer()
        }
        if peerLookupFunctions.contains(functionID.int32Value) {
            harvestPeerNames(data)
        }
        // Returns patched data only if something was actually modified.
        // Returning nil means "no change" — caller uses original data as-is.
        return stripAntiSelfDestruct(data)
    }
    // MARK: - Forward Cloning (Universal Forwarding)

    private struct ForwardRequest {
        let fromPeer: Api.InputPeer
        let ids: [Int32]
        let toPeer: Api.InputPeer
    }

    private static func parseForwardRequest(_ data: NSData) -> ForwardRequest? {
        let buffer = Buffer(data: data as Data)
        let reader = BufferReader(buffer)
        guard let signature = reader.readInt32() else { 
            NSLog("[Kira] parseForwardRequest: Failed to read signature")
            return nil 
        }
        
        if signature != 326126204 {
            // NSLog("[Kira] parseForwardRequest: Unexpected signature %d", signature)
            return nil
        }
        
        NSLog("[Kira] parseForwardRequest: Detected forwardMessages")
        
        let _ = reader.readInt32() ?? 0
        
        // fromPeer (boxed)
        guard let fromSig = reader.readInt32(),
              let fromPeer = Api.parse(reader, signature: fromSig) as? Api.InputPeer else { return nil }
              
        // id: [Int32] (Vector)
        guard let vecSig1 = reader.readInt32(), vecSig1 == 481674261,
              let countIds = reader.readInt32() else { return nil }
        var ids: [Int32] = []
        for _ in 0..<countIds {
            if let val = reader.readInt32() { ids.append(val) }
        }
        
        // randomId: [Int64] (Vector)
        guard let vecSig2 = reader.readInt32(), vecSig2 == 481674261,
              let countRand = reader.readInt32() else { return nil }
        for _ in 0..<countRand { reader.skip(8) }
        
        // toPeer (boxed)
        guard let toSig = reader.readInt32(),
              let toPeer = Api.parse(reader, signature: toSig) as? Api.InputPeer else { return nil }
        
        switch toPeer {
        case let .inputPeerUser(data): NSLog("[Kira]   Target User: id=%lld, hash=%lld", data.userId, data.accessHash)
        case let .inputPeerChannel(data): NSLog("[Kira]   Target Channel: id=%lld, hash=%lld", data.channelId, data.accessHash)
        default: break
        }
              
        return ForwardRequest(fromPeer: fromPeer, ids: ids, toPeer: toPeer)
    }

    @objc(handleForwardRequest:)
    static func handleForwardRequest(_ data: NSData) -> Bool {
        NSLog("[Kira] handleForwardRequest called")
        guard let request = parseForwardRequest(data) else { 
            NSLog("[Kira] handleForwardRequest: Failed to parse forward request")
            return false 
        }
        
        let fromId: Int64
        switch request.fromPeer {
        case let .inputPeerChannel(data): fromId = data.channelId
        case let .inputPeerChat(data): fromId = data.chatId
        case let .inputPeerUser(data): fromId = data.userId
        default: fromId = 0
        }
        
        NSLog("[Kira] handleForwardRequest: fromId = \(fromId)")
        // For now, if the setting is ON, we hijack ALL forwards from channels or chats to be safe.
        return fromId != 0
    }

    @objc(createGetMessagesRequest:)
    static func createGetMessagesRequest(fromForward data: NSData) -> NSData? {
        guard let request = parseForwardRequest(data) else { return nil }
        
        let msgIds = request.ids.map { Api.InputMessage.inputMessageID(Api.InputMessage.Cons_inputMessageID(id: $0)) }
        
        switch request.fromPeer {
        case let .inputPeerChannel(data):
            let getMsgs = Api.functions.channels.getMessages(channel: .inputChannel(Api.InputChannel.Cons_inputChannel(channelId: data.channelId, accessHash: data.accessHash)), id: msgIds)
            return getMsgs.1.makeData() as NSData
        default:
            let getMsgs = Api.functions.messages.getMessages(id: msgIds)
            return getMsgs.1.makeData() as NSData
        }
    }

    @objc(createSendMediaRequests:originalForwardData:)
    static func createSendMediaRequests(_ response: Any, originalForwardData: NSData) -> [NSData] {
        guard let messagesResponse = response as? Api.messages.Messages else { 
            NSLog("[Kira] Failed to cast response to Api.messages.Messages")
            return [] 
        }
        
        guard let originalRequest = parseForwardRequest(originalForwardData) else { return [] }
        
        var messages: [Api.Message] = []
        switch messagesResponse {
        case let .messages(data): messages = data.messages
        case let .messagesSlice(data): messages = data.messages
        case let .channelMessages(data): messages = data.messages
        default: break
        }
        
        NSLog("[Kira] Cloning %d messages", messages.count)
        
        return messages.compactMap { msg -> NSData? in
            guard case let .message(data) = msg else { return nil }
            
            var inputMedia: Api.InputMedia?
            if let media = data.media {
                switch media {
                case let .messageMediaPhoto(m):
                    if let photo = m.photo, case let .photo(p) = photo {
                        NSLog("[Kira]   Detected Photo: id=%lld, accessHash=%lld, refLen=%d", p.id, p.accessHash, p.fileReference.size)
                        inputMedia = .inputMediaPhoto(Api.InputMedia.Cons_inputMediaPhoto(flags: 0, id: .inputPhoto(Api.InputPhoto.Cons_inputPhoto(id: p.id, accessHash: p.accessHash, fileReference: p.fileReference)), ttlSeconds: nil, video: nil))
                    } else {
                        NSLog("[Kira]   Photo media but photo is empty")
                    }
                case let .messageMediaDocument(m):
                    if let document = m.document, case let .document(d) = document {
                        NSLog("[Kira]   Detected Document: id=%lld, accessHash=%lld, refLen=%d", d.id, d.accessHash, d.fileReference.size)
                        inputMedia = .inputMediaDocument(Api.InputMedia.Cons_inputMediaDocument(flags: 0, id: .inputDocument(Api.InputDocument.Cons_inputDocument(id: d.id, accessHash: d.accessHash, fileReference: d.fileReference)), videoCover: nil, videoTimestamp: nil, ttlSeconds: nil, query: nil))
                    } else {
                        NSLog("[Kira]   Document media but document is empty")
                    }
                case let .messageMediaGeo(m):
                    if case let .geoPoint(gp) = m.geo {
                        inputMedia = .inputMediaGeoPoint(Api.InputMedia.Cons_inputMediaGeoPoint(geoPoint: .inputGeoPoint(Api.InputGeoPoint.Cons_inputGeoPoint(flags: 0, lat: gp.lat, long: gp.long, accuracyRadius: nil))))
                    }
                case let .messageMediaContact(m):
                    inputMedia = .inputMediaContact(Api.InputMedia.Cons_inputMediaContact(phoneNumber: m.phoneNumber, firstName: m.firstName, lastName: m.lastName, vcard: m.vcard))
                case let .messageMediaVenue(m):
                    if case let .geoPoint(gp) = m.geo {
                        inputMedia = .inputMediaVenue(Api.InputMedia.Cons_inputMediaVenue(geoPoint: .inputGeoPoint(Api.InputGeoPoint.Cons_inputGeoPoint(flags: 0, lat: gp.lat, long: gp.long, accuracyRadius: nil)), title: m.title, address: m.address, provider: m.provider, venueId: m.venueId, venueType: m.venueType))
                    }
                case .messageMediaWebPage(_):
                    NSLog("[Kira]   Detected WebPage, sending as text fallback")
                    inputMedia = nil
                default:
                    NSLog("[Kira]   Unsupported media type: \(String(describing: media))")
                    inputMedia = nil
                }
            } else {
                NSLog("[Kira]   No media in message")
            }
            
            var flags: Int32 = 0x80
            if data.entities != nil && !data.entities!.isEmpty {
                flags |= (1 << 3)
            }
            
            let randomId = Int64.random(in: 1...Int64.max)
            
            if let im = inputMedia {
                // MATCHING NATIVE LOG: ID -> flags -> peer -> random_id -> media
                let buffer = Buffer()
                buffer.appendInt32(53536639) // 0x0330E77F (7F E7 30 03)
                buffer.appendInt32(flags)     // 0x80
                
                // 1. Peer
                originalRequest.toPeer.serialize(buffer, true)
                
                // 2. Random ID (8 bytes) - Native log shows it BEFORE media
                buffer.appendInt64(randomId)
                
                // 3. Media
                im.serialize(buffer, true)
                
                NSLog("[Kira]   Created NATIVE-ALIGNED sendMedia payload (len: %d)", buffer.size)
                return buffer.makeData() as NSData
            } else {
                // Send as text only if no media or media not supported
                let sendMessage = Api.functions.messages.sendMessage(
                    flags: flags, 
                    peer: originalRequest.toPeer, 
                    replyTo: nil, 
                    message: data.message, 
                    randomId: randomId, 
                    replyMarkup: nil, 
                    entities: data.entities, 
                    scheduleDate: nil, 
                    scheduleRepeatPeriod: nil, 
                    sendAs: nil, 
                    quickReplyShortcut: nil, 
                    effect: nil, 
                    allowPaidStars: nil,
                    suggestedPost: nil,
                    richMessage: nil
                )
                NSLog("[Kira]   Created sendMessage payload (len: %d)", sendMessage.1.size)
                return sendMessage.1.makeData() as NSData
            }
        }
    }

    @objc(parseMessagesResponse:)
    static func parseMessagesResponse(_ data: NSData) -> Any? {
        var workingData = data as Data
        if workingData.count >= 4 {
            let signature = workingData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if signature == 0x3072CFA1 { // gzip_packed
                NSLog("[Kira] parseMessagesResponse: Detected GZIP, decompressing...")
                if let decompressed = decompressGzip(workingData.withUnsafeBytes { $0.baseAddress?.advanced(by: 4) }, workingData.count - 4) {
                    workingData = decompressed as Data
                    NSLog("[Kira] parseMessagesResponse: GZIP decompressed success (new len: \(workingData.count))")
                } else {
                    NSLog("[Kira] parseMessagesResponse: GZIP decompression FAILED")
                }
            }
        }

        let buffer = Buffer(data: workingData)
        let reader = BufferReader(buffer)
        guard let signature = reader.readInt32() else { 
            NSLog("[Kira] parseMessagesResponse: Failed to read signature")
            return nil 
        }
        return Api.parse(reader, signature: signature)
    }

    @objc static func fakeUpdatesResponse() -> NSData {
        let outBuf = Buffer()
        let updates = Api.Updates.updates(Api.Updates.Cons_updates(updates: [], users: [], chats: [], date: Int32(Date().timeIntervalSince1970), seq: 0))
        Api.serializeObject(updates, buffer: outBuf, boxed: true)
        return outBuf.makeData() as NSData
    }

    static func serializeBoxed(_ obj: Any) -> NSData {
        let outBuf = Buffer()
        Api.serializeObject(obj, buffer: outBuf, boxed: true)
        return outBuf.makeData() as NSData
    }

    // MARK: - Video to Voice, wire side
    //
    // Telegram's `.file` path attaches nothing but a filename, so the extracted
    // audio arrives as a document. Turning it into a voice message means giving
    // the document a documentAttributeAudio with the voice flag, a duration and
    // a waveform, and the only place left to do that is the outgoing request.
    //
    // Everything here is keyed off the file name the extractor invented, so a
    // request that was not produced by Video to Voice is never touched.

    private struct RoundVideoUpload {
        let duration: Double
        let registeredAt: TimeInterval
    }

    // The MediaPicker rewrites the selected item to a file. Telegram may then
    // replace its filename while uploading, so look up both the document
    // filename attribute AND the actual InputFile.name on the wire.
    private static let roundQueue = DispatchQueue(label: "com.kira.roundUploads")
    private static var _roundUploads = [String: RoundVideoUpload]()
    private static var _roundOrder = [String]()
    private static var _roundFallbackUsed = Set<String>()

    @objc static func registerRoundVideoUpload(withFileName fileName: String,
                                                duration: Int) {
        guard !fileName.isEmpty else { return }
        roundQueue.sync {
            if _roundUploads[fileName] == nil { _roundOrder.append(fileName) }
            _roundUploads[fileName] = RoundVideoUpload(
                duration: Double(max(1, duration)),
                registeredAt: Date().timeIntervalSince1970)
            _roundFallbackUsed.remove(fileName)
            while _roundOrder.count > 32 {
                let oldest = _roundOrder.removeFirst()
                _roundUploads.removeValue(forKey: oldest)
                _roundFallbackUsed.remove(oldest)
            }
        }
    }

    private static func roundUpload(forNames names: [String],
                                    mimeType: String) -> RoundVideoUpload? {
        return roundQueue.sync {
            // Exact file names always win, even when the UI toggle has already
            // reset for the next preview.
            for name in names {
                if let item = _roundUploads[name] { return item }
            }

            // Some Telegram forks upload with a generic InputFile.name and
            // omit documentAttributeFilename. Only consume a fallback if ONE
            // round export is outstanding and its type matches a video file.
            let type = mimeType.lowercased()
            let looksLikeVideo = type.hasPrefix("video/") ||
                (type == "application/octet-stream" &&
                 UserDefaults.standard.bool(forKey: "MxVideoToNote"))
            guard looksLikeVideo else { return nil }
            let now = Date().timeIntervalSince1970
            let candidates = _roundOrder.filter {
                guard let item = _roundUploads[$0] else { return false }
                return now - item.registeredAt < 180 &&
                       !_roundFallbackUsed.contains($0)
            }
            guard candidates.count == 1, let name = candidates.first,
                  let item = _roundUploads[name] else { return nil }
            _roundFallbackUsed.insert(name)
            return item
        }
    }

    private struct VoiceUpload {
        let duration: Int32
        let waveform: Data?
        let registeredAt: TimeInterval
    }

    private static let voiceQueue = DispatchQueue(label: "com.kira.voiceUploads")
    private static var _voiceUploads = [String: VoiceUpload]()
    private static var _voiceOrder = [String]()
    private static var _voiceFallbackUsed = Set<String>()

    @objc static func registerVoiceUpload(withFileName fileName: String,
                                          duration: Int,
                                          waveform: NSData?) {
        guard !fileName.isEmpty else { return }
        let entry = VoiceUpload(duration: Int32(max(1, duration)),
                                waveform: waveform as Data?,
                                registeredAt: Date().timeIntervalSince1970)
        // Must complete registration before TGMediaAssetsController returns
        // the file description. An asynchronous barrier raced the MTProto send.
        voiceQueue.sync {
            if _voiceUploads[fileName] == nil { _voiceOrder.append(fileName) }
            _voiceUploads[fileName] = entry
            _voiceFallbackUsed.remove(fileName)
            while _voiceOrder.count > 32 {
                let oldest = _voiceOrder.removeFirst()
                _voiceUploads.removeValue(forKey: oldest)
                _voiceFallbackUsed.remove(oldest)
            }
        }
    }

    private static func voiceUpload(forNames names: [String],
                                    mimeType: String) -> VoiceUpload? {
        return voiceQueue.sync {
            for name in names {
                if let item = _voiceUploads[name] { return item }
            }
            let type = mimeType.lowercased()
            let looksLikeAudio = type.hasPrefix("audio/") ||
                (type == "application/octet-stream" &&
                 UserDefaults.standard.bool(forKey: "MxVideoToVoice"))
            guard looksLikeAudio else { return nil }
            let now = Date().timeIntervalSince1970
            let candidates = _voiceOrder.filter {
                guard let item = _voiceUploads[$0] else { return false }
                return now - item.registeredAt < 180 &&
                       !_voiceFallbackUsed.contains($0)
            }
            guard candidates.count == 1, let name = candidates.first,
                  let item = _voiceUploads[name] else { return nil }
            _voiceFallbackUsed.insert(name)
            return item
        }
    }

    /// Packs 0…31 amplitudes into the five-bits-per-sample bitstream Telegram
    /// expects. Mirrors AudioWaveform.makeBitstream in the app.
    private static func packWaveform(_ bars: Data) -> Data {
        let count = bars.count
        guard count > 0 else { return Data() }
        let byteLength = (count * 5 + 7) / 8
        // Four bytes of slack: each sample is written with an unaligned 32-bit
        // OR, which can reach past the last byte on the final sample.
        var out = Data(count: byteLength + 4)
        out.withUnsafeMutableBytes { rawOut in
            guard let base = rawOut.baseAddress else { return }
            for i in 0 ..< count {
                let value = UInt32(bars[bars.startIndex + i] & 0x1f)
                let bitOffset = i * 5
                let pointer = base.advanced(by: bitOffset / 8)
                var current: UInt32 = 0
                memcpy(&current, pointer, 4)
                current |= value << UInt32(bitOffset % 8)
                memcpy(pointer, &current, 4)
            }
        }
        return out.prefix(byteLength)
    }

    /// documentAttributeAudio with voice set, plus the waveform when we have one.
    private static func voiceAttribute(_ upload: VoiceUpload) -> Api.DocumentAttribute {
        var flags: Int32 = 1 << 10          // voice
        var waveform: Buffer?
        if let bars = upload.waveform, !bars.isEmpty {
            flags |= 1 << 2                 // waveform present
            waveform = Buffer(data: packWaveform(bars))
        }
        return Api.DocumentAttribute.documentAttributeAudio(
            Api.DocumentAttribute.Cons_documentAttributeAudio(
                flags: flags, duration: upload.duration,
                title: nil, performer: nil, waveform: waveform))
    }

    // Telegram documentAttributeVideo: round_message is flags bit 0;
    // supports_streaming is bit 1. The actual MP4 has already been cropped to
    // a square by AVFoundation, unlike a normal file merely labeled 'round'.
    private static func roundVideoAttribute(_ upload: RoundVideoUpload) -> Api.DocumentAttribute {
        return Api.DocumentAttribute.documentAttributeVideo(
            Api.DocumentAttribute.Cons_documentAttributeVideo(
                flags: (1 << 0) | (1 << 1),
                duration: upload.duration,
                w: 640,
                h: 640,
                preloadPrefixSize: nil,
                videoStartTs: nil,
                videoCodec: nil))
    }

    /// Swaps the attributes of an upload that should go out as a voice message.
    /// Returns nil for anything else, which means "leave it alone".
    private static func voiceMedia(from media: Api.InputMedia) -> Api.InputMedia? {
        guard case let .inputMediaUploadedDocument(data) = media else { return nil }

        var fileName: String?
        var existingAudio: Api.DocumentAttribute.Cons_documentAttributeAudio?
        for attribute in data.attributes {
            switch attribute {
            case let .documentAttributeFilename(nameData):
                fileName = nameData.fileName
            case let .documentAttributeAudio(audioData):
                existingAudio = audioData
            default:
                break
            }
        }

        var inputName: String?
        switch data.file {
        case let .inputFile(fileData):
            inputName = fileData.name
        case let .inputFileBig(fileData):
            inputName = fileData.name
        default:
            break
        }

        let names = [fileName, inputName].compactMap { $0 }.filter { !$0.isEmpty }
        var newAttributes: [Api.DocumentAttribute]?
        var newMimeType = data.mimeType

        if let round = roundUpload(forNames: names, mimeType: data.mimeType) {
            // Telegram recognizes Video Notes from documentAttributeVideo bit 0,
            // not from a circular visual crop or a filename.
            diag("v2note wire: \(names) -> round video, \(round.duration)s")
            newAttributes = [roundVideoAttribute(round)]
            newMimeType = "video/mp4"
        } else if let upload = voiceUpload(forNames: names, mimeType: data.mimeType) {
            // Telegram recognizes a real voice message from bit 10 of
            // documentAttributeAudio; leave other file uploads unchanged.
            diag("v2v wire: \(names) -> voice, \(upload.duration)s")
            newAttributes = [voiceAttribute(upload)]
            newMimeType = "audio/mp4"
        } else if UserDefaults.standard.bool(forKey: "MxSendAsVoice"),
                  let audio = existingAudio,
                  (Int(audio.flags) & (1 << 10)) == 0 {
            // Send as Voice: an audio file Telegram already described, with a
            // duration read from the file itself. Only the voice bit is added —
            // inventing a waveform for a file we never decoded would draw a
            // shape that has nothing to do with the sound.
            diag("send-as-voice wire: \(audio.duration)s")
            newAttributes = data.attributes.map { attribute in
                guard case let .documentAttributeAudio(audioData) = attribute else { return attribute }
                return Api.DocumentAttribute.documentAttributeAudio(
                    Api.DocumentAttribute.Cons_documentAttributeAudio(
                        flags: audioData.flags | (1 << 10),
                        duration: audioData.duration,
                        title: audioData.title,
                        performer: audioData.performer,
                        waveform: audioData.waveform))
            }
        }

        guard let attributes = newAttributes else { return nil }

        return Api.InputMedia.inputMediaUploadedDocument(
            Api.InputMedia.Cons_inputMediaUploadedDocument(
                // TGMediaAssetsController's "file" branch sets force_file
                // (bit 4), which overrides voice/round rendering. Clear it
                // only for a conversion we positively recognized above.
                flags: data.flags & ~(1 << 4),
                file: data.file,
                thumb: data.thumb,
                mimeType: newMimeType,
                attributes: attributes,
                stickers: data.stickers,
                videoCover: data.videoCover,
                videoTimestamp: data.videoTimestamp,
                ttlSeconds: data.ttlSeconds))
    }

    /// Reads one boxed object and throws the value away — used to step over the
    /// fields that sit before the media without having to know their shape.
    private static func skipBoxed(_ reader: BufferReader) -> Bool {
        guard let signature = reader.readInt32() else { return false }
        return Api.parse(reader, signature: signature) != nil
    }

    /// The album case: every item in the vector is offered to voiceMedia, and
    /// the whole vector is re-emitted only if at least one of them was ours.
    private static func rewriteMultiMedia(_ payload: Data, reader: BufferReader) -> NSData? {
        let vectorStart = Int(reader.offset)
        guard reader.readInt32() == 481674261 else { return nil }   // Vector
        guard let items = Api.parseVector(reader, elementSignature: 0,
                                          elementType: Api.InputSingleMedia.self) else { return nil }
        let vectorEnd = Int(reader.offset)

        var changed = false
        let rewritten: [Api.InputSingleMedia] = items.map { item in
            guard case let .inputSingleMedia(data) = item,
                  let media = voiceMedia(from: data.media) else { return item }
            changed = true
            return Api.InputSingleMedia.inputSingleMedia(
                Api.InputSingleMedia.Cons_inputSingleMedia(
                    flags: data.flags, media: media, randomId: data.randomId,
                    message: data.message, entities: data.entities))
        }
        guard changed else { return nil }

        let vectorBuffer = Buffer()
        vectorBuffer.appendInt32(481674261)
        vectorBuffer.appendInt32(Int32(rewritten.count))
        for item in rewritten { item.serialize(vectorBuffer, true) }

        var out = Data()
        out.append(payload.subdata(in: 0 ..< vectorStart))
        out.append(vectorBuffer.makeData())
        out.append(payload.subdata(in: vectorEnd ..< payload.count))
        return out as NSData
    }

    /// Rewrites the media inside an outgoing send request.
    ///
    /// Only the fields ahead of the media are decoded; everything after it is
    /// copied through byte for byte. That keeps the rewrite honest about what it
    /// understands — a constructor that changed shape after the media field
    /// cannot be corrupted by it.
    @objc static func rewriteVoiceUpload(_ data: NSData) -> NSData? {
        let defaults = UserDefaults.standard
        // A media transfer can remain queued after the preview selection
        // resets. Registered uploads must still be detected on retry.
        let hasPendingVoice = voiceQueue.sync { !_voiceUploads.isEmpty }
        let hasPendingRound = roundQueue.sync { !_roundUploads.isEmpty }
        guard hasPendingVoice || hasPendingRound ||
              defaults.bool(forKey: "MxSendAsVoice") else { return nil }

        let payload = data as Data
        let reader = BufferReader(Buffer(data: payload))
        guard let functionId = reader.readInt32() else { return nil }

        switch functionId {
        case 53536639:   // messages.sendMedia
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
        case 345405816:  // messages.uploadMedia
            guard let flags = reader.readInt32() else { return nil }
            if (Int(flags) & (1 << 0)) != 0 {
                guard parseString(reader) != nil else { return nil }     // business_connection_id
            }
            guard skipBoxed(reader) else { return nil }                  // peer
        case 469278068:  // messages.sendMultiMedia — several clips picked at once
            guard let flags = reader.readInt32() else { return nil }
            guard skipBoxed(reader) else { return nil }                  // peer
            if (Int(flags) & (1 << 0)) != 0 {
                guard skipBoxed(reader) else { return nil }              // reply_to
            }
            return rewriteMultiMedia(payload, reader: reader)
        default:
            return nil
        }

        let mediaStart = Int(reader.offset)
        guard let signature = reader.readInt32(), signature == 58495792 else { return nil }
        guard let media = Api.parse(reader, signature: signature) as? Api.InputMedia else { return nil }
        let mediaEnd = Int(reader.offset)
        guard let rewritten = voiceMedia(from: media) else { return nil }

        let mediaBuffer = Buffer()
        rewritten.serialize(mediaBuffer, true)

        var out = Data()
        out.append(payload.subdata(in: 0 ..< mediaStart))
        out.append(mediaBuffer.makeData())
        out.append(payload.subdata(in: mediaEnd ..< payload.count))
        return out as NSData
    }
}
