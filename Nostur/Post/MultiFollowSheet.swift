//
//  MultiFollowSheet.swift
//  Nostur
//
//  Created by Fabian Lachman on 17/09/2023.
//

import SwiftUI

struct MultiFollowSheet: View {
    public let pubkey:String
    public let name:String
    public var onDismiss:(() -> Void)?
    
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var theme:Theme
    
    private var accounts:[Account] { // Only accounts with private key
        NRState.shared.accounts.filter { $0.privateKey != nil }
    }
    
    @State private var followingOn = Set<String>()
    
    private func toggleAccount(_ account:Account) {
        if followingOn.contains(account.publicKey) {
            followingOn.remove(account.publicKey)
            Task {
                self.unfollow(pubkey, account: account)
            }
        }
        else {
            followingOn.insert(account.publicKey)
            Task {
                self.follow(pubkey, account: account)
            }
        }
    }
    
    private func isFollowingOn(_ account:Account) -> Bool {
        followingOn.contains(account.publicKey)
    }
    
    var body: some View {
        VStack(alignment: .center) {
            Text("Follow \(name) on")
            HStack {
                ForEach(accounts) { account in
                    PFP(pubkey: account.publicKey, account: account, size: 50)
                        .overlay(alignment: .bottom) {
                            if isFollowingOn(account) {
                                Text("Following", comment: "Shown when you follow someone in the multi follow sheet")
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(theme.accent)
                                    .cornerRadius(13)
                                    .offset(y: 10)
                            }
                        }
                        .onTapGesture {
                            toggleAccount(account)
                        }
                        .opacity(isFollowingOn(account) ? 1.0 : 0.25)
                }
            }
        }
        .onAppear {
            followingOn = Set(
                accounts
                    .filter({ $0.getFollowingPublicKeys().contains(pubkey) })
                    .map({ $0.publicKey })
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    onDismiss?()
                }
            }
        }
    }
    
    private func follow(_ pubkey:String, account:Account) {
        if let contact = Contact.contactBy(pubkey: pubkey, context: viewContext) {
            contact.couldBeImposter = 0
            account.addToFollows(contact)
        }
        else {
            // if nil, create new contact
            let contact = Contact(context: viewContext)
            contact.pubkey = pubkey
            contact.couldBeImposter = 0
            account.addToFollows(contact)
        }
        if account == Nostur.account() {
            NRState.shared.loggedInAccount?.reloadFollows()            
            sendNotification(.followingAdded, pubkey) // For WoT
        }
        account.publishNewContactList()
        DataProvider.shared().save()
    }
    

    private func unfollow(_ pubkey: String, account:Account) {
        guard let contact = Contact.contactBy(pubkey: pubkey, context: viewContext) else {
            return
        }
        account.removeFromFollows(contact)
        if account == Nostur.account() {
            NRState.shared.loggedInAccount?.reloadFollows()
        }
        account.publishNewContactList()
        DataProvider.shared().save()
    }
}
