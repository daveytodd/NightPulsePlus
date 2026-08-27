import SwiftUI

struct MigrationResultView: View {
    let didUnlock: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: didUnlock ? "checkmark.seal.fill" : "xmark.octagon.fill").font(.system(size: 48)).foregroundStyle(didUnlock ? .green : .red)
            Text(didUnlock ? "Lifetime access unlocked" : "Invalid migration link").font(.title2.weight(.semibold))
            Text(didUnlock ? "Your grandfathered Pro access is now available on this device." : "This link could not be validated.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }.padding(32).presentationDetents([.medium])
    }
}
