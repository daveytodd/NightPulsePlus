import SwiftUI

struct SessionRowView: View { let session: SleepSession; @ObservedObject var sessionManager: SessionManager; var body: some View { HStack { VStack(alignment: .leading) { Text(session.startTime.formatted(date: .abbreviated, time: .shortened)); Text(session.durationFormatted).foregroundStyle(.secondary) }; Spacer(); Button(role: .destructive) { sessionManager.delete(session) } label: { Image(systemName: "trash") } }.padding(.horizontal, 20) } }
