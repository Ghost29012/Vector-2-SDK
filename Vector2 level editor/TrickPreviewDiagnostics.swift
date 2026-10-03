//
//  TrickPreviewDiagnostics.swift
//  Vector2 level editor
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class TrickPreviewDiagnostics: ObservableObject {
    static let shared = TrickPreviewDiagnostics()

    @Published var isVisible = false
    @Published private(set) var lines: [String] = []

    private init() {}

    func clear() {
        lines.removeAll()
    }

    func log(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("[Trick] \(trimmed)")
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }
}

struct TrickPreviewConsoleView: View {
    @ObservedObject private var diagnostics = TrickPreviewDiagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trick Preview Console")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.lines.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") {
                    diagnostics.clear()
                }
                Button("Hide") {
                    diagnostics.isVisible = false
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: diagnostics.lines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(height: 190)
            .padding(8)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .frame(width: 560)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.borderless)
    }
}
