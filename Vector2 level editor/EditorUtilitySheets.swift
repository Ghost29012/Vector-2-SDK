//
//  EditorUtilitySheets.swift
//  Vector2 level editor
//
//  Small editor popups that do real document work live here instead of making
//  ContentView even more gigantic. Keep them focused: receive a Binding, make
//  one clear edit, report what happened, and get out of the way.
//

import Foundation
import SwiftUI

/// Keeps canvas pan/zoom updates from rebuilding the diagnostic log overlay.
/// RoomWeaverConsoleView still refreshes itself through its ObservedObject when
/// an actual log entry changes.
struct RoomWeaverConsoleHost: View, Equatable {
    static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }

    var body: some View {
        RoomWeaverConsoleView()
    }
}

struct SwarmWaypointBinderSheet: View {
    @Binding var document: LevelDocument
    let onClose: () -> Void
    let onStatus: (String) -> Void

    @State private var swarmTriggerID = ""
    @State private var startWaypointID = ""
    @State private var nextWaypointID = ""
    @State private var delayFrames = ""

    private struct BinderCandidate: Identifiable, Hashable {
        var id: LevelNode.ID
        var name: String
        var detail: String

        var idString: String { id.uuidString }
        var label: String { detail.isEmpty ? name : "\(name) - \(detail)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Swarm Waypoint Binder")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button("Close", action: onClose)
            }

            Text("Hook swarm waypoint flow without touching positions. Move waypoints on the canvas; this only writes the Next link and optional Delay.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            formRow("Swarm trigger", selection: $swarmTriggerID, candidates: swarmTriggerCandidates, allowsNone: true)
            formRow("Start waypoint", selection: $startWaypointID, candidates: waypointCandidates, allowsNone: false)
            formRow("Next waypoint", selection: $nextWaypointID, candidates: waypointCandidates, allowsNone: false)

            HStack {
                Text("Delay")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 112, alignment: .leading)
                TextField("optional frames", text: $delayFrames)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text("Leave empty for instant next waypoint.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Bind Next Waypoint") {
                    bindNextWaypoint()
                }
                .buttonStyle(.borderedProminent)
                .disabled(startWaypointID.isEmpty || nextWaypointID.isEmpty || startWaypointID == nextWaypointID)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: seedDefaults)
    }

    private func formRow(
        _ title: String,
        selection: Binding<String>,
        candidates: [BinderCandidate],
        allowsNone: Bool
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 112, alignment: .leading)
            Picker(title, selection: selection) {
                if allowsNone {
                    Text("None").tag("")
                }
                if candidates.isEmpty {
                    Text("No matches").tag("")
                } else {
                    ForEach(candidates) { candidate in
                        Text(candidate.label).tag(candidate.idString)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var waypointCandidates: [BinderCandidate] {
        collectCandidates(in: document.root) { node in
            node.kind == .waypoint || searchBlob(for: node).contains("waypoint")
        }
    }

    private var swarmTriggerCandidates: [BinderCandidate] {
        collectCandidates(in: document.root) { node in
            searchBlob(for: node).contains("swarm")
        }
    }

    private func seedDefaults() {
        if swarmTriggerID.isEmpty {
            swarmTriggerID = swarmTriggerCandidates.first?.idString ?? ""
        }
        if startWaypointID.isEmpty {
            startWaypointID = waypointCandidates.first { $0.name.lowercased() == "start" }?.idString
                ?? waypointCandidates.first?.idString
                ?? ""
        }
        if nextWaypointID.isEmpty {
            nextWaypointID = waypointCandidates.first { $0.idString != startWaypointID }?.idString ?? ""
        }
    }

    private func bindNextWaypoint() {
        guard
            let startID = UUID(uuidString: startWaypointID),
            let nextID = UUID(uuidString: nextWaypointID),
            let next = document.root.find(id: nextID)
        else {
            onStatus("Pick a start and next waypoint first")
            return
        }

        let nextName = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty else {
            onStatus("Next waypoint needs a name before binding")
            return
        }

        let delay = delayFrames.trimmingCharacters(in: .whitespacesAndNewlines)
        document.root.update(id: startID) { node in
            node.metadata.sourcePropertiesXML = Self.propertiesXML(
                existing: node.metadata.sourcePropertiesXML,
                nextWaypointName: nextName,
                delay: delay
            )
        }
        if let swarmID = UUID(uuidString: swarmTriggerID) {
            document.select(swarmID)
        } else {
            document.select(startID)
        }
        onStatus(delay.isEmpty ? "Bound waypoint to \(nextName)" : "Bound waypoint to \(nextName) after \(delay) frames")
    }

    private func collectCandidates(
        in node: LevelNode,
        matching predicate: (LevelNode) -> Bool
    ) -> [BinderCandidate] {
        var results: [BinderCandidate] = []
        if node.kind != .document,
           node.kind != .track,
           node.kind != .factor,
           predicate(node) {
            results.append(
                BinderCandidate(
                    id: node.id,
                    name: displayName(for: node),
                    detail: node.kind.rawValue
                )
            )
        }
        for child in node.children {
            results.append(contentsOf: collectCandidates(in: child, matching: predicate))
        }
        return results
    }

    private func displayName(for node: LevelNode) -> String {
        [
            node.name,
            node.metadata.className,
            node.xml.template,
            node.metadata.tag,
            node.kind.rawValue
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Unnamed"
    }

    private func searchBlob(for node: LevelNode) -> String {
        [
            node.name,
            node.metadata.className,
            node.metadata.filename,
            node.metadata.tag,
            node.xml.template,
            node.xml.choice,
            node.xml.variant,
            node.kind.rawValue
        ]
            .joined(separator: " ")
            .lowercased()
    }

    private static func propertiesXML(existing: String, nextWaypointName: String, delay: String) -> String {
        let properties: XMLElement
        if let document = try? XMLDocument(xmlString: existing, options: []),
           let root = document.rootElement()?.copy() as? XMLElement,
           root.name == "Properties" {
            properties = root
        } else {
            properties = XMLElement(name: "Properties")
        }

        let staticElement: XMLElement
        if let existingStatic = properties.elements(forName: "Static").first {
            staticElement = existingStatic
        } else {
            staticElement = XMLElement(name: "Static")
            properties.addChild(staticElement)
        }

        for next in staticElement.elements(forName: "Next") {
            next.detach()
        }

        let nextElement = XMLElement(name: "Next")
        let waypoint = XMLElement(name: "Waypoint")
        waypoint.addAttribute(XMLNode.attribute(withName: "Name", stringValue: nextWaypointName) as! XMLNode)
        if !delay.isEmpty {
            waypoint.addAttribute(XMLNode.attribute(withName: "Delay", stringValue: delay) as! XMLNode)
        }
        nextElement.addChild(waypoint)
        staticElement.addChild(nextElement)
        return properties.xmlString(options: .nodeCompactEmptyElement)
    }
}
