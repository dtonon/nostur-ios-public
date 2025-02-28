//
//  NotificationsNewFollowers.swift
//  Nostur
//
//  Created by Fabian Lachman on 26/09/2023.
//

import SwiftUI
import CoreData
import Combine

// Copy pasta from old NotificationsPosts, only using the new follower parts.
struct NotificationsFollowers: View {
    @EnvironmentObject private var theme:Theme
    @ObservedObject private var settings:SettingsStore = .shared
    @StateObject private var fl = FastLoader()
    @State private var backlog = Backlog()
    @State private var didLoad = false
    @Binding private var navPath:NavigationPath
    
    @AppStorage("selected_tab") private var selectedTab = "Main"
    @AppStorage("selected_notifications_tab") private var selectedNotificationsTab = "Followers"
    @Namespace private var top
    
    @FetchRequest
    private var notifications:FetchedResults<PersistentNotification>
    
    init(pubkey: String, navPath: Binding<NavigationPath>) {
        _navPath = navPath
        let fr = PersistentNotification.fetchRequest()
        fr.sortDescriptors = [NSSortDescriptor(keyPath: \PersistentNotification.createdAt, ascending: false)]
        fr.predicate = NSPredicate(format: "pubkey == %@ AND type_ == %@", pubkey, PNType.newFollowers.rawValue)
        _notifications = FetchRequest(fetchRequest: fr)
    }
    
    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 1).id(top)
                LazyVStack(spacing: 10) {
                    ForEach(notifications) { notification in
                        NewFollowersNotificationView(notification: notification)
                            .padding(10)
                            .background(theme.background)
                            .id(notification.id)
                    }
                }
            }
            .onReceive(receiveNotification(.didTapTab)) { notification in
                guard selectedNotificationsTab == "Followers" else { return }
                guard let tabName = notification.object as? String, tabName == "Notifications" else { return }
                if navPath.count == 0 {
                    withAnimation {
                        proxy.scrollTo(top)
                    }
                }
            }
        }
        .background(theme.listBackground)
        .onReceive(receiveNotification(.activeAccountChanged)) { notification in
            let account = notification.object as! Account
            notifications.nsPredicate = NSPredicate(format: "pubkey == %@ AND type_ == %@", account.publicKey, PNType.newFollowers.rawValue)
        }
        .simultaneousGesture(
               DragGesture().onChanged({
                   if 0 < $0.translation.height {
                       sendNotification(.scrollingUp)
                   }
                   else if 0 > $0.translation.height {
                       sendNotification(.scrollingDown)
                   }
               }))
    }
    
    private func saveLastSeenFollowersCreatedAt() {
        guard selectedTab == "Notifications" && selectedNotificationsTab == "Followers" else { return }
        if let first = notifications.first {
            let firstCreatedAt = first.createdAt
            bg().perform {
                if let account = account() {
                    if account.lastFollowerCreatedAt != Int64(firstCreatedAt.timeIntervalSince1970) {
                        account.lastFollowerCreatedAt = Int64(firstCreatedAt.timeIntervalSince1970)
                    }
                }
                DataProvider.shared().bgSave()
            }
        }
    }

}

#Preview("Notifications Followers") {
    let pubkey = "9be0be0e64d38a29a9cec9a5c8ef5d873c2bfa5362a4b558da5ff69bc3cbb81e"
    return PreviewContainer({ pe in
        pe.loadContacts()
        pe.loadNewFollowersNotification()
    }) {
        VStack {
            NotificationsFollowers(pubkey: pubkey, navPath: .constant(NavigationPath()))
        }
    }
}
