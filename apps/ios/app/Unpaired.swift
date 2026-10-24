import SwiftUI

/// The iPhone with no Mac to talk to (Phone.needsPairing: never paired, removed from the Mac, or
/// its 30 days up): Oby on its stage (Sangam's Home.tsx `.stage`), one line in Oby's voice saying
/// what to do on the Mac, and Connect, where Home has its message box. Connect opens the camera on
/// the Mac's QR code, with the six digits (ConnectScreen) a tap away; once paired, Home takes over.
struct UnpairedScreen: View {
    @Environment(Phone.self) private var phone
    @ScaledMetric(relativeTo: .body) private var lineSize = Tokens.textBase
    let character: ObyCharacter
    @State private var scanning = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    StageOby(character: character)
                    Text(UnpairedLine.message(phone.notice))
                        .font(Tokens.font(lineSize)).foregroundStyle(Tokens.text)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                        .padding(.top, 14)
                    // Sangam's stage sits a little above centre, like a face at eye level.
                    Spacer(minLength: 32)
                    Spacer(minLength: 0)
                    PrimaryButton(title: "Connect") { scanning = true }
                        .frame(maxWidth: 362)
                        .accessibilityHint("Opens the camera to scan the code your Mac shows")
                }
                .padding(.horizontal, Tokens.gutter).padding(.bottom, 16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.bg)
        .sheet(isPresented: $scanning) { ScanSheet() }
    }
}

/// The line under Oby: why there's no Mac, and where on the Mac to pair.
enum UnpairedLine {
    static func message(_ notice: ReachNotice?) -> String {
        switch notice {
        case .removed: "Your Mac removed this iPhone. Pair again from Settings › Runner › Pair a device."
        case .expired: "Pairing ended after 30 days. Pair again from Settings › Runner › Pair a device."
        case .keyChanged: "Your Mac's key changed, so Oby won't talk to it. Pair again from Settings › Runner › Pair a device."
        default: "Let's connect to your Mac. On it, open Settings › Runner › Pair a device."
        }
    }
}

/// The camera on the Mac's QR code: pairing starts as soon as it's seen. The six digits, or an
/// invitation pasted, are on ConnectScreen, one tap down.
private struct ScanSheet: View {
    @Environment(Phone.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    /// The last code tried: the camera sees it many times a second.
    @State private var tried: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRScanner { value in
                    guard value != tried else { return }
                    tried = value
                    Task {
                        do { try await phone.pair(scanned: value) } catch { problem = error.localizedDescription }
                    }
                }
                .ignoresSafeArea()
                .accessibilityLabel("Camera")
                VStack(spacing: 4) {
                    Text(problem ?? "Point the camera at the code on your Mac.")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(problem == nil ? Tokens.ink : Tokens.danger)
                        .multilineTextAlignment(.center)
                    NavigationLink { ConnectScreen() } label: {
                        Text("Use the six-digit code instead").frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .font(Tokens.font(Tokens.textBase, .medium))
                }
                .padding(.top, 18).padding(.horizontal, 18).padding(.bottom, 6).frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, Tokens.gutter).padding(.bottom, 16)
            }
            .background(.black)
            // Over the camera it's dark in both themes; Connect, pushed from here, keeps the app's.
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle("Scan the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

#Preview("Light") {
    UnpairedScreen(character: ObyCharacter(query: "embed&size=1.23"))
        .environment(Phone())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    UnpairedScreen(character: ObyCharacter(query: "embed&size=1.23"))
        .environment(Phone())
        .preferredColorScheme(.dark)
}

#Preview("Scanning") {
    ScanSheet()
        .environment(Phone())
}
