//
//  DetailFooterFragment.swift
//  Nostur
//
//  Created by Fabian Lachman on 22/06/2023.
//

import SwiftUI

struct DetailFooterFragment: View {
    let er:ExchangeRateModel = .shared // Not Observed for performance
    @ObservedObject var nrPost:NRPost // TODO: Remvoe observable, only use footerAttributes
    @ObservedObject var footerAttributes:FooterAttributes
    
    init(nrPost: NRPost) {
        self.nrPost = nrPost
        self.footerAttributes = nrPost.footerAttributes
    }
    
    var tallyString:String {
        if (er.bitcoinPrice != 0.0) {
            let fiatPrice = String(format: "$%.02f",(Double(footerAttributes.zapTally) / 100000000 * Double(er.bitcoinPrice)))
            return fiatPrice
        }
        return String(footerAttributes.zapTally.formatNumber)
    }

    var body: some View {
        Divider()
        HStack {
            NavigationLink(value: ViewPath.NoteReactions(id: nrPost.id)) {
                HStack(spacing: 3) {
                    AnimatedNumber(number: footerAttributes.likesCount)
                        .fontWeight(.bold)
                    Text("reactions", comment: "Label for reactions count, example: (7) reactions")
                }
            }
            NavigationLink(value: ViewPath.NoteReposts(id: nrPost.id)) {
                HStack(spacing: 3) {
                    AnimatedNumber(number: footerAttributes.repostsCount)
                        .fontWeight(.bold)
                    Text("reposts", comment: "Label for reposts count, example: (7) reposts")
                }
            }
            NavigationLink(value: ViewPath.NoteZaps(id: nrPost.id)) {
                HStack(spacing: 3) {
                    AnimatedNumber(number: footerAttributes.zapsCount)
                        .fontWeight(.bold)
                    Text("zaps", comment: "Label for zaps count, example: (4) zaps")
                }
                
                if IS_APPLE_TYRANNY {
                    HStack(spacing: 3) {
                        AnimatedNumberString(number: tallyString)
                            .fontWeight(.bold)
                    }
                    .opacity(footerAttributes.zapTally != 0 ? 1.0 : 0)
                }
            }

            Spacer()
            
            Text(nrPost.createdAt.formatted(date: .omitted, time: .shortened))
            Text(nrPost.createdAt.formatted(
                .dateTime
                    .day().month(.defaultDigits)
            ))
        }
        .buttonStyle(.plain)
        .foregroundColor(.gray)
        .font(.system(size: 14))
        .task {
            guard let contact = nrPost.contact?.mainContact else { return }
            guard contact.anyLud else { return }
            guard contact.zapperPubkey == nil else {
                if let zpk = nrPost.contact?.mainContact.zapperPubkey {
                    reverifyZaps(eventId: nrPost.id, expectedZpk: zpk)
                }
                return
            }
            do {
                if let lud16 = contact.lud16, lud16 != "" {
                    let response = try await LUD16.getCallbackUrl(lud16: lud16)
                    await MainActor.run {
                        if (response.allowsNostr ?? false) && (response.nostrPubkey != nil) {
                            contact.zapperPubkey = response.nostrPubkey!
                            L.og.info("contact.zapperPubkey updated: \(response.nostrPubkey!)")
                            reverifyZaps(eventId: nrPost.id, expectedZpk: contact.zapperPubkey!)
                        }
                    }
                }
                else if let lud06 = contact.lud06, lud06 != "" {
                    let response = try await LUD16.getCallbackUrl(lud06: lud06)
                    await MainActor.run {
                        if (response.allowsNostr ?? false) && (response.nostrPubkey != nil) {
                            contact.zapperPubkey = response.nostrPubkey!
                            L.og.info("contact.zapperPubkey updated: \(response.nostrPubkey!)")
                            reverifyZaps(eventId: nrPost.id, expectedZpk: contact.zapperPubkey!)
                        }
                    }
                }
            }
            catch {
                L.og.error("problem in lnurlp \(error)")
            }
        }
        Divider()
    }
}

func reverifyZaps(eventId: String, expectedZpk: String) {
    let fr = Event.fetchRequest()
    fr.predicate = NSPredicate(format: "zappedEventId == %@ AND kind == 9735", eventId)
    if let zaps = try? DataProvider.shared().viewContext.fetch(fr) {
        for zap in zaps {
            if zap.flags != "zpk_verified" && zap.pubkey == expectedZpk {
                zap.flags = "zpk_verified"
            }
        }
    }
}


struct Previews_DetailFooterFragment_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in pe.loadPosts() }) {
            if let p = PreviewFetcher.fetchNRPost() {
                DetailFooterFragment(nrPost: p)
            }
        }
    }
}
