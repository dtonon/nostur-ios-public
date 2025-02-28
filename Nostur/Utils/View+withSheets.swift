//
//  View+withSheets.swift
//  Nostur
//
//  Created by Fabian Lachman on 13/03/2023.
//

import SwiftUI
import CoreData
import UIKit
import Combine

public extension View {
    func withSheets() -> some View {
        modifier(WithSheets())
    }
}

private struct WithSheets: ViewModifier {
    @EnvironmentObject private var theme:Theme
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var dim:DIMENSIONS
    @Environment(\.colorScheme) private var colorScheme
    
    
    // Sheet contents (item based)
    @State private var privateNote:PrivateNote? = nil
    @State private var post:Event? = nil
    @State private var contact:Contact? = nil
    @State private var fullImage:FullScreenItem? = nil
    @State private var reportPost:ReportPost? = nil
    @State private var reportContact:ReportContact? = nil
    @State private var addRemoveContactFromList:Contact? = nil
    
    // Confirmation dialogs
    @State private var restoreContactSheet = false
    @State private var removed:RemovedPubkeys? = nil
    
    @State private var deletePostSheet = false
    @State private var deletePost:DeletePost? = nil
    
    // new post/quote post / new reply
    @State private var replyToEvent:EventNotification? = nil
    @State private var quoteOrRepostEvent:Event? = nil
    @State private var quotePostEvent:Event? = nil
    
    // Zap sheet
    @State private var paymentInfo:PaymentInfo? = nil
    
    // New highlight sheet
    @State private var newHighlight:NewHighlight? = nil
    
    @State private var contextMenuNrPost:NRPost? = nil
    @State private var zapCustomizerSheetInfo:ZapCustomizerSheetInfo? = nil
    
    // Share post screenshot
    @State private var sharablePostImage:ShareablePostImage? = nil
    @State private var screenshotRenderer:AnyCancellable? = nil
    //    @State private var renderer:ImageRenderer<AnyView>? = nil
    @State private var shareableWeblink:ShareableWeblink? = nil
    
    @State private var miniProfileSheetInfo:MiniProfileSheetInfo? = nil
    @State private var miniProfileAnimateIn = false
    
    func body(content: Content) -> some View {
        content
            .onReceive(receiveNotification(.fullScreenView)) { notification in
                let item = notification.object as! FullScreenItem
                fullImage = item
            }
            .fullScreenCover(item: $fullImage) { f in
                FullImageViewer(fullImageURL: f.url, galleryItem: f.galleryItem)
                    .environmentObject(theme)
                    .environmentObject(dim)
                    .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.editingPrivateNote)) { notification in
                let note = notification.object as! PrivateNote
                self.privateNote = note
            }
            .sheet(item: $privateNote) { note in
                EditPrivateNoteSheet(privateNote: note)
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.newPrivateNoteOnPost)) { notification in
                let id = notification.object as! String
                post = try! Event.fetchEvent(id: id, context: viewContext)
            }
            .sheet(item: $post) { post in
                NewPrivateNoteSheet(post: post)
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.newPrivateNoteOnContact)) { notification in
                let pubkey = notification.object as! String
                contact = Contact.fetchByPubkey(pubkey, context: viewContext)
            }
            .sheet(item: $contact) { contact in
                NewPrivateNoteSheet(contact: contact)
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.reportPost), perform: { notification in
                let post = notification.object as! NRPost
                reportPost = ReportPost(nrPost: post)
            })
            .sheet(item: $reportPost, content: { reportPost in
                NavigationStack {
                    ReportPostSheet(nrPost: reportPost.nrPost)
                        .environmentObject(dim)
                        .environmentObject(NRState.shared)
                        .environmentObject(theme)
                }
                .presentationBackground(theme.background)
            })
        
            .onReceive(receiveNotification(.reportContact), perform: { notification in
                let contact = notification.object as! Contact
                reportContact = ReportContact(contact: contact)
            })
            .sheet(item: $reportContact, content: { reportContact in
                NavigationStack {
                    ReportContactSheet(contact: reportContact.contact)
                        .environmentObject(theme)
                }
                .presentationBackground(theme.background)
            })
        
            .onReceive(receiveNotification(.requestConfirmationChangedFollows)) { notification in
                let removed = notification.object as! RemovedPubkeys
                self.removed = removed
                self.restoreContactSheet = true
            }
            .confirmationDialog("It looks like \(removed?.pubkeys.count ?? 0) contacts were removed from your following list, perhaps from another nostr app\(removed?.namesString != nil ? ": \(removed?.namesString ?? "")" : "")", isPresented: $restoreContactSheet, titleVisibility: .visible,  actions: {
                Button("Remove \(removed?.pubkeys.count ?? 0) contacts", role: .destructive) {
                    guard let removed = self.removed else { return }
                    FollowingGuardian.shared.removeFollowing(removed.pubkeys)
                }
                Button("Restore \(removed?.pubkeys.count ?? 0) contacts") {
                    FollowingGuardian.shared.restoreFollowing(removed:removed?.pubkeys ?? [])
                }
                Button("Ignore", role: .cancel) {
                    FollowingGuardian.shared.restoreFollowing(removed:removed?.pubkeys ?? [], republish: false)
                }
                .keyboardShortcut(.defaultAction)
            })
        
            .onReceive(receiveNotification(.requestDeletePost)) { notification in
                let eventId = notification.object as! String
                self.deletePost = DeletePost(eventId: eventId)
                self.deletePostSheet = true
            }
            .confirmationDialog("It's up to relays and other apps to honor your request", isPresented: $deletePostSheet, titleVisibility: .visible,  actions: {
                Button("Request delete", role: .destructive) {
                    guard let account = account() else { return }
                    guard let deletePost = self.deletePost else { return }
                    
                    if account.isNC {
                        var deletion = EventMessageBuilder.makeDeleteEvent(eventId: deletePost.eventId)
                        deletion.publicKey = account.publicKey
                        deletion = deletion.withId()
                        
                        NSecBunkerManager.shared.requestSignature(forEvent: deletion, usingAccount: account, whenSigned: { signedEvent in
                            Unpublisher.shared.publishNow(signedEvent)
                        })
                    }
                    else {
                        guard let signedDeletion = NRState.shared.loggedInAccount?.deletePost(deletePost.eventId) else {
                            return
                        }
                        Unpublisher.shared.publishNow(signedDeletion)
                    }
                }
            })
        
            .onReceive(receiveNotification(.createNewReply)) { notification in
                guard isFullAccount() else { showReadOnlyMessage(); return }
                replyToEvent = notification.object as? EventNotification
            }
        
            .onReceive(receiveNotification(.createNewQuoteOrRepost)) { notification in
                guard isFullAccount() else { showReadOnlyMessage(); return }
                quoteOrRepostEvent = notification.object as? Event
            }
        
            .sheet(item: $replyToEvent) { eventNotification in
                NavigationStack {
                    if let account = account(), account.isNC {
                        WithNSecBunkerConnection(nsecBunker: NSecBunkerManager.shared) {
                            NewReply(replyTo: eventNotification.event)
                                .environmentObject(NRState.shared)
                                .environmentObject(dim)
                        }
                        .environmentObject(theme)
                    }
                    else {
                        NewReply(replyTo: eventNotification.event)
                            .environmentObject(NRState.shared)
                            .environmentObject(dim)
                            .environmentObject(theme)
                    }
                }
                .presentationBackground(theme.background)
            }
        
            .sheet(item: $quoteOrRepostEvent) { event in
                if let account = account(), account.isNC {
                    WithNSecBunkerConnection(nsecBunker: NSecBunkerManager.shared) {
                        QuoteOrRepostChoiceSheet(originalEvent:event, quotePostEvent:$quotePostEvent)
                            .environmentObject(NRState.shared)
                            .environmentObject(dim)
                            .presentationDetents([.height(200)])
                            .presentationDragIndicator(.visible)
                    }
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
                }
                else {
                    QuoteOrRepostChoiceSheet(originalEvent:event, quotePostEvent:$quotePostEvent)
                        .environmentObject(NRState.shared)
                        .environmentObject(dim)
                        .presentationDetents([.height(200)])
                        .presentationDragIndicator(.visible)
                        .environmentObject(theme)
                        .presentationBackground(theme.background)
                }
            }
        
            .sheet(item: $quotePostEvent) { quotePostEvent in
                NavigationStack {
                    if let account = account(), account.isNC {
                        WithNSecBunkerConnection(nsecBunker: NSecBunkerManager.shared) {
                            NewQuoteRepost(quotingEvent: quotePostEvent)
                                .environmentObject(NRState.shared)
                                .environmentObject(dim)
                        }
                        .environmentObject(theme)
                    }
                    else {
                        NewQuoteRepost(quotingEvent: quotePostEvent)
                            .environmentObject(NRState.shared)
                            .environmentObject(dim)
                            .environmentObject(theme)
                    }
                }
                .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.showZapSheet)) { notification in
                let paymentInfo = notification.object as! PaymentInfo
                self.paymentInfo = paymentInfo
            }
            .sheet(item: $paymentInfo) { paymentInfo in
                PaymentAmountSelector(paymentInfo:paymentInfo)
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
            .onReceive(receiveNotification(.addRemoveToListsheet)) { notification in
                let contact = notification.object as! Contact
                addRemoveContactFromList = contact
            }
            .sheet(item: $addRemoveContactFromList) { contact in
                AddRemoveToListsheet(contact: contact)
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
        // New highlight
            .onReceive(receiveNotification(.newHighlight)) { notification in
                let newHighlight = notification.object as! NewHighlight
                self.newHighlight = newHighlight
            }
            .sheet(item: $newHighlight) { newHighlight in
                NavigationStack {
                    HighlightComposer(highlight: newHighlight)
                        .environmentObject(NRState.shared)
                        .environmentObject(theme)
                }
                .presentationBackground(theme.background)
            }
        
        // Lazy note context menu (because Menu() on every post is slow???)
            .onReceive(receiveNotification(.showNoteMenu)) { notification in
                let nrPost = notification.object as! NRPost
                self.contextMenuNrPost = nrPost
            }
            .sheet(item: $contextMenuNrPost) { nrPost in
                LazyNoteMenuSheet(nrPost: nrPost)
                    .environmentObject((NRState.shared))
                    .presentationDetents([.medium])
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
        // Zap customizer sheet
            .onReceive(receiveNotification(.showZapCustomizerSheet)) { notification in
                let zapCustomizerSheetInfo = notification.object as! ZapCustomizerSheetInfo
                self.zapCustomizerSheetInfo = zapCustomizerSheetInfo
            }
            .sheet(item: $zapCustomizerSheetInfo) { zapCustomizerSheetInfo in
                ZapCustomizerSheet(name: zapCustomizerSheetInfo.name, customZapId: zapCustomizerSheetInfo.customZapId)
                    .environmentObject(NRState.shared)
                    .presentationDetents([.large])
                    .environmentObject(theme)
                    .presentationBackground(theme.background)
            }
        
        // Share post screenshot
            .onReceive(receiveNotification(.sharePostScreenshot)) { notification in
                let nrPost = notification.object as! NRPost
                nrPost.following = true // Force load image for screenshot...
                nrPost.isPreview = true // Will hide 'Sent to X relays' in footer
                
                let renderer = ImageRenderer(content:
                                                VStack(spacing:0) {
                    if nrPost.kind == 30023 {
                        ArticleView(nrPost, isDetail: true, fullWidth: false, hideFooter: false)
                    }
                    else {
                        PostRowDeletable(nrPost: nrPost, missingReplyTo: true, connect: nrPost.replyToId != nil ? .top : nil, fullWidth: false, isDetail: true)
                    }
                    Group {
                        if SettingsStore.shared.includeSharedFrom {
                            Text("Shared from **Nostur**")
                            Text("A nostr client for iOS & macOS - nostur.com")
                                .padding(.bottom, 5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(Color.secondary)
                }
                    .frame(width: 600)
                    .padding(10)
                                             
                    .background(
                        RoundedRectangle(cornerRadius: 10.0)
                            .foregroundColor(theme.background)
                            .shadow(color: Color("ShadowColor").opacity(0.25), radius: 5)
                    )
                                             
                        .padding(.horizontal, DIMENSIONS.POST_ROW_HPADDING)
                        .padding(.vertical, 10)
                        .environmentObject(dim)
                        .environmentObject(NRState.shared)
                        .environment(\.managedObjectContext, DataProvider.shared().viewContext)
                        .environment(\.colorScheme, colorScheme)
                        .environmentObject(theme)
                )
                
                
                renderer.scale = 2.0
                
                // First render:
                guard renderer.uiImage != nil else { return }
                
                // We need another render after any async stuff is loaded (inline quotes, images...)
                screenshotRenderer = renderer.objectWillChange
                    .debounce(for: 0.35, scheduler: RunLoop.main)
                    .sink {
                        guard let uiImage = renderer.uiImage else { return }
                        
                        // Trigger the share sheet
                        self.sharablePostImage = ShareablePostImage(image: uiImage, title: "Screenshot", subtitle: "Screenshot")
                        screenshotRenderer = nil
                    }
                
            }
            .sheet(item: $sharablePostImage) { sharablePostImage in
                ActivityView(activityItems: [sharablePostImage])
            }
        
        // Share post weblink
            .onReceive(receiveNotification(.shareWeblink)) { notification in
                let nrPost = notification.object as! NRPost
                
                let relays = nrPost.relays.split(separator: " ").map { String($0) }
                    .filter {
                        // don't inculude localhost / 127.0.x.x / ws:// (non-wss)
                        !$0.contains("/localhost") && !$0.contains("ws:/") && !$0.contains("s:/127.0")
                    }
                    .map { relay in
                        // first try to put just scheme+hostname as relay. because extra parameters in url can be irrelevant
                        if let url = URL(string: relay), let scheme = url.scheme, let host = url.host {
                            return (scheme + "://" + host)
                        }
                        else {
                            return relay
                        }
                    }
                
                if nrPost.kind == 30023 {
                    guard let sharable = try? ShareableIdentifier(prefix: "naddr", kind: nrPost.kind, pubkey: nrPost.pubkey, dTag: nrPost.mainEvent.dTag, relays: relays) else { return }
                    let url = "https://njump.me/\(sharable.bech32string)"
                    self.shareableWeblink = ShareableWeblink(url: url)
                }
                else {
                    guard let sharable = try? ShareableIdentifier(prefix: "nevent", kind: nrPost.kind, pubkey: nrPost.pubkey, eventId: nrPost.id, relays: relays) else { return }
                    let url = "https://njump.me/\(sharable.bech32string)"
                    self.shareableWeblink = ShareableWeblink(url: url)
                }
            }
            .sheet(item: $shareableWeblink) { shareableWeblink in
                ActivityView(activityItems: [NSURL(string: shareableWeblink.url)!])
            }
        
            .onReceive(receiveNotification(.showMiniProfile)) { notification in
                let miniProfileSheetInfo = notification.object as! MiniProfileSheetInfo
                self.miniProfileSheetInfo = miniProfileSheetInfo
            }
        
            .overlay(alignment:.topLeading) {
                if let m = miniProfileSheetInfo {
                    ZStack(alignment:.topLeading) {
                        Rectangle()
                            .fill(.thinMaterial)
                            .opacity(0.8)
                            .zIndex(50)
                            .onTapGesture {
                                miniProfileSheetInfo = nil
                            }
                            .onAppear {
                                miniProfileAnimateIn = true
                            }
                        ProfileOverlayCardContainer(pubkey: m.pubkey, contact: m.contact, zapEtag: m.zapEtag)
                            .scaleEffect(miniProfileAnimateIn ? 1.0 : 0.25, anchor: .leading)
                            .opacity(miniProfileAnimateIn ? 1.0 : 0.15)
                            .animation(.easeInOut(duration: 0.15), value: miniProfileAnimateIn)
                            .offset(x: 0.0, y: min(max(m.location.y - 60,50), UIScreen.main.bounds.height - 200))
                            .zIndex(50)
                    }
                    .onDisappear {
                        miniProfileAnimateIn = false
                    }
                    .onReceive(receiveNotification(.dismissMiniProfile)) { _ in
                        miniProfileSheetInfo = nil
                    }
                }
            }
    }
}

struct MiniProfileSheetInfo: Identifiable, Equatable {
    let id = UUID()
    let pubkey: String
    var contact: NRContact?
    let zapEtag: String
    let location: CGPoint
    
    static func == (lhs: MiniProfileSheetInfo, rhs: MiniProfileSheetInfo) -> Bool {
        lhs.id == rhs.id
    }
}

struct EventNotification: Identifiable {
    let id = UUID()
    let event:Event // bg
}

import LinkPresentation
import UniformTypeIdentifiers

final class ShareablePostImage: NSObject, UIActivityItemSource, Identifiable {
    let id = UUID()
    private let image: UIImage
    private var pngData: Data?
    private let title: String
    private let subtitle: String?
    
    init(image: UIImage, title: String, subtitle: String? = nil) {
        self.image = image
        self.pngData = image.pngData()
        self.title = title
        self.subtitle = subtitle
        
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return title
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if pngData != nil {
            return pngData
        }
        return image
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        if pngData != nil {
            return UTType.png.identifier
        }
        return UTType.jpeg.identifier
    }
    
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        
        metadata.iconProvider = NSItemProvider(object: self.image)
        metadata.title = title
        if let subtitle = subtitle {
            metadata.originalURL = URL(fileURLWithPath: subtitle)
        }
        
        return metadata
    }
}

struct ShareableWeblink: Identifiable {
    let id = UUID()
    let url:String
}

struct RemovedPubkeys: Identifiable {
    let pubkeys:Set<String>
    let id = UUID()
    var namesString: String?
}

struct ReportPost: Identifiable {
    let id = UUID()
    let nrPost:NRPost
}

struct ReportContact: Identifiable {
    let id = UUID()
    let contact:Contact
}


struct DeletePost: Identifiable {
    let id = UUID()
    let eventId:String
}

struct NewHighlight: Identifiable {
    let id = UUID()
    let url:String
    let selectedText:String
    var title:String? = nil
}

struct Previews_View_withSheets_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in
            pe.loadPosts()
        }) {
            VStack {
                Button("Test") {
                    sendNotification(
                        .requestConfirmationChangedFollows,
                        Set(["dede","dededed"])
                    )
                }
                Color.clear.withSheets()
            }
        }
    }
}
