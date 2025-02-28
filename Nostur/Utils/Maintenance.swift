//
//  Maintenance.swift
//  Nostur
//
//  Created by Fabian Lachman on 01/02/2023.
//

import Foundation
import CoreData

struct Maintenance {

    static let BOOTSTRAP_RELAYS = ["wss://relay.nostr.band", "wss://relayable.org", "wss://nos.lol", "wss://nostr.wine", "wss://nostr.mutinywallet.com", "wss://purplepag.es"]
    
    // Removed: wss://relay.damus.io // shows only cameri bug
    // Removed: time out... "wss://nostr.fmt.wiz.biz"
    // Removed: too many subscriptions "wss://relay.snort.social"
    
    static func ensureBootstrapRelaysExist(context:NSManagedObjectContext) {
        context.performAndWait {
            let r = Relay.fetchRequest()
            if let relaysCount = try? context.fetch(r).count {
                var relays:[Relay] = []
                
                if (relaysCount == 0) {
                    for url in BOOTSTRAP_RELAYS {
                        let bootstrapRelay = Relay(context: context)
                        bootstrapRelay.read = url == "wss://nostr.mutinywallet.com" ? false : true // this one is write only
                        bootstrapRelay.write = true
                        bootstrapRelay.createdAt = Date.now
                        bootstrapRelay.url = url
                        relays.append(bootstrapRelay)
                    }
                    let sp = SocketPool.shared
                    for relay in relays { // CONNECT TO RELAYS
                        _ = sp.addSocket(relayId: relay.objectID.uriRepresentation().absoluteString, url: relay.url!, read:relay.read, write: relay.write)
                    }
                }
            }
            
        }
    }
    
    // Clean up things older than X days
    // Deletes ALL KIND=0 Events (except own), because should have Contact entity.
    // Keeps bookmarks
    // Keeps own events
    // Keeps contacts/posts with private notes
    
    // TODO: hmm should also keep kind 3 + 10002 of follows for WoT spam filter
    static func maintenance(context:NSManagedObjectContext) {
        
        // Version based migrations
        L.maintenance.info("Starting version based maintenance")
        context.perform {
            Self.runDeleteEventsWithoutId(context: context)
            Self.runUseDtagForReplacableEvents(context: context)
            Self.runInsertFixedNames(context: context)
            Self.runFixArticleReplies(context: context)
//            Self.runFixImposterFalsePositives(context: context)
            Self.runMigrateDMState(context: context)
            Self.runFixImposterFalsePositivesAgainAgain(context: context)
//            Self.runTempAlways(context: context)
            Self.runFixZappedContactPubkey(context: context)
            Self.runPutRepostedPubkeyInOtherPubkey(context: context)
            Self.runPutReactionToPubkeyInOtherPubkey(context: context)
            
            do {
                if context.hasChanges {
                    try context.save()
                }
            }
            catch {
                L.maintenance.error("🧹🧹 🔴🔴 Version based maintenance could not save: \(error)")
            }
        }
        // Time based migrations
    
        let lastMaintenanceTimestamp = Date(timeIntervalSince1970: TimeInterval(SettingsStore.shared.lastMaintenanceTimestamp))
        let hoursAgo = Date(timeIntervalSinceNow: (-24 * 60 * 60))
        guard lastMaintenanceTimestamp < hoursAgo else { // don't do maintenance more than once every 24 hours
            L.maintenance.info("Skipping maintenance");
            Importer.shared.preloadExistingIdsCache()
            return
        }
        SettingsStore.shared.lastMaintenanceTimestamp = Int(Date.now.timeIntervalSince1970)
        L.maintenance.info("Starting time based maintenance")
        
        context.perform {
            let frA = Account.fetchRequest()
            let allAccounts = Array(try! context.fetch(frA))
            let ownAccountPubkeys = allAccounts.reduce([String]()) { partialResult, account in
                var newResult = Array(partialResult)
                if (account.privateKey != nil) { // only if it is really our account
                    newResult.append(account.publicKey)
                }
                return newResult
            }
            
            let regex = ".*(" + ownAccountPubkeys.map {
                NSRegularExpression.escapedPattern(for: serializedP($0))
            }.joined(separator: "|") + ").*"
            
            let ownAccountBookmarkIds = allAccounts.reduce([String]()) { partialResult, account in
                var newResult = Array(partialResult)
                if (account.bookmarks != nil) {
                    let ids = account.bookmarks!.map { $0.id }
                    newResult.append(contentsOf: ids)
                }
                return newResult
            }
            
            let ownAccountPrivateNoteEventIds = allAccounts.reduce([String]()) { partialResult, account in
                var newResult = Array(partialResult)
                if (account.privateNotes != nil) {
                    let ids = account.privateNotes!.compactMap { $0.post?.id }
                    newResult.append(contentsOf: ids)
                }
                return newResult
            }
            
            let xDaysAgo = Date.now.addingTimeInterval(-4 * 86400) // 4 days
            
            
            // Steps .. get ALL list states (This is ordered by most recent updated at)
            let listStates = ListState.fetchListStates(context: context)
            
            // ListStates we don't delete are in this bag:
            var keepListStates:[ListState] = []
            
            // Keep 1 (most recent) "Explore", it is not tied to account
            if let explore = listStates.first(where: { $0.listId == "Explore"}) {
                keepListStates.append(explore)
            }
            // For every account keep the most recent "Following"
            ownAccountPubkeys.forEach {  pubkey in
                if let following = listStates.first(where: { $0.listId == "Following" && $0.pubkey == pubkey}) {
                    keepListStates.append(following)
                }
            }
            // For every NosturList, keep most recent
            let nosturLists = NosturList.fetchLists(context: context)
            nosturLists.forEach { nosturList in
                if nosturList.id == nil {
                    nosturList.id = UUID()
                }
                if let list = listStates.first(where: { $0.listId == nosturList.subscriptionId }) {
                    keepListStates.append(list)
                }
            }
            
            // Ok, now delete all listStates not in keepListStates
            var deletedLists = 0
            var postsIdToKeep = Set<String>()
            listStates.forEach { listState in
                if !keepListStates.contains(listState) {
                    context.delete(listState)
                    deletedLists += 1
                }
                else {
                    postsIdToKeep = postsIdToKeep.union(Set(listState.leafIds))
                }
            }
            
            L.maintenance.info("Deleted \(deletedLists) old list states")
            L.maintenance.info("Going to keep \(postsIdToKeep.count) posts that are part of listState.leafs")
          
            
            
            // CLEAN UP EVENTS WITHOUT SIG (BUG FROM PostPreview)
            let frNoSig = NSFetchRequest<NSFetchRequestResult>(entityName: "Event")
            frNoSig.predicate = NSPredicate(format: "sig == nil AND flags != \"nsecbunker_unsigned\"")
            
            let frNoSigbatchDelete = NSBatchDeleteRequest(fetchRequest: frNoSig)
            frNoSigbatchDelete.resultType = .resultTypeCount
            
            do {
                let result = try context.execute(frNoSigbatchDelete) as! NSBatchDeleteResult
                if let count = result.result as? Int, count > 0 {
                    L.maintenance.info("🧹🧹 Deleted \(count) events without signature")
                }
            } catch {
                L.maintenance.info("🔴🔴 Failed to delete events without signature")
            }
            
            
            
            
            // KIND 1,4,5,6,9802,30023
            // OLDER THAN X DAYS
            // IS NOT BOOKMARKED
            // IS NOT OWN EVENT
            // DOES NOT HAVE OUR PUBKEY IN P (Notifications)
            // DONT DELETE MUTED BLOCKED, SO OUR BLOCK LIST STILL FUNCTIONS....
            // TODO: DONT EXPORT MUTED / BLOCKED. KEEP HERE SO WE DONT HAVE TO KEEP ..REPARSING
            
            // Ids to keep: own bookmarks, privatenotes, leafs from list states
            let mergedIds = Set(ownAccountBookmarkIds).union(Set(ownAccountPrivateNoteEventIds)).union(postsIdToKeep)
            
            let fr16 = NSFetchRequest<NSFetchRequestResult>(entityName: "Event")
            fr16.predicate = NSPredicate(format: "created_at < %i AND kind IN {1,4,5,6,9802,30023} AND NOT id IN %@ AND NOT (pubkey IN %@ OR tagsSerialized MATCHES %@)", Int64(xDaysAgo.timeIntervalSince1970), mergedIds, ownAccountPubkeys, regex)
            
            let fr16batchDelete = NSBatchDeleteRequest(fetchRequest: fr16)
            fr16batchDelete.resultType = .resultTypeCount
            
            do {
                let result = try context.execute(fr16batchDelete) as! NSBatchDeleteResult
                if let count = result.result as? Int, count > 0 {
                    L.maintenance.info("🧹🧹 Deleted \(count) kind {1,4,5,6,9802,30023} events")
                }
            } catch {
                L.maintenance.info("🔴🔴 Failed to delete {1,4,5,6,9802,30023} data")
            }
            
            
            // KIND 7,8
            // OLDER THAN X DAYS
            // PUBKEY NOT IN OWN ACCOUNTS
            // OR PUBKEY OF OWN ACCOUNTS NOT IN SERIALIZED TAGS
            //            context.perform {
            let fr78 = NSFetchRequest<NSFetchRequestResult>(entityName: "Event")
            
            fr78.predicate = NSPredicate(format: "created_at < %i AND kind IN {8,7} AND NOT (pubkey IN %@ OR tagsSerialized MATCHES %@)", Int64(xDaysAgo.timeIntervalSince1970), ownAccountPubkeys, regex)
            
            let fr78batchDelete = NSBatchDeleteRequest(fetchRequest: fr78)
            fr78batchDelete.resultType = .resultTypeCount
            
            do {
                let result = try context.execute(fr78batchDelete) as! NSBatchDeleteResult
                if let count = result.result as? Int, count > 0 {
                    L.maintenance.info("🧹🧹 Deleted \(count) kind {8,7} events")
                }
            } catch {
                L.maintenance.info("🔴🔴 Failed to delete 8,7 data")
            }
            
            // KIND 9735
            // OLDER THAN X DAYS
            // otherPubkey NOT IN OWN ACCOUNTS
            //            context.perform {
            let fr9735 = Event.fetchRequest()
            fr9735.predicate = NSPredicate(format: "created_at < %i AND kind == 9735 AND (otherPubkey == nil OR NOT otherPubkey IN %@)", Int64(xDaysAgo.timeIntervalSince1970), ownAccountPubkeys)
            
            var deleted9735 = 0
            var deleted9734 = 0
            if let zaps = try? context.fetch(fr9735) {
                for zap in zaps {
                    // Also delete zap request (not sure if cascades from 9735 so just delete here anyway)
                    if let zapReq = zap.zapFromRequest {
                        context.delete(zapReq)
                        deleted9734 += 1
                    }
                    context.delete(zap)
                    deleted9735 += 1
                }
            }
            L.maintenance.info("🧹🧹 Deleted \(deleted9735) zaps and \(deleted9734) zap requests")
            
            // KIND 0
            // REMOVE ALL BECAUSE EVERY KIND 0 HAS A CONTACT
            // DONT REMOVE OWN KIND 0
            //            context.perform {
            let fr0 = NSFetchRequest<NSFetchRequestResult>(entityName: "Event")
            fr0.predicate = NSPredicate(format: "(kind == 0) AND NOT pubkey IN %@", ownAccountPubkeys)
            
            let fr0batchDelete = NSBatchDeleteRequest(fetchRequest: fr0)
            fr0batchDelete.resultType = .resultTypeCount
            
            do {
                let result = try context.execute(fr0batchDelete) as! NSBatchDeleteResult
                if let count = result.result as? Int, count > 0 {
                    L.maintenance.info("🧹🧹 Deleted \(count) kind=0 events")
                }
            } catch {
                L.maintenance.info("🔴🔴 Failed to delete kind=0 data")
            }

            
            // DELETE OLDER KIND 3 + 10002 EVENTS
            // BUT NOT OUR OWN OR THOSE WE ARE FOLLOWING (FOR WoT follows-follows)
            // AND NOT OUR PUBKEY IN Ps (is following us, for following notifications)
            
            var followingPubkeys = Set(ownAccountPubkeys)
            for account in allAccounts {
                if account.privateKey != nil {
                    followingPubkeys = followingPubkeys.union(Set(account.follows_.map { $0.pubkey }))
                }
            }
            
            let r = NSFetchRequest<Event>(entityName: "Event")
            r.predicate = NSPredicate(format: "kind IN {3,10002} AND NOT (pubkey IN %@ OR tagsSerialized MATCHES %@)", followingPubkeys, regex)
            r.sortDescriptors = [NSSortDescriptor(keyPath: \Event.created_at, ascending: false)]
            let kind3or10002 = try! context.fetch(r)
            
            var noDuplicates:Dictionary<String, Event> = [:]
            var forDeletion:[Event] = []
            
            for event in kind3or10002 {
                if noDuplicates[event.pubkey + String(event.kind)] != nil {
                    forDeletion.append(event)
                }
                else {
                    noDuplicates[event.pubkey + String(event.kind)] = event
                }
            }
            for toDelete in forDeletion {
                context.delete(toDelete)
            }
            
            var olderKind3DeletedCount = 0
            for remaining in noDuplicates.values {
                if remaining.created_at < Int64(xDaysAgo.timeIntervalSince1970) {
                    context.delete(remaining)
                    olderKind3DeletedCount = olderKind3DeletedCount + 1
                }
            }
            
            if !forDeletion.isEmpty {
                L.maintenance.info("🧹🧹 Deleted \(forDeletion.count) duplicate kind 3,10002 events")
            }
            if olderKind3DeletedCount > 0 {
                L.maintenance.info("🧹🧹 Deleted \(olderKind3DeletedCount) older kind 3,10002 events")
            }
            
            do {
                if context.hasChanges {
                    try context.save()
                }
            }
            catch {
                L.maintenance.error("🧹🧹 🔴🔴 Time based maintenance could not save: \(error)")
            }
            
            Importer.shared.preloadExistingIdsCache()
        }
    }
    
    
    // SetMetadata can have a banner field now.
    func rescanForBannerFields() {
        DataProvider.shared().container.viewContext.perform {
            
            do {
                let decoder = JSONDecoder()
                
                let er = NSFetchRequest<Event>(entityName: "Event")
                er.predicate = NSPredicate(format: "kind == 0")
                er.sortDescriptors = [NSSortDescriptor(keyPath: \Event.created_at, ascending: false)]
                let metaEvents = try! er.execute()
                
                let cr = NSFetchRequest<Contact>(entityName: "Contact")
                cr.sortDescriptors = [NSSortDescriptor(keyPath: \Contact.updated_at, ascending: false)]
                let contacts = try! cr.execute()
                
                for contact in contacts {
                    // TODO: `replace with new function (updateContactFromMetaEvent)
                    if let lastEvent = metaEvents.first(where: { $0.pubkey == contact.pubkey }) {
                        guard let metaData = try? decoder.decode(NSetMetadata.self, from: (lastEvent.content?.data(using: .utf8, allowLossyConversion: false)!)!) else {
                            continue
                        }
                        if metaData.banner != nil {
                            contact.banner = metaData.banner!
                            L.maintenance.info("🟡🟡 Updated banner \(metaData.banner!) for \(contact.pubkey)")
                        }
                    }
                }
                try DataProvider.shared().container.viewContext.save()
            }
            
            catch let error {
                L.maintenance.info("😢😢😢 XX \(error)")
            }
        }
    }
    
    func deleteAllContacts() {
        //        if (1 == 1) { return }
        //        DataProvider.shared().container.viewContext.perform {
        //            do {
        //                let r = NSFetchRequest<Contact>()
        //                r.entity = Contact.entity()
        //                r.sortDescriptors = [NSSortDescriptor(keyPath: \Contact.updated_at, ascending: false)]
        //
        //                guard let allContacts = try? r.execute() else {
        //                    L.maintenance.info("😢 XX")
        //                    return
        //                }
        //
        //                for contact in allContacts {
        //                    DataProvider.shared().container.viewContext.delete(contact)
        //                }
        //
        //                try DataProvider.shared().container.viewContext.save()
        //            } catch let error  {
        //                L.maintenance.info("😢😢😢 XX \(error)")
        //            }
        //        }
    }
    
    
    // Check if a migration has already been executed
    static func didRun(migrationCode:migrationCode, context:NSManagedObjectContext) -> Bool {
        let fr = Migration.fetchRequest()
        fr.predicate = NSPredicate(format: "migrationCode == %@", migrationCode.rawValue)
        fr.fetchLimit = 1
        fr.resultType = .countResultType
        return ((try? context.count(for: fr)) ?? 0) > 0
    }
    
    
    // Run once to fill dTag and delete old replacable events
    static func runUseDtagForReplacableEvents(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.useDtagForReplacableEvents, context: context) else { return }
        
        // 1. For each replacable event, save the dtag
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "kind >= 30000 AND kind < 40000")
        
        guard let replacableEvents = try? context.fetch(fr) else {
            L.maintenance.error("runUseDtagForReplacableEvents: Could not fetch replacable events")
            return
        }
        
        L.maintenance.info("runUseDtagForReplacableEvents: Found \(replacableEvents.count) replacable events")
        
        for event in replacableEvents {
            event.dTag = event.fastTags.first(where: { $0.0 == "d" })?.1 ?? ""
            if event.dTag != "" {
                L.maintenance.info("runUseDtagForReplacableEvents: dTag set to: \(event.dTag) for \(event.id)")
            }
        }
        
        // 2. For each replacable event, find same author + dtag, keep most recent, delete older
        for event in replacableEvents {
            let matches = replacableEvents.filter { $0.pubkey == event.pubkey && $0.dTag == event.dTag }
            if matches.count <= 1 { continue } // if we have just 1 match, no need to delete older
            
            // only keep the most recent
            guard let keep = matches.sorted(by: { $0.created_at > $1.created_at }).first else { continue }
            for match in matches {
                if match != keep {
                    match.mostRecentId = keep.id
                }
            }
        }
        
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.useDtagForReplacableEvents.rawValue
    }
    
    // Run once to delete events without id (old bug)
    static func runDeleteEventsWithoutId(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.deleteEventsWithoutId, context: context) else { return }
        
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "id == \"\"")
        
        guard let eventsWithoutId = try? context.fetch(fr) else {
            L.maintenance.error("runDeleteEventsWithoutId: Could not fetch eventsWithoutId")
            return
        }
        
        L.maintenance.info("eventsWithoutId: Found \(eventsWithoutId.count) eventsWithoutId")
        
        for event in eventsWithoutId {
            context.delete(event)
        }
        
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.deleteEventsWithoutId.rawValue
    }
    
    // Run once to put .anyName in fixedName
    static func runInsertFixedNames(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.insertFixedNames, context: context) else { return }
        
        let fr = Contact.fetchRequest()
        fr.predicate = NSPredicate(format: "fixedName == nil")
        
        guard let contacts = try? context.fetch(fr) else {
            L.maintenance.error("runInsertFixedNames: Could not fetch")
            return
        }
        
        L.maintenance.info("runInsertFixedNames: Found \(contacts.count) contacts")
        
        for contact in contacts {
            if contact.anyName != contact.authorKey {
                contact.fixedName = contact.anyName
            }
        }
        
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.insertFixedNames.rawValue
    }
    
    // Run once to fix replies to existing replacable events
    static func runFixArticleReplies(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.fixArticleReplies, context: context) else { return }
        
        // Find all posts referencing an article
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "kind == 1 AND tagsSerialized CONTAINS %@", "[\"a\",\"30023:")
        
        if let articleReplies = try? context.fetch(fr) {
            L.maintenance.info("runFixArticleReplies: Found \(articleReplies.count) article replies")
            for reply in articleReplies {
                let event = reply.toNEvent()
                
                // The following code is similar as in .saveEvent()
                if let replyToAtag = event.replyToAtag() { // Comment on article
                    if let dbArticle = Event.fetchReplacableEvent(aTag: replyToAtag.value, context: context) {
                        reply.replyToId = dbArticle.id
                        reply.replyTo = dbArticle
                        L.maintenance.info("runFixArticleReplies: Fixing reply (\(reply.id)) -> \(replyToAtag.value) (article already in DB)")
                    }
                    else {
                        // we don't have the article yet, store aTag in replyToId
                        reply.replyToId = replyToAtag.value
                        L.maintenance.info("runFixArticleReplies: Fixing reply (\(reply.id)) -> \(replyToAtag.value) (article not in DB)")
                    }
                }
                else if let replyToRootAtag = event.replyToRootAtag() {
                    // Comment has article as root, but replying to other comment, not to article.
                    if let dbArticle = Event.fetchReplacableEvent(aTag: replyToRootAtag.value, context: context) {
                        reply.replyToRootId = dbArticle.id
                        reply.replyToRoot = dbArticle
                        L.maintenance.info("runFixArticleReplies: Fixing replyToRoot (\(reply.id)) -> \(replyToRootAtag.value) (article already in DB)")
                    }
                    else {
                        // we don't have the article yet, store aTag in replyToRootId
                        reply.replyToRootId = replyToRootAtag.value
                        L.maintenance.info("runFixArticleReplies: Fixing replyToRoot (\(reply.id)) -> \(replyToRootAtag.value) (article not in DB)")
                    }
                }
                
                if reply.replyToId == nil && reply.replyToRootId != nil { // If there is a replyToRoot but not a reply, set replyToRoot as replyTo
                    reply.replyToId = reply.replyToRootId
                    reply.replyTo = reply.replyToRoot
                }
            }
        }
                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.fixArticleReplies.rawValue
    }
    
    // Run once to fix false positives from imposter checking
    // In older versions right after switching accounts it would put the label
    // and then cache the result
    static func runFixImposterFalsePositives(context: NSManagedObjectContext) {
        // removed. no need to run anymore, only run the last one below
    }
    
    // Need to run it again... false positives still
    // And again - found another bug during new account onboarding
    static func runFixImposterFalsePositivesAgainAgain(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.fixImposterFalsePositivesAgainAgain, context: context) else { return }
        
        let frA = Account.fetchRequest()
        let allAccounts = Array(try! context.fetch(frA))
        
        var imposterCacheFixedCount = 0
        var imposterCacheFollowCount = 0
        for account in allAccounts {
//            guard account.privateKey != nil else { continue }
            for contact in account.follows_ { // We are following so can't be imposter
                if contact.couldBeImposter == 1 {
                    contact.couldBeImposter = 0
                    imposterCacheFixedCount += 1
                }
                else if contact.couldBeImposter == -1 { // We are following so can't be imposter
                    contact.couldBeImposter = 0
                    imposterCacheFollowCount += 1
                }
            }
        }
        
        L.maintenance.info("fixImposterFalsePositivesAgain: Fixed \(imposterCacheFixedCount) false positives, preset-to-0 \(imposterCacheFollowCount) contacts")
                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.fixImposterFalsePositivesAgainAgain.rawValue
    }
    
    // Run once to migrate DM info in "root" DM event to DMState record
    static func runMigrateDMState(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.migrateDMState, context: context) else { return }
        
        let frA = Account.fetchRequest()
        let allAccounts = Array(try! context.fetch(frA))
        // This one includes read-only accounts
        _ = allAccounts.reduce([String]()) { partialResult, account in
            var newResult = Array(partialResult)
                newResult.append(account.publicKey)
            return newResult
        }
        
        // Need to do per account, because we can have multiple accounts in Nostur, can message eachother,
        // Each account needs its own conversation state.
        
        typealias ConversationKeypair = String // "accountPubkey-contactPubkey"
        typealias AccountPubkey = String
        typealias ContactPubkey = String
        typealias IsAccepted = Bool
        typealias MarkedReadAt = Date?
        
        var dmStates:[ConversationKeypair: (AccountPubkey, ContactPubkey, IsAccepted, MarkedReadAt)] = [:]
        
        for account in allAccounts {
            let sent = Event.fetchRequest()
            sent.predicate = NSPredicate(format: "kind == 4 AND pubkey == %@", account.publicKey)
            sent.fetchLimit = 9999
            sent.sortDescriptors = [NSSortDescriptor(keyPath:\Event.created_at, ascending: false)]

            if let sent = try? context.fetch(sent) {
                for messageSent in sent {
                    // sent is always "accepted"
                    guard let contactPubkey = messageSent.firstP() else { continue }
                    messageSent.otherPubkey = contactPubkey
                    
                    let accountPubkey = messageSent.pubkey
                    
                    guard accountPubkey != contactPubkey else { continue }
                    
                    let markedReadAt = messageSent.lastSeenDMCreatedAt != 0 ? Date(timeIntervalSince1970: TimeInterval(messageSent.lastSeenDMCreatedAt)) : nil
                    
                    // Set or update the DM conversation state, use the most recent markedReadAt (lastSeenDMCreatedAt)
                    if let existingDMState = dmStates[accountPubkey + "-" + contactPubkey], let newerMarkedReadAt = markedReadAt, newerMarkedReadAt > (existingDMState.3 ?? Date(timeIntervalSince1970: 0) ) {
                        dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, true, newerMarkedReadAt)
                    }
                    else {
                        dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, true, markedReadAt)
                    }
                }
            }
            
            
            let received = Event.fetchRequest()
            received.predicate = NSPredicate(
                format: "kind == 4 AND tagsSerialized CONTAINS %@ AND NOT pubkey == %@", serializedP(account.publicKey), account.publicKey)
            received.fetchLimit = 9999
            received.sortDescriptors = [NSSortDescriptor(keyPath:\Event.created_at, ascending: false)]
            
            if let received = try? context.fetch(received) {
                for messageReceived in received {
                    
                    let contactPubkey = messageReceived.pubkey
                    guard messageReceived.firstP() == account.publicKey || messageReceived.lastP() == account.publicKey else { continue }
                    let accountPubkey = account.publicKey
                    messageReceived.otherPubkey = accountPubkey
                    
                    guard accountPubkey != contactPubkey else { continue }
                    
                    let didSend = dmStates[accountPubkey + "-" + contactPubkey] != nil
                    
                    // received is "accepted" if we manually accepted before, or if we replied
                    if messageReceived.dmAccepted || didSend {
                        let markedReadAt = messageReceived.lastSeenDMCreatedAt != 0 ? Date(timeIntervalSince1970: TimeInterval(messageReceived.lastSeenDMCreatedAt)) : nil
                        
                        // Set or update the DM conversation state, use the most recent markedReadAt (lastSeenDMCreatedAt)
                        if let existingDMState = dmStates[accountPubkey + "-" + contactPubkey], let newerMarkedReadAt = markedReadAt, newerMarkedReadAt > (existingDMState.3 ?? Date(timeIntervalSince1970: 0) ) {
                            dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, true, newerMarkedReadAt)
                        }
                        else {
                            dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, true, markedReadAt)
                        }
                    }
                    else {
                        let markedReadAt = messageReceived.lastSeenDMCreatedAt != 0 ? Date(timeIntervalSince1970: TimeInterval(messageReceived.lastSeenDMCreatedAt)) : nil
                        
                        // Set or update the DM conversation state, use the most recent markedReadAt (lastSeenDMCreatedAt)
                        if let existingDMState = dmStates[accountPubkey + "-" + contactPubkey], let newerMarkedReadAt = markedReadAt, newerMarkedReadAt > (existingDMState.3 ?? Date(timeIntervalSince1970: 0) ) {
                            dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, existingDMState.2, newerMarkedReadAt)
                        }
                        else {
                            dmStates[accountPubkey + "-" + contactPubkey] = (accountPubkey, contactPubkey, false, markedReadAt)
                        }
                    }
                }
            }
        }
        
        for dmState in dmStates {
            let record = DMState(context: context)
            record.accountPubkey = dmState.value.0
            record.contactPubkey = dmState.value.1
            record.accepted = dmState.value.2
            record.markedReadAt = dmState.value.3
        }

                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.migrateDMState.rawValue
    }
    
    static func runTempAlways(context: NSManagedObjectContext) {
        
    }
    
    
    // Run once to fix ZappedContactPubkey not migrated to otherPubkey, ughh Xcode
    static func runFixZappedContactPubkey(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.fixZappedContactPubkey, context: context) else { return }
        
        // Find all zaps 9735
        // if otherPubkey is nil:
        // get it from first P
        // set otherPubkey
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "kind == 9735 AND otherPubkey == nil")
        
        var fixed = 0
        if let zaps = try? context.fetch(fr) {
            L.maintenance.info("runFixZappedContactPubkey: Found \(zaps.count) zaps without otherPubkey")
            for zap in zaps {
                if let firstP = zap.firstP() {
                    zap.otherPubkey = firstP
                    zap.zappedContact = Contact.fetchByPubkey(firstP, context: context)
                    fixed += 1
                }
            }
            L.maintenance.info("runFixZappedContactPubkey: Fixed \(fixed) otherPubkey in zaps")
        }
                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.fixZappedContactPubkey.rawValue
    }
    
    // Run once to put .firstQuote.pubkey in .otherPubkey, for fast reposts notification querying
    static func runPutRepostedPubkeyInOtherPubkey(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.runPutRepostedPubkeyInOtherPubkey, context: context) else { return }
        
        // Find all reposts
        // if otherPubkey is nil:
        // get it from firstQuote
        // if we don't have firstQuote, get it from firstP
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "kind == 6 AND otherPubkey == nil")
        
        var fixed = 0
        if let reposts = try? context.fetch(fr) {
            L.maintenance.info("runPutRepostedPubkeyInOtherPubkey: Found \(reposts.count) reposts without otherPubkey")
            for repost in reposts {
                
                // Same code as in saveEvent():
                // Save reposted pubkey in .otherPubkey for easy querying for repost notifications
                // if we already have the firstQuote (reposted post), we use that .pubkey
                if let otherPubkey = repost.firstQuote?.pubkey {
                    repost.otherPubkey = otherPubkey
                    fixed += 1
                } // else we take the pubkey from the tags (should be there)
                else if let firstP = repost.firstP() {
                    repost.otherPubkey = firstP
                    fixed += 1
                }
            }
            L.maintenance.info("runPutRepostedPubkeyInOtherPubkey: Fixed \(fixed) otherPubkey in reposts")
        }
                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.runPutRepostedPubkeyInOtherPubkey.rawValue
    }
    
    // Run once to put .reactionTo.pubkey in .otherPubkey, for fast reaction notification querying
    static func runPutReactionToPubkeyInOtherPubkey(context: NSManagedObjectContext) {
        guard !Self.didRun(migrationCode: migrationCode.runPutReactionToPubkeyInOtherPubkey, context: context) else { return }
        
        // Find all reposts
        // if otherPubkey is nil:
        // get it from firstQuote
        // if we don't have firstQuote, get it from firstP
        let fr = Event.fetchRequest()
        fr.predicate = NSPredicate(format: "kind == 7 AND otherPubkey == nil")
        
        var fixed = 0
        if let reactions = try? context.fetch(fr) {
            L.maintenance.info("runPutReactionToPubkeyInOtherPubkey: Found \(reactions.count) reactions without otherPubkey")
            for reaction in reactions {
                
                // Similar as in saveEvent()
                if let lastP = reaction.lastP() {
                    reaction.otherPubkey = lastP
                    fixed += 1
                }
                else if let otherPubkey = reaction.reactionTo?.pubkey {
                    reaction.otherPubkey = otherPubkey
                    fixed += 1
                }
            }
            L.maintenance.info("runPutReactionToPubkeyInOtherPubkey: Fixed \(fixed) otherPubkey in reactions")
        }
                
        let migration = Migration(context: context)
        migration.migrationCode = migrationCode.runPutReactionToPubkeyInOtherPubkey.rawValue
    }
    
    // All available migrations
    enum migrationCode:String {
        
        // Run once to delete events without id (old bug)
        case deleteEventsWithoutId = "deleteEventsWithoutId"
        
        // Run once to fill dTag and delete old replacable events
        case useDtagForReplacableEvents = "useDtagForReplacableEvents"
        
        // Run once to put .anyName in fixedName
        case insertFixedNames = "insertFixedNames"
        
        // Run once to fix replies to existing replacable events
        case fixArticleReplies = "fixArticleReplies"
        
        // Run once to fix false positive results incorrectly cached
        case fixImposterFalsePositives = "fixImposterFalsePositives"
        
        case migrateDMState = "runMigrateDMState"
        
        // Need to run it again... false positives still
        // And again - found another bug during new account onboarding
        case fixImposterFalsePositivesAgainAgain = "fixImposterFalsePositivesAgainAgain"
        
        // Move zappedContactPubkey to otherPubkey
        case fixZappedContactPubkey = "fixZappedContactPubkey"
        
        // Cache .firstQuote.pubkey in .otherPubkey
        case runPutRepostedPubkeyInOtherPubkey = "runPutRepostedPubkeyInOtherPubkey"
        
        // Cache .reactionTo.pubkey in .otherPubkey
        case runPutReactionToPubkeyInOtherPubkey = "runPutReactionToPubkeyInOtherPubkey"
   
    }
}
