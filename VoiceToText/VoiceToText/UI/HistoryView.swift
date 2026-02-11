import SwiftUI

struct HistoryView: View {
    @StateObject private var historyStore = TranscriptionHistoryStore.shared
    @State private var searchText = ""

    private var filteredRecords: [TranscriptionRecord] {
        historyStore.search(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.bar)

            Divider()

            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No transcriptions yet" : "No results")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "Your transcription history will appear here." : "Try a different search term.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        HistoryRow(record: record) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.displayText, forType: .string)
                        } onDelete: {
                            historyStore.deleteRecord(record)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredRecords.count) transcription\(filteredRecords.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !historyStore.records.isEmpty {
                    Button("Clear All", role: .destructive) {
                        historyStore.clearAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 400, height: 500)
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let record: TranscriptionRecord
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(formatDuration(record.durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(record.modelName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Text(record.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") { onCopy() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}
