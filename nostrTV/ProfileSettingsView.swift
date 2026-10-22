import SwiftUI

struct ProfileSettingsView: View {
    @ObservedObject var authManager: NostrAuthManager
    @Binding var isPresented: Bool
    @State private var showLoginSheet = false
    @AppStorage("cove.showChat") private var showChat = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 45) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("YOUR SPACE").font(.coveCaption).tracking(4).foregroundStyle(Color.coveAccent)
                    Text("Make yourself at home.").font(.coveHeading)
                    Text("Your identity, your people, your way to watch.").font(.coveBody).foregroundStyle(Color.coveSecondary)
                }
                HStack(alignment: .top, spacing: 60) {
                    identity.frame(width: 500)
                    VStack(alignment: .leading, spacing: 30) {
                        Text("While you watch").font(.coveSubheading)
                        Button { showChat.toggle() } label: {
                            HStack(spacing: 30) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Show chat when a stream opens")
                                    Text("Change this in the player anytime.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                                }
                                Spacer()
                                Image(systemName: showChat ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.coveAccent)
                            }
                        }.buttonStyle(CoveButtonStyle()).accessibilityValue(showChat ? "On" : "Off")
                            .accessibilityIdentifier("preference-chat")
                        Text("Focus animations follow your Apple TV Reduce Motion setting.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                        if authManager.isAuthenticated {
                            Divider()
                            Label(signingDescription, systemImage: "key.horizontal").font(.coveBody)
                            Text("Your Nostr identity stays with you across apps.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                            Button("Refresh profile and follow list") { authManager.fetchUserData() }
                                .buttonStyle(CoveButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
                }
            }.padding(.horizontal, 80).padding(.vertical, 45)
        }
        .background(Color.coveBackground)
        .fullScreenCover(isPresented: $showLoginSheet) { WelcomeView(authManager: authManager) }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in if authenticated { showLoginSheet = false } }
        .onAppear {
            if authManager.currentProfile == nil && authManager.isAuthenticated { authManager.fetchUserData() }
        }
    }

    private var signingDescription: String {
        switch authManager.authMethod {
        case .bunker: return "Signed in with a remote signer"
        case .nsec: return "Signed in on this Apple TV"
        case nil: return "Not signed in"
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 24) {
            CoveAvatar(profile: authManager.currentProfile, size: 110)
            if !authManager.isAuthenticated {
                Text("Welcome to Cove").font(.coveSection)
                Text("Browse freely. Connect your Nostr identity to join the conversation and send zaps.").font(.coveBody).foregroundStyle(Color.coveSecondary)
                Button("Sign in") { showLoginSheet = true }.buttonStyle(CoveButtonStyle(prominent: true))
            } else if let profile = authManager.currentProfile {
                Text(profile.displayNameOrName).font(.coveSection).lineLimit(2)
                if let name = profile.name { Text("@\(name)").font(.coveBody).foregroundStyle(Color.coveSecondary) }
                if let about = profile.about, !about.isEmpty { Text(about).font(.coveCaption).foregroundStyle(Color.coveSecondary).lineLimit(4) }
                Text("Following \(authManager.followList.count) people").font(.coveBody).foregroundStyle(Color.coveAccent)
                Button("Sign out") { authManager.logout() }.buttonStyle(CoveButtonStyle())
            } else {
                Text(authManager.isLoadingProfile ? "Finding your profile…" : "Profile unavailable").font(.coveSubheading)
                if authManager.isLoadingProfile { ProgressView().tint(.coveAccent) }
                else {
                    Text(authManager.errorMessage ?? "Try refreshing your profile.").font(.coveCaption).foregroundStyle(Color.coveSecondary)
                    Button("Try again") { authManager.fetchUserData() }.buttonStyle(CoveButtonStyle(prominent: true))
                }
                Button("Sign out") { authManager.logout() }.buttonStyle(CoveButtonStyle())
            }
        }.padding(35).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coveSurface).clipShape(RoundedRectangle(cornerRadius: 24)).focusSection()
    }
}
