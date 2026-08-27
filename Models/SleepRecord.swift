import Foundation

struct SleepRecord: Identifiable, Codable, Equatable {
 let id: UUID
 let startTime: Date
 let endTime: Date
 init(id: UUID = UUID(), startTime: Date, endTime: Date) { self.id = id; self.startTime = startTime; self.endTime = endTime }
 var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
}
