//
//  ProfileZapButton.swift
//  Nostur
//
//  Created by Fabian Lachman on 09/07/2023.
//

import SwiftUI

// Zap button uses NWC if available, else just falls back to the old LightningButton
struct ProfileZapButton: View {
    @EnvironmentObject var dim:DIMENSIONS
    private let er:ExchangeRateModel = .shared // Not Observed for performance
    
    @ObservedObject var contact:Contact
    var zapEtag: String?
    
    @ObservedObject private var ss:SettingsStore = .shared
    @State private var cancellationId:UUID? = nil
    @State private var customZapId:UUID? = nil
    @State private var activeColor = Self.grey
    static let grey = Color.init(red: 113/255, green: 118/255, blue: 123/255)
    
    var body: some View {
        if ss.defaultLightningWallet.scheme.contains(":nwc:") && !ss.activeNWCconnectionId.isEmpty {
            if let cancellationId {
                HStack {
                    Text("Zapped \(Image(systemName: "bolt.fill"))", comment: "Text in zap button after zapping")
                        .padding(.horizontal, 10)
                        .lineLimit(1)
                        .frame(width: 160, height: 30)
                        .font(.caption.weight(.heavy))
                        .foregroundColor(Color.yellow)
                        .background(Color.secondary)
                        .cornerRadius(20)
                        .overlay {
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(.gray, lineWidth: 1)
                        }
                        .onTapGesture {
                            _ = Unpublisher.shared.cancel(cancellationId)
                            NWCRequestQueue.shared.removeRequest(byCancellationId: cancellationId)
                            NWCZapQueue.shared.removeZap(byCancellationId: cancellationId)
                            self.cancellationId = nil
                            // TODO: MOVE state to contact (maybe increase lightning ring size)
//                            nrPost.zapState = .cancelled
                            activeColor = Self.grey
                            contact.zapState = .cancelled
                            contact.zapStateChanged.send((.cancelled, zapEtag))
                            L.og.info("⚡️ Zap cancelled")
                        }
                }
            }
            // TODO elsif zap .failed .overlay error !
            else if [.initiated,.nwcConfirmed,.zapReceiptConfirmed].contains(contact.zapState) {
                HStack {
                    Text("Zapped \(Image(systemName: "bolt.fill"))", comment: "Text in zap button after zapping")
                        .padding(.horizontal, 10)
                        .lineLimit(1)
                        .frame(width: 160, height: 30)
                        .font(.caption.weight(.heavy))
                        .foregroundColor(Color.yellow)
                        .background(Color.secondary)
                        .cornerRadius(20)
                        .overlay {
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(.gray, lineWidth: 1)
                        }
                }
            }
            else {
                Text("Send \(ss.defaultZapAmount.clean) sats \(Image(systemName: "bolt.fill"))")
                    .padding(.horizontal, 10)
                    .lineLimit(1)
                    .frame(width: 160, height: 30)
                    .font(.caption.weight(.heavy))
                    .foregroundColor(Color.white)
                    .background(Color.secondary)
                    .cornerRadius(20)
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(.gray, lineWidth: 1)
                    }
                    .overlay(
                        GeometryReader { geo in
                            Color.white.opacity(0.001)
                                .simultaneousGesture(
                                       LongPressGesture()
                                           .onEnded { _ in
                                               guard NosturState.shared.account != nil else { return }
                                               guard NosturState.shared.account?.privateKey != nil else {
                                                   NosturState.shared.readOnlyAccountSheetShown = true
                                                   return
                                               }
                                               // Trigger custom zap
                                               customZapId = UUID()
                                               if let customZapId {
                                                   sendNotification(.showZapCustomizerSheet, ZapCustomizerSheetInfo(name: contact.anyName, customZapId: customZapId))
                                               }
                                           }
                                   )
                                   .highPriorityGesture(
                                       TapGesture()
                                           .onEnded { _ in
                                               let point = CGPoint(x: geo.frame(in: .global).origin.x + 55, y: geo.frame(in: .global).origin.y + 10)
                                               self.triggerZap(strikeLocation: point, contact:contact)
                                           }
                                   )
                                   .onReceive(receiveNotification(.sendCustomZap)) { notification in
                                       // Complete custom zap
                                       let customZap = notification.object as! CustomZap
                                       guard customZap.customZapId == customZapId else { return }
                                       
                                       let point = CGPoint(x: geo.frame(in: .global).origin.x + 55, y: geo.frame(in: .global).origin.y + 10)
                                       self.triggerZap(strikeLocation: point, contact:contact, zapMessage:customZap.publicNote, amount: customZap.amount)
                                   }
                        }
                    )
            }
        }
        else {
            ProfileLightningButton(contact: contact)
        }
    }
    
    func triggerZap(strikeLocation:CGPoint, contact:Contact, zapMessage:String = "", amount:Double? = nil) {
        guard let account = NosturState.shared.account else { return }
        guard NosturState.shared.account?.privateKey != nil else {
            NosturState.shared.readOnlyAccountSheetShown = true
            return
        }
        let isNC = account.isNC
        let impactMed = UIImpactFeedbackGenerator(style: .medium)
        impactMed.impactOccurred()
        let selectedAmount = amount ?? ss.defaultZapAmount
        sendNotification(.lightningStrike, LightningStrike(location:strikeLocation, amount:selectedAmount, sideStrikeWidth: (dim.listWidth - (DIMENSIONS.PFP_BIG + 20.0))))
        withAnimation(.easeIn(duration: 0.25).delay(0.25)) {// wait 0.25 for the strike
            activeColor = .yellow
        }
        cancellationId = UUID()
        contact.zapState = .initiated
        contact.zapStateChanged.send((.initiated, zapEtag))

        DataProvider.shared().bg.perform {
            guard let bgContact = DataProvider.shared().bg.object(with: contact.objectID) as? Contact else { return }
            NWCRequestQueue.shared.ensureNWCconnection()
            guard let cancellationId = cancellationId else { return }
            let zap = Zap(isNC:isNC, amount: Int64(selectedAmount), contact: bgContact, eventId: zapEtag, cancellationId: cancellationId, zapMessage: zapMessage)
            NWCZapQueue.shared.sendZap(zap)
            bgContact.zapState = .initiated
        }
    }
}

struct ProfileZapButton_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in
            pe.loadContacts()
            pe.loadZaps()
        }) {
            VStack {
                if let nrPost = PreviewFetcher.fetchNRPost("49635b590782cb1ab1580bd7e9d85ba586e6e99e48664bacf65e71821ae79df1"), let contact = nrPost.contact?.contact {
                    ProfileZapButton(contact: contact, zapEtag: nrPost.id)
                }
                
                
//                Image("BoltIconActive").foregroundColor(.yellow)
//                    .padding(.horizontal, 10)
//                    .padding(.vertical, 5)
            }
        }
    }
}
