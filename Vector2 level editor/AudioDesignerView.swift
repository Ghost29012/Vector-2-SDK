import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudioDesignerView: View {
    let projectRoot: URL
    let onStatus: (String) -> Void
    @State private var definition = AudioProjectDefinition()
    @State private var selectedIndex = 0
    @State private var audioFiles: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.plus").font(.title2.bold()).foregroundStyle(.white).frame(width: 48, height: 48).background(.orange.gradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading) { Text("Audio").font(.title.bold()); Text("Choose which music and sounds are used by each chapter or zone.").foregroundStyle(.secondary) }
                Spacer(); Button("Import Audio", action: importAudio); Button("Save", action: save).buttonStyle(.borderedProminent)
            }.padding(18)
            Divider()
            HSplitView {
                poolList.frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
                if definition.pools.indices.contains(selectedIndex) { poolEditor($definition.pools[selectedIndex]) }
                else { ContentUnavailableView("No music list selected", systemImage: "music.note.list", description: Text("Add a chapter or zone list, then choose the tracks it can play.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).onAppear(perform: reload)
    }

    private var poolList: some View {
        VStack(spacing: 8) {
            HStack { Text("MUSIC POOLS").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Menu { Button("Chapter Pool") { addPool(.chapter) }; Button("Zone Pool") { addPool(.zone) } } label: { Image(systemName: "plus") } }.padding(14)
            ScrollView { LazyVStack(spacing: 7) { ForEach(Array(definition.pools.enumerated()), id: \.offset) { index, pool in Button { selectedIndex = index } label: { HStack { Image(systemName: pool.scope == .chapter ? "books.vertical" : "square.3.layers.3d"); VStack(alignment: .leading) { Text(pool.reference.isEmpty ? "New \(pool.scope.rawValue)" : pool.reference).fontWeight(.semibold); Text("\(pool.tracks.count) tracks").font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(10).contentShape(Rectangle()) }.buttonStyle(.plain).background(selectedIndex == index ? Color.orange.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 11)) } }.padding(8) }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private func poolEditor(_ pool: Binding<AudioPoolDefinition>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("\(pool.wrappedValue.scope.rawValue) music").font(.title2.bold()); Spacer(); Button("Delete Pool", role: .destructive) { definition.pools.remove(at: selectedIndex); selectedIndex = max(0, selectedIndex - 1) } }
                group("Where it plays") {
                    Picker("Scope", selection: pool.scope) { ForEach(AudioPoolDefinition.Scope.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextField("Exact custom chapter or zone ID", text: pool.reference).textFieldStyle(.roundedBorder)
                }
                group("Tracks", subtitle: "Vector randomly chooses by weight. Floor 0 means no limit.") {
                    ForEach(Array(pool.wrappedValue.tracks.enumerated()), id: \.offset) { index, _ in
                        HStack { Picker("Track", selection: pool.tracks[index].id) { Text("Choose audio").tag(""); ForEach(audioFiles, id: \.path) { Text($0.deletingPathExtension().lastPathComponent).tag($0.deletingPathExtension().lastPathComponent) } }.frame(minWidth: 180); Stepper("Weight \(pool.wrappedValue.tracks[index].weight)", value: pool.tracks[index].weight, in: 1...100); Stepper("From \(pool.wrappedValue.tracks[index].minimumFloor)", value: pool.tracks[index].minimumFloor, in: 0...999); Stepper("To \(pool.wrappedValue.tracks[index].maximumFloor)", value: pool.tracks[index].maximumFloor, in: 0...999); Button(role: .destructive) { pool.wrappedValue.tracks.remove(at: index) } label: { Image(systemName: "trash") } }
                    }
                    Button { pool.wrappedValue.tracks.append(.init(id: audioFiles.first?.deletingPathExtension().lastPathComponent ?? "")) } label: { Label("Add Track", systemImage: "plus") }
                }
                group("Ambient") {
                    Picker("Ambient loop", selection: pool.ambientID) { Text("None").tag(""); ForEach(audioFiles, id: \.path) { Text($0.deletingPathExtension().lastPathComponent).tag($0.deletingPathExtension().lastPathComponent) } }
                    Slider(value: pool.ambientVolume, in: 0...1) { Text("Volume") }; Text("Volume \(pool.wrappedValue.ambientVolume, format: .number.precision(.fractionLength(2)))").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 1000).padding(24).frame(maxWidth: .infinity)
        }
    }

    private func group<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }; content() }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)) }
    private func addPool(_ scope: AudioPoolDefinition.Scope) { definition.pools.append(.init(scope: scope, reference: "")); selectedIndex = definition.pools.count - 1 }
    private func reload() { definition = AudioProjectXMLCodec.load(from: projectRoot); audioFiles = Self.audioFiles(projectRoot); selectedIndex = min(selectedIndex, max(0, definition.pools.count - 1)) }
    private func save() { do { try AudioProjectXMLCodec.write(definition, to: projectRoot); onStatus("Saved chapter and zone music pools.") } catch { onStatus("Could not save audio settings: \(error.localizedDescription)") } }
    private func importAudio() { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.audio]; guard panel.runModal() == .OK else { return }; let folder = projectRoot.appendingPathComponent("custom_audio", isDirectory: true); do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); for source in panel.urls { let target = folder.appendingPathComponent(source.lastPathComponent); if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }; try FileManager.default.copyItem(at: source, to: target) }; reload(); onStatus("Imported \(panel.urls.count) audio file(s).") } catch { onStatus("Audio import failed: \(error.localizedDescription)") } }
    private static func audioFiles(_ root: URL) -> [URL] { let folder = root.appendingPathComponent("custom_audio", isDirectory: true); let allowed = Set(["wav", "mp3", "ogg", "aif", "aiff", "m4a"]); return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { allowed.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
}
