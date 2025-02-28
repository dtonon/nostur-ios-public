//
//  PreviewHelper.swift
//  Nostur
//
//  Created by Fabian Lachman on 24/01/2023.
//

import SwiftUI
import CoreData

let PREVIEW_ACCOUNT_ID = "9be0be0e64d38a29a9cec9a5c8ef5d873c2bfa5362a4b558da5ff69bc3cbb81e"
let PREVIEW_DEVICE = "iPhone 15"

public class PreviewEnvironment {
    
    var didLoad = false
    let sp:SocketPool = .shared
    let er:ExchangeRateModel = .shared
    let tm:DetailTabsModel = .shared
    let dim:DIMENSIONS = .shared
    let ss:SettingsStore = .shared
    let sm = SideBarModel()
    let theme:Theme = .default
    
    static let shared = PreviewEnvironment()
        
    let userDefaults:UserDefaults = {
        let d = UserDefaults(suiteName: "preview_user_defaults")!
        d.set(PREVIEW_ACCOUNT_ID, forKey: "activeAccountPublicKey")
        d.set(true, forKey: "devToggle")
        d.set("Following", forKey: "selected_subtab")
        d.set("Main", forKey: "selected_tab")
        d.set(false, forKey: "full_width_images")
        return d
    }()
    let context:NSManagedObjectContext = DataProvider.shared().container.viewContext
    let decoder = JSONDecoder()
    
    init() { }
    
//    var didParseMessages = false
    public func parseMessages(_ messages:[String]) {
//        guard !didParseMessages else { return }
//        didParseMessages = true
        // TODO: Should reuse Importer.shared
        context.performAndWait {
            for text in messages {
                guard let message = try? RelayMessage.parseRelayMessage(text: text, relay: "wss://memory") else { continue }
                guard var event = message.event else { continue }
                
                // FIX FOR KIND 6 WITH JSON STRING OF ANOTHER EVENT IN EVENT.CONTENT. WTF
                if event.kind == .repost && event.content.prefix(2) == #"{""# {
                    if let noteInNote = try? decoder.decode(NEvent.self, from: event.content.data(using: .utf8, allowLossyConversion: false)!) {
                        _ = Event.saveEvent(event: noteInNote)
                        event.content = "#[0]"
                        if let firstTag = event.tags.first {
                            if firstTag.type == "e" {
                                event.tags[0] = NostrTag(["e", firstTag.id, "", "mention"])
                            }
                        }
                    }
                }
                
                let savedEvent = Event.saveEvent(event: event)
                
                if event.kind == .setMetadata {
                    Contact.saveOrUpdateContact(event: event)
                }
                
                // UPDATE THINGS THAT THIS EVENT RELATES TO. LIKES CACHE ETC (REACTIONS)
                if event.kind == .zapNote {
                    let _ = Event.updateZapTallyCache(savedEvent, context: context)
                }
            }
        }
    }
}

extension PreviewEnvironment {
    
    @MainActor func loadAccount() -> Bool {
//        guard !didLoad else { return false }
//        didLoad = true
        NRState.shared.loadAccounts()
        context.performAndWait {
            print("💄💄LOADING ACCOUNT")
            let account = Account(context: self.context)
            account.createdAt = Date()
            account.id = UUID()
            account.publicKey = "9be0be0e64d38a29a9cec9a5c8ef5d873c2bfa5362a4b558da5ff69bc3cbb81e"
            account.name = "Fabian"
            account.nip05 = "fabian@nostur.com"
            account.about = "Creatur of Nostur"
            account.picture = "https://profilepics.nostur.com/profilepic_v1/e358d89477e2303af113a2c0023f6e77bd5b73d502cf1dbdb432ec59a25bfc0f/profilepic.jpg?1682440972"
            account.banner = "https://profilepics.nostur.com/banner_v1/e358d89477e2303af113a2c0023f6e77bd5b73d502cf1dbdb432ec59a25bfc0f/banner.jpg?1682440972"
            NRState.shared.loadAccount(account)
            SettingsStore.shared.webOfTrustLevel = "WOT_OFF"
//            return account
        }
        return true
    }
    
    @MainActor func loadAccounts() {
        context.performAndWait {
            let account = Account(context: self.context)
            account.createdAt = Date()
            account.id = UUID()
            account.publicKey = "9be0be0e64d38a29a9cec9a5c8ef5d873c2bfa5362a4b558da5ff69bc3cbb81e"
            account.name = "Fabian"
            account.nip05 = "fabian@nostur.com"
            account.about = "Creatur of Nostur"
            account.picture = "https://profilepics.nostur.com/profilepic_v1/e358d89477e2303af113a2c0023f6e77bd5b73d502cf1dbdb432ec59a25bfc0f/profilepic.jpg?1682440972"
            account.banner = "https://profilepics.nostur.com/banner_v1/e358d89477e2303af113a2c0023f6e77bd5b73d502cf1dbdb432ec59a25bfc0f/banner.jpg?1682440972"
            
            let account2 = Account(context: self.context)
            account2.createdAt = Date()
            account2.id = UUID()
            account2.publicKey = "c118d1b814a64266730e75f6c11c5ffa96d0681bfea594d564b43f3097813844"
            account2.name = "Rookie"
            account2.about = "Second account"
            
            let account3 = Account(context: self.context)
            account3.createdAt = Date()
            account3.id = UUID()
            account3.publicKey = "afba415fa31944f579eaf8d291a1d76bc237a527a878e92d7e3b9fc669b14320"
            account3.name = "Explorer"
            account3.about = "Third account"
            
            
            let account4keys = NKeys.newKeys()
            let account4 = Account(context: self.context)
            account4.createdAt = Date()
            account4.id = UUID()
            account4.publicKey = account4keys.publicKeyHex()
            account4.privateKey = account4keys.privateKeyHex()
            account4.name = "The Poster"
            account4.about = "4th account, with private key"
            
            let account5keys = NKeys.newKeys()
            let account5 = Account(context: self.context)
            account5.createdAt = Date()
            account5.id = UUID()
            account5.publicKey = account5keys.publicKeyHex()
            account5.privateKey = account5keys.privateKeyHex()
            account5.name = "Alt"
            account5.about = "5th account, with private kay"
        }
        
        NRState.shared.loadAccounts()
        if let account = NRState.shared.accounts.first {
            NRState.shared.loadAccount(account)
        }
    }
    
    func loadContacts() {
        context.performAndWait {
            self.parseMessages(testKind0Events())
        }
    }
    
    func loadContactLists() {
        context.performAndWait {
            self.parseMessages(testKind3Events())
        }
    }
    
    func loadPosts() {
        context.performAndWait {
            self.parseMessages(testKind1Events())
            self.parseMessages(testSnowden())
        }
    }

    func loadReposts() {
        context.performAndWait {
            self.parseMessages(testKind6Events())
        }
    }
    
    func loadKind1063() {
        context.performAndWait {
            self.parseMessages(testKind1063())
        }
    }
    
    func loadHighlights() {
        context.performAndWait {
            self.parseMessages(testHighlights())
        }
    }
    
    func loadBadges() {
        context.performAndWait {
            self.parseMessages(testBadges())
        }
    }
    
    func loadDMs() {
        context.performAndWait {
            self.parseMessages(testDMs())
        }
    }
        
    func loadDMs2() {
        context.performAndWait {
            self.parseMessages(testDMs2())
        }
    }
    
    
    func loadMedia() {
        context.performAndWait {
            self.parseMessages(testMedia())
        }
    }
    
    func loadArticles() {
        context.performAndWait {
            self.parseMessages(testArticles())
        }
    }
    
    func loadFollowers() {
        guard let account = account() else { L.og.debug("Preview.loadFollowers - missing Account"); return }
        context.performAndWait {
            if let clNevent = PreviewFetcher.fetchEvents(account.publicKey, kind: 3, context: context).first?.toNEvent() {
                
                let pTags = clNevent.pTags()
                var existingAndCreatedContacts = [Contact]()
                for pTag in pTags {
                    let contact = Contact.fetchByPubkey(pTag, context: context)
                    guard contact == nil else {
                        // Skip if we already have a contact
                        existingAndCreatedContacts.append(contact!)
                        continue
                    }
                    // Else create a new one
                    let newContact = Contact(context: context)
                    newContact.pubkey = pTag
                    newContact.metadata_created_at = 0
                    newContact.updated_at = 0
                    existingAndCreatedContacts.append(newContact)
                }
                account.addToFollows(NSSet(array: existingAndCreatedContacts))
            }
        }
    }
    
    func loadNewFollowersNotification() {
        guard let account = account() else { L.og.debug("Preview.loadNewFollowersNotification - missing Account"); return }
        context.performAndWait {
            let followers = "84dee6e676e5bb67b4ad4e042cf70cbd8681155db535942fcc6a0533858a7240,32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245,5195320c049ccff15766e070413bbec1c021bca03ee022838724a8ffb680bf3a,3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24,3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24,febbaba219357c6c64adfa2e01789f274aa60e90c289938bfc80dd91facb2899,aff9a9f017f32b2e8b60754a4102db9d9cf9ff2b967804b50e070780aa45c9a8".split(separator: ",").map { String($0) }
            let _ = PersistentNotification.create(pubkey: account.publicKey, followers: followers, context: context)
        }
    }

    func loadZapsNotifications() {
        guard let account = account() else { L.og.debug("Preview.loadZapsNotifications - missing Account"); return }
        context.performAndWait {
            let content = "Zap failed for [post](nostur:e:78b8d514554a03dadd366e920768e439d3a45495ca3efa89010229aae823c07c) Something went wrong while paying invoice: not enough balance. Make sure you have at least 1% reserved for potential fees"
            let _ = PersistentNotification.createFailedNWCZap(pubkey: account.publicKey, message: content, context: context)
        }
    }
    
    // Needs account(s) and some kind = 1 events first
    func loadBookmarks() {
        context.performAndWait {
            let randomTextEventsR = Event.fetchRequest()
            randomTextEventsR.fetchLimit = 10
            randomTextEventsR.fetchOffset = Int.random(in: 0..<100)
            randomTextEventsR.predicate = NSPredicate(format: "kind == 1")
            let randomTextEvents = try? context.fetch(randomTextEventsR)
            if let randomTextEvents {
                for _ in 0..<10 {
                    if let random = randomTextEvents.randomElement() {
                        NRState.shared.accounts.randomElement()?
                            .addToBookmarks(random)
                    }
                }
            }
        }
    }
    
    // Needs account(s) and some kind = 1 events first
    func loadPrivateNotes() {
        context.performAndWait {
            let randomTextEventsR = Event.fetchRequest()
            randomTextEventsR.fetchLimit = 10
            randomTextEventsR.fetchOffset = Int.random(in: 0..<100)
            randomTextEventsR.predicate = NSPredicate(format: "kind == 1")
            let randomTextEvents = try? context.fetch(randomTextEventsR)
            if let randomTextEvents {
                for _ in 0..<10 {
                    let privateNote = PrivateNote(context: context)
                    privateNote.content = ["Some more text here, I think I need to fix this in some way or another, I don't know how yet. But this text is a bit longer.","I made a private note here\nYo!","I made a private note here\nWith some more lines\n\nCool", "This is good"].randomElement()!
                    privateNote.by = NRState.shared.accounts.randomElement()
                    privateNote.post = randomTextEvents.randomElement()
                    privateNote.createdAt = Date.now
                    privateNote.updatedAt = Date.now
                }
            }
        }
    }
    
    func loadRelays() {
        context.performAndWait {
            let relay = Relay(context: context)
            relay.url = "ws://localhost:3000"
            relay.createdAt = Date()
            relay.id = UUID()
            relay.read = false
            relay.write = false
            
            let relay2 = Relay(context: context)
            relay2.url = "ws://localhost:3001"
            relay2.createdAt = Date()
            relay2.id = UUID()
            relay2.read = false
            relay2.write = false
        }
    }
    
    func loadNosturLists() {
        context.performAndWait {
            NosturList.generateExamples(context: context)
        }
    }
    
    func loadRelayNosturLists() {
        context.performAndWait {
            NosturList.generateRelayExamples(context: context)
        }
    }
    
    func loadRepliesAndReactions() {
        context.performAndWait {
            self.parseMessages(testRepliesAndReactions())
        }
    }
    
    func loadZaps() {
        context.performAndWait {
            self.parseMessages(testZaps())
        }
    }
    
    func loadNotifications() {
        context.performAndWait {
            self.parseMessages(testNotifications())
        }
    }
    
    func loadCommunities() {
        context.performAndWait {
            self.parseMessages(testCommunities())
        }
    }
    
    // Needs account, some kind = 1 events, and some contacts first
    func loadBlockedAndMuted() {
        guard let account = account() else { L.og.debug("Preview.loadBlockedAndMuted - missing Account"); return }
        context.performAndWait {
            let randomContactsR = Contact.fetchRequest()
            randomContactsR.fetchLimit = 10
            randomContactsR.fetchOffset = Int.random(in: 0..<100)
            let randomContacts = try? context.fetch(randomContactsR)
            if let randomContacts {
                account.blockedPubkeys_.append(contentsOf:randomContacts.randomSample(count: 3).map { $0.pubkey })
                
            }
            
            let randomTextEventsR = Event.fetchRequest()
            randomTextEventsR.fetchLimit = 10
            randomTextEventsR.fetchOffset = Int.random(in: 0..<100)
            randomTextEventsR.predicate = NSPredicate(format: "kind == 1")
            let randomTextEvents = try? context.fetch(randomTextEventsR)
            if let randomTextEvents {
                for _ in 0..<10 {
                    if let random = randomTextEvents.randomElement() {
                        account.mutedRootIds_.append(random.id)
                    }
                }
            }
        }
    }
    
    func defaultSetup() {
        context.performAndWait {

            var messages:[String] = []
            messages.append(contentsOf: test1())
            
            messages.append(contentsOf: testMinimal())
            print("1 \(messages.count)")
            messages.append(contentsOf: testKind0Events())
            print("2 \(messages.count)")
            messages.append(contentsOf: testKind3Events())
            print("3 \(messages.count)")
            messages.append(contentsOf: testKind1Events())
            print("4 \(messages.count)")
//            messages.append(contentsOf: testKindMixedOldDunnoEvents())
            print("5 \(messages.count)")
            messages.append(contentsOf: testRepliesAndReactions())
            print("6 \(messages.count)")
//            messages.append(contentsOf: testSnowden())
            print("7 \(messages.count)")
//            messages.append(contentsOf: testBadges())
            print("8 \(messages.count)")
    //        messages.append(contentsOf: testMentions())
            print("9 \(messages.count)")
            messages.append(contentsOf: testKind6Events())
            print("10 \(messages.count)")
//            messages.append(contentsOf: testEfilter())
            print("11 \(messages.count)")
            messages.append(contentsOf: testZaps())
            print("12 \(messages.count)")
            messages.append(contentsOf: testSomeFakeAndRealZaps())
            print("13 \(messages.count)")
//            messages.append(contentsOf: testNotifications())
            print("15 \(messages.count)")
//            messages.append(contentsOf: testThread())
            print("16 \(messages.count)")
            messages.append(contentsOf: testDMs())
            print("17 \(messages.count)")
            messages.append(contentsOf: testTimelineThreads())
            print("19 \(messages.count)")
            messages.append(contentsOf: testHighlights())
            print("20 \(messages.count)")
            messages.append(contentsOf: testKind1063())
            print("21 \(messages.count)")
            
            print ("☢️☢️☢️ LOADED (SHOULD ONLY APPEAR ONCE) ☢️☢️☢️")
        }
    }

}

public typealias PreviewSetup = (_ pe:PreviewEnvironment) -> ()

struct PreviewContainer<Content: View>: View {
    let pe = PreviewEnvironment.shared
    var setup:PreviewSetup? = nil
    let previewDevice:PreviewDevice
    var content: () -> Content
    @State var didSetup = false
    
    init(_ setup:PreviewSetup? = nil, previewDevice:PreviewDevice? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.setup = setup
        self.previewDevice = previewDevice ?? PreviewDevice(rawValue: PREVIEW_DEVICE)
        self.content = content
    }
    
    var body: some View {
        VStack(spacing:0) {
            if didSetup {
                content()
                    .environment(\.managedObjectContext, pe.context)
                    .environmentObject(NRState.shared)
                    .environmentObject(pe.sp)
                    .environmentObject(pe.er)
                    .environmentObject(pe.ss)
                    .environmentObject(pe.sm)
                    .environmentObject(pe.tm)
                    .environmentObject(pe.dim)
                    .environmentObject(pe.theme)
                    .environmentObject(pe.dim)
                    .buttonStyle(NRButtonStyle(theme: pe.theme))
                    .tint(pe.theme.accent)
            }
            else {
                EmptyView()
            }
        }
        .onAppear {
            if pe.loadAccount() {
                if let setup {
                    setup(pe)
                }
            }
            didSetup = true
        }
        .previewDevice(previewDevice)
    }
}

struct PreviewFetcher {
    
    static let viewContext = DataProvider.shared().container.viewContext
    
    static func allContacts(context:NSManagedObjectContext? = nil) -> [Contact] {
        let request = NSFetchRequest<Contact>(entityName: "Contact")
        request.sortDescriptors = []

        return try! (context ?? PreviewFetcher.viewContext).fetch(request)
    }
    
    static func fetchEvents(_ pubkey:String, kind:Int? = nil, context:NSManagedObjectContext? = nil) -> [Event] {
        let request = Event.fetchRequest()
//        request.entity = Event.entity()
        if (kind != nil) {
            request.predicate = NSPredicate(format: "pubkey == %@ AND kind == %d", pubkey, kind!)
        } else {
            request.predicate = NSPredicate(format: "pubkey == %@", pubkey)
        }
        
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Event.created_at, ascending: false)]
        
        return try! (context ?? PreviewFetcher.viewContext).fetch(request)
    }
    
    static func fetchEvents(_ pubkeys:Set<String>, kind:Int? = nil, context:NSManagedObjectContext? = nil) -> [Event] {
        let request = Event.fetchRequest()
        if let kind {
            request.predicate = NSPredicate(format: "pubkey IN %@ AND kind == %d", pubkeys, kind)
        } else {
            request.predicate = NSPredicate(format: "pubkey IN %@", pubkeys)
        }
        
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Event.created_at, ascending: false)]
        
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request)) ?? []
    }
    
    static func fetchRelays(context:NSManagedObjectContext? = nil) -> [Relay] {
        let request = Relay.fetchRequest()
        request.predicate = NSPredicate(value: true)
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request)) ?? []
    }
    
    static func fetchAccount(_ pubkey:String? = nil, context:NSManagedObjectContext? = nil) -> Account? {
        let accountKey = pubkey ?? PREVIEW_ACCOUNT_ID
        let request = Account.fetchRequest()
        request.predicate = NSPredicate(format: "publicKey == %@", accountKey)
        request.sortDescriptors = []
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request))?.first
    }
    
    static func fetchEvent(_ id:String? = nil, context:NSManagedObjectContext? = nil) -> Event? {
        let request = Event.fetchRequest()
        if let id {
            request.predicate = NSPredicate(format: "id == %@", id)
        }
        else {
            request.predicate = NSPredicate(format: "kind == 1")
        }
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request))?.randomElement()
    }
    
    static func fetchNRPost(_ id:String? = nil, context:NSManagedObjectContext? = nil, withReplyTo:Bool = false, withParents:Bool = false, withReplies:Bool = false, plainText:Bool = false) -> NRPost? {
        if let event = fetchEvent(id) {
            if (withParents) {
                event.parentEvents = Event.getParentEvents(event)
            }
            return NRPost(event: event, withReplyTo: withReplyTo, withParents: withParents, withReplies: withReplies, plainText: plainText)
        }
        return nil
    }
    
    static func fetchContact(_ pubkey:String? = nil, context:NSManagedObjectContext? = nil) -> Contact? {
        let request = Contact.fetchRequest()
        if let pubkey {
            request.predicate = NSPredicate(format: "pubkey == %@", pubkey)
            request.fetchLimit = 1
        }
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request))?.randomElement()
    }
    
    static func fetchNRContact(_ pubkey:String? = nil, context:NSManagedObjectContext? = nil) -> NRContact? {
        let request = Contact.fetchRequest()
        if let pubkey {
            request.predicate = NSPredicate(format: "pubkey == %@", pubkey)
        }
        if let contact = (try? (context ?? PreviewFetcher.viewContext).fetch(request))?.randomElement() {
           return NRContact(contact: contact)
        }
        return nil
    }
    
    static func fetchList(context:NSManagedObjectContext? = nil) -> NosturList? {
        let request = NosturList.fetchRequest()
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request))?.randomElement()
    }
    
    static func fetchLists(context:NSManagedObjectContext? = nil) -> [NosturList] {
        let request = NosturList.fetchRequest()
        return (try? (context ?? PreviewFetcher.viewContext).fetch(request)) ?? []
    }
    
    
    static func fetchPersistentNotification(_ id:String? = nil, context:NSManagedObjectContext? = nil) -> PersistentNotification? {
        let request = PersistentNotification.fetchRequest()
        if let id {
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PersistentNotification.createdAt, ascending: false)]
            request.predicate = NSPredicate(format: "id == %@", id)
        } else {
            request.predicate = NSPredicate(value: true)
        }
        return try! (context ?? PreviewFetcher.viewContext).fetch(request).first
    }
}
