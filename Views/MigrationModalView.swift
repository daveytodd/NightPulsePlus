import SwiftUI

struct MigrationModalView: View { let didUnlock: Bool; @Environment(\.dismiss) private var dismiss; var body: some View { VStack(spacing: 16) { Text(didUnlock ? "Lifetime access unlocked" : "Invalid migration link").font(.title2); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }.padding() } }
