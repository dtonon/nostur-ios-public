//
//  HighlightRenderer.swift
//  Nostur
//
//  Created by Fabian Lachman on 03/05/2023.
//

import SwiftUI

// TODO: Not sure why we have Highlight() and HighlightRenderer(). Can maybe remove one.
struct HighlightRenderer: View {
    @EnvironmentObject private var theme:Theme
    private let nrPost:NRPost
    @ObservedObject private var highlightAttributes:NRPost.HighlightAttributes
    
    init(nrPost: NRPost) {
        self.nrPost = nrPost
        self.highlightAttributes = nrPost.highlightAttributes
    }
    
    var body: some View {
        VStack {
            Text(nrPost.content ?? "")
                .fixedSize(horizontal: false, vertical: true)
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
            
            if let hlAuthorPubkey = highlightAttributes.authorPubkey {
                HStack {
                    Spacer()
                    PFP(pubkey: hlAuthorPubkey, nrContact: highlightAttributes.contact, size: 20)
                    Text(highlightAttributes.anyName ?? "Unknown")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    navigateTo(ContactPath(key: hlAuthorPubkey))
                }
                .padding(.trailing, 40)
            }
            HStack {
                Spacer()
                if let url = highlightAttributes.url, let md = try? AttributedString(markdown:"[\(url)](\(url))") {
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
                .stroke(theme.lineColor.opacity(0.2), lineWidth: 1)
        )
    }
}

struct HighlightRenderer_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in
            pe.loadPosts()
        }) {
            NavigationStack {
                if let nrPost = PreviewFetcher.fetchNRPost() {
                    HighlightRenderer(nrPost: nrPost)
                }
            }
        }
    }
}
