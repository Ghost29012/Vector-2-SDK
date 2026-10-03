import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Trap manifest and its compiled `v2trap_<id>.xml` library.
struct CustomTrapDefinition: Identifiable, Equatable {
    enum Impact: String, CaseIterable, Identifiable {
        case defeat = "Instant defeat"
        case armor = "Damage armour"
        case knockback = "Knockback only"
        var id: String { rawValue }
    }

    enum ArmorSlot: String, CaseIterable, Identifiable {
        case helmet = "Helmet", torso = "Torso", hands = "Hands", legs = "Legs", belt = "Belt"
        var id: String { rawValue }
    }
    enum Mount: String, CaseIterable, Identifiable {
        case floor = "Floor", wall = "Wall", ceiling = "Ceiling", floating = "Floating"
        var id: String { rawValue }
    }

    enum Mechanism: String, CaseIterable, Identifiable {
        case contact = "Contact hazard"
        case beam = "Beam"
        case flame = "Flame"
        case tesla = "Tesla"
        case rolling = "Rolling ball"

        var id: String { rawValue }
        var subtitle: String {
            switch self {
            case .contact: return "A tested mine that activates at jump height"
            case .beam: return "A directional laser emitter"
            case .flame: return "A timed flame hazard"
            case .tesla: return "A timed electrical hazard"
            case .rolling: return "A rolling projectile launcher"
            }
        }
        var stockObject: String {
            switch self {
            case .contact: return "Mine_Shortjump"
            case .beam: return "BeamTrapFloating_LR"
            case .flame: return "Flame_Shortjump"
            case .tesla: return "Tesla_Shortjump"
            case .rolling: return "Blackball_Shortjump"
            }
        }

        var supportsCycle: Bool { self != .contact }
        var supportsReach: Bool { self == .beam || self == .flame || self == .tesla }
        var supportsArea: Bool { self != .beam }
        var supportedMounts: [Mount] { self == .beam ? Mount.allCases : [.floor] }

        func stockObject(for mount: Mount) -> String {
            guard self == .beam else { return stockObject }
            switch mount {
            case .floor: return "BeamTrapMounted_DT"
            case .wall: return "BeamTrapMounted_LR"
            case .ceiling: return "BeamTrapMounted_TD"
            case .floating: return "BeamTrapFloating_LR"
            }
        }
    }

    var id: String
    var name: String
    var mechanism: Mechanism = .contact
    var mount: Mount = .floor
    var artwork: String = ""
    var width: Int = 180
    var height: Int = 180
    var cycleFrames: Int = 0
    var reach: Int = 400
    var lethal = true
    var impact: Impact = .defeat
    var armorSlot: ArmorSlot = .torso
    var damageAmount: Int = 1
    var chargeArtwork: String = ""
    var disabledArtwork: String = ""
    var hitArtwork: String = ""
    var idleSound: String = ""
    var chargeSound: String = ""
    var hitSound: String = ""
    var disabledSound: String = ""
    var soundVolume: Double = 1
    var chargeFrames: Int = 20
    var hitFrames: Int = 8
    var enabledByArea = true
    var dangerX: Int = -90
    var dangerY: Int = -180
    var dangerWidth: Int = 180
    var dangerHeight: Int = 180
    var activationX: Int = -260
    var activationY: Int = -260
    var activationWidth: Int = 520
    var activationHeight: Int = 300
    var packageURL: URL?

    var libraryFilename: String { "v2trap_\(Self.clean(id)).xml" }
    var objectName: String { "V2Trap_\(Self.clean(id))" }

    static func load(from projectRoot: URL) -> [CustomTrapDefinition] {
        let folder = projectRoot.appendingPathComponent("custom_traps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "manifest.xml" }
            .compactMap(read)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func read(_ url: URL) -> CustomTrapDefinition? {
        guard let document = try? XMLDocument(contentsOf: url), let root = document.rootElement(), root.name == "CustomTrap" else { return nil }
        func attr(_ name: String, _ fallback: String = "") -> String { root.attribute(forName: name)?.stringValue ?? fallback }
        var result = CustomTrapDefinition(
            id: attr("ID", url.deletingLastPathComponent().lastPathComponent),
            name: attr("Name", "Custom Trap"),
            mechanism: Mechanism(rawValue: attr("Mechanism")) ?? .contact,
            mount: Mount(rawValue: attr("Mount")) ?? .floor,
            artwork: attr("Artwork"),
            width: Int(attr("Width", "180")) ?? 180,
            height: Int(attr("Height", "180")) ?? 180,
            cycleFrames: Int(attr("CycleFrames", "0")) ?? 0,
            reach: Int(attr("Reach", "400")) ?? 400,
            lethal: attr("Lethal", "true") != "false",
            impact: Impact(rawValue: attr("Impact")) ?? (attr("Lethal", "true") == "false" ? .knockback : .defeat),
            armorSlot: ArmorSlot(rawValue: attr("ArmorSlot")) ?? .torso,
            damageAmount: min(12, max(1, Int(attr("DamageAmount", "1")) ?? 1)),
            chargeArtwork: attr("ChargeArtwork"), disabledArtwork: attr("DisabledArtwork"), hitArtwork: attr("HitArtwork"),
            idleSound: attr("IdleSound"), chargeSound: attr("ChargeSound"), hitSound: attr("HitSound"), disabledSound: attr("DisabledSound"),
            soundVolume: Double(attr("SoundVolume", "1")) ?? 1,
            chargeFrames: Int(attr("ChargeFrames", "20")) ?? 20, hitFrames: Int(attr("HitFrames", "8")) ?? 8,
            enabledByArea: attr("EnabledByArea", "true") != "false",
            dangerX: Int(attr("DangerX", "-90")) ?? -90,
            dangerY: Int(attr("DangerY", "-180")) ?? -180,
            dangerWidth: Int(attr("DangerWidth", "180")) ?? 180,
            dangerHeight: Int(attr("DangerHeight", "180")) ?? 180,
            activationX: Int(attr("ActivationX", "-260")) ?? -260,
            activationY: Int(attr("ActivationY", "-260")) ?? -260,
            activationWidth: Int(attr("ActivationWidth", "520")) ?? 520,
            activationHeight: Int(attr("ActivationHeight", "300")) ?? 300
        )
        result.packageURL = url.deletingLastPathComponent()
        return result
    }

    @discardableResult
    func write(to projectRoot: URL) throws -> URL {
        let cleanID = Self.clean(id)
        guard !cleanID.isEmpty else { throw NSError(domain: "CustomTraps", code: 1, userInfo: [NSLocalizedDescriptionKey: "Give the trap a stable ID."]) }
        let package = projectRoot
            .appendingPathComponent("custom_traps", isDirectory: true)
            .appendingPathComponent(cleanID, isDirectory: true)
        let libraries = projectRoot
            .appendingPathComponent("custom_gamedata", isDirectory: true)
            .appendingPathComponent("run_data", isDirectory: true)
            .appendingPathComponent("libraries", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)

        try compileGIFArtwork(projectRoot: projectRoot, package: package, cleanID: cleanID)

        let manifest = XMLElement(name: "CustomTrap")
        attributes([
            "SchemaVersion": "1", "ID": cleanID, "Name": name, "Mechanism": mechanism.rawValue,
            "Mount": mount.rawValue, "Artwork": artwork, "Width": String(width), "Height": String(height),
            "CycleFrames": String(cycleFrames), "Reach": String(reach), "Lethal": lethal ? "true" : "false",
            "Impact": impact.rawValue, "ArmorSlot": armorSlot.rawValue, "DamageAmount": String(damageAmount),
            "ChargeArtwork": chargeArtwork, "DisabledArtwork": disabledArtwork, "HitArtwork": hitArtwork,
            "IdleSound": idleSound, "ChargeSound": chargeSound, "HitSound": hitSound,
            "DisabledSound": disabledSound, "SoundVolume": String(soundVolume),
            "ChargeFrames": String(chargeFrames), "HitFrames": String(hitFrames),
            "EnabledByArea": enabledByArea ? "true" : "false", "Library": libraryFilename,
            "Object": objectName, "DangerX": String(dangerX), "DangerY": String(dangerY),
            "DangerWidth": String(dangerWidth), "DangerHeight": String(dangerHeight),
            "ActivationX": String(activationX), "ActivationY": String(activationY),
            "ActivationWidth": String(activationWidth), "ActivationHeight": String(activationHeight)
        ], to: manifest)
        try xmlDocument(root: manifest).xmlData(options: .nodePrettyPrint).write(to: package.appendingPathComponent("manifest.xml"), options: .atomic)

        let library = compiledLibrary()
        let packageLibrary = package.appendingPathComponent(libraryFilename)
        let runtimeLibrary = libraries.appendingPathComponent(libraryFilename)
        let data = library.xmlData(options: .nodePrettyPrint)
        try data.write(to: packageLibrary, options: .atomic)
        try data.write(to: runtimeLibrary, options: .atomic)

        // A stable ID rename changes both the package folder and runtime
        // filename. Clean the previous pair only after the new pair is safely
        // written so renaming cannot leave ghost traps in the game install.
        if let previousPackage = packageURL?.standardizedFileURL,
           previousPackage != package.standardizedFileURL {
            if let previous = Self.read(previousPackage.appendingPathComponent("manifest.xml")) {
                let previousRuntime = libraries.appendingPathComponent(previous.libraryFilename)
                if FileManager.default.fileExists(atPath: previousRuntime.path) { try? FileManager.default.removeItem(at: previousRuntime) }
            }
            if FileManager.default.fileExists(atPath: previousPackage.path) { try? FileManager.default.removeItem(at: previousPackage) }
        }
        return packageLibrary
    }

    func delete(from projectRoot: URL) throws {
        let package = packageURL ?? projectRoot
            .appendingPathComponent("custom_traps", isDirectory: true)
            .appendingPathComponent(Self.clean(id), isDirectory: true)
        let runtimeLibrary = projectRoot
            .appendingPathComponent("custom_gamedata", isDirectory: true)
            .appendingPathComponent("run_data", isDirectory: true)
            .appendingPathComponent("libraries", isDirectory: true)
            .appendingPathComponent(libraryFilename)
        if FileManager.default.fileExists(atPath: package.path) {
            try FileManager.default.removeItem(at: package)
        }
        if FileManager.default.fileExists(atPath: runtimeLibrary.path) {
            try FileManager.default.removeItem(at: runtimeLibrary)
        }
    }

    func compiledLibrary() -> XMLDocument {
        let root = XMLElement(name: "Root")
        let objects = XMLElement(name: "Objects")
        let object = XMLElement(name: "Object")
        attributes(["Name": objectName, "X": "0", "Y": "0", "EditorTitle": name, "EditorFamily": "Custom"], to: object)
        let content = XMLElement(name: "Content")

        addVisual(artwork, state: "Idle", initiallyVisible: true, to: content)
        addVisual(chargeArtwork, state: "Charge", initiallyVisible: false, to: content)
        addVisual(disabledArtwork, state: "Disabled", initiallyVisible: false, to: content)
        addVisual(hitArtwork, state: "Hit", initiallyVisible: false, to: content)

        if enabledByArea {
            content.addChild(makeActivationTrigger())
        }
        content.addChild(makeDangerTrigger())

        let objectProperties = XMLElement(name: "Properties")
        let objectStatic = XMLElement(name: "Static")
        let variables = XMLElement(name: "ContentVariable")
        let defaults: [(String, Int)] = [
            ("DangerX", dangerX), ("DangerY", dangerY), ("DangerWidth", dangerWidth), ("DangerHeight", dangerHeight),
            ("ActivationX", activationX), ("ActivationY", activationY),
            ("ActivationWidth", activationWidth), ("ActivationHeight", activationHeight)
        ]
        for (key, value) in defaults {
            let variable = XMLElement(name: "Variable")
            attributes(["Name": key, "Type": "E_Int", "Default": String(value), "AvailableTypes": "E_Int"], to: variable)
            variables.addChild(variable)
        }
        let areaVariable = XMLElement(name: "Variable")
        attributes(["Name": "EnableArea", "Default": enabledByArea ? "1" : "0"], to: areaVariable)
        variables.addChild(areaVariable)
        objectStatic.addChild(variables); objectProperties.addChild(objectStatic)
        object.addChild(content); object.addChild(objectProperties); objects.addChild(object); root.addChild(objects)
        return xmlDocument(root: root)
    }

    /// A genuinely new Vector object: proximity enters/exits toggle the trap's
    /// own danger trigger. No stock trap object is embedded or overridden.
    private func makeActivationTrigger() -> XMLElement {
        let trigger = XMLElement(name: "Trigger")
        attributes(["Name": "Activation Area", "X": "~ActivationX", "Y": "~ActivationY", "Width": "~ActivationWidth", "Height": "~ActivationHeight"], to: trigger)
        let content = triggerContent()
        var enterActions: [(String, [String: String])] = []
        appendSound(chargeSound, to: &enterActions)
        enterActions += [("Transform", ["Name": "VisualCharge"]), ("Wait", ["Frames": String(max(0, chargeFrames))])]
        appendSound(idleSound, to: &enterActions)
        enterActions += [("Transform", ["Name": "VisualIdle"]), ("Transform", ["Name": "CustomTrapDangerOn"])]
        var disabledActions: [(String, [String: String])] = [("Transform", ["Name": "CustomTrapDangerOff"])]
        appendSound(disabledSound, to: &disabledActions)
        disabledActions.append(("Transform", ["Name": "VisualDisabled"]))
        content.addChild(loop(event: "Enter", actions: enterActions))
        content.addChild(loop(event: "Exit", actions: disabledActions))
        content.addChild(loop(event: "OnHide", actions: disabledActions))
        trigger.addChild(content)
        return trigger
    }

    private func makeDangerTrigger() -> XMLElement {
        let trigger = XMLElement(name: "Trigger")
        attributes(["Name": "Danger Area", "X": "~DangerX", "Y": "~DangerY", "Width": "~DangerWidth", "Height": "~DangerHeight"], to: trigger)
        let content = triggerContent()
        var actions: [(String, [String: String])] = [("Transform", ["Name": "VisualHit"])]
        appendSound(hitSound, to: &actions)
        switch impact {
        case .defeat:
            actions.append(("Kill", ["Model": "Player"]))
        case .armor:
            // Vector's gadget HUD already shows charge loss. A second floating
            // number looked like a separate damage system and, worse, preserved
            // stale values such as the old -35 durability prototype.
            actions.append(("ArmorDamage", ["Model": "Player", "Amount": String(min(12, max(1, damageAmount))), "Slot": armorSlot.rawValue]))
        case .knockback:
            actions.append(("Impulse", ["Model": "Player", "Impulse": "40", "R": "1000", "Absorption": "0.8"]))
        }
        actions.append(("Wait", ["Frames": String(max(0, hitFrames))]))
        actions.append(("Transform", ["Name": "VisualIdle"]))
        content.addChild(loop(event: "Enter", actions: actions))
        trigger.addChild(content)

        if enabledByArea {
            let properties = XMLElement(name: "Properties")
            let statics = XMLElement(name: "Static")
            let enable = XMLElement(name: "Enable"); attributes(["Value": "0"], to: enable); statics.addChild(enable)
            let dynamic = XMLElement(name: "Dynamic")
            for (name, type) in [("CustomTrapDangerOn", "On"), ("CustomTrapDangerOff", "Off")] {
                let transformation = XMLElement(name: "Transformation"); attributes(["Name": name], to: transformation)
                let interval = XMLElement(name: "ActivationInterval"); attributes(["Type": type], to: interval)
                transformation.addChild(interval); dynamic.addChild(transformation)
            }
            properties.addChild(statics); properties.addChild(dynamic); trigger.addChild(properties)
        }
        return trigger
    }

    private func appendSound(_ id: String, to actions: inout [(String, [String: String])]) {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.append(("Sound", ["Action": "Play", "Channel": "Sound", "Name": id, "Volume": String(min(1, max(0, soundVolume)))]))
    }

    private func addVisual(_ filename: String, state: String, initiallyVisible: Bool, to content: XMLElement) {
        let selected = filename.isEmpty ? artwork : filename
        guard !selected.isEmpty else { return }
        let isGIF = URL(fileURLWithPath: selected).pathExtension.lowercased() == "gif"
        let image = XMLElement(name: isGIF ? "CustomAnimation" : "Image")
        // Empty state artwork means "reuse Regular". Reuse its animation
        // manifest too instead of pointing Vector at a nonexistent state file.
        let animationState = filename.isEmpty ? "Idle" : state
        let className = isGIF ? animationManifestName(state: animationState) : URL(fileURLWithPath: selected).deletingPathExtension().lastPathComponent
        var visualAttributes = ["ClassName": className, "X": String(-width / 2), "Y": String(-height), "Layer": "TrapsColor", "Width": String(width), "Height": String(height), "Factor": "0"]
        if isGIF { visualAttributes.merge(["Speed": "30", "Iterations": "-1"]) { _, new in new } }
        attributes(visualAttributes, to: image)
        let properties = XMLElement(name: "Properties"); let statics = XMLElement(name: "Static"); let matrix = XMLElement(name: "Matrix")
        attributes(["A": String(width), "B": "0", "C": "0", "D": String(height), "Tx": "0", "Ty": "0"], to: matrix)
        statics.addChild(matrix)
        let start = XMLElement(name: "StartColor"); attributes(["Color": initiallyVisible ? "#FFFFFFFF" : "#FFFFFF00"], to: start); statics.addChild(start)
        let dynamic = XMLElement(name: "Dynamic")
        for visibleState in ["Idle", "Charge", "Disabled", "Hit"] {
            let transformation = XMLElement(name: "Transformation"); attributes(["Name": "Visual\(visibleState)"], to: transformation)
            let color = XMLElement(name: "ColorInterval"); attributes(["Frames": "1", "ColorFinish": visibleState == state ? "#FFFFFFFF" : "#FFFFFF00"], to: color)
            transformation.addChild(color); dynamic.addChild(transformation)
        }
        properties.addChild(statics); properties.addChild(dynamic); image.addChild(properties); content.addChild(image)
    }

    private func animationManifestName(state: String) -> String {
        "v2trap_\(Self.clean(id))_\(state.lowercased()).xml"
    }

    /// Vector's runtime has a frame-sequence player but no portable GIF decoder.
    /// Decode once while authoring so the installed trap works identically on macOS and iOS.
    private func compileGIFArtwork(projectRoot: URL, package: URL, cleanID: String) throws {
        let textureRoot = projectRoot.appendingPathComponent("custom_textures", isDirectory: true)
            .appendingPathComponent("v2trap_\(cleanID)", isDirectory: true)
        let animationRoot = package.appendingPathComponent("animations", isDirectory: true)
        try FileManager.default.createDirectory(at: textureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: animationRoot, withIntermediateDirectories: true)

        let textureSourceRoot = projectRoot.appendingPathComponent("custom_textures", isDirectory: true)
        for (state, filename) in [("Idle", artwork), ("Charge", chargeArtwork), ("Disabled", disabledArtwork), ("Hit", hitArtwork)] {
            guard !filename.isEmpty, URL(fileURLWithPath: filename).pathExtension.lowercased() == "gif" else { continue }
            let sourceURL = textureSourceRoot.appendingPathComponent(filename)
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw NSError(domain: "CustomTraps", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not decode GIF: \(filename)"])
            }
            let stateKey = state.lowercased()
            let manifest = XMLElement(name: "CustomAnimation")
            for index in 0..<CGImageSourceGetCount(source) {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                let frameName = "\(stateKey)_\(String(format: "%04d", index)).png"
                let output = textureRoot.appendingPathComponent(frameName)
                guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, frame, nil)
                guard CGImageDestinationFinalize(destination) else { continue }

                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? (1.0 / 30.0)
                let frameNode = XMLElement(name: "Frame")
                attributes(["Texture": "v2trap_\(cleanID)/\(frameName)", "Frames": String(max(1, Int((delay * 30).rounded())))], to: frameNode)
                manifest.addChild(frameNode)
            }
            guard manifest.childCount > 0 else { continue }
            let data = xmlDocument(root: manifest).xmlData(options: .nodePrettyPrint)
            try data.write(to: animationRoot.appendingPathComponent(animationManifestName(state: state)), options: .atomic)
        }
    }

    private func triggerContent() -> XMLElement {
        let content = XMLElement(name: "Content")
        let initNode = XMLElement(name: "Init")
        for values in [
            ["Name": "$AI", "Type": "AI", "Value": "0"],
            ["Name": "$Active", "Type": "Bool", "Value": "1"],
            ["Name": "$Node", "Type": "Node", "Value": "COM"]
        ] {
            let variable = XMLElement(name: "SetVariable"); attributes(values, to: variable); initNode.addChild(variable)
        }
        content.addChild(initNode)
        return content
    }

    private func loop(event: String, conditions: [[String: String]] = [], actions: [(String, [String: String])]) -> XMLElement {
        let loop = XMLElement(name: "Loop")
        let events = XMLElement(name: "Events"); events.addChild(XMLElement(name: event)); loop.addChild(events)
        if !conditions.isEmpty {
            let conditionList = XMLElement(name: "Conditions")
            for values in conditions {
                let condition = XMLElement(name: "Equal"); attributes(values, to: condition); conditionList.addChild(condition)
            }
            loop.addChild(conditionList)
        }
        let actionList = XMLElement(name: "Actions")
        for (name, values) in actions {
            let action = XMLElement(name: name); attributes(values, to: action); actionList.addChild(action)
        }
        loop.addChild(actionList)
        return loop
    }

    static func clean(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
            .split(separator: "_").filter { !$0.isEmpty }.joined(separator: "_")
    }

    private func xmlDocument(root: XMLElement) -> XMLDocument { Self.xmlDocument(root: root) }
    private static func xmlDocument(root: XMLElement) -> XMLDocument { let document = XMLDocument(rootElement: root); document.version = "1.0"; document.characterEncoding = "utf-8"; return document }
    private func attributes(_ values: [String: String], to element: XMLElement) { Self.attributes(values, to: element) }
    private static func attributes(_ values: [String: String], to element: XMLElement) {
        for (key, value) in values { element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
    }
}
