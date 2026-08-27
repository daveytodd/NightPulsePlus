import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @State private var showingRecording = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 60)).foregroundStyle(.gray)
                        Text("NightPulse").font(.system(size: 32, weight: .light)).foregroundStyle(.gray)
                    }.padding(.top, 40)
                    Button { showingRecording = true } label: {
                        Label("Start Sleep Session", systemImage: "video.fill")
                            .font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 18)
                    }.buttonStyle(.borderedProminent).padding(.horizontal, 20)
                    if !sessionManager.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Previous Sessions").font(.title3.weight(.medium)).padding(.horizontal, 20)
                            ForEach(sessionManager.sessions) { session in
                                SessionRowView(session: session, sessionManager: sessionManager)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity).padding(.bottom, 40)
            }.background(Color.black).fullScreenCover(isPresented: $showingRecording) {
                RecordingView(sessionManager: sessionManager)
            }
        }
    }
}
