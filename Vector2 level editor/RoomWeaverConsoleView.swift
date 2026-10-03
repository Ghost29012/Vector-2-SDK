//
//  RoomWeaverConsoleView.swift
//  Vector2 level editor
//
//  Just the diagnostic UI. It displays data from RoomWeaverDiagnostics and
//  should never parse, reconstruct, or mutate imported rooms.
//

import SwiftUI

struct RoomWeaverConsoleView: View {
    @ObservedObject var diagnostics = RoomWeaverDiagnostics.shared
    @AppStorage("vector2RoomWeaverVerboseDiagnostics") private var verboseDiagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RoomWeaver Console")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Deep trace", isOn: $verboseDiagnostics)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("Import Game TSV") { diagnostics.importRuntimeSnapshot() }
                Button("Export Editor TSV") { diagnostics.exportEditorLayout() }
                Button("Copy") { diagnostics.copyToClipboard() }
                Button("Export TXT") { diagnostics.exportText() }
                Button("Clear") { diagnostics.clear() }
            }
            Text("Deep trace reports named operations that exceed 4 ms; warnings exceeded one 60 FPS frame (16.67 ms). Static on-scene counts are no longer sampled during editing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(diagnostics.liveCanvasPerformance)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(diagnostics.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(entry.level.rawValue)] \(entry.message)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 420)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        // An opaque console avoids continuously blurring the already-heavy
        // editor canvas underneath this large panel while diagnostics are open.
        .background(Color.editorChromeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .frame(width: 860)
    }
}

