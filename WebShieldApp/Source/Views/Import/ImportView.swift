import SwiftData
import SwiftUI

class ImportViewState: ObservableObject {
    @Published var urlStrings: [String] = [""]
    @Published var isImporting = false
    @Published var showError = false
    @Published var error: Error?

    func reset() {
        urlStrings = [" "]
        isImporting = false
        showError = false
        error = nil
    }
}

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @StateObject private var state = ImportViewState()
    @FocusState private var isTextFieldFocused: Bool

    let filterListProcessor = FilterListProcessor()

    var body: some View {
        NavigationStack {
            Form {
                instructionsSection
                urlsInputSection
            }
            .formStyle(.grouped)
            .navigationTitle("Import Filter Lists")
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    cancelButton
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    importButton
                }
            }
            //            .disabled(state.isImporting)
            .alert("Error", isPresented: $state.showError, presenting: state.error) { error in
                Button("OK") {}
            } message: { error in
                Text(error.localizedDescription)
            }
            // Add this modifier to reset state when view appears
            .onAppear {
                state.reset()
                isTextFieldFocused = true
            }
            //            .onDisappear {
            //                state.reset()
            //            }
        }
    }

    private func urlInputRow(for index: Int) -> some View {
        HStack {
            TextField("Enter URL", text: $state.urlStrings[index])
                .autocorrectionDisabled(true)
                .disabled(state.isImporting)  // Move disabled state here
                .focused($isTextFieldFocused)
                .tint(.accentColor)
            if state.urlStrings.count > 1 {
                removeUrlButton(at: index)
                //                    .disabled(state.isImporting)  // And here
            }
        }
    }

    private var addUrlButton: some View {
        Button {
            state.urlStrings.append(" ")
        } label: {
            Label("Add URL", systemImage: "plus.circle.fill")
        }
        //        .disabled(state.isImporting)  // And here
    }

    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        //        .disabled(state.isImporting)  // And here
    }

    // MARK: - Subviews

    private var instructionsSection: some View {
        Section {
            Text(
                "Enter the URLs of filter lists to import, each on a new line. Ensure the URLs point directly to valid filter list files."
            )
        }
    }

    private var urlsInputSection: some View {
        Section(header: Text("Filter List URLs")) {
            ForEach(state.urlStrings.indices, id: \.self) { index in
                urlInputRow(for: index)
            }
            addUrlButton
        }
    }

    private func removeUrlButton(at index: Int) -> some View {
        Button(role: .destructive) {
            state.urlStrings.remove(at: index)
        } label: {
            Image(systemName: "minus.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundColor(.red)
    }

    private var importButton: some View {
        Group {
            if state.isImporting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                Button("Import") {
                    Task {
                        await importFilterLists()
                    }
                }
                //                .disabled(state.urlStrings.allSatisfy { $0.isEmpty })
            }
        }
    }

    // MARK: - Import Logic

    private func importFilterLists() async {
        await MainActor.run {
            state.isImporting = true
        }

        let validUrls =
            state.urlStrings
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(URL.init(string:))

        guard !validUrls.isEmpty else {
            await MainActor.run {
                state.error = FilterListError.invalidURL
                state.showError = true
                state.isImporting = false
            }
            return
        }

        do {
            for url in validUrls {
                let (data, _) = try await filterListProcessor.downloadFilterList(from: url)
                let content = try parseFilterListData(data)
                let filterList = createFilterList(from: content, url: url)

                modelContext.insert(filterList)
                await WebShieldLogger.shared.logFilterListProcessingStep(
                    "Added new filter list: \(filterList.name)", for: "Import")
            }

            try modelContext.save()

            await MainActor.run {
                state.urlStrings = [" "]  // Reset URLs
                state.isImporting = false  // Re-enable inputs
                dismiss()
            }

        } catch {
            await MainActor.run {
                state.error = error
                state.showError = true
                state.isImporting = false
            }
            await WebShieldLogger.shared.logFilterListProcessingStep(
                "Failed to import: \(error.localizedDescription)", for: "Import")
        }
    }

    private func parseFilterListData(_ data: Data) throws -> String {
        guard let content = String(data: data, encoding: .utf8) else {
            throw FilterListError.invalidData
        }
        return content
    }

    private func createFilterList(from content: String, url: URL) -> FilterList {
        var title = url.lastPathComponent
        var version = "0.0.0"
        var description = "Imported filter list"

        var foundTitle = false
        var foundVersion = false
        var foundDescription = false

        // Single pass: split on newlines, trim each line, check prefixes
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Check each known prefix
            switch true {
            case trimmedLine.hasPrefix("! Title:"):
                title =
                    trimmedLine
                    .dropFirst("! Title:".count)
                    .trimmingCharacters(in: .whitespaces)
                foundTitle = true

            case trimmedLine.hasPrefix("! Version:"):
                version =
                    trimmedLine
                    .dropFirst("! Version:".count)
                    .trimmingCharacters(in: .whitespaces)
                foundVersion = true

            case trimmedLine.hasPrefix("! Description:"):
                description =
                    trimmedLine
                    .dropFirst("! Description:".count)
                    .trimmingCharacters(in: .whitespaces)
                foundDescription = true

            default:
                break
            }

            // Early exit once we've found all fields
            if foundTitle && foundVersion && foundDescription {
                break
            }
        }

        // Construct and return the FilterList
        return FilterList(
            name: title,
            version: version,
            desc: description,
            category: .custom,
            isEnabled: true,
            downloadUrl: url.absoluteString,
            downloaded: false
        )
    }

    private func resetUrlStrings() {
        DispatchQueue.main.async {
            state.urlStrings = [" "]
        }
    }
}
