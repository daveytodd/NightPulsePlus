import AVFoundation
import Combine
import Foundation

@MainActor final class AudioTracker: NSObject, ObservableObject {
 @Published private(set) var isMonitoring = false
 private var recorder: AVAudioRecorder?
 func stop() { recorder?.stop(); isMonitoring = false }
}
