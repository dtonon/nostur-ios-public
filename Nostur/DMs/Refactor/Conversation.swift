//
//  ConversationRow.swift
//  Nostur
//
//  Created by Fabian Lachman on 05/09/2023.
//

import SwiftUI
import Combine

class Conversation: Identifiable, Hashable, ObservableObject {
    
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id && lhs.unread == rhs.unread
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(dmState.unread)
    }
    
    var id:String { contactPubkey }
    let contactPubkey:String
    var nrContact:NRContact?
    let mostRecentMessage:String
    let mostRecentDate:Date
    let mostRecentEvent:Event // bg context
    @Published var unread:Int
    @Published var accepted:Bool
    var dmState:DMState
    
    var subscriptions = Set<AnyCancellable>()
    
    init(contactPubkey: String, nrContact: NRContact? = nil, mostRecentMessage: String, mostRecentDate: Date, mostRecentEvent: Event, unread: Int, dmState: DMState) {
        self.contactPubkey = contactPubkey
        self.nrContact = nrContact
        self.mostRecentMessage = mostRecentMessage
        self.mostRecentDate = mostRecentDate
        self.mostRecentEvent = mostRecentEvent
        self.unread = unread
        self.dmState = dmState
        self.accepted = dmState.accepted
        
        dmState.didUpdate
            .sink { _ in
                bg().perform {
                    let allReceived = Event.fetchEventsBy(pubkey: self.contactPubkey, andKind: 4, context: bg())
                    let unreadSince = self.dmState.markedReadAt ?? Date(timeIntervalSince1970: 0)
                    let unread = allReceived.filter { $0.date > unreadSince }.count
                    let accepted = dmState.accepted
                    Task { @MainActor in
                        self.unread = unread
                        self.accepted = accepted
                    }
                }
            }
            .store(in: &subscriptions)
        
        mostRecentEvent.contactUpdated
            .sink { contact in
                let nrContact = NRContact(contact: contact, following: isFollowing(contact.pubkey))
                Task { @MainActor in
                    self.objectWillChange.send()
                    self.nrContact = nrContact
                }
            }
            .store(in: &subscriptions)
    }
}
