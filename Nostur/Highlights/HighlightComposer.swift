//
//  HighlightComposer.swift
//  Nostur
//
//  Created by Fabian Lachman on 29/04/2023.
//

import SwiftUI

struct HighlightComposer: View {
    @EnvironmentObject private var la:LoggedInAccount
    @EnvironmentObject private var theme:Theme
    @Environment(\.dismiss) private var dismiss
    public var highlight:NewHighlight
    @State private var selectedAuthor:Contact?
    @State private var isAuthorSelectionShown = false
    @State private var activeAccount:Account? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            if let account = activeAccount {
                VStack {
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        PostAccountSwitcher(activeAccount: account, onChange: { account in
                            activeAccount = account
                        }).equatable()

                        VStack(alignment:.leading, spacing: 3) {
                            HStack { // name + reply + context menu
                                PreviewHeaderView(authorName: account.anyName)
                                Spacer()
                            }

                            
                            VStack {
                                Text(highlight.selectedText)
                                    .italic()
                                    .padding(20)
                                    .overlay(alignment:.topLeading) {
                                        Image(systemName: "quote.opening")
                                            .foregroundColor(Color.secondary)
                                    }
                                    .overlay(alignment:.bottomTrailing) {
                                        Image(systemName: "quote.closing")
                                            .foregroundColor(Color.secondary)
                                    }
                                
                                if let selectedAuthor = selectedAuthor {
                                    HStack {
                                        Spacer()
                                        PFP(pubkey: selectedAuthor.pubkey, contact: selectedAuthor, size: 20)
                                        Text(selectedAuthor.authorName)
                                    }
                                    .padding(.trailing, 40)
                                }
                                HStack {
                                    Spacer()
                                    if let md = try? AttributedString(markdown:"[\(highlight.url)](\(highlight.url))") {
                                        Text(md)
                                            .lineLimit(1)
                                            .font(.caption)
                                    }
                                }
                                .padding(.trailing, 40)
                            }
                            .padding(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(.regularMaterial, lineWidth: 1)
                            )
                            PreviewFooterFragmentView()
                        }
                    }
                    .padding(10)
                    Divider()
                    Spacer()
                }
                .padding(.top, 20)
                .navigationTitle(String(localized:"Share highlight", comment:"Navigation title for screen to Share a Highlighted Text"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack {
                            if selectedAuthor != nil {
                                Button(String(localized:"Remove author", comment: "Button to Remove author from Highlight")) { selectedAuthor = nil }
                            }
                            else {
                                Button(String(localized:"Include author", comment: "Button to include author in Highlight")) { isAuthorSelectionShown = true }
                            }
                            Button(String(localized:"Post.verb", comment: "Button to post a highlight")) { send() }
                                .buttonStyle(NRButtonStyle(theme: Theme.default, style: .borderedProminent))
                        }
                    }
                }
                .sheet(isPresented: $isAuthorSelectionShown) {
                    NavigationStack {
                        ContactsSearch(followingPubkeys: follows(),
                                       prompt: "Search", onSelectContact: { selectedContact in
                            selectedAuthor = selectedContact
                            isAuthorSelectionShown = false
                        })
                        .equatable()
                        .navigationTitle(String(localized:"Find author", comment:"Navigation title of Find author screen"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    isAuthorSelectionShown = false
                                }
                            }
                        }
                    }
                    .presentationBackground(theme.background)
                }
            }
        }
        .onAppear {
            activeAccount = la.account
        }
    }
    
    func send() {
        guard let account = activeAccount else { return }
        guard isFullAccount(account) else { showReadOnlyMessage(); return }
        var nEvent = NEvent(content: highlight.selectedText)
        nEvent.createdAt = NTimestamp.init(date: Date())
        nEvent.kind = .highlight
        if let selectedAuthor = selectedAuthor {
            nEvent.tags.append(NostrTag(["p", selectedAuthor.pubkey]))
        }
        nEvent.tags.append(NostrTag(["r", highlight.url]))
                
        let cancellationId = UUID()
        if account.isNC {
            nEvent.publicKey = account.publicKey
            nEvent = nEvent.withId()
            
            // Save unsigned event:
            bg().perform {
                let savedEvent = Event.saveEvent(event: nEvent, flags: "nsecbunker_unsigned")
                savedEvent.cancellationId = cancellationId
                DispatchQueue.main.async {
                    sendNotification(.newPostSaved, savedEvent)
                }
                DataProvider.shared().bgSave()
                dismiss()
                DispatchQueue.main.async {
                    NSecBunkerManager.shared.setAccount(account)
                    NSecBunkerManager.shared.requestSignature(forEvent: nEvent, usingAccount: account, whenSigned: { signedEvent in
                        bg().perform {
                            savedEvent.sig = signedEvent.signature
                            savedEvent.flags = "awaiting_send"
                            savedEvent.cancellationId = cancellationId
                            savedEvent.updateNRPost.send(savedEvent)
                            DispatchQueue.main.async {
                                _ = Unpublisher.shared.publish(signedEvent, cancellationId: cancellationId)
                            }
                        }
                    })
                }
            }
        }
        else if let signedEvent = try? account.signEvent(nEvent) {
            bg().perform {
                let savedEvent = Event.saveEvent(event: signedEvent, flags: "awaiting_send")
                savedEvent.cancellationId = cancellationId
                DataProvider.shared().bgSave()
                dismiss()
                if ([1,6,9802,30023].contains(savedEvent.kind)) {
                    DispatchQueue.main.async {
                        sendNotification(.newPostSaved, savedEvent)
                    }
                }
            }
            _ = Unpublisher.shared.publish(signedEvent, cancellationId: cancellationId)
        }
    }
}

struct HighlightComposer_Previews: PreviewProvider {
    static var previews: some View {
        let example = NewHighlight(url: "https://nostur.com", selectedText: "This is amazing, this is some text that is being highlighted by Nostur highlightur", title:"Nostur - a nostr client for iOS/macOS")
        
        PreviewContainer {
            NavigationStack {
                HighlightComposer(highlight: example)
            }
        }
    }
}
