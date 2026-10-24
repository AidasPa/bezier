// Sends an automation command to a running debug Bezier (BEZIER_AUTOMATION=1).
// Usage: swift scripts/bezierctl.swift key:cmd+s | action:toggleSidebar:
import Foundation
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("app.bezier.automation"), object: command, userInfo: nil, deliverImmediately: true)
