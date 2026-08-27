import SwiftUI
import AVFoundation
import UIKit
import HealthKit
import WatchConnectivity
import UserNotifications

@main
struct NightPulsePlusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

enum CaptureMode: String, Codable, CaseIterable {
    case off = "Off"
    case interval = "Regular Interval"
    case smart = "Smart"
    
    var icon: String {
        switch self {
        case .off: return "video.slash"
        case .interval: return "timer"
        case .smart: return "brain"
        }
    }
    
    var description: String {
        switch self {
        case .off: return "No photos captured"
        case .interval: return "Captures at set intervals"
        case .smart: return "Captures on interval + motion"
        }
    }
}

struct SleepSession: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    var videoFileName: String?
    var photoFileNames: [String]?
    var heartRateData: [HeartRateReading]?
    var alarmTime: Date?
    var audioFileName: String?
    var movementEvents: [MovementEvent]?
    var sleepScore: Int?
    
    var duration: TimeInterval {
        guard let endTime = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return endTime.timeIntervalSince(startTime)
    }
    
    var durationFormatted: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    var averageHeartRate: Double? {
        guard let heartRateData = heartRateData, !heartRateData.isEmpty else { return nil }
        let sum = heartRateData.reduce(0.0) { $0 + $1.bpm }
        return sum / Double(heartRateData.count)
    }
    
    var sleepQuality: String {
        guard let score = sleepScore else { return "Not Rated" }
        switch score {
        case 90...100: return "Excellent"
        case 80..<90: return "Very Good"
        case 70..<80: return "Good"
        case 60..<70: return "Fair"
        default: return "Poor"
        }
    }
    
    var sleepQualityColor: Color {
        guard let score = sleepScore else { return Color(white: 0.4) }
        switch score {
        case 90...100: return Color.green
        case 80..<90: return Color.blue
        case 70..<80: return Color.cyan
        case 60..<70: return Color.orange
        default: return Color.red
        }
    }
}

struct HeartRateReading: Codable {
    let bpm: Double
    let timestamp: Date
}

struct MovementEvent: Codable {
    let timestamp: Date
    let intensity: Double
}

class AlarmManager: ObservableObject {
    @Published var notificationPermissionGranted = false
    
    init() {
        checkPermission()
    }
    
    func checkPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationPermissionGranted = (settings.authorizationStatus == .authorized)
            }
        }
    }
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationPermissionGranted = granted
            }
        }
    }
    
    func scheduleAlarm(at date: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sleepAlarm"])
        
        let content = UNMutableNotificationContent()
        content.title = "Wake Up"
        content.body = "Good morning! Time to wake up."
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: "sleepAlarm", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling alarm: \(error.localizedDescription)")
            }
        }
    }
    
    func cancelAlarm() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sleepAlarm"])
    }
}

class AudioMonitor: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var currentAudioLevel: Float = 0
    @Published var movementEvents: [MovementEvent] = []
    
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var monitoringTimer: Timer?
    private let movementThreshold: Float = 0.15
    
    func checkPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func startMonitoring(saveAudio: Bool = false) {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true)
            
            if saveAudio {
                startRecording()
            }
            
            startLevelMonitoring()
            
            isRecording = true
        } catch {
            print("Failed to start audio monitoring: \(error)")
        }
    }
    
    private func startRecording() {
        let fileName = "sleep_audio_\(UUID().uuidString).m4a"
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    private func startLevelMonitoring() {
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            self.audioRecorder?.updateMeters()
            
            if let recorder = self.audioRecorder {
                let averagePower = recorder.averagePower(forChannel: 0)
                let normalizedLevel = self.normalizeSoundLevel(level: averagePower)
                
                DispatchQueue.main.async {
                    self.currentAudioLevel = normalizedLevel
                }
                
                if normalizedLevel > self.movementThreshold {
                    let event = MovementEvent(timestamp: Date(), intensity: Double(normalizedLevel))
                    DispatchQueue.main.async {
                        self.movementEvents.append(event)
                    }
                }
            }
        }
    }
    
    private func normalizeSoundLevel(level: Float) -> Float {
        let minDb: Float = -60
        let maxDb: Float = 0
        
        let clampedLevel = max(minDb, min(level, maxDb))
        return (clampedLevel - minDb) / (maxDb - minDb)
    }
    
    func stopMonitoring() -> URL? {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        var recordingURL: URL?
        
        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
            recordingURL = recorder.url
        }
        
        audioRecorder = nil
        isRecording = false
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        return recordingURL
    }
    
    func calculateSleepScore(duration: TimeInterval, movementEvents: [MovementEvent], heartRateData: [HeartRateReading]?) -> Int {
        var score: Double = 100
        
        let durationHours = duration / 3600
        if durationHours < 4 {
            score -= 30
        } else if durationHours < 6 {
            score -= 15
        } else if durationHours > 10 {
            score -= 10
        }
        
        let movementsPerHour = Double(movementEvents.count) / max(durationHours, 1)
        score -= min(movementsPerHour * 2, 20)
        
        let highIntensityMovements = movementEvents.filter { $0.intensity > 0.5 }.count
        score -= min(Double(highIntensityMovements) * 3, 15)
        
        if let heartRateData = heartRateData, !heartRateData.isEmpty {
            let avgHeartRate = heartRateData.reduce(0.0) { $0 + $1.bpm } / Double(heartRateData.count)
            
            if avgHeartRate < 45 || avgHeartRate > 80 {
                score -= 10
            } else if avgHeartRate >= 50 && avgHeartRate <= 65 {
                score += 5
            }
        }
        
        return max(0, min(100, Int(score)))
    }
}

class HealthKitManager: ObservableObject {
    @Published var isAuthorized = false
    private let healthStore = HKHealthStore()
    
    init() {
        checkAuthorization()
    }
    
    func checkAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        
        let typesToShare: Set<HKSampleType> = [sleepType, heartRateType]
        let typesToRead: Set<HKObjectType> = [sleepType, heartRateType]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            DispatchQueue.main.async {
                self.isAuthorized = success
            }
        }
    }
    
    func saveSleepSession(_ session: SleepSession) {
        guard isAuthorized, let endTime = session.endTime else { return }
        
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        
        let sleepSample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: session.startTime,
            end: endTime
        )
        
        healthStore.save(sleepSample) { success, error in
            if let error = error {
                print("Error saving sleep to HealthKit: \(error.localizedDescription)")
            }
        }
        
        if let heartRateData = session.heartRateData {
            saveHeartRateData(heartRateData)
        }
    }
    
    private func saveHeartRateData(_ readings: [HeartRateReading]) {
        guard isAuthorized else { return }
        
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let unit = HKUnit.count().unitDivided(by: .minute())
        
        let samples = readings.map { reading in
            HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: unit, doubleValue: reading.bpm),
                start: reading.timestamp,
                end: reading.timestamp
            )
        }
        
        healthStore.save(samples) { success, error in
            if let error = error {
                print("Error saving heart rate to HealthKit: \(error.localizedDescription)")
            }
        }
    }
}

class WatchConnectivityManager: NSObject, ObservableObject {
    @Published var isWatchConnected = false
    @Published var isWatchReachable = false
    @Published var currentHeartRate: Double?
    
    var onHeartRateReceived: ((Double) -> Void)?
    
    override init() {
        super.init()
        
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    func startHeartRateMonitoring() {
        guard WCSession.default.isReachable else { return }
        
        WCSession.default.sendMessage(["command": "startHeartRate"], replyHandler: nil) { error in
            print("Error starting heart rate monitoring: \(error.localizedDescription)")
        }
    }
    
    func stopHeartRateMonitoring() {
        guard WCSession.default.isReachable else { return }
        
        WCSession.default.sendMessage(["command": "stopHeartRate"], replyHandler: nil) { error in
            print("Error stopping heart rate monitoring: \(error.localizedDescription)")
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isWatchConnected = (activationState == .activated)
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchConnected = false
        }
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchConnected = false
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let heartRate = message["heartRate"] as? Double {
            DispatchQueue.main.async {
                self.currentHeartRate = heartRate
                self.onHeartRateReceived?(heartRate)
            }
        }
    }
}

class SessionManager: ObservableObject {
    @Published var sessions: [SleepSession] = []
    
    private let sessionsFileName = "sessions.json"
    let healthKitManager = HealthKitManager()
    
    init() {
        loadSessions()
    }
    
    func addSession(_ session: SleepSession) {
        sessions.insert(session, at: 0)
        saveSessions()
    }
    
    func updateSession(_ session: SleepSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            saveSessions()
            
            if session.endTime != nil {
                healthKitManager.saveSleepSession(session)
            }
        }
    }
    
    func deleteSession(_ session: SleepSession) {
        if let videoFileName = session.videoFileName {
            let fileURL = documentsDirectory().appendingPathComponent(videoFileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        if let photoFileNames = session.photoFileNames {
            for photoFileName in photoFileNames {
                let fileURL = documentsDirectory().appendingPathComponent(photoFileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        sessions.removeAll { $0.id == session.id }
        saveSessions()
    }
    
    func importFromCSV(url: URL) -> (success: Int, failed: Int) {
        var successCount = 0
        var failedCount = 0
        
        guard url.startAccessingSecurityScopedResource() else {
            return (0, 1)
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        do {
            let csvContent = try String(contentsOf: url, encoding: .utf8)
            let rows = csvContent.components(separatedBy: .newlines)
            
            guard rows.count > 1 else {
                return (0, 1)
            }
            
            let headers = rows[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            
            for i in 1..<rows.count {
                let row = rows[i]
                guard !row.isEmpty else { continue }
                
                let columns = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard columns.count >= headers.count else {
                    failedCount += 1
                    continue
                }
                
                if let session = parseCSVRow(headers: headers, columns: columns) {
                    addSession(session)
                    successCount += 1
                } else {
                    failedCount += 1
                }
            }
        } catch {
            return (0, 1)
        }
        
        return (successCount, failedCount)
    }
    
    private func parseCSVRow(headers: [String], columns: [String]) -> SleepSession? {
        var dateString: String?
        var sleepQuality: Double?
        var duration: TimeInterval?
        var startTimeString: String?
        var endTimeString: String?
        
        for (index, header) in headers.enumerated() {
            guard index < columns.count else { continue }
            let value = columns[index]
            
            let headerLower = header.lowercased()
            
            if headerLower.contains("date") || headerLower.contains("start") {
                if headerLower.contains("start") {
                    startTimeString = value
                } else {
                    dateString = value
                }
            } else if headerLower.contains("end") {
                endTimeString = value
            } else if headerLower.contains("quality") || headerLower.contains("score") {
                sleepQuality = Double(value.replacingOccurrences(of: "%", with: ""))
            } else if headerLower.contains("duration") || headerLower.contains("time in bed") {
                if let hours = parseTimeString(value) {
                    duration = hours * 3600
                }
            }
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        var startDate: Date?
        var endDate: Date?
        
        if let startTimeString = startTimeString {
            startDate = dateFormatter.date(from: startTimeString)
        } else if let dateString = dateString {
            dateFormatter.dateFormat = "yyyy-MM-dd"
            startDate = dateFormatter.date(from: dateString)
        }
        
        if let endTimeString = endTimeString {
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            endDate = dateFormatter.date(from: endTimeString)
        }
        
        guard let start = startDate else { return nil }
        
        let end = endDate ?? (duration != nil ? start.addingTimeInterval(duration!) : nil)
        
        var score: Int?
        if let quality = sleepQuality {
            score = Int(quality)
        }
        
        return SleepSession(
            id: UUID(),
            startTime: start,
            endTime: end,
            videoFileName: nil,
            photoFileNames: nil,
            heartRateData: nil,
            alarmTime: nil,
            audioFileName: nil,
            movementEvents: nil,
            sleepScore: score
        )
    }
    
    private func parseTimeString(_ timeString: String) -> Double? {
        let components = timeString.components(separatedBy: ":")
        
        if components.count == 2 {
            if let hours = Double(components[0]), let minutes = Double(components[1]) {
                return hours + (minutes / 60.0)
            }
        } else if components.count == 3 {
            if let hours = Double(components[0]), let minutes = Double(components[1]) {
                return hours + (minutes / 60.0)
            }
        } else if let hours = Double(timeString.replacingOccurrences(of: "h", with: "").trimmingCharacters(in: .whitespaces)) {
            return hours
        }
        
        return nil
    }
    
    private func saveSessions() {
        let fileURL = documentsDirectory().appendingPathComponent(sessionsFileName)
        if let encoded = try? JSONEncoder().encode(sessions) {
            try? encoded.write(to: fileURL)
        }
    }
    
    private func loadSessions() {
        let fileURL = documentsDirectory().appendingPathComponent(sessionsFileName)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SleepSession].self, from: data) {
            sessions = decoded
        }
    }
    
    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isRecording = false
    @Published var isSessionRunning = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoDataQueue = DispatchQueue(label: "camera.videodata.queue")
    
    var currentVideoURL: URL?
    var recordingCompletionHandler: ((URL?) -> Void)?
    
    var captureMode: CaptureMode = .off
    var captureInterval: TimeInterval = 60
    var captureTimer: Timer?
    var photoFileNames: [String] = []
    var sessionStartTime: Date?
    
    private var lastFrame: CVPixelBuffer?
    private var motionThreshold: Double = 0.05
    var onMotionDetected: (() -> Void)?
    private var shouldCaptureNextFrame = false
    
    override init() {
        super.init()
        checkAuthorization()
    }
    
    func checkAuthorization() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        if authorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted {
                        self.setupSession()
                    }
                }
            }
        } else if authorizationStatus == .authorized {
            setupSession()
        }
    }
    
    private func setupSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high
            
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                self.captureSession.commitConfiguration()
                return
            }
            
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            
            if self.captureSession.canAddOutput(self.movieOutput) {
                self.captureSession.addOutput(self.movieOutput)
            }
            
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
            self.videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            
            if self.captureSession.canAddOutput(self.videoDataOutput) {
                self.captureSession.addOutput(self.videoDataOutput)
            }
            
            self.captureSession.commitConfiguration()
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                }
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
            }
        }
    }
    
    func startRecording(completion: @escaping (URL?) -> Void) {
        recordingCompletionHandler = completion
        
        let fileName = "sleep_\(UUID().uuidString).mov"
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        
        currentVideoURL = fileURL
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.movieOutput.startRecording(to: fileURL, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
            }
        }
    }
    
    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.movieOutput.stopRecording()
        }
    }
    
    func startPhotoCapture(mode: CaptureMode, interval: TimeInterval) {
        captureMode = mode
        captureInterval = interval
        photoFileNames = []
        sessionStartTime = Date()
        
        if mode == .off { return }
        
        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.capturePhoto()
        }
        
        capturePhoto()
    }
    
    func stopPhotoCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        lastFrame = nil
        shouldCaptureNextFrame = false
    }
    
    func capturePhoto() {
        shouldCaptureNextFrame = true
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        if shouldCaptureNextFrame {
            shouldCaptureNextFrame = false
            saveFrameAsImage(pixelBuffer: pixelBuffer)
        }
        
        if captureMode == .smart {
            if let lastFrame = lastFrame {
                let difference = calculateFrameDifference(current: pixelBuffer, previous: lastFrame)
                
                if difference > motionThreshold {
                    DispatchQueue.main.async {
                        self.onMotionDetected?()
                    }
                }
            }
            
            lastFrame = pixelBuffer
        }
    }
    
    private func saveFrameAsImage(pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        let deviceOrientation = UIDevice.current.orientation
        var orientedImage = ciImage
        
        switch deviceOrientation {
        case .landscapeLeft:
            orientedImage = ciImage.oriented(.right)
        case .landscapeRight:
            orientedImage = ciImage.oriented(.left)
        case .portraitUpsideDown:
            orientedImage = ciImage.oriented(.down)
        case .portrait, .faceUp, .faceDown:
            orientedImage = ciImage.oriented(.up)
        default:
            orientedImage = ciImage.oriented(.up)
        }
        
        guard let cgImage = context.createCGImage(orientedImage, from: orientedImage.extent) else { return }
        
        let uiImage = UIImage(cgImage: cgImage)
        
        guard let imageData = uiImage.jpegData(compressionQuality: 0.8) else { return }
        
        let fileName = "photo_\(UUID().uuidString).jpg"
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        
        do {
            try imageData.write(to: fileURL)
            DispatchQueue.main.async {
                self.photoFileNames.append(fileName)
            }
        } catch {
            print("Error saving photo: \(error)")
        }
    }
    
    private func calculateFrameDifference(current: CVPixelBuffer, previous: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(current, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        
        guard let currentAddress = CVPixelBufferGetBaseAddress(current),
              let previousAddress = CVPixelBufferGetBaseAddress(previous) else {
            return 0
        }
        
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(current)
        
        let sampleSize = 100
        var totalDifference: Double = 0
        var sampleCount = 0
        
        for _ in 0..<sampleSize {
            let x = Int.random(in: 0..<width)
            let y = Int.random(in: 0..<height)
            
            let offset = (y * bytesPerRow) + (x * 4)
            
            let currentPixel = currentAddress.load(fromByteOffset: offset, as: UInt32.self)
            let previousPixel = previousAddress.load(fromByteOffset: offset, as: UInt32.self)
            
            let currentR = Double((currentPixel >> 16) & 0xFF)
            let currentG = Double((currentPixel >> 8) & 0xFF)
            let currentB = Double(currentPixel & 0xFF)
            
            let previousR = Double((previousPixel >> 16) & 0xFF)
            let previousG = Double((previousPixel >> 8) & 0xFF)
            let previousB = Double(previousPixel & 0xFF)
            
            let diff = abs(currentR - previousR) + abs(currentG - previousG) + abs(currentB - previousB)
            totalDifference += diff
            sampleCount += 1
        }
        
        return (totalDifference / Double(sampleCount)) / (255.0 * 3.0)
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRecording = false
            
            if error == nil {
                self.recordingCompletionHandler?(outputFileURL)
            } else {
                self.recordingCompletionHandler?(nil)
            }
            
            self.recordingCompletionHandler = nil
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        context.coordinator.previewLayer = previewLayer
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = context.coordinator.previewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = SessionManager()
    @State private var showingRecording = false
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var showingImportPicker = false
    @State private var importResult: (success: Int, failed: Int)?
    @State private var showingImportAlert = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color(white: 0.4), Color(white: 0.25)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        VStack(spacing: 4) {
                            Text("NightPulse")
                                .font(.system(size: 36, weight: .ultraLight, design: .rounded))
                                .foregroundColor(Color(white: 0.6))
                            
                            Text("PLUS")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .tracking(3)
                                .foregroundColor(Color(white: 0.4))
                        }
                    }
                    .padding(.top, 50)
                    
                    VStack(spacing: 12) {
                        Button(action: {
                            showingRecording = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 20))
                                Text("Start Sleep Session")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .foregroundColor(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(
                                LinearGradient(
                                    colors: [Color(white: 0.25), Color(white: 0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(16)
                            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
                        }
                        
                        Button(action: {
                            showingImport = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 18))
                                Text("Import Sleep Data")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundColor(Color(white: 0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(white: 0.12))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    if !sessionManager.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("PREVIOUS SESSIONS")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .tracking(2)
                                .foregroundColor(Color(white: 0.45))
                                .padding(.horizontal, 24)
                            
                            ForEach(sessionManager.sessions) { session in
                                SessionRowView(session: session, sessionManager: sessionManager)
                            }
                        }
                        .padding(.top, 32)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
            .background(Color(red: 0, green: 0, blue: 0))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Color(white: 0.5))
                    }
                }
            }
            .fullScreenCover(isPresented: $showingRecording) {
                RecordingView(sessionManager: sessionManager)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingImport) {
                ImportDataView(sessionManager: sessionManager)
            }
            .alert("Import Complete", isPresented: $showingImportAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                if let result = importResult {
                    Text("Successfully imported \(result.success) sessions.\(result.failed > 0 ? " \(result.failed) failed." : "")")
                }
            }
        }
    }
}

struct SessionRowView: View {
    let session: SleepSession
    @ObservedObject var sessionManager: SessionManager
    @State private var showingPlayer = false
    @State private var showingDeleteAlert = false
    
    var hasMedia: Bool {
        (session.videoFileName != nil) || (session.photoFileNames?.isEmpty == false)
    }
    
    var body: some View {
        Button(action: {
            if hasMedia {
                showingPlayer = true
            }
        }) {
            HStack(spacing: 16) {
                Image(systemName: hasMedia ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(white: 0.5), Color(white: 0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(white: 0.75))
                    
                    HStack(spacing: 8) {
                        Text("Duration: \(session.durationFormatted)")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.45))
                        
                        if let photoCount = session.photoFileNames?.count, photoCount > 0 {
                            Text("•")
                                .foregroundColor(Color(white: 0.3))
                            Text("\(photoCount) photos")
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.45))
                        }
                    }
                }
                
                Spacer()
                
                Button(action: {
                    showingDeleteAlert = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.35))
                        .padding(10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(white: 0.08))
                    .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
            )
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showingPlayer) {
            if hasMedia {
                MediaPlayerView(session: session)
            }
        }
        .alert("Delete Session", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                sessionManager.deleteSession(session)
            }
        } message: {
            Text("Are you sure you want to delete this sleep session and its media?")
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("captureMode") private var captureModeRaw: String = CaptureMode.smart.rawValue
    @AppStorage("captureInterval") private var captureInterval: Double = 60
    @AppStorage("healthKitEnabled") private var healthKitEnabled = true
    @AppStorage("watchEnabled") private var watchEnabled = true
    @AppStorage("alarmEnabled") private var alarmEnabled = false
    @AppStorage("audioMonitoringEnabled") private var audioMonitoringEnabled = true
    @AppStorage("defaultAlarmHour") private var defaultAlarmHour = 7
    @AppStorage("defaultAlarmMinute") private var defaultAlarmMinute = 0
    
    @StateObject private var healthKitManager = HealthKitManager()
    @StateObject private var watchManager = WatchConnectivityManager()
    @StateObject private var alarmManager = AlarmManager()
    
    var captureMode: CaptureMode {
        CaptureMode(rawValue: captureModeRaw) ?? .smart
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 24) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("HEALTH & WATCH")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                                
                                Text("Connect your devices")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.35))
                            }
                            Spacer()
                        }
                        
                        VStack(spacing: 14) {
                            HStack {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color.red.opacity(0.7), Color.red.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Apple Health")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    
                                    Text(healthKitManager.isAuthorized ? "Connected" : "Tap to connect")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $healthKitEnabled)
                                    .labelsHidden()
                                    .tint(Color(white: 0.65))
                                    .onChange(of: healthKitEnabled) { oldValue, newValue in
                                        if newValue && !healthKitManager.isAuthorized {
                                            healthKitManager.checkAuthorization()
                                        }
                                    }
                            }
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                            
                            HStack {
                                Image(systemName: "applewatch")
                                    .font(.system(size: 20))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color(white: 0.5), Color(white: 0.35)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Apple Watch")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    
                                    Text(watchManager.isWatchReachable ? "Connected" : watchManager.isWatchConnected ? "Not reachable" : "Not connected")
                                        .font(.system(size: 13))
                                        .foregroundColor(watchManager.isWatchReachable ? Color.green : Color(white: 0.4))
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $watchEnabled)
                                    .labelsHidden()
                                    .tint(Color(white: 0.65))
                            }
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                            
                            HStack {
                                Image(systemName: "waveform")
                                    .font(.system(size: 20))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color.purple.opacity(0.7), Color.purple.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Audio Monitoring")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    
                                    Text("Track movement via sound")
                                        .font(.system(size: 13))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $audioMonitoringEnabled)
                                    .labelsHidden()
                                    .tint(Color(white: 0.65))
                            }
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(20)
                    
                    Divider()
                        .background(Color(white: 0.15))
                        .padding(.vertical, 20)
                    
                    VStack(spacing: 24) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ALARM SETTINGS")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                                
                                Text("Set your wake up time")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.35))
                            }
                            Spacer()
                        }
                        
                        VStack(spacing: 14) {
                            HStack {
                                Image(systemName: "alarm.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [Color.orange.opacity(0.7), Color.orange.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 36)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Wake Up Alarm")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Color(white: 0.75))
                                    
                                    if alarmEnabled {
                                        Text(String(format: "%02d:%02d", defaultAlarmHour, defaultAlarmMinute))
                                            .font(.system(size: 13, design: .rounded))
                                            .foregroundColor(Color(white: 0.4))
                                    } else {
                                        Text("Disabled")
                                            .font(.system(size: 13))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                                
                                Spacer()
                                
                                Toggle("", isOn: $alarmEnabled)
                                    .labelsHidden()
                                    .tint(Color(white: 0.65))
                                    .onChange(of: alarmEnabled) { oldValue, newValue in
                                        if newValue && !alarmManager.notificationPermissionGranted {
                                            alarmManager.requestPermission()
                                        }
                                    }
                            }
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                            
                            if alarmEnabled {
                                VStack(spacing: 12) {
                                    HStack {
                                        Text("Default Wake Time")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(Color(white: 0.6))
                                        Spacer()
                                    }
                                    
                                    HStack(spacing: 20) {
                                        Picker("Hour", selection: $defaultAlarmHour) {
                                            ForEach(0..<24) { hour in
                                                Text(String(format: "%02d", hour))
                                                    .tag(hour)
                                            }
                                        }
                                        .pickerStyle(.wheel)
                                        .frame(width: 80)
                                        
                                        Text(":")
                                            .font(.system(size: 24, weight: .light))
                                            .foregroundColor(Color(white: 0.5))
                                        
                                        Picker("Minute", selection: $defaultAlarmMinute) {
                                            ForEach(0..<60) { minute in
                                                Text(String(format: "%02d", minute))
                                                    .tag(minute)
                                            }
                                        }
                                        .pickerStyle(.wheel)
                                        .frame(width: 80)
                                    }
                                    .frame(height: 120)
                                }
                                .padding(18)
                                .background(Color(white: 0.06))
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(20)
                    
                    Divider()
                        .background(Color(white: 0.15))
                        .padding(.vertical, 20)
                    
                    VStack(spacing: 24) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("TIME-LAPSE SETTINGS")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                                
                                Text("Configure photo capture")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.35))
                            }
                            Spacer()
                        }
                        
                        VStack(spacing: 14) {
                            ForEach(CaptureMode.allCases, id: \.self) { mode in
                                Button(action: {
                                    captureModeRaw = mode.rawValue
                                }) {
                                    HStack(spacing: 18) {
                                        Image(systemName: mode.icon)
                                            .font(.system(size: 22))
                                            .foregroundStyle(
                                                LinearGradient(
                                                    colors: [Color(white: 0.55), Color(white: 0.4)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 36)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(mode.rawValue)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(Color(white: 0.75))
                                            
                                            Text(mode.description)
                                                .font(.system(size: 13))
                                                .foregroundColor(Color(white: 0.4))
                                        }
                                        
                                        Spacer()
                                        
                                        if captureMode == mode {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(Color(white: 0.65))
                                        }
                                    }
                                    .padding(18)
                                    .background(Color(white: 0.08))
                                    .cornerRadius(12)
                                }
                            }
                        }
                        
                        if captureMode != .off {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Capture Interval")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(Color(white: 0.65))
                                    Spacer()
                                    Text(intervalText)
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                
                                Slider(value: $captureInterval, in: 10...300, step: 10) {
                                    Text("Interval")
                                } minimumValueLabel: {
                                    Text("10s")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(white: 0.4))
                                } maximumValueLabel: {
                                    Text("5m")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                .tint(Color(white: 0.55))
                            }
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(20)
                    
                    Divider()
                        .background(Color(white: 0.15))
                        .padding(.vertical, 20)
                    
                    VStack(spacing: 14) {
                        Button(action: shareApp) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18))
                                Text("Share NightPulsePlus")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(white: 0.35))
                            }
                            .foregroundColor(Color(white: 0.75))
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                        }
                        
                        Button(action: sendFeedback) {
                            HStack {
                                Image(systemName: "envelope")
                                    .font(.system(size: 18))
                                Text("Send Feedback")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(white: 0.35))
                            }
                            .foregroundColor(Color(white: 0.75))
                            .padding(18)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 40)
            }
            .background(Color(red: 0, green: 0, blue: 0))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
        }
    }
    
    private var intervalText: String {
        let seconds = Int(captureInterval)
        if seconds >= 60 {
            let minutes = seconds / 60
            return "\(minutes) min"
        }
        return "\(seconds) sec"
    }
    
    private func shareApp() {
        let activityVC = UIActivityViewController(
            activityItems: ["Check out NightPulsePlus - Premium sleep tracking with time-lapse recording and health integration!"],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(activityVC, animated: true)
        }
    }
    
    private func sendFeedback() {
        let email = "feedback@nightpulseplus.app"
        let subject = "NightPulsePlus Feedback"
        let body = ""
        
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}

struct RecordingView: View {
    @ObservedObject var sessionManager: SessionManager
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var watchManager = WatchConnectivityManager()
    @StateObject private var alarmManager = AlarmManager()
    @StateObject private var audioMonitor = AudioMonitor()
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("captureMode") private var captureModeRaw: String = CaptureMode.smart.rawValue
    @AppStorage("captureInterval") private var captureInterval: Double = 60
    @AppStorage("watchEnabled") private var watchEnabled = true
    @AppStorage("alarmEnabled") private var alarmEnabled = false
    @AppStorage("audioMonitoringEnabled") private var audioMonitoringEnabled = true
    @AppStorage("defaultAlarmHour") private var defaultAlarmHour = 7
    @AppStorage("defaultAlarmMinute") private var defaultAlarmMinute = 0
    
    var captureMode: CaptureMode {
        CaptureMode(rawValue: captureModeRaw) ?? .smart
    }
    
    @State private var currentSession: SleepSession?
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var showingStopAlert = false
    @State private var motionDetectedCount = 0
    @State private var heartRateReadings: [HeartRateReading] = []
    @State private var customAlarmTime: Date = Date()
    @State private var showingAlarmPicker = false
    @State private var audioPermissionGranted = false
    
    var body: some View {
        ZStack {
            Color(red: 0, green: 0, blue: 0)
                .ignoresSafeArea()
            
            if cameraManager.authorizationStatus == .authorized && currentSession == nil {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
                    .opacity(0.3)
            }
            
            VStack {
                HStack {
                    Spacer()
                    
                    Button(action: {
                        if currentSession != nil {
                            showingStopAlert = true
                        } else {
                            dismiss()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18))
                            .foregroundColor(Color(white: 0.5))
                            .padding(12)
                            .background(Color(white: 0.1))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                
                Spacer()
                
                VStack(spacing: 24) {
                    if currentSession != nil {
                        VStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                Text("Recording")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.5))
                            }
                            
                            Text(timeString(from: elapsedTime))
                                .font(.system(size: 48, weight: .thin, design: .monospaced))
                                .foregroundColor(Color(white: 0.6))
                            
                            if watchEnabled, let heartRate = watchManager.currentHeartRate {
                                HStack(spacing: 6) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 14))
                                    Text("\(Int(heartRate)) BPM")
                                        .font(.system(size: 15, design: .monospaced))
                                }
                                .foregroundColor(Color.red.opacity(0.7))
                                .padding(.top, 4)
                            }
                            
                            if audioMonitoringEnabled {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14))
                                    Text("\(audioMonitor.movementEvents.count) movements")
                                        .font(.system(size: 15, design: .monospaced))
                                }
                                .foregroundColor(Color.purple.opacity(0.7))
                                .padding(.top, 4)
                            }
                        }
                        
                        Button(action: {
                            showingStopAlert = true
                        }) {
                            HStack {
                                Image(systemName: "stop.fill")
                                Text("End Session")
                                    .font(.system(size: 18, weight: .medium))
                            }
                            .foregroundColor(Color(white: 0.8))
                            .frame(width: 200)
                            .padding(.vertical, 16)
                            .background(Color(white: 0.15))
                            .cornerRadius(12)
                        }
                    } else {
                        VStack(spacing: 20) {
                            VStack(spacing: 12) {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(Color(white: 0.3))
                                
                                Text("Ready to sleep")
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(white: 0.4))
                                
                                if watchEnabled && watchManager.isWatchReachable {
                                    HStack(spacing: 6) {
                                        Image(systemName: "applewatch")
                                            .font(.system(size: 12))
                                        Text("Watch connected")
                                            .font(.system(size: 13))
                                    }
                                    .foregroundColor(Color.green.opacity(0.7))
                                    .padding(.top, 4)
                                }
                            }
                            
                            if alarmEnabled {
                                Button(action: {
                                    showingAlarmPicker = true
                                }) {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "alarm")
                                                .font(.system(size: 16))
                                            Text("Wake at")
                                                .font(.system(size: 14))
                                        }
                                        .foregroundColor(Color(white: 0.45))
                                        
                                        Text(customAlarmTime.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 28, weight: .light, design: .rounded))
                                            .foregroundColor(Color.orange.opacity(0.8))
                                    }
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 24)
                                    .background(Color(white: 0.08))
                                    .cornerRadius(12)
                                }
                            }
                        }
                        
                        Button(action: {
                            startSession()
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Start Recording")
                                    .font(.system(size: 18, weight: .medium))
                            }
                            .foregroundColor(Color(white: 0.8))
                            .frame(width: 200)
                            .padding(.vertical, 16)
                            .background(Color(white: 0.15))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .onAppear {
            if cameraManager.authorizationStatus == .notDetermined {
                cameraManager.checkAuthorization()
            }
            cameraManager.startSession()
            
            if audioMonitoringEnabled {
                audioMonitor.checkPermission { granted in
                    audioPermissionGranted = granted
                }
            }
            
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = defaultAlarmHour
            components.minute = defaultAlarmMinute
            
            if var alarmDate = Calendar.current.date(from: components) {
                if alarmDate <= Date() {
                    alarmDate = Calendar.current.date(byAdding: .day, value: 1, to: alarmDate) ?? alarmDate
                }
                customAlarmTime = alarmDate
            }
        }
        .onDisappear {
            timer?.invalidate()
            cameraManager.stopSession()
        }
        .alert("End Sleep Session", isPresented: $showingStopAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End Session", role: .destructive) {
                stopSession()
            }
        } message: {
            Text("Are you sure you want to end this sleep session?")
        }
        .sheet(isPresented: $showingAlarmPicker) {
            AlarmPickerView(alarmTime: $customAlarmTime)
        }
    }
    
    private func startSession() {
        let session = SleepSession(id: UUID(), startTime: Date(), endTime: nil, videoFileName: nil, photoFileNames: nil, heartRateData: nil, alarmTime: alarmEnabled ? customAlarmTime : nil, audioFileName: nil, movementEvents: nil, sleepScore: nil)
        currentSession = session
        sessionManager.addSession(session)
        heartRateReadings = []
        
        if alarmEnabled {
            alarmManager.scheduleAlarm(at: customAlarmTime)
        }
        
        if audioMonitoringEnabled && audioPermissionGranted {
            audioMonitor.startMonitoring(saveAudio: false)
        }
        
        if captureMode != .off {
            cameraManager.startPhotoCapture(mode: captureMode, interval: captureInterval)
            
            if captureMode == .smart {
                cameraManager.onMotionDetected = { [weak cameraManager] in
                    motionDetectedCount += 1
                    cameraManager?.capturePhoto()
                }
            }
        }
        
        if watchEnabled {
            watchManager.startHeartRateMonitoring()
            
            watchManager.onHeartRateReceived = { [weak self] heartRate in
                let reading = HeartRateReading(bpm: heartRate, timestamp: Date())
                self?.heartRateReadings.append(reading)
            }
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let startTime = currentSession?.startTime {
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    private func stopSession() {
        timer?.invalidate()
        timer = nil
        
        alarmManager.cancelAlarm()
        
        let audioURL = audioMonitor.stopMonitoring()
        let movements = audioMonitor.movementEvents
        
        cameraManager.stopPhotoCapture()
        cameraManager.onMotionDetected = nil
        
        if watchEnabled {
            watchManager.stopHeartRateMonitoring()
            watchManager.onHeartRateReceived = nil
        }
        
        if var session = currentSession {
            session.endTime = Date()
            
            if !cameraManager.photoFileNames.isEmpty {
                session.photoFileNames = cameraManager.photoFileNames
            }
            
            if !heartRateReadings.isEmpty {
                session.heartRateData = heartRateReadings
            }
            
            if let audioURL = audioURL {
                session.audioFileName = audioURL.lastPathComponent
            }
            
            if !movements.isEmpty {
                session.movementEvents = movements
            }
            
            let score = audioMonitor.calculateSleepScore(
                duration: session.duration,
                movementEvents: movements,
                heartRateData: heartRateReadings.isEmpty ? nil : heartRateReadings
            )
            session.sleepScore = score
            
            sessionManager.updateSession(session)
        }
        
        currentSession = nil
        dismiss()
    }
    
    private func timeString(from timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

struct MediaPlayerView: View {
    let session: SleepSession
    @Environment(\.dismiss) private var dismiss
    @State private var currentPhotoIndex = 0
    @State private var isPlaying = false
    @State private var playbackTimer: Timer?
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    
    var hasVideo: Bool { session.videoFileName != nil }
    var hasPhotos: Bool { (session.photoFileNames?.isEmpty == false) }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0, green: 0, blue: 0)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        if hasVideo, let videoFileName = session.videoFileName {
                            let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent(videoFileName)
                            
                            VideoPlayerRepresentable(url: fileURL)
                                .frame(height: 300)
                                .cornerRadius(12)
                        } else if hasPhotos, let photoFileNames = session.photoFileNames {
                            VStack(spacing: 12) {
                                let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                    .appendingPathComponent(photoFileNames[currentPhotoIndex])
                                
                                if let uiImage = UIImage(contentsOfFile: fileURL.path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(height: 300)
                                        .cornerRadius(12)
                                }
                                
                                HStack(spacing: 16) {
                                    Button(action: {
                                        if currentPhotoIndex > 0 {
                                            currentPhotoIndex -= 1
                                        }
                                    }) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(currentPhotoIndex > 0 ? Color(white: 0.6) : Color(white: 0.3))
                                    }
                                    .disabled(currentPhotoIndex == 0)
                                    
                                    Button(action: {
                                        isPlaying.toggle()
                                        if isPlaying {
                                            startPlayback()
                                        } else {
                                            stopPlayback()
                                        }
                                    }) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(Color(white: 0.6))
                                    }
                                    
                                    Button(action: {
                                        if currentPhotoIndex < (photoFileNames.count - 1) {
                                            currentPhotoIndex += 1
                                        }
                                    }) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(currentPhotoIndex < (photoFileNames.count - 1) ? Color(white: 0.6) : Color(white: 0.3))
                                    }
                                    .disabled(currentPhotoIndex == (photoFileNames.count - 1))
                                }
                                .padding(.vertical, 12)
                                
                                Text("\(currentPhotoIndex + 1) of \(photoFileNames.count)")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.4))
                            }
                        }
                        
                        VStack(spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SLEEP SUMMARY")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .tracking(2)
                                        .foregroundColor(Color(white: 0.45))
                                }
                                Spacer()
                            }
                            
                            if let sleepScore = session.sleepScore {
                                VStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .stroke(Color(white: 0.15), lineWidth: 12)
                                            .frame(width: 140, height: 140)
                                        
                                        Circle()
                                            .trim(from: 0, to: CGFloat(sleepScore) / 100.0)
                                            .stroke(
                                                session.sleepQualityColor,
                                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                                            )
                                            .frame(width: 140, height: 140)
                                            .rotationEffect(.degrees(-90))
                                        
                                        VStack(spacing: 4) {
                                            Text("\(sleepScore)")
                                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                                .foregroundColor(session.sleepQualityColor)
                                            
                                            Text(session.sleepQuality)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(Color(white: 0.5))
                                        }
                                    }
                                    
                                    Text("Sleep Quality Score")
                                        .font(.system(size: 15))
                                        .foregroundColor(Color(white: 0.5))
                                }
                                .padding(.vertical, 20)
                            }
                            
                            VStack(spacing: 12) {
                                SleepStatCard(
                                    icon: "bed.double.fill",
                                    title: "Sleep Duration",
                                    value: session.durationFormatted,
                                    color: .blue
                                )
                                
                                if let movementCount = session.movementEvents?.count {
                                    SleepStatCard(
                                        icon: "waveform",
                                        title: "Movements Detected",
                                        value: "\(movementCount)",
                                        color: .purple
                                    )
                                }
                                
                                if let avgHeartRate = session.averageHeartRate {
                                    SleepStatCard(
                                        icon: "heart.fill",
                                        title: "Avg Heart Rate",
                                        value: "\(Int(avgHeartRate)) BPM",
                                        color: .red
                                    )
                                }
                                
                                if let photoCount = session.photoFileNames?.count {
                                    SleepStatCard(
                                        icon: "camera.fill",
                                        title: "Photos Captured",
                                        value: "\(photoCount)",
                                        color: .cyan
                                    )
                                }
                                
                                if let alarmTime = session.alarmTime {
                                    SleepStatCard(
                                        icon: "alarm.fill",
                                        title: "Alarm Time",
                                        value: alarmTime.formatted(date: .omitted, time: .shortened),
                                        color: .orange
                                    )
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("DETAILS")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                                Spacer()
                            }
                            
                            DetailRow(label: "Start Time", value: session.startTime.formatted(date: .abbreviated, time: .shortened))
                            
                            if let endTime = session.endTime {
                                DetailRow(label: "End Time", value: endTime.formatted(date: .abbreviated, time: .shortened))
                            }
                            
                            if let heartRateCount = session.heartRateData?.count {
                                DetailRow(label: "Heart Rate Readings", value: "\(heartRateCount)")
                            }
                            
                            if let movementCount = session.movementEvents?.count {
                                DetailRow(label: "Movement Events", value: "\(movementCount)")
                            }
                        }
                        .padding(20)
                        .background(Color(white: 0.08))
                        .cornerRadius(12)
                        
                        Button(action: {
                            shareSession()
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18))
                                Text("Share Sleep Session")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [Color(white: 0.25), Color(white: 0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(12)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Sleep Recording")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Color(white: 0.6))
                        Text(session.startTime.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        stopPlayback()
                        dismiss()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
            .onDisappear {
                stopPlayback()
            }
            .sheet(isPresented: $showingShareSheet) {
                if !shareItems.isEmpty {
                    ShareSheet(items: shareItems)
                }
            }
        }
    }
    
    private func startPlayback() {
        guard let photoFileNames = session.photoFileNames, !photoFileNames.isEmpty else { return }
        
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if currentPhotoIndex < (photoFileNames.count - 1) {
                currentPhotoIndex += 1
            } else {
                currentPhotoIndex = 0
            }
        }
    }
    
    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    private func shareSession() {
        var items: [Any] = []
        
        let scoreText = session.sleepScore != nil ? "\nSleep Score: \(session.sleepScore!) - \(session.sleepQuality)" : ""
        let movementText = session.movementEvents != nil ? "\nMovements Detected: \(session.movementEvents!.count)" : ""
        
        let sleepSummary = """
        NightPulsePlus Sleep Session
        Date: \(session.startTime.formatted(date: .long, time: .omitted))
        Duration: \(session.durationFormatted)\(scoreText)
        \(session.averageHeartRate != nil ? "Avg Heart Rate: \(Int(session.averageHeartRate!)) BPM" : "")\(movementText)
        """
        
        items.append(sleepSummary)
        
        if let videoFileName = session.videoFileName {
            let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(videoFileName)
            items.append(fileURL)
        }
        
        if let photoFileNames = session.photoFileNames, !photoFileNames.isEmpty {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            
            if photoFileNames.count <= 10 {
                for fileName in photoFileNames {
                    let fileURL = documentsURL.appendingPathComponent(fileName)
                    items.append(fileURL)
                }
            } else {
                let firstPhotoURL = documentsURL.appendingPathComponent(photoFileNames[0])
                items.append(firstPhotoURL)
            }
        }
        
        shareItems = items
        showingShareSheet = true
    }
}

struct SleepStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.8), color.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
                
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(white: 0.8))
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color(white: 0.08))
        .cornerRadius(12)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

struct VideoPlayerView: View {
    let videoFileName: String
    let session: SleepSession
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0, green: 0, blue: 0)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent(videoFileName)
                        
                        VideoPlayerRepresentable(url: fileURL)
                            .frame(height: 300)
                            .cornerRadius(12)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Session Details")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(Color(white: 0.6))
                                Spacer()
                            }
                            
                            DetailRow(label: "Start Time", value: session.startTime.formatted(date: .abbreviated, time: .shortened))
                            
                            if let endTime = session.endTime {
                                DetailRow(label: "End Time", value: endTime.formatted(date: .abbreviated, time: .shortened))
                            }
                            
                            DetailRow(label: "Duration", value: session.durationFormatted)
                        }
                        .padding(20)
                        .background(Color(white: 0.08))
                        .cornerRadius(12)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Sleep Recording")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(Color(white: 0.4))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(white: 0.6))
        }
    }
}

struct ImportDataView: View {
    @ObservedObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false
    @State private var importResult: (success: Int, failed: Int)?
    @State private var showingResult = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0, green: 0, blue: 0)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 30) {
                        VStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 60))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.7), Color.blue.opacity(0.5)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            
                            Text("Import Sleep Data")
                                .font(.system(size: 28, weight: .light))
                                .foregroundColor(Color(white: 0.6))
                        }
                        .padding(.top, 40)
                        
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("SUPPORTED SOURCES")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                                
                                Text("Import your historical sleep data from other apps")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            
                            VStack(spacing: 14) {
                                SupportedAppCard(
                                    name: "Sleep Cycle",
                                    icon: "moon.stars.fill",
                                    description: "Recommended sleep tracker",
                                    isRecommended: true
                                )
                                
                                SupportedAppCard(
                                    name: "Apple Health",
                                    icon: "heart.fill",
                                    description: "Export from Health app",
                                    isRecommended: false
                                )
                                
                                SupportedAppCard(
                                    name: "CSV File",
                                    icon: "doc.text.fill",
                                    description: "Custom CSV format",
                                    isRecommended: false
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("HOW TO IMPORT")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .tracking(2)
                                    .foregroundColor(Color(white: 0.45))
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                ImportStep(number: "1", text: "Export your sleep data from Sleep Cycle or other app as CSV")
                                ImportStep(number: "2", text: "Save the file to your device")
                                ImportStep(number: "3", text: "Tap 'Select CSV File' below")
                                ImportStep(number: "4", text: "Choose your exported file")
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        Button(action: {
                            showingFilePicker = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 18))
                                Text("Select CSV File")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .foregroundColor(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.7), Color.blue.opacity(0.5)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(14)
                            .shadow(color: Color.blue.opacity(0.3), radius: 10, x: 0, y: 4)
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.commaSeparatedText, .text],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let result = sessionManager.importFromCSV(url: url)
                        importResult = result
                        showingResult = true
                    }
                case .failure(let error):
                    print("Import error: \(error.localizedDescription)")
                }
            }
            .alert("Import Complete", isPresented: $showingResult) {
                Button("OK", role: .cancel) {
                    if let result = importResult, result.success > 0 {
                        dismiss()
                    }
                }
            } message: {
                if let result = importResult {
                    if result.success > 0 {
                        Text("Successfully imported \(result.success) sleep sessions!\(result.failed > 0 ? "\n\(result.failed) entries could not be imported." : "")")
                    } else {
                        Text("Failed to import data. Please check your file format and try again.")
                    }
                }
            }
        }
    }
}

struct SupportedAppCard: View {
    let name: String
    let icon: String
    let description: String
    let isRecommended: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(
                    LinearGradient(
                        colors: isRecommended ? [Color.blue.opacity(0.8), Color.blue.opacity(0.6)] : [Color(white: 0.5), Color(white: 0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 50)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(white: 0.8))
                    
                    if isRecommended {
                        Text("RECOMMENDED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundColor(Color.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.45))
            }
            
            Spacer()
        }
        .padding(18)
        .background(Color(white: 0.08))
        .cornerRadius(12)
    }
}

struct ImportStep: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color.blue.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(14)
            
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.6))
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
    }
}

struct AlarmPickerView: View {
    @Binding var alarmTime: Date
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0, green: 0, blue: 0)
                    .ignoresSafeArea()
                
                VStack(spacing: 30) {
                    VStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.orange.opacity(0.7), Color.orange.opacity(0.5)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        
                        Text("Wake Up Time")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(Color(white: 0.6))
                    }
                    .padding(.top, 40)
                    
                    DatePicker("", selection: $alarmTime, displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .colorScheme(.dark)
                    
                    Button(action: {
                        dismiss()
                    }) {
                        Text("Set Alarm")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                LinearGradient(
                                    colors: [Color(white: 0.25), Color(white: 0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 30)
                    
                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
        }
    }
}

struct VideoPlayerRepresentable: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.view.backgroundColor = .black
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
    }
}