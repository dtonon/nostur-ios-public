//
//  ZapCustomizerSheet.swift
//  Nostur
//
//  Created by Fabian Lachman on 10/07/2023.
//

import SwiftUI

struct ZapCustomizerSheet: View {
    @EnvironmentObject var theme:Theme
    let name:String
    var customZapId:UUID?
    var supportsZap = false
    var sendAction:((CustomZap) -> Void)?
    
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("last_custom_zap_amount") var lastCustomZapAmount:Double = 0.0
    @State var zapMessage = ""
    @State var selectedAmount:Double = 3
    @State var customAmount:Double = 0.0
    @State var showCustomAmountsheet = false
    @State var setAmountAsDefault = false
    
    var body: some View {
        NavigationStack {
            VStack {
                
                Grid {
                    GridRow {
                        ZapAmountButton(3, isSelected: selectedAmount == 3).onTapGesture {
                            selectedAmount = 3
                        }
                        ZapAmountButton(21, isSelected: selectedAmount == 21).onTapGesture {
                            selectedAmount = 21
                        }
                        ZapAmountButton(100, isSelected: selectedAmount == 100).onTapGesture {
                            selectedAmount = 100
                        }
                        ZapAmountButton(500, isSelected: selectedAmount == 500).onTapGesture {
                            selectedAmount = 500
                        }
                    }
                    GridRow {
                        ZapAmountButton(1000, isSelected: selectedAmount == 1000).onTapGesture {
                            selectedAmount = 1000
                        }
                        ZapAmountButton(2000, isSelected: selectedAmount == 2000).onTapGesture {
                            selectedAmount = 2000
                        }
                        ZapAmountButton(5000, isSelected: selectedAmount == 5000).onTapGesture {
                            selectedAmount = 5000
                        }
                        ZapAmountButton(10000, isSelected: selectedAmount == 10000).onTapGesture {
                            selectedAmount = 10000
                        }
                    }
                    GridRow {
                        ZapAmountButton(25000, isSelected: selectedAmount == 25000).onTapGesture {
                            selectedAmount = 25000
                        }
                        ZapAmountButton(50000, isSelected: selectedAmount == 50000).onTapGesture {
                            selectedAmount = 50000
                        }
                        ZapAmountButton(100000, isSelected: selectedAmount == 100000).onTapGesture {
                            selectedAmount = 100000
                        }
                        ZapAmountButton(200000, isSelected: selectedAmount == 200000).onTapGesture {
                            selectedAmount = 200000
                        }
                    }
                    GridRow {
                        ZapAmountButton(500000, isSelected: selectedAmount == 500000).onTapGesture {
                            selectedAmount = 500000
                        }
                        ZapAmountButton(1000000, isSelected: selectedAmount == 1000000).onTapGesture {
                            selectedAmount = 1000000
                        }
                        if lastCustomZapAmount != 0.0 {
                            ZapAmountButton(lastCustomZapAmount, isSelected: selectedAmount == lastCustomZapAmount).onTapGesture {
                                selectedAmount = lastCustomZapAmount
                            }
                        }
                        ZapAmountButton(customAmount, isSelected: selectedAmount == customAmount).onTapGesture {
                            showCustomAmountsheet = true
                        }
                        .onChange(of: customAmount) { newValue in
                            selectedAmount = newValue
                            lastCustomZapAmount = selectedAmount
                        }
                    }
                }
                .padding(.bottom, 10)
                
                if supportsZap {
                    HStack(alignment: .center) {
                        TextField("Add public note (optional)", text: $zapMessage)
                            .multilineTextAlignment(.leading)
                            .lineLimit(5, reservesSpace: true)
                            .textFieldStyle(.roundedBorder)
                            .padding(20)
                            .frame(height: 100)
                    }
                }
                
                Button {
                    if sendAction != nil {
                        sendAction?(CustomZap(
                            publicNote: zapMessage,
                            customZapId: customZapId,
                            amount: selectedAmount
                        ))
                    }
                    else {
                        sendNotification(.sendCustomZap,
                                         CustomZap(
                                            publicNote: zapMessage,
                                            customZapId: customZapId,
                                            amount: selectedAmount
                                         ))
                    }
                    if setAmountAsDefault {
                        SettingsStore.shared.defaultZapAmount = selectedAmount
                    }
                    dismiss()
                } label: {
                    Text("Send \(selectedAmount.clean) sats to \(name)")
                        .lineLimit(1)
                        .foregroundColor(Color.white)
                        .fontWeight(.bold)
                        .padding(10)
                        .background(theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8.0))
                        .frame(maxWidth: 300)
                        .controlSize(.large)
                }
                
                Toggle(isOn: $setAmountAsDefault) {
                    Text("Remember this amount for all zaps", comment:"Toggle on zap screen to set selected amount as default for all zaps")
                }
                .padding(10)
                .padding(.horizontal, 20)
            }
            .navigationTitle(String(localized:"Send sats", comment:"Title of sheet showing zap options when sending sats (satoshis)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                    
                }
            }
            .sheet(isPresented: $showCustomAmountsheet) {
                NavigationStack {
                    CustomZapAmountEntry(customAmount: $customAmount)
                }
                .presentationBackground(theme.background)
            }
            .onAppear {
                selectedAmount = SettingsStore.shared.defaultZapAmount
            }
        }
    }
}

struct ZapCustomizerSheetInfo: Identifiable {
    let name:String
    var customZapId:UUID?
    var id:UUID { customZapId ?? UUID() }
}

struct CustomZap: Identifiable {
    var id:UUID { customZapId ?? UUID() }
    var publicNote = ""
    var customZapId:UUID?
    let amount:Double
}

struct ZapCustomizerSheet_Previews: PreviewProvider {
    static var previews: some View {
        PreviewContainer({ pe in pe.loadPosts() }) {
            VStack {
                if let nrPost = PreviewFetcher.fetchNRPost() {
                    ZapCustomizerSheet(name:nrPost.anyName, customZapId: UUID())
                }
            }
        }
    }
}
