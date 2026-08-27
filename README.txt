NightPulse SwiftUI source

Add all Swift files under App, Models, Managers, and Views to an Xcode iOS app target named NightPulse. Enable camera usage with NSCameraUsageDescription in the target's Info settings.

URL scheme setup

In the NightPulsePlus target, add URL Types with URL Schemes set to nightpulse. The app handles nightpulse://migrate?code=RESTRIGHTVIP and nightpulse://redeem?code=RESTRIGHTVIP through SwiftUI onOpenURL.
