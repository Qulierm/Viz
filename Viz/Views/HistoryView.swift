//
//  HistoryView.swift
//  Viz
//
//  Created by Alin Lupascu on 3/27/25.
//
import SwiftUI
import AlinFoundation

struct HistoryView: View {
    @ObservedObject private var historyState = HistoryState.shared
    @State private var tappedItemID: String?
    @State private var filterSelection = "All"
    private let filters = ["All", "Text", "Colors"]
    private var filteredItems: [HistoryEntry] {
        historyState.historyItems
            .reversed()
            .filter { item in
                switch filterSelection {
                case "Text":
                    if case .text = item { return true }
                    return false
                case "Colors":
                    if case .color = item { return true }
                    return false
                default:
                    return true
                }
            }
    }

    var body: some View {

        VStack(alignment: .center, spacing: 0) {

            Text("History")
                .font(.title)
                .padding(.vertical)

            Spacer()

            if filteredItems.isEmpty {
                Text(filterSelection == "All" ? "No items have been captured" : filterSelection == "Text" ? "No text has been captured" : "No colors have been captured").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(filteredItems) { item in
                            HStack {
                                row(for: item)
                                deleteButton(for: item)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer()

            HStack {
                Picker("", selection: $filterSelection) {
                    ForEach(filters, id: \.self) { filter in
                        Text(filter).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(.leading)

                Spacer()

                Button {
                    clearClipboard()
                } label: {
                    Image(systemName: "trash")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .padding(5)
                        .padding(.leading, 1)
                }
                .vizGlassButton(prominent: true, tint: .red)
            }
            .padding(.vertical)


        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .vizGlassSurface(cornerRadius: 0, tint: VizTheme.surfaceTint)
    }

    @ViewBuilder
    private func row(for item: HistoryEntry) -> some View {
        switch item {
        case .color(let colorItem):
            colorRow(colorItem)
        case .text(let textItem):
            textRow(textItem)
        }
    }

    private func colorRow(_ colorItem: ColorItem) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading) {
                Text("HEX: \(colorItem.hex)")
                Text("RGB: \(colorItem.rgb)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        tappedItemID = colorItem.id
                        copyToClipboard(colorItem.rgb)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            tappedItemID = nil
                        }
                    }
            }
            .frame(width: 100)
            .padding()
            swatch(for: colorItem)
        }
        .modifier(HistoryRowSurface(isCopied: tappedItemID == colorItem.id))
        .animation(.easeInOut(duration: 0.2), value: tappedItemID)
        .onTapGesture {
            tappedItemID = colorItem.id
            copyToClipboard(colorItem.hex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                tappedItemID = nil
            }
        }
    }

    private func swatch(for colorItem: ColorItem) -> some View {
        TrailingRoundedRectangle(cornerRadius: 8)
            .fill(colorItem.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                TrailingRoundedRectangle(cornerRadius: 8)
                    .stroke(VizTheme.link.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: VizTheme.link.opacity(0.25), radius: 4, x: 0, y: 1)
    }

    private func textRow(_ textItem: TextItem) -> some View {
        HStack {
            HStack(alignment: .center, spacing: 0) {
                urlButton(for: textItem)
                Text(textItem.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .modifier(HistoryRowSurface(isCopied: tappedItemID == textItem.id))
            .animation(.easeInOut(duration: 0.2), value: tappedItemID)
            .onTapGesture {
                tappedItemID = textItem.id
                copyToClipboard(textItem.text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    tappedItemID = nil
                }
            }
        }
    }

    @ViewBuilder
    private func urlButton(for textItem: TextItem) -> some View {
        let trimmed = textItem.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRecognizedURLFormat(trimmed),
           let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)") {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "safari")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundColor(VizTheme.link)
                    .padding(.trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private func deleteButton(for item: HistoryEntry) -> some View {
        Button(action: {
            if tappedItemID != item.id {
                historyState.historyItems.removeAll { $0.id == item.id }
            }
        }) {
            Image(systemName: tappedItemID == item.id ? "checkmark" : "xmark.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundColor(tappedItemID == item.id ? VizTheme.success : .secondary)
                .padding(.horizontal, 5)
        }
        .buttonStyle(.borderless)
    }
}

// Helper function for recognized URL formats
func isRecognizedURLFormat(_ text: String) -> Bool {
    let pattern = #"^(https?:\/\/)?(www\.)?[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}.*$"#
    return text.range(of: pattern, options: .regularExpression) != nil
}

/// Row surface shared by the text and colour entries: a glass panel that shows an
/// accent-tinted ring while the row reports its copied feedback.
private struct HistoryRowSurface: ViewModifier {
    let isCopied: Bool

    func body(content: Content) -> some View {
        content
            .vizGlassSurface(cornerRadius: VizTheme.cornerSmall, tint: VizTheme.cardTint)
            .overlay {
                RoundedRectangle(cornerRadius: VizTheme.cornerSmall)
                    .strokeBorder(isCopied ? VizTheme.success : Color.secondary.opacity(0.25),
                                  lineWidth: isCopied ? 2 : 1)
            }
    }
}
