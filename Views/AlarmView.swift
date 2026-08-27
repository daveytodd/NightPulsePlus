import SwiftUI
import Foundation

struct AlarmView: View { @StateObject private var alarmManager = AlarmManager(); var body: some View { Button("Enable sleep alarm") { Task { await alarmManager.requestAuthorization() } }.buttonStyle(.borderedProminent) } }
