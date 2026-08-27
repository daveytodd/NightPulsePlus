import SwiftUI
import UIKit

// Add this view to Rest Right. Register nightpulse as a URL scheme in its Info.plist.
struct NightPulseMigrationModal: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Text("NightPulsePlus").font(.title2.bold())
            Text("Claim your free lifetime Pro access.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Claim Free Lifetime Access") {
                guard let url = URL(string: "nightpulse://migrate?code=RESTRIGHTVIP") else { return }
                UIApplication.shared.open(url)
            }.buttonStyle(.borderedProminent)
            Button("Not now") { dismiss() }.foregroundStyle(.secondary)
        }.padding(28)
    }
}
