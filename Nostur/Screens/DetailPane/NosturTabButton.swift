//
//  NosturTabButton.swift
//  Nostur
//
//  Created by Fabian Lachman on 16/06/2023.
//

import SwiftUI

struct NosturTabButton: View {
    @EnvironmentObject var theme:Theme
    var isSelected:Bool = false
    var onSelect:() -> Void
    var onClose:() -> Void
    @ObservedObject var tab:TabModel
    var isArticle:Bool { tab.isArticle }
    
    @State var isHoveringCloseButton = false
    @State var isHoveringTab = false
    
    var body: some View {
        HStack(spacing:5) {
            if IS_CATALYST {
                Image(systemName: "xmark")
                    .foregroundColor(isHoveringTab ? .gray : .clear)
                    .padding(4)
                    .contentShape(Rectangle())
                    .background(isHoveringCloseButton ? .gray.opacity(0.1) : .clear)
                    .onHover { over in
                        isHoveringCloseButton = over
                    }
                    .onTapGesture {
                        self.onClose()
                    }
            }
            else {
                Image(systemName: "xmark").foregroundColor(.gray)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.onClose()
                    }
            }
            Text(tab.navigationTitle)
                .lineLimit(1)
                .foregroundColor(theme.accent)
                .frame(maxWidth: 150)
        }
        .padding(.trailing, 23)
        .padding(.vertical, 10)
        .padding(.leading, 5)
        .background(isSelected ? (isArticle ? theme.secondaryBackground : theme.background) : .clear)
        .contentShape(Rectangle())
        .onHover { over in
            isHoveringTab = over
        }
        .onTapGesture {
            self.onSelect()
        }
    }
}
