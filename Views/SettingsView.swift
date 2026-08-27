import SwiftUI

struct SettingsView: View { @AppStorage("previewEnabled") private var previewEnabled = true; var body: some View { Form { Toggle("Camera preview", isOn: $previewEnabled) }.navigationTitle("Settings") } }
