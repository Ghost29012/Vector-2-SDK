import SwiftUI

struct ProjectStudioShell<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let content: Content

    init(title: String, subtitle: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint; self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: symbol).font(.system(size: 25, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(tint.gradient, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 30, weight: .bold))
                        Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                content
            }.frame(maxWidth: 1260).padding(26).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
