//
//  MutedWords.swift
//  Nostur
//
//  Created by Fabian Lachman on 12/04/2023.
//

import SwiftUI

struct MutedWordsView: View {
    @EnvironmentObject var theme:Theme
    @Environment(\.managedObjectContext) var viewContext
    
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(value: true))
    var mutedWords:FetchedResults<MutedWords>
    
    @State var selected:MutedWords?
    
    var body: some View {
        List {
            ForEach(mutedWords) { mutedWord in
                Text(mutedWord.words == "" ? "Tap to edit..." : mutedWord.words ?? "Tap to edit...")
                    .onTapGesture {
                        selected = mutedWord
                    }
            }
            .onDelete { offsets in
                offsets.forEach { viewContext.delete(mutedWords[$0]) }
                DataProvider.shared().save()
                NRState.shared.loadMutedWords()
            }
        }
        .sheet(item: $selected) { words in
            EditWordSheet(mutedWords: words)
                .presentationBackground(theme.background)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .none) {
                    let m = MutedWords(context: viewContext)
                    m.words = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }

            }
        }
    }
    
    struct EditWordSheet: View {
        @Environment(\.dismiss) var dismiss
        @ObservedObject var mutedWords:MutedWords
        @State var text:String
        init(mutedWords: MutedWords) {
            self.mutedWords = mutedWords
            _text = State(initialValue: mutedWords.words ?? "")
        }
        
        var body: some View {
            NavigationStack {
                Form {
                    Section(header: Text("Specific word or sentence", comment: "Heading for entering a word or sentence to mute"), footer: Text("Posts containing this will be filtered from your feed")) {
                        TextField("Specific word or sentence", text: $text, prompt: Text(verbatim: "nft"))
                        
                        Toggle(isOn: $mutedWords.enabled) {
                            Text("Activate this filter", comment: "Toggle to activate filter")
                        }
                    }
                }
                .navigationTitle(String(localized:"Edit muted word", comment: "Navigation title for screen to edit muted word"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            mutedWords.words = text
                            DataProvider.shared().save()
                            NRState.shared.loadMutedWords()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct MutedWordsView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in
            pe.loadBlockedAndMuted()
        }) {
            NavigationStack {
                MutedWordsView()
            }
        }
    }
}
