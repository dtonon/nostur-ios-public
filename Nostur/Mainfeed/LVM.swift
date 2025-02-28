//
//  ListViewModel.swift
//  Nostur
//
//  Created by Fabian Lachman on 10/03/2023.
//

import Foundation
import SwiftUI
import CoreData
import Combine

let LVM_MAX_VISIBLE:Int = 20

// LVM handles the main feed and other lists
// Posts are loaded from local database andprocessed in background,
// turning any Event (from database) into a NRPost (for view)
// The posts are in .nrPostLeafs and any update to .nrPostLeafs is reflected in SmoothList
// Uses InstantFeed() to go from start-up to posts on screen as fast as possible

// 

class LVM: NSObject, ObservableObject {
        
    var feed:NosturList?
    
    @Published var state:LVM.LIST_STATE = .INIT
    @Published var nrPostLeafs:[NRPost] = [] {
        didSet {
            if state != .READY { state = .READY }
            leafsAndParentIdsOnScreen = self.getAllObjectIds(nrPostLeafs) // Data race in Nostur.LVM.leafsAndParentIdsOnScreen.setter : Swift.Set<Swift.String> at 0x10e60b600 - THREAD 1
            leafIdsOnScreen = Set(nrPostLeafs.map { $0.id })
            
            // Pre-fetch next page.
            // Don't prefetch again unless the last post on screen has changed (this happens when a page is added during infinite scroll):
            // Don't prefetch again if the posts on screen are less than before (posts get removed from bottom, when new ones are added to top):
            if oldValue.count < nrPostLeafs.count, let oldLastId = oldValue.last?.id, let currentLastId = nrPostLeafs.last?.id, oldLastId != currentLastId {
                L.lvm.info("📖 \(self.nrPostLeafs.count) posts loaded. prefetching next page")
                self.throttledCommand.send {
                    self.fetchNextPage()
                }
            }
        }
    }
    var performingLocalOlderFetch = false
    var leafsAndParentIdsOnScreen:Set<String> = [] // Should always be in sync with nrPostLeafs
    var leafIdsOnScreen:Set<String> = []
    var onScreenSeen:Set<NRPostID> = [] // other .id trackers are in sync with nrPostLeafs. This one keeps track even after nrPostLeafs changed
    var alreadySkipped = false
    var danglingIds:Set<NRPostID> = [] // posts that are transformed, but somehow not on screen. either we put on on screen or not, dont transform over and over again, so for some reason these are not on screen, dont know why. keep track here and dont transform again
    
    let ot:NewOnboardingTracker = .shared
    
    let FETCH_FEED_INTERVAL = 9.0
    var id:String // "Following", "Explore", "List-0xb893daf22106244b"
    var uuid = UUID().uuidString
    var name:String = "" // for debugging
    
    enum ListType:String, Identifiable, Hashable {
        case pubkeys = "pubkeys"
        case relays = "relays"
        
        var id:String {
            String(self.rawValue)
        }
    }
    
    let type:ListType
    var listStateObjectId:NSManagedObjectID?
    var pubkey:String?
    var pubkeys:Set<String> {
        didSet {
            L.lvm.info("\(self.id) \(self.name) - pubkeys.count \(oldValue.count) -> \(self.pubkeys.count)")
        }
    }
    
    // TODO: Switch entire SocketPool .sockets to bg context, so we don't have to deal with viewContext relays
    var relays:Set<Relay> = []
    var bgRelays:Set<Relay> = []
    
    // for Relay feeds
    @Published var wotEnabled = true {
        didSet {
            guard oldValue != wotEnabled else { return }
            lvmCounter.count = 0
            instantFinished = false
            nrPostLeafs = []
            onScreenSeen = []
            leafIdsOnScreen = []
            leafsAndParentIdsOnScreen = []
            startInstantFeed()
        }
    }
    
    @MainActor func reload() {
        loadHashtags()
        lvmCounter.count = 0
        instantFinished = false
        nrPostLeafs = []
        onScreenSeen = []
        leafIdsOnScreen = []
        leafsAndParentIdsOnScreen = []
        startInstantFeed()
    }
    
    @Published var hideReplies = false {
        didSet {
            guard oldValue != hideReplies else { return }
            nrPostLeafs = []
            onScreenSeen = []
            leafIdsOnScreen = []
            leafsAndParentIdsOnScreen = []
            self.performLocalFetch()
            self.saveListState()
        }
    }
    
    var viewIsVisible:Bool {
        if isDeck { return true }
        if id.prefix(5) == "List-" {
            return selectedSubTab == "List" && selectedListId == id
        }
        return selectedSubTab == id
    }
    
    @AppStorage("selected_tab") var sTab = "Main"
    @AppStorage("selected_subtab") var ssTab = "Following"
    
    // @AppStorage things
    var selectedSubTab = "" {
        didSet {
            if oldValue != selectedSubTab && viewIsVisible {
                self.didAppear()
            }
            else if oldValue != selectedSubTab && !viewIsVisible {
                self.didDisappear()
            }
        }
    }
    var selectedListId = "" {
        didSet {
            if oldValue != selectedListId && viewIsVisible {
                self.didAppear()
            }
            else if oldValue != selectedListId && !viewIsVisible {
                self.didDisappear()
            }
        }
    }
    
    var restoreScrollToId:String? = nil
    var initialIndex:Int = 0 // derived from restoreScrollToId's index
    
    func didDisappear() {
        self.closeSubAndTimer()
    }
    
    func closeSubAndTimer() {
        if type == .relays {
            L.lvm.info("\(self.id) \(self.name) - Closing subscriptions for .relays tab");
//            15    95.00 ms    0.1%    15.00 ms LVM.performLocalFetchAfterImport()
//            5    62.00 ms    0.1%    5.00 ms               LVM.performLocalFetch(refreshInBackground:) 
//            1    32.00 ms    0.0%    1.00 ms                LVM.closeSubAndTimer() 
//            7    30.00 ms    0.0%    7.00 ms                 SocketPool.closeSubscription(_:)
            DispatchQueue.global().async { // .closeSubAndTimer eventually hits main, but doesn't need to block.
                SocketPool.shared.closeSubscription(self.id)
            }
        }
        self.fetchFeedTimer?.invalidate()
        self.fetchFeedTimer = nil
    }
    
    func didAppear() {
        guard instantFinished else {
            startInstantFeed()
            return
        }
        L.lvm.info("🟢🟢 \(self.id) \(self.name) \(self.pubkey?.short ?? "") didAppear")
        self.restoreSubscription()
        
        
        // TODO: Provide a setting to enable this again, instead of InstantFeed()... maybe for Lists only
//        if nrPostLeafs.count == 0 {
//            if (self.restoreLeafs != nil) {
//                self.performLocalRestoreFetch()
//            }
//            else {
//                self.performLocalFetch()
//            }
//        }
    }
    
    func nextTickNow() {
        self.configureTimer()
        fetchFeedTimerNextTick()
    }
    
    enum LIST_STATE:String {
        case INIT = "INIT"
        case READY = "READY"
    }
    
    private var fetchFeedTimer: Timer?
    
    var throttledCommand = PassthroughSubject<() -> (), Never>()
    var lastAppearedIdSubject = CurrentValueSubject<String?, Never>(nil) // Need it for debounce etc
    var lastAppearedIndex:Int? {
        lastAppearedIdSubject.value != nil
        ? nrPostLeafs.firstIndex(where: { $0.id == self.lastAppearedIdSubject.value! })
        : nil
    }
    var lastReadId:String? // so we dont have to fetch from different context by objectId if we want to save ListState in background
    var lastReadIdIndex:Int? { lastReadId != nil ? nrPostLeafs.firstIndex(where: { $0.id == self.lastReadId! }) : nil }
    
    private var subscriptions = Set<AnyCancellable>()
    public func cleanUp() {
        self.subscriptions.removeAll()
    }
    
    var postsAppearedSubject = PassthroughSubject<[NRPostID], Never>()
    var startRenderingSubject = PassthroughSubject<[Event], Never>()
    var startRenderingOlderSubject = PassthroughSubject<[Event], Never>()
    var didCatchup = false
    var backlog = Backlog(auto: true)
    
    var hashtags: Set<String> = []
    
    public func loadHashtags() {
        self.hashtags =
        if self.id == "Following" {
            (account()?.followingHashtags ?? [])
        }
        else {
            (self.feed?.followingHashtags ?? [])
        }
    }
    
    private func getAllObjectIds(_ nrPosts:[NRPost]) -> Set<NRPostID> { // called from main thread?
        return nrPosts.reduce(Set<NRPostID>()) { partialResult, nrPost in
            if nrPost.isRepost, let firstPost = nrPost.firstQuote {
                // for repost add post + reposted post
                return partialResult.union(Set([nrPost.id, firstPost.id]))
            } else {
                return partialResult.union(Set([nrPost.id] + nrPost.parentPosts.map { $0.id }))
            }
        }
    }
    
    private func getAllEventIds(_ events:[Event]) -> Set<String> {
        return events.reduce(Set<String>()) { partialResult, event in
            if event.isRepost, let firstQuote = event.firstQuote_ {
                // for repost add post + reposted post
                return partialResult.union(Set([event.id, firstQuote.id]))
            }
            else {
                return partialResult.union(Set([event.id] + event.parentEvents.map { $0.id }))
            }
        }
    }
    
    func getRestoreScrollIndex(_ nrPostLeafs:[NRPost], lastAppearedId:String? = nil) -> Int? {
        if let lastAppearedId {
            if let index = nrPostLeafs.firstIndex(where: { $0.id == lastAppearedId }) {
                L.lvm.info("🟢🟢🟢 \(self.id) \(self.pubkey?.short ?? "") should scroll to leaf index: \(index)")
                if index+1 < nrPostLeafs.count {
                    return index+1
                }
                return index
            }
            // or maybe the leaf is now a parent?
            else if let index = nrPostLeafs.firstIndex(where: { $0.parentPosts.map { $0.id }.contains(lastAppearedId) }) {
                L.lvm.info("🟢🟢🟢 \(self.id) \(self.pubkey?.short ?? "") should scroll to leaf-to-parent index: \(index)")
                if index+1 < nrPostLeafs.count {
                    return index+1
                }
                return index
            }
            else {
                L.lvm.info("🟢🟢🟢 \(self.id) \(self.pubkey?.short ?? "") dunno where to scroll to 1")
                return nil
            }
        }
        else {
            return nil
        }
    }
    
    private func applyWoTifNeeded(_ events:[Event]) -> [Event] {
        guard WOT_FILTER_ENABLED() else { return events }  // Return all if globally disabled
        guard self.type == .relays else { return events.filter { $0.inWoT } } // Return inWoT if following/pubkeys list
        
        // if we are here, type is .relays, only filter if the feed specific WoT filter is enabled
        
        guard self.wotEnabled else { return events } // Return all if feed specific WoT is not enabled
        
        return events.filter { $0.inWoT } // apply WoT filter
    }
    
    // MARK: FROM DB TO SCREEN STEP 3:
    private func processPostsInBackground(_ events:[Event], older:Bool = false) { // events are from viewContext
        let taskId = UUID().uuidString
        L.lvm.notice("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") Start transforming \(events.count) events - \(taskId)")
        let context = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ? DataProvider.shared().viewContext : DataProvider.shared().bg
        
        // onScreenIds includes leafs and parents, so all posts.
        let leafsAndParentIdsOnScreen = leafsAndParentIdsOnScreen // Data race in Nostur.LVM.leafsAndParentIdsOnScreen.setter : Swift.Set<Swift.String> at 0x10e60b600 - THREAD 142
        let leafIdsOnScreen = leafIdsOnScreen
        let currentNRPostLeafs = self.nrPostLeafs // viewContext. First (0) is newest
        
        context.perform { [weak self] in
            guard let self = self else { return }
            var newNRPostLeafs:[NRPost] = []
            var transformedIds = Set<NRPostID>()
            
            for event in events {
                guard !danglingIds.contains(event.id) else { continue }
                // Skip if the post is already on screen
                guard !leafsAndParentIdsOnScreen.contains(event.id) else {
                    if let existingNRPost = currentNRPostLeafs.first(where: { $0.id == event.id }) {
                        newNRPostLeafs.append(existingNRPost)
                    }
                    continue
                } // Skip if the post is already on screen

                // If we are not hiding replies, we render leafs + parents --> withParents: true
                //     and we don't load replies (withReplies) because any reply we follow should already be its own leaf (PostOrThread)
                // If we are hiding replies (view), we show mini pfp replies instead, for that we need reply info: withReplies: true
                let newNRPostLeaf = NRPost(event: event, withParents: !hideReplies, withReplies: hideReplies, withRepliesCount: true, cancellationId: event.cancellationId)
                transformedIds.insert(newNRPostLeaf.id)
                newNRPostLeafs.append(newNRPostLeaf)
            }
            
            let added = newNRPostLeafs
//                .filter(notMuted) // TODO: ADD BACK NOT MUTED IN RIGHT CONTEXT / THREAD

            guard !transformedIds.isEmpty else {
                DispatchQueue.main.async {
                    self.performingLocalOlderFetch = false
                }
                return
            }
            L.lvm.notice("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") Transformed \(transformedIds.count) posts - \(taskId)")

            if currentNRPostLeafs.isEmpty {
                let leafThreads = self.renderLeafs(added, onScreenSeen:self.onScreenSeen) // Transforms seperate posts into threads, .id for each thread is leaf.id
                
                let (danglers, newLeafThreads) = extractDanglingReplies(leafThreads)
                if !danglers.isEmpty && !self.hideReplies {
                    L.lvm.info("🟪🟠🟠 processPostsInBackground: \(danglers.count) replies without replyTo. Fetching...")
                    fetchParents(danglers, older:older)
                }
                                
                DispatchQueue.main.async {
                    self.initialIndex = self.getRestoreScrollIndex(newLeafThreads, lastAppearedId: self.restoreScrollToId) ?? 0
                    L.sl.info("⭐️ LVM.initialIndex: \(self.name) \(self.initialIndex) - \(taskId)")
                    self.nrPostLeafs = newLeafThreads
                    self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
                }
            }
            else {
                let newLeafThreadsWithMissingParents = self.renderNewLeafs(added, onScreen:currentNRPostLeafs, onScreenSeen: self.onScreenSeen)
                
                let (danglers, newLeafThreads) = extractDanglingReplies(newLeafThreadsWithMissingParents)
//                self.needsReplyTo.append(contentsOf: danglers)
                let newDanglers = danglers.filter { !self.danglingIds.contains($0.id) }
                if !newDanglers.isEmpty && !self.hideReplies {
                    L.lvm.info("🟠🟠 processPostsInBackground: \(danglers.count) replies without replyTo. Fetching...")
                    danglingIds = danglingIds.union(newDanglers.map { $0.id })
                    fetchParents(newDanglers, older:older)
                }
                putNewThreadsOnScreen(newLeafThreads, leafIdsOnScreen:leafIdsOnScreen, currentNRPostLeafs: currentNRPostLeafs, older:older)
            }
        }
    }
    
    func safeInsert(_ nrPosts:[NRPost], older:Bool = false) -> [NRPost] {
        #if DEBUG
            if !Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should be main")
            }
        #endif
        let leafIdsOnScreen = Set(self.nrPostLeafs.map { $0.id })
        let onlyNew = nrPosts
            .filter { !leafIdsOnScreen.contains($0.id) }
            .uniqued(on: { $0.id })
        
        if older {
            // ADD TO THE END (OLDER POSTS, NEXT PAGE)
            performingLocalOlderFetch = false
            self.nrPostLeafs = self.nrPostLeafs + onlyNew
            self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
        }
        else {
            // ADD TO THE TOP, NEW POSTS.
            
            let nrPostLeafsWithNew = onlyNew + self.nrPostLeafs
            
            // IF AT TOP, TRUNCATE:
            
            let dropCount = max(0, nrPostLeafsWithNew.count - LVM_MAX_VISIBLE) // Drop any above LVM_MAX_VISIBLE
            if self.isAtTop && dropCount > 5 { // No need to drop all the time, do in batches of 5, or 10? // Data race in Nostur.LVM.isAtTop.setter : Swift.Bool at 0x112b87480 (Thread 1)
                let nrPostLeafsWithNewTruncated = nrPostLeafsWithNew.dropLast(dropCount)
                self.nrPostLeafs = Array(nrPostLeafsWithNewTruncated)
                self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
                L.lvm.info("\(self.id) \(self.name) safeInsert() dropped \(dropCount) from end ");
            }
            else {
                if !Set(nrPostLeafsWithNew.map{ $0.id }).subtracting(Set(self.nrPostLeafs.map { $0.id })).isEmpty {
                    self.nrPostLeafs = nrPostLeafsWithNew
                    self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
                }
                else {
                    L.lvm.debug("\(self.id) \(self.name) safeInsert() no new items in Set. skipped ");
                }
            }
        }
        return onlyNew
    }
    
    var isAtTop = true
    
    func putNewThreadsOnScreen(_ newLeafThreadsWithDuplicates:[NRPost], leafIdsOnScreen:Set<String>, currentNRPostLeafs:[NRPost], older:Bool = false) {
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        let newLeafThreads = newLeafThreadsWithDuplicates.filter { !leafIdsOnScreen.contains($0.id) }
        let diff = newLeafThreadsWithDuplicates.count - newLeafThreads.count
        if diff > 0 {
            L.lvm.debug("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") putNewThreadsOnScreen: skipped \(diff) duplicates")
        }
        
        // leafs+parents count
        let addedCount = newLeafThreads.reduce(0, { partialResult, nrPost in
            return partialResult + nrPost.threadPostsCount
        })
        
        DispatchQueue.main.async {
            let inserted = self.safeInsert(newLeafThreads, older: older)
            self.fetchAllMissingPs(inserted)
        }
        
        guard !older else { return }
        DispatchQueue.main.async {
            if !self.isAtTop || !SettingsStore.shared.autoScroll {
                self.lvmCounter.count += addedCount
            }
        }
        
    }
    
    func fetchAllMissingPs(_ posts:[NRPost]) {
        DispatchQueue.global().async {
            let missingPs = posts.reduce([Ptag]()) { partialResult, nrPost in
                return partialResult + nrPost.missingPs
            }
            QueuedFetcher.shared.enqueue(pTags: missingPs)
        }
    }
    
    func fetchParents(_ danglers:[NRPost], older:Bool = false) {
        danglers.forEach { nrPost in
            EventRelationsQueue.shared.addAwaitingEvent(nrPost.event, debugInfo: "LVM.001")
        }
        
        let danglingFetchTask = ReqTask(
            reqCommand: { [weak self] (taskId) in
                guard let self = self else { return }
                L.lvm.info("😈😈 reqCommand: \(self.id) \(self.name)/\(self.pubkey?.short ?? "") - \(taskId) - dng: \(danglers.count)")
                let danglerIds = danglers.compactMap { $0.replyToId }
                    .filter { postId in
                        Importer.shared.existingIds[postId] == nil
                    }
                
                if !danglerIds.isEmpty {
                    req(RM.getEvents(ids: danglerIds, subscriptionId: taskId))
                }
            },
            processResponseCommand: { [weak self] (taskId, _, _) in
                guard let self = self else { return }
                L.lvm.info("😈😈 processResponseCommand: \(self.id) \(self.name)/\(self.pubkey?.short ?? "") - \(taskId) dng: \(danglers.count)")
                let lastCreatedAt = self.nrPostLeafs.last?.created_at ?? 0 // SHOULD CHECK ONLY LEAFS BECAUSE ROOTS CAN BE VERY OLD
                let idsOnScreen = self.leafsAndParentIdsOnScreen
                bg().perform { [weak self] in
                    guard let self = self else { return }
                    let danglingEvents = danglers.map { $0.event }
                    if older {
                        self.setOlderEvents(events: self.filterMutedWords(danglingEvents))
                    }
                    else {
                        self.setUnorderedEvents(events: self.filterMutedWords(danglingEvents), lastCreatedAt:lastCreatedAt, idsOnScreen: idsOnScreen)
                    }
                }
            },
            timeoutCommand: { [weak self] (taskId) in
                guard let self = self else { return }
                L.lvm.info("😈😈 timeoutCommand: \(self.id) \(self.name)/\(self.pubkey?.short ?? "") - \(taskId) dng: \(danglers.count)")
                for d in danglers {
                    L.lvm.info("😈😈 timeoutCommand dng id: \(d.id)")
                }
                
                let lastCreatedAt = self.nrPostLeafs.last?.created_at ?? 0 // SHOULD CHECK ONLY LEAFS BECAUSE ROOTS CAN BE VERY OLD
                let danglingEvents = danglers.map { $0.event }
                
                let idsOnScreen = self.leafsAndParentIdsOnScreen
                bg().perform {
                    self.setUnorderedEvents(events: self.filterMutedWords(danglingEvents), lastCreatedAt:lastCreatedAt, idsOnScreen: idsOnScreen)
                }
            })

        DispatchQueue.main.async {
            self.backlog.add(danglingFetchTask)
        }
        danglingFetchTask.fetch()
    }
    
    func extractDanglingReplies(_ newLeafThreads:[NRPost]) -> (danglers:[NRPost], threads:[NRPost]) {
        // is called from bg thread only?
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        var danglers:[NRPost] = []
        var threads:[NRPost] = []
        newLeafThreads.forEach { nrPost in
            if (nrPost.replyToRootId != nil || nrPost.replyToId != nil) && nrPost.parentPosts.isEmpty {
                danglers.append(nrPost)
            }
            else {
                threads.append(nrPost)
            }
        }
        return (danglers:danglers, threads:threads)
    }
    
    func fetchRelated(_ recentNRPosts:ArraySlice<NRPost>) {
        let ids = recentNRPosts.map { $0.id }.compactMap { $0 }
        recentNRPosts.map { $0.event }.forEach { event in
            EventRelationsQueue.shared.addAwaitingEvent(event, debugInfo: "LVM.002")
        }
        req(RM.getEventReferences(ids: ids, subscriptionId: "RELATED-"+UUID().uuidString))
        L.lvm.info("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") Skip render and fetch related of \(ids.joined(separator: ",")) first.")
    }
    
    func renderLeafs(_ nrPosts:[NRPost], onScreenSeen:Set<String>) -> [NRPost] {
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        let sortedByLongest = nrPosts.sorted(by: { $0.parentPosts.count > $1.parentPosts.count })

        var renderedIds = [String]()
        var renderedPosts = [NRPost]()
        for post in sortedByLongest {
            if post.isRepost && post.firstQuoteId != nil && renderedIds.contains(post.firstQuoteId!) {
                // Reposted post already on screen
                continue
            }
            guard !renderedIds.contains(post.id) else { continue } // Post is already in screen
            
            guard !post.isRepost else {
                // Render a repost, but track firstQuoteId instead of .id in renderedIds
                if let firstQuoteId = post.firstQuoteId {
                    renderedIds.append(firstQuoteId)
                    renderedIds.append(post.id)
                    renderedPosts.append(post)
                }
                continue
            }
            
            guard !post.parentPosts.isEmpty else {
                // Render a root post, that has no parents
                renderedIds.append(post.id)
                renderedPosts.append(post)
                continue
            }
            // render thread, truncated
            let truncatedPost = post
            // structure is: parentPosts: [root, reply, reply, reply, replyTo] post: ThisPost
            if let replyTo = post.parentPosts.last {
                // always keep at least 1 parent (replyTo)
                
                // keep parents until we have already seen one, don't traverse further
                var parentsKeep:[NRPost] = []
                
                // dropLast because we always add at least 1 reply back with: + [replyTo]
                for parent in post.parentPosts.dropLast(1).reversed() {
                    if !renderedIds.contains(parent.id) && !onScreenSeen.contains(parent.id) {
                        parentsKeep.insert(parent, at: 0)
                    }
                    else {
                        break
                    }
                }
                // parentsKeep is now parentPosts with parents we have seen and older removed
                // so we don't have gaps like before when using just .filter { }
                
                // Thread 27 -  Data race in Nostur.NRPost.parentPosts.setter : Swift.Array<Nostur.NRPost> at 0x112075600
                truncatedPost.parentPosts = (parentsKeep + [replyTo]) // add back the replyTo, so we don't have dangling replies.
            }
            truncatedPost.threadPostsCount = 1 + truncatedPost.parentPosts.count // Data race in Nostur.NRPost.threadPostsCount.setter : Swift.Int at 0x10fbe9680 - thread 311
            truncatedPost.isTruncated = post.parentPosts.count > truncatedPost.parentPosts.count
            renderedIds.append(contentsOf: [truncatedPost.id] + truncatedPost.parentPosts.map { $0.id })
            renderedPosts.append(truncatedPost)
        }
        return renderedPosts
            .sorted(by: { $0.created_at > $1.created_at })
//            .sorted(by: { $0.parentPosts.first?.created_at ?? $0.created_at > $1.parentPosts.first?.created_at ?? $1.created_at })
    }
    
    func renderNewLeafs(_ nrPosts:[NRPost], onScreen:[NRPost], onScreenSeen:Set<String>) -> [NRPost] {
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        
        let onScreenLeafIds = onScreen.map { $0.id }
//        let onScreenAllIds = onScreen.flatMap { [$0.id] + $0.parentPosts.map { $0.id } }
        
        
        // First do same as first fetch
        let nrPostLeafs = self.renderLeafs(nrPosts, onScreenSeen: onScreenSeen)
        
        
        // Then remove everything that is already on screen
        let onlyNewLeafs = nrPostLeafs.filter { !onScreenLeafIds.contains($0.id) }
        
        // Then from new replies in threads we already have, only keep the leaf and 1 parent
        let oldThreadsRemoved = onlyNewLeafs.map {
            // render thread, truncated
            let post = $0
            let truncatedPost = post
            // structure is: parentPosts: [root, reply, reply, reply, replyTo] post: ThisPost
            if let replyTo = post.parentPosts.last {
                truncatedPost.parentPosts = [replyTo]
            }
            truncatedPost.threadPostsCount = 1 + truncatedPost.parentPosts.count
            truncatedPost.isTruncated = post.parentPosts.count > truncatedPost.parentPosts.count
            return truncatedPost
        }
        
        return oldThreadsRemoved
            .sorted(by: { $0.created_at > $1.created_at })
    }
    
    var lvmCounter = LVMCounter()
    var restoreLeafs:String?
    
    var instantFeed = InstantFeed()
    var isDeck = false
    
    init(type:ListType, pubkey:String? = nil, pubkeys:Set<String>, listId:String, name:String = "", relays:Set<Relay> = [], wotEnabled:Bool = true, isDeck:Bool = false, feed:NosturList? = nil) {
        self.feed = feed
        self.type = type
        self.name = name
        self.pubkey = pubkey
        self.pubkeys = pubkeys
        self.wotEnabled = wotEnabled
        self.isDeck = isDeck

        self.id = listId
        super.init()
        
        self.loadHashtags()
        
        let ctx = DataProvider.shared().viewContext
        let bg = DataProvider.shared().bg
        if type == .relays {
            self.relays = relays // viewContext relays
            SocketPool.shared.connectFeedRelays(relays: relays)
            bg.performAndWait {
                let relays = relays.map { bg.object(with: $0.objectID) as! Relay }
                self.bgRelays = Set(relays) // bgContext relays
            }
        }
        var ls:ListState?
        if let pubkey {
            ls = ListState.fetchListState(pubkey, listId: listId, context: ctx)
        }
        else {
            ls = ListState.fetchListState(listId: listId, context: ctx)
        }
        
        if (ls == nil) {
            bg.perform { [weak self] in
                guard let self = self else { return }
                ls = ListState(context: bg)
                ls!.listId = listId
                ls!.pubkey = pubkey
                ls!.updatedAt = Date.now
                do { try bg.save() }
                catch { L.lvm.error("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") could not save new listState") }
                self.listStateObjectId = ls!.objectID
            }
        }
        else {
            self.listStateObjectId = ls!.objectID
            self.lastReadId = ls!.mostRecentAppearedId
            self.lastAppearedIdSubject.send(ls!.lastAppearedId)
            self.restoreLeafs = ls!.leafs
            self.hideReplies = ls!.hideReplies
        }
        
        if (self.restoreLeafs != nil) {
//            self.restoreScrollToId = ls!.lastAppearedId
//            self.performLocalRestoreFetch()
        }
        else {
//            self.performLocalFetch()
        }
        
//        self.configureTimer()
        
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            let d = UserDefaults(suiteName: "preview_user_defaults")!
            selectedSubTab = (d.string(forKey: "selected_subtab") ?? "Unknown")
            selectedListId = (d.string(forKey: "selected_listId") ?? "Unknown")
        }
        else {
            selectedSubTab = (UserDefaults.standard.string(forKey: "selected_subtab") ?? "Unknown")
            selectedListId = (UserDefaults.standard.string(forKey: "selected_listId") ?? "Unknown")
        }
        addSubscriptions()
        
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.viewIsVisible {
                self.startInstantFeed()
            }
        }
    }
    
    func startInstantFeed() {
        guard !instantFinished && !instantFeed.isRunning else { return }
        let completeInstantFeed = { [weak self] events in
            guard let self = self else { return }
            self.startRenderingSubject.send(events)
            
            if (!self.instantFinished) {
                self.performLocalFetchAfterImport()
            }
//            fetchFeedTimerNextTick()
            self.instantFinished = true
            
            if type == .relays {
                DispatchQueue.main.async {
                    self.fetchRelaysRealtimeSinceNow(subscriptionId: self.id) // Subscription should stay active
                }
            }
            else {
                DispatchQueue.main.async {
                    self.fetchRealtimeSinceNow(subscriptionId: self.id) // Subscription should stay active
                }
            }
            
            let hoursAgo = Int64(Date.now.timeIntervalSince1970) - (3600 * 4)  // 4 hours  ago

            // Continue from first (newest) on screen?
            let since = (self.nrPostLeafs.first?.created_at ?? hoursAgo) - (60 * 5) // (take 5 minutes earlier to not mis out of sync posts)
            let ago = Date(timeIntervalSince1970: Double(since)).agoString

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                guard let self = self else { return }
                if type == .relays {
                    self.fetchRelaysNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                }
                else {
                    self.fetchNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                    fetchProfiles(pubkeys: self.pubkeys, subscriptionId: "Profiles")
                }
            }
        }
        if id == "Following", let pubkey {
            L.lvm.notice("🟪 instantFeed.start \(self.name) \(self.id)")
            instantFeed.start(pubkey, onComplete: completeInstantFeed)
        }
        else if type == .relays {
            L.lvm.notice("🟪 instantFeed.start \(self.name) \(self.id)")
            instantFeed.start(bgRelays, onComplete: completeInstantFeed)
        }
        else {
            L.lvm.notice("🟪 instantFeed.start \(self.name) \(self.id)")
            instantFeed.start(pubkeys, onComplete: completeInstantFeed)
        }
    }
    
    var instantFinished = false {
        didSet {
            if instantFinished {
                L.lvm.notice("🟪 \(self.name) instantFinished")
                // if nothing on screen, fetch from local
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if self.nrPostLeafs.isEmpty {
                        self.performLocalFetch()
                    }
                }
                self.configureTimer()
            }
        }
    }

    func configureTimer() {
        self.fetchFeedTimer?.invalidate()
        self.fetchFeedTimer = Timer.scheduledTimer(withTimeInterval: FETCH_FEED_INTERVAL, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.fetchFeedTimerNextTick()
        }
        self.fetchFeedTimer?.tolerance = 2.0
    }
    
    deinit {
        L.lvm.info("⭐️ LVM.deinit \(self.id) \(self.name)/\(self.pubkey?.short ?? "")")
        self.fetchFeedTimer?.invalidate()
    }
        
    // MARK: STEP 0: FETCH FROM RELAYS
    func fetchFeedTimerNextTick() {
        guard self.viewIsVisible else {
            return
        }
        let isImporting = bg().performAndWait { // TODO: Hang here... need to remove ..AndWait { }
            return Importer.shared.isImporting
        }
        guard !isImporting else { L.lvm.info("\(self.id) \(self.name) ⏳ Still importing, new fetch skipped."); return }
        
        if !UserDefaults.standard.bool(forKey: "firstTimeCompleted") {
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: "firstTimeCompleted")
            }
        }
        
        if type == .relays {
            fetchRelaysRealtimeSinceNow(subscriptionId: self.id) // Subscription should stay active
        }
        else {
            fetchRealtimeSinceNow(subscriptionId: self.id) // Subscription should stay active
        }
        
        if nrPostLeafs.isEmpty { // Nothing on screen
            // Dont need anymore because InstantFeed()?:
//            fetchNewestUntilNow(subscriptionId: self.id) // This one closes after EOSE
//            fetchProfiles(pubkeys: self.pubkeys, subscriptionId: "Profiles")
        }
        else { // Already on screen, app probably returned from from background
            // Catch up?
            let hoursAgo = Int64(Date.now.timeIntervalSince1970) - (3600 * 4)  // 4 hours  ago

            // Continue from first (newest) on screen?
            let since = (self.nrPostLeafs.first?.created_at ?? hoursAgo) - (60 * 5) // (take 5 minutes earlier to not mis out of sync posts)
            let ago = Date(timeIntervalSince1970: Double(since)).agoString

            DispatchQueue.main.async {
                if (!self.didCatchup) {
                    // THIS ONE IS TO CATCH UP, WILL CLOSE AFTER EOSE:
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
                        guard let self = self else { return }
                        if type == .relays {
                            self.fetchRelaysNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                        }
                        else {
                            self.fetchNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                            fetchProfiles(pubkeys: self.pubkeys, subscriptionId: "Profiles")
                        }
                    }
                    self.didCatchup = true
                }
            }
        }
    }
}


extension LVM {
    
    func restoreSubscription() {
        guard instantFinished else {
            L.lvm.debug("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") instantFinished=false, not restoring subscription! \(self.selectedSubTab) and selectedListId: \(self.selectedListId)")
            if viewIsVisible {
                startInstantFeed()
            }
            return
        }
        self.didCatchup = false
        // Always try to restore timer
        self.configureTimer()
        
        guard viewIsVisible else {
            L.lvm.debug("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") NOT VISIBLE, NOT RESTORING. current selectedSubTab: \(self.selectedSubTab) and selectedListId: \(self.selectedListId)")
            return
        }
        
        L.lvm.info("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") restoreSubscription")
        if type == .relays {
            fetchRelaysRealtimeSinceNow(subscriptionId: self.id)
        }
        else {
            fetchRealtimeSinceNow(subscriptionId: self.id)
        }
        
        let hoursAgo = Int64(Date.now.timeIntervalSince1970) - (3600 * 4)  // 4 hours  ago

        // Continue from first (newest) on screen?
        let since = (self.nrPostLeafs.first?.created_at ?? hoursAgo) - (60 * 5) // (take 5 minutes earlier to not mis out of sync posts)
        let ago = Date(timeIntervalSince1970: Double(since)).agoString

        DispatchQueue.main.async {
            if (!self.didCatchup) {
                // THIS ONE IS TO CATCH UP, WILL CLOSE AFTER EOSE:
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
                    guard let self = self else { return }
                    if self.type == .relays {
                        self.fetchRelaysNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                    }
                    else {
                        self.fetchNewerSince(subscriptionId: "\(self.id)-\(ago)", since:NTimestamp(timestamp: Int(since))) // This one closes after EOSE
                        fetchProfiles(pubkeys: self.pubkeys, subscriptionId: "Profiles")
                    }
                    L.lvm.info("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") restoreSubscription + 8 seconds fetchNewerSince()")
                }
                self.didCatchup = true
            }
        }
    }
    
    
    func stopSubscription() {
        self.fetchFeedTimer?.invalidate()
        self.fetchFeedTimer = nil
    }
    
    
    func addSubscriptions() {
        keepListStateSaved()
        trackLastAppeared()
        processNewEventsInBg()
        keepFilteringMuted()
        showOwnNewPostsImmediately()
        removeUnpublishedEvents()
        trackListSettingsChanged()
        renderFromLocalIfWeHaveNothingNewAndScreenIsEmpty()
        trackTabVisibility()
        loadMoreWhenNearBottom()
        throttledCommands()
        fetchCountsForVisibleIndexPaths()
    }
    
    func fetchCountsForVisibleIndexPaths() {
        postsAppearedSubject
            .filter { _ in
                !ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] nrPostIds in
                guard let self = self else { return }
                guard SettingsStore.shared.fetchCounts else { return }
                guard !SettingsStore.shared.lowDataMode else { return } // Also don't fetch if low data mode
                
                let events = self.nrPostLeafs
                    .filter { nrPostIds.contains($0.id) }
                    .compactMap {
                        if $0.isRepost {
                            return $0.firstQuote?.event
                        }
                        return $0.event
                    }
                
                guard !events.isEmpty else { return }
                
                bg().perform {
                    for event in events {
                        EventRelationsQueue.shared.addAwaitingEvent(event)
                    }
                    let eventIds = events.map { $0.id }
                    L.fetching.info("🔢 Fetching counts for \(eventIds.count) posts")
                    fetchStuffForLastAddedNotes(ids: eventIds)
                }
                
            
            }
            .store(in: &subscriptions)
    }
    
    func throttledCommands() {
        throttledCommand
            .throttle(for: .seconds(1.5), scheduler: RunLoop.main, latest: true)
            .sink { command in
                L.lvm.info("🪡🪡 Running throttled command")
                command()
            }
            .store(in: &subscriptions)
    }
    
    func trackTabVisibility() {
        // Listen for changes on user setting:
        NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .compactMap { _ in UserDefaults.standard.string(forKey: "selected_subtab") }
                .assign(to: \.selectedSubTab, on: self)
                .store(in: &subscriptions)
        
        NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .compactMap { _ in UserDefaults.standard.string(forKey: "selected_listId") }
                .assign(to: \.selectedListId, on: self)
                .store(in: &subscriptions)
    }
    
    func performLocalFetchAfterImport() {
        Importer.shared.newEventsInDatabase
            .subscribe(on: DispatchQueue.global())
            .throttle(for: .seconds(2.5), scheduler: DispatchQueue.global(), latest: true)
            .receive(on: RunLoop.main) // Main because .performLocalFetch() needs some Main things
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard instantFinished else { return }
                L.lvm.info("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") performLocalFetchAfterImport \(self.uuid)")
                self.performLocalFetch()
            }
            .store(in: &subscriptions)
    }
    
    func renderFromLocalIfWeHaveNothingNewAndScreenIsEmpty() {
        receiveNotification(.noNewEventsInDatabase)
            .throttle(for: .seconds(2.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.viewIsVisible else { return }
                guard self.nrPostLeafs.isEmpty else { return }
                L.lvm.info("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") renderFromLocalIfWeHaveNothingNew")
                self.performLocalFetch()
            }
            .store(in: &subscriptions)
    }
    
    func trackListSettingsChanged() {
        receiveNotification(.followersChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard self.id == "Following" else { return }
                SocketPool.shared.allowNewFollowingSubscriptions()
                let pubkeys = notification.object as! Set<String>
                self.pubkeys = pubkeys
                self.performLocalFetch(refreshInBackground: true)
            }
            .store(in: &subscriptions)
        
        receiveNotification(.explorePubkeysChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard self.id == "Explore" else { return }
                let pubkeys = notification.object as! Set<String>
                self.pubkeys = pubkeys
                self.performLocalFetch()
            }
            .store(in: &subscriptions)
        
        receiveNotification(.listPubkeysChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let newPubkeyInfo = notification.object as! NewPubkeysForList
                guard newPubkeyInfo.subscriptionId == self.id else { return }
                L.lvm.info("LVM .listPubkeysChanged \(self.pubkeys.count) -> \(newPubkeyInfo.pubkeys.count)")
                self.pubkeys = newPubkeyInfo.pubkeys
                
                lvmCounter.count = 0
                instantFinished = false
                nrPostLeafs = []
                onScreenSeen = []
                leafIdsOnScreen = []
                leafsAndParentIdsOnScreen = []
                startInstantFeed()
            }
            .store(in: &subscriptions)
        
        
        receiveNotification(.listRelaysChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let newRelaysInfo = notification.object as! NewRelaysForList
                guard newRelaysInfo.subscriptionId == self.id else { return }
                L.lvm.info("LVM .listRelaysChanged \(self.relays.count) -> \(newRelaysInfo.relays.count)")
                
                self.relays = newRelaysInfo.relays // viewContext relays
                
                SocketPool.shared.closeSubscription(self.id)
                SocketPool.shared.connectFeedRelays(relays: relays)
                let bg = DataProvider.shared().bg
                bg.performAndWait {
                    let relays = newRelaysInfo.relays.map { bg.object(with: $0.objectID) as! Relay }
                    self.bgRelays = Set(relays) // bgContext relays
                }
                
                if newRelaysInfo.wotEnabled == self.wotEnabled {
                    // if WoT did not change, manual clear:
                    lvmCounter.count = 0
                    instantFinished = false
                    nrPostLeafs = []
                    onScreenSeen = []
                    leafIdsOnScreen = []
                    leafsAndParentIdsOnScreen = []
                    startInstantFeed()
                }
                else { // else LVM will clear from didSet on .wotEnabled
                    self.wotEnabled = newRelaysInfo.wotEnabled
                }
            }
            .store(in: &subscriptions)
        
    }
    
    func showOwnNewPostsImmediately() {
        receiveNotification(.newPostSaved)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard self.id == "Following" else { return }
                let event = notification.object as! Event
                let context = DataProvider.shared().bg
                context.perform { [weak self] in
                    guard let self = self else { return }
                    guard let pubkey = self.pubkey, event.pubkey == pubkey else { return }
                    guard !self.leafIdsOnScreen.contains(event.id) else { return }
                    EventRelationsQueue.shared.addAwaitingEvent(event, debugInfo: "LVM.showOwnNewPostsImmediately")
                    // If we are not hiding replies, we render leafs + parents --> withParents: true
                    //     and we don't load replies (withReplies) because any reply we follow should already be its own leaf (PostOrThread)
                    // If we are hiding replies (view), we show mini pfp replies instead, for that we need reply info: withReplies: true
                    let newNRPostLeaf = NRPost(event: event, withParents: !hideReplies, withReplies: hideReplies, withRepliesCount: true, cancellationId: event.cancellationId)
                    DispatchQueue.main.async {
                        self.nrPostLeafs.insert(newNRPostLeaf, at: 0)
                        self.lvmCounter.count = self.isAtTop && SettingsStore.shared.autoScroll ? 0 : (self.lvmCounter.count + 1)
                    }
                }
            }
            .store(in: &subscriptions)
    }
    
    func removeUnpublishedEvents() {
        receiveNotification(.unpublishedNRPost)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let nrPost = notification.object as! NRPost
                let context = DataProvider.shared().bg
                
                // Remove from view
                DispatchQueue.main.async {
                    self.nrPostLeafs.removeAll(where: { $0.id == nrPost.id })
                    self.lvmCounter.count = max(0, self.lvmCounter.count - 1)
                }
                
                // Remove from database
                context.perform {
                    context.delete(nrPost.event)
                    DataProvider.shared().bgSave()
                }
            }
            .store(in: &subscriptions)
    }
    
    func keepFilteringMuted() {
        receiveNotification(.muteListUpdated)
            .sink { [weak self] notification in
                guard let self = self else { return }
                self.nrPostLeafs = self.nrPostLeafs.filter(notMuted)
                self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
            }
            .store(in: &subscriptions)
        
        receiveNotification(.blockListUpdated)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let blockedPubkeys = notification.object as! [String]
                self.nrPostLeafs = self.nrPostLeafs.filter({ !blockedPubkeys.contains($0.pubkey) })
                self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
            }
            .store(in: &subscriptions)
        
        receiveNotification(.mutedWordsChanged)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let words = notification.object as! [String]
                self.nrPostLeafs = self.nrPostLeafs.filter { notMutedWords(in: $0.event.noteText, mutedWords: words) }
                self.onScreenSeen = self.onScreenSeen.union(self.getAllObjectIds(self.nrPostLeafs))
            }
            .store(in: &subscriptions)
    }
    
    func processNewEventsInBg() {
        startRenderingSubject
           .removeDuplicates()
           .sink { [weak self] posts in
               self?.processPostsInBackground(posts)
           }
           .store(in: &subscriptions)
        
        startRenderingOlderSubject
           .removeDuplicates()
           .receive(on: RunLoop.main)
           .sink { [weak self] posts in
               self?.processPostsInBackground(posts, older: true)
           }
           .store(in: &subscriptions)
    }
        
    func trackLastAppeared() {
        lastAppearedIdSubject
//            .throttle(for: 0.05, scheduler: RunLoop.main, latest: false)
            .compactMap { $0 }
            .sink { [weak self] eventId in
                guard let self = self else { return }
                guard self.lastAppearedIndex != nil else { return }
                guard !self.nrPostLeafs.isEmpty else { return }
                
//                print("COUNTER . new lastAppearedId. Index is: \(self.lastAppearedIndex) ")

                
                // unread should only go down, not up
                // only way to go up is when new posts are added.
                if self.itemsAfterLastAppeared < self.lvmCounter.count {
//                if self.itemsAfterLastAppeared != 0 && self.itemsAfterLastAppeared < self.lvmCounter.count {
//                    print("COUNTER A: \(self.lvmCounter.count)")
                    self.lvmCounter.count = self.itemsAfterLastAppeared
//                    print("COUNTER AA: \(self.lvmCounter.count)")
                    self.lastReadId = eventId
                }
                else if self.lastReadId == nil {
                    self.lastReadId = eventId
                }
                
//                // Put onScreenSeen, so when when a new leaf for a long thread is inserted at top, it won't show all the parents you already seen again
//                bg().perform { [weak self] in
//                    guard let self = self else { return }
//                    self.onScreenSeen.insert(eventId)
//                }
            }
            .store(in: &subscriptions)
    }
    
    func loadMoreWhenNearBottom() {
        lastAppearedIdSubject
//            .throttle(for: 0.05, scheduler: RunLoop.main, latest: false)
            .compactMap { $0 }
            .sink { [weak self] eventId in
                guard let self = self else { return }
                guard let lastAppeareadIndex = self.lastAppearedIndex else { return }
                guard !self.nrPostLeafs.isEmpty else { return }
                
                if lastAppeareadIndex > (self.nrPostLeafs.count-15) {
                    L.lvm.info("📖 Appeared: \(lastAppeareadIndex)/\(self.nrPostLeafs.count) - loading more from local")
                    self.performLocalOlderFetch()
                }
            }
            .store(in: &subscriptions)
    }
    
    // 1 2 3 [4] 5 6 7 8 9 10
    // 0 1 2 [3] 4 5 6 7 8 9
    // Old version, without threads
//    var itemsAfterLastAppeared:Int {
//        guard let lastAppearedIndex = self.lastAppearedIndex else { return self.nrPosts.count }
//        return max(0,((self.nrPosts.count - lastAppearedIndex) - 1))
//    }
    
    // With threads. cannot simply count, need to use the thread count value
    var itemsAfterLastAppeared:Int {
        guard let lastAppearedIndex = self.lastAppearedIndex else {
            return 0
        }
        let postsAfterLastAppeared = self.nrPostLeafs.prefix(lastAppearedIndex)
        let count = threadCount(Array(postsAfterLastAppeared))
        return max(0,count) // cant go negative
    }
    
    var itemsAfterLastRead:Int {
        guard let lastReadIndex = self.lastReadIdIndex else {
            return 0
        }
        let postsAfterLastRead = self.nrPostLeafs.prefix(lastReadIndex)
        let count = threadCount(Array(postsAfterLastRead))
        return max(0,count) // cant go negative
    }
    
    func keepListStateSaved() {
        lastAppearedIdSubject
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: false)
        //            .debounce(for: .seconds(1), scheduler: DispatchQueue.global())
        //            .throttle(for: .seconds(5), scheduler: DispatchQueue.global(), latest: false)
//            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.saveListState()
            }
            .store(in: &subscriptions)
    }
    
    func saveListState() {
        let context = DataProvider.shared().bg
        let lastAppearedId = self.lastAppearedIdSubject.value
        let lastReadId = self.lastReadId
        let leafs = self.nrPostLeafs.map { $0.id }.joined(separator: ",")
        context.perform { [weak self] in
            guard let self = self else { return }
            guard let listStateObjectId = self.listStateObjectId else { return }
            guard let listState = context.object(with: listStateObjectId) as? ListState else { return }
            listState.lastAppearedId = lastAppearedId
            listState.mostRecentAppearedId = lastReadId
            listState.updatedAt = Date.now
            listState.leafs = leafs
            listState.hideReplies = hideReplies
            L.lvm.debug("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") saveListState. lastAppearedId: \(lastAppearedId?.description.prefix(11) ?? "??") (index: \(self.lastAppearedIndex?.description ?? "??"))")
            do {
                try context.save()
            }
            catch {
                L.lvm.error("🔴🔴 \(self.id) \(self.name)/\(self.pubkey?.short ?? "") Error saving list state \(self.id) \(listState.pubkey ?? "")")
            }
        }
    }
}

extension LVM {
    
    // MARK: FROM DB TO SCREEN STEP 1: FETCH REQUEST
    func performLocalFetch(refreshInBackground:Bool = false) {
        let mostRecentEvent:Event? = self.nrPostLeafs.first?.event
        let visibleOrInRefreshInBackground = self.viewIsVisible || refreshInBackground
        guard visibleOrInRefreshInBackground else {
            L.lvm.debug("\(self.id) \(self.name)/\(self.pubkey?.short ?? "") performLocalFetch cancelled - view is not visible")
            // For some reason the subscription is not closed when switching tab, so close here
            self.closeSubAndTimer()
            return
        }
        let ctx = DataProvider.shared().bg
        let lastCreatedAt = self.nrPostLeafs.last?.created_at ?? 0 // SHOULD CHECK ONLY LEAFS BECAUSE ROOTS CAN BE VERY OLD
        let hashtagRegex = self.hashtagRegex
        let idsOnScreen = self.leafsAndParentIdsOnScreen
        ctx.perform { [weak self] in
            guard let self = self else { return }
            L.lvm.info("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") performLocalFetch LVM.id (\(self.uuid)")
            if let mostRecentEvent = mostRecentEvent {
                //            print("🟢🟢🟢🟢🟢🟢 from mostRecent \(mostRecent.id)")
                let fr = type == .relays
                    ? Event.postsByRelays(self.bgRelays, mostRecent: mostRecentEvent, hideReplies: self.hideReplies)
                    : Event.postsByPubkeys(self.pubkeys, mostRecent: mostRecentEvent, hideReplies: self.hideReplies, hashtagRegex: hashtagRegex)
                
                
                guard let posts = try? ctx.fetch(fr) else { return }
                self.setUnorderedEvents(events: self.filterMutedWords(posts), lastCreatedAt:lastCreatedAt, idsOnScreen: idsOnScreen)
            }
            else {
//                print("🟢🟢🟢🟢🟢🟢 from lastAppearedCreatedAt \(self.lastAppeared?.created_at ?? 0)")
                let fr = type == .relays
                    ? Event.postsByRelays(self.bgRelays, lastAppearedCreatedAt: self.lastAppearedCreatedAt ?? 0, hideReplies: self.hideReplies)
                    : Event.postsByPubkeys(self.pubkeys, lastAppearedCreatedAt: self.lastAppearedCreatedAt ?? 0, hideReplies: self.hideReplies, hashtagRegex: hashtagRegex)

                guard let posts = try? ctx.fetch(fr) else { return }
                self.setUnorderedEvents(events: self.filterMutedWords(posts), lastCreatedAt:lastCreatedAt, idsOnScreen: idsOnScreen)
            }
        }
    }
    
//    func performLocalRestoreFetch(refreshInBackground:Bool = false) {
//        let ctx = DataProvider.shared().bg
//        ctx.perform { [weak self] in
//            guard let self = self else { return }
//            if let leafs = self.restoreLeafs?.split(separator: ",") {
//                let fr = Event.fetchRequest()
//                fr.predicate = NSPredicate(format: "id IN %@", leafs)
//                if let events = try? ctx.fetch(fr) {
//
//
//                    let restoredPosts = leafs
//                        .compactMap({ leafId in
//                            return events.first { event in
//                                return event.id == leafId
//                            }
//                        })
//                        .map {
//                            $0.parentEvents = Event.getParentEvents($0)
//                            return $0
//                        }
//
//                    // don't load too many:
//                    // if restored posts > MAX.
//                    // and lastAppearedIndex < MAX-20 (so we can scroll at least 20 more back)
//                    // example 500 (RESTORED) > 250 (MAX), 77 (LAST APPEARED) < 230 (MAX - 20)
//                    // Then remove all after 250 (RESTORED.prefix(250))
//                    if restoredPosts.count > LVM_MAX_VISIBLE, let lastAppearedIndex = restoredPosts.firstIndex(where: { $0.id == self.lastAppearedIdSubject.value }), lastAppearedIndex < (LVM_MAX_VISIBLE-20)  {
////                        DispatchQueue.main.async {
////                            self.state = .AWAITING_RESTORE_SCROLL
////                        }
//                        self.startRenderingSubject.send(Array(restoredPosts.prefix(250)))
//                    }
//                    else {
////                        DispatchQueue.main.async {
////                            self.state = .AWAITING_RESTORE_SCROLL
////                        }
//                        self.startRenderingSubject.send(restoredPosts)
//                    }
//                }
//                self.performLocalFetch()
//            }
//            else {
//                self.performLocalFetch()
//            }
//        }
//    }
    
    
    func performLocalOlderFetch() {
        guard !performingLocalOlderFetch else { // Data race in Nostur.LVM.performingLocalOlderFetch.setter : Swift.Bool at 0x114481300
            L.lvm.debug("Already performingLocalOlderFetch, cancelled")
            // reset in 2 seconds just in case
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.performingLocalOlderFetch {
                    self.performingLocalOlderFetch = false
                }
            }
            return
        }
//        guard let oldestEvent = self.nrPostLeafs.last?.event else { L.og.debug("Empty screen, cancelled") ;return } // bug: sometimes last is not oldest (delayed receive?, slow relay?), so don't take last but actual oldest on screen:
        
        // Actual oldest:
        guard let oldestEvent = self.nrPostLeafs.max(by: { $0.createdAt > $1.createdAt })?.event else {
            L.lvm.debug("Empty screen, cancelled") ;return
        }
        
        performingLocalOlderFetch = true
        let ctx = DataProvider.shared().bg
        let hashtagRegex = self.hashtagRegex
        ctx.perform { [weak self] in
            guard let self = self else { return }
            L.lvm.info("🏎️🏎️ \(self.id) \(self.name)/\(self.pubkey?.short ?? "") performLocalOlderFetch LVM.id (\(self.uuid)")
            let fr = type == .relays
                ? Event.postsByRelays(self.bgRelays, until: oldestEvent, hideReplies: self.hideReplies)
                : Event.postsByPubkeys(self.pubkeys, until: oldestEvent, hideReplies: self.hideReplies, hashtagRegex: hashtagRegex)
            guard let posts = try? ctx.fetch(fr) else {
                DispatchQueue.main.async {
                    self.performingLocalOlderFetch = false
                }
                return
            }
            self.setOlderEvents(events: self.filterMutedWords(posts))
        }
    }
    
    var lastAppearedCreatedAt:Int64? {
        guard let lastAppearedId = self.lastAppearedIdSubject.value else { return nil }
        return nrPostLeafs.first(where: { $0.id == lastAppearedId })?.created_at
    }
    
    func filterMutedWords(_ events:[Event]) -> [Event] {
        guard !NRState.shared.mutedWords.isEmpty else { return events }
        return events
            .filter {
                notMutedWords(in: $0.noteText, mutedWords: NRState.shared.mutedWords)
            }
    }
    
    // MARK: FROM DB TO SCREEN STEP 2: FIRST FILTER PASS, GETTING PARENTS AND LIMIT, NOT ON SCREEN YET
    func setUnorderedEvents(events:[Event], lastCreatedAt:Int64 = 0, idsOnScreen: Set<String> = []) {
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        var newUnrenderedEvents:[Event]
        
        let filteredEvents = applyWoTifNeeded(events)
        
        switch (self.state) {
            case .INIT: // Show last X (FORCED CUTOFF)
                newUnrenderedEvents = filteredEvents.filter(onlyRootOrReplyingToFollower)
                    .prefix(LVM_MAX_VISIBLE)
                    .map {
                        $0.parentEvents = hideReplies ? [] : Event.getParentEvents($0, fixRelations: true)
                        _ = $0.replyTo__
                        return $0
                    }
                let newEventIds = getAllEventIds(newUnrenderedEvents)
                let newCount = newEventIds.subtracting(idsOnScreen).count
                if newCount > 0 {
                    self.startRenderingSubject.send(newUnrenderedEvents)
                }
                
            default:
                newUnrenderedEvents = filteredEvents
                    .filter { $0.created_at > lastCreatedAt } // skip all older than first on screen (check LEAFS only)
                    .filter(onlyRootOrReplyingToFollower)
                    .map {
                        $0.parentEvents = hideReplies ? [] : Event.getParentEvents($0, fixRelations: true)
                        _ = $0.replyTo__
                        return $0
                    }

                let newEventIds = getAllEventIds(newUnrenderedEvents)
                let newCount = newEventIds.subtracting(idsOnScreen).count
                if newCount > 0 {
                    self.startRenderingSubject.send(newUnrenderedEvents)
                }
                
                return
        }
    }
    
    
    
    func setOlderEvents(events:[Event]) {
        #if DEBUG
            if Thread.isMainThread && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
                fatalError("Should only be called from bg()")
            }
        #endif
        var newUnrenderedEvents:[Event]
        
        let filteredEvents = applyWoTifNeeded(events)
        
        newUnrenderedEvents = filteredEvents
            .filter(onlyRootOrReplyingToFollower)
            .map {
                $0.parentEvents = Event.getParentEvents($0, fixRelations: true)
                return $0
            }

        let newEventIds = getAllEventIds(newUnrenderedEvents)
        let newCount = newEventIds.subtracting(leafsAndParentIdsOnScreen).count // Thread 105 - Data race in Nostur.LVM.leafsAndParentIdsOnScreen.getter : Swift.Set<Swift.String> at 0x10c479400
        if newCount > 0 {
            self.startRenderingOlderSubject.send(newUnrenderedEvents)
        }
        else {
            DispatchQueue.main.async {
                self.performingLocalOlderFetch = false
            }
        }
    }
        
    func onlyRootOrReplyingToFollower(_ event:Event) -> Bool {
        // TODO: Add setting to show replies to all...
        return true
//        if let replyToPubkey = event.replyTo?.pubkey {
//            if pubkeys.contains(replyToPubkey) {
//                return true
//            }
//        }
//        return event.replyToId == nil
    }
}

func notMutedWords(in text: String, mutedWords: [String]) -> Bool {
    return mutedWords.first(where: { text.localizedCaseInsensitiveContains($0) }) == nil
}

func notMuted(_ nrPost:NRPost) -> Bool {
    let mutedRootIds = account()?.mutedRootIds_ ?? []
    return !mutedRootIds.contains(nrPost.id) && !mutedRootIds.contains(nrPost.replyToRootId ?? "NIL") && !mutedRootIds.contains(nrPost.replyToId ?? "NIL")
}



func threadCount(_ nrPosts:[NRPost]) -> Int {
    nrPosts.reduce(0) { partialResult, nrPost in
        (partialResult + nrPost.threadPostsCount) //  Data race in Nostur.NRPost.threadPostsCount.setter : Swift.Int at 0x10fbe9680 - thread 1
    }
}

struct NewPubkeysForList {
    var subscriptionId:String
    var pubkeys:Set<String>
}

struct NewRelaysForList {
    var subscriptionId:String
    var relays:Set<Relay>
    var wotEnabled:Bool
}
