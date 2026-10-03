import SwiftUI

struct DynamicStudioHelpSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dynamic Studio")
                .font(.system(size: 17, weight: .bold))
            Text("Add two poses on the timeline and Vector 2 animates between them. The frame numbers set the timing: at 60 FPS, 60 frames is about one second.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            helpRow("Bezier", "Moves or resizes directly between timeline poses. Vector 2 uses the keyframe positions as path points. This is the safest default.")
            helpRow("Sin: Ease In", "Starts slowly and speeds up.")
            helpRow("Sin: Ease Out", "Starts quickly and slows before arriving.")
            helpRow("Sin: Ease In-Out", "Starts and ends gently. Usually the most natural motion.")
            helpRow("Fast-Slow-Fast", "Moves quickly at both ends and slows in the middle.")
            helpRow("Backtrack then Finish", "Moves backwards first, then heads to the destination.")

            Divider()
            Text("Rotation modes").font(.system(size: 14, weight: .bold))
            helpRow("Linear", "One constant rotation speed.")
            helpRow("Cubic Ease In / Out", "A stronger mechanical acceleration or deceleration.")
            helpRow("Smooth Ease In / Out", "A gentler sine-based acceleration or settling motion.")
            helpRow("Smooth Ease In-Out", "Slow, then fast, then slow. Good for doors and platforms.")

            Divider()
            Text("Try it").font(.system(size: 14, weight: .bold))
            Text("Select an object → add a pose at frame 0 → move the playhead and object → add another pose → Preview → Save.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("Only properties that changed are exported. A position change writes MoveInterval, a size change writes SizeInterval, and a rotation change writes RotationInterval. An unchanged gap becomes DelayInterval.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.platformControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.editorHairline, lineWidth: 1))
    }

    private func helpRow(_ title: String, _ explanation: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 150, alignment: .leading)
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
