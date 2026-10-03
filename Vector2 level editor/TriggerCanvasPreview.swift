import SwiftUI

struct TriggerCanvasPreview: View {
    let definition: TriggerDefinition

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, CGFloat(definition.bounds.width))
            let height = max(1, CGFloat(definition.bounds.height))
            let scale = min((proxy.size.width - 48) / width, (proxy.size.height - 48) / height, 1)
            ZStack {
                TriggerPreviewGrid().opacity(0.35)
                VectorRuntimeRegionBox(title: definition.name, kind: .trigger)
                    .frame(width: width * scale, height: height * scale)
            }
        }
        .frame(minHeight: 240)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .clipped()
    }
}

/// Matches the room canvas and Vector's XML geometry language. Trigger regions
/// are yellow with the native brown outline; damage/area regions are red. No
/// decorative icons, rounded cards or dashed mockup borders are involved.
struct VectorRuntimeRegionBox: View {
    enum Kind { case trigger, area }
    let title: String
    let kind: Kind

    private var fill: Color { kind == .trigger ? Color(rgbaHex: Vector2RuntimeSettings.triggerFillHex) : Color(rgbaHex: Vector2RuntimeSettings.areaFillHex) }
    private var outline: Color { kind == .trigger ? Color(rgbaHex: Vector2RuntimeSettings.triggerOutlineHex) : Color(rgbaHex: Vector2RuntimeSettings.areaOutlineHex) }

    var body: some View {
        Rectangle()
            .fill(fill)
            .overlay(Rectangle().stroke(outline, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title).font(.system(size: 10, weight: .regular)).foregroundStyle(outline).padding(3)
            }
    }
}

private struct TriggerPreviewGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: 0.0, through: size.width, by: 32) { path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)) }
            for y in stride(from: 0.0, through: size.height, by: 32) { path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)) }
            context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
    }
}
