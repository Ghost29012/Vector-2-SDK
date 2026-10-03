import Foundation

/// Editor-facing values mirrored from Vector 2's settings_default.xml.
/// Runtime debug flags and GUI-only settings intentionally stay game-owned.
enum Vector2RuntimeSettings {
    static let modelBoundingBoxSize = 300
    static let modelLayer = "Model"
    static let cameraMinZoom = 0.1
    static let cameraMaxZoom = 1.3
    static let cameraDefaultZoom = 0.5
    static let cameraMaxSpeed = 50.0
    static let cameraFluency = 2.0
    static let gridCellWidth = 300
    static let gridCellHeight = 300
    static let generatorMaxAttemptCount = 3
    static let roomPropertiesFile = "room_properties.xml"

    static let platformFillHex = "0000FF40"
    static let platformOutlineHex = "0000FFFF"
    static let triggerFillHex = "FFFF0040"
    static let triggerOutlineHex = "CE7D14FF"
    static let cameraFillHex = "9B30FF40"
    static let cameraOutlineHex = "2E0854FF"
    static let spawnFillHex = "00800080"
    static let spawnOutlineHex = "004000FF"
    static let areaFillHex = "FF000040"
    static let areaOutlineHex = "800000FF"
}
