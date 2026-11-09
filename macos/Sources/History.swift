import AppKit
import SwiftUI

/// Local transcript history, stored only on this Mac in
/// ~/Library/Application Support/Floe/history.json (newest first).
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var raw: String
    var final: String
    var rewritten: Bool { raw != final }
}

final class HistoryStore: ObservableObject {
    static let limit = 1000
    @Published private(set) var entries: [HistoryEntry] = []
    private let url: URL
    private let queue = DispatchQueue(label: "Floe.History")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Floe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.history.decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    var fileURL: URL { url }

    func add(raw: String, final: String) {
        guard !final.isEmpty || !raw.isEmpty else { return }
        entries.insert(HistoryEntry(date: Date(), raw: raw, final: final), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let snapshot = entries, url = url
        queue.async {
            guard let data = try? JSONEncoder.history.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @State private var query = ""
    @State private var showRaw = Set<UUID>()
    @State private var confirmClear = false

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { $0.final.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                Text("\(filtered.count) items").font(.caption).foregroundStyle(.secondary)
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                Button("Clear All…") { confirmClear = true }.disabled(store.entries.isEmpty)
            }
            if filtered.isEmpty {
                Spacer()
                Text(store.entries.isEmpty ? "No transcripts yet" : "No matches")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.rewritten {
                                Text("Rewritten").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.teal.opacity(0.15), in: Capsule())
                            }
                            Spacer()
                            if entry.rewritten {
                                Button(showRaw.contains(entry.id) ? "Hide original" : "Original") {
                                    if showRaw.contains(entry.id) { showRaw.remove(entry.id) } else { showRaw.insert(entry.id) }
                                }.controlSize(.small)
                            }
                            Button("Copy") { DictationClipboard.write(entry.final, transient: false) }.controlSize(.small)
                            Button(role: .destructive) { store.delete(entry) } label: { Image(systemName: "trash") }
                                .controlSize(.small).buttonStyle(.borderless)
                        }
                        Text(entry.final).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if entry.rewritten && showRaw.contains(entry.id) {
                            HStack(alignment: .top) {
                                Text(entry.raw).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Copy") { DictationClipboard.write(entry.raw, transient: false) }.controlSize(.small)
                            }
                            .padding(6).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog("Delete all saved transcripts?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.clear() }
        }
    }
}
