import SwiftUI
import Foundation

struct SleepView: View { let record: SleepRecord; var body: some View { VStack { Text("Sleep").font(.title); Text(record.duration.formatted()) }.padding() } }
