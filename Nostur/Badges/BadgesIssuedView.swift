//
//  BadgesIssuedView.swift
//  Nostur
//
//  Created by Fabian Lachman on 01/03/2023.
//
import SwiftUI
import Nuke
import NukeUI

struct Badge: Hashable {
    var badge:Event
    init(_ badge: Event) {
        self.badge = badge
    }
}

struct BadgesIssuedContainer:View {
    @EnvironmentObject var la:LoggedInAccount
    var body: some View {
        BadgesIssuedView(pubkey: la.account.publicKey)
    }
}

struct BadgesIssuedView: View {
    @EnvironmentObject var theme:Theme
    @State var createNewBadgeSheetShown = false
    @FetchRequest
    var badges:FetchedResults<Event>
    var pubkey:String
    
    init(pubkey:String) {
        self.pubkey = pubkey
        let r = Event.fetchRequest()
        r.predicate = NSPredicate(format: "kind == 30009 AND pubkey == %@", pubkey)
        r.sortDescriptors = [NSSortDescriptor(keyPath:\Event.created_at, ascending: false)]
        _badges = FetchRequest(fetchRequest: r)
    }
    
    var body: some View {
//        let _ = Self._printChanges()
        VStack {
            List(badges) { badge in
                NavigationLink(value: Badge(badge)) {
                    BadgeIssuedRow(badge: badge)
                }
                .listRowBackground(theme.background)
            }
            .scrollContentBackground(.hidden)
            .background(theme.listBackground)
        }
        .background(theme.listBackground)
        .onAppear {
            // fetch missing badge definitions:
            // or just all...
            let req = RequestMessage.getBadgesCreatedAndAwarded(pubkey: pubkey)
            let message = ClientMessage(type: .REQ, message: req)
            SocketPool.shared.sendMessage(message)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    guard isFullAccount() else { showReadOnlyMessage(); return }
                    createNewBadgeSheetShown = true
                }, label: {
                    Text("Create new badge", comment: "Button to create a new badge")
                })
            }
        }
        .navigationTitle(String(localized:"Badges", comment:"Navigation title of Bagdes screen"))
        .sheet(isPresented: $createNewBadgeSheetShown) {
            NavigationStack {
                CreateNewBadgeSheet()
            }
            .presentationBackground(theme.background)
        }
    }
}

struct BadgeIssuedRow: View {
    @EnvironmentObject var theme:Theme
    var badge:Event
    var nBadge:NEvent { badge.toNEvent() }
    
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .center) {
                if let pictureUrl = nBadge.badgeImage?.tag[safe: 1] {
                    if (pictureUrl.suffix(4) == ".gif") { // NO ENCODING FOR GIF (OR ANIMATION GETS LOST)
                        LazyImage(url: URL(string: pictureUrl)) { state in
                            if let container = state.imageContainer {
                                if container.type == .gif, let gifData = container.data {
                                    GIFImage(data: gifData, isPlaying: .constant(true))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 50, height: 50)
                                        .clipped()
                                        .padding(10)
                                }
                                else if let image = state.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 50, height: 50)
                                        .clipped()
                                        .padding(10)
                                }
                                else {
                                    CenteredProgressView()
                                }
                            }
                            else {
                                CenteredProgressView()
                            }
                        }
                        .pipeline(ImageProcessing.shared.badges) // NO PROCESSING FOR ANIMATED GIF (BREAKS ANIMATION)
                    }
                    else {
                        LazyImage(request: ImageRequest(url: URL(string:pictureUrl),
                                                        processors: [.resize(width: 50)],
                                                        options: SettingsStore.shared.lowDataMode ? [.returnCacheDataDontLoad] : [],
                                                        userInfo: [.scaleKey: UIScreen.main.scale])) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 50, height: 50)
                                    .clipped()
                                    .padding(10)
                            }
                            else {
                                CenteredProgressView()
                            }
                        }
                                                        .pipeline(ImageProcessing.shared.badges)
                    }
                }
            }
            .frame(width: 60)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(nBadge.badgeName?.value ?? "No name")
                    .font(.subheadline)
                Text(nBadge.badgeDescription?.value ?? "No description").font(.caption2)
                Text("Awarded to \(badge.awardedTo.count) people", comment: "Text showing how many badges have been awarded").font(.caption)
            }.padding(10)
        }
        .background(theme.background)
        .navigationTitle("")
    }
    
}

struct BadgesIssuedView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in pe.loadBadges() }) {
            NavigationStack {
                BadgesIssuedContainer()
            }
        }
    }
}
