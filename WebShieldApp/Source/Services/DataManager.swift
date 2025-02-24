import Foundation
import SwiftData

@MainActor
final class DataManager: ObservableObject, Sendable {
    let container: ModelContainer
    private let filterListProcessor = FilterListProcessor()

    init() {
        // Initialize ModelContainer once
        guard
            let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Identifiers.groupID)
        else {
            fatalError("Failed to get container URL for app group.")
        }

        let storeURL = groupURL.appendingPathComponent("Library/Application Support/default.store")
        let config = ModelConfiguration(url: storeURL)

        // Define the schema for your models
        let schema = Schema([FilterList.self])

        // Initialize the container with the schema and configuration
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    /// Resets the data model by deleting all records and reseeding.
    func resetModel() async {  // Marked as async
        do {
            // Use await when calling container.mainContext
            try container.mainContext.delete(model: FilterList.self)
            // Call seedData with await
            await seedData()
            await WebShieldLogger.shared.log("Model reset successfully.")
        } catch {
            await WebShieldLogger.shared.log("Failed to reset model: \(error)")
        }
    }

    /// Seeds initial data into the database.
    func seedData() async {

        // For each pre-defined filter list in FilterListProvider:
        for (index, data) in FilterListProvider.filterListData.enumerated() {
            // Use await when calling actor-isolated method
            filterListProcessor.saveFilterList(
                to: container.mainContext,
                id: data.id,
                name: data.name,
                version: "N/A",
                description: data.description,
                category: data.category,
                isEnabled: data.isSelected,
                order: index,
                downloadUrl: data.downloadUrl,
                homepageUrl: data.homepageUrl,
                downloaded: false,
                needsRefresh: true
            )
        }

        // Save the inserted records to SwiftData
        do {
            try container.mainContext.save()
            await WebShieldLogger.shared.log("Seed data saved successfully.")
        } catch {
            await WebShieldLogger.shared.log("Failed to save seed data: \(error)")
        }
    }

    /// Seeds data only if the database is empty.
    func seedDataIfNeeded() async {
        // Use the mainContext from the container
        let context = container.mainContext

        let fetchRequest = FetchDescriptor<FilterList>()
        do {
            let results = try context.fetch(fetchRequest)
            if results.isEmpty {
                // Call seedData with await
                await seedData()
                await WebShieldLogger.shared.log("Seed data inserted.")
            } else {
                await WebShieldLogger.shared.log("Database is not empty.")
                // Call update logic
                //                await updateDataFromProvider()

            }
        } catch {
            await WebShieldLogger.shared.log("Error fetching or saving data: \(error)")
        }
    }

    // NEW: Update data from FilterListProvider
    func updateDataFromProvider() async {
        let context = container.mainContext

        // 1. Process updates and additions from FilterListProvider
        for providerData in FilterListProvider.filterListData {
            let providerDataId = providerData.id

            let fetchDescriptor = FetchDescriptor<FilterList>(
                predicate: #Predicate { filterList in
                    filterList.id == providerDataId
                }
            )

            do {
                if let existingFilterList = try context.fetch(fetchDescriptor).first {
                    // Update metadata, but *preserve* user-set isEnabled and downloaded
                    existingFilterList.name = providerData.name
                    existingFilterList.desc = providerData.description
                    existingFilterList.categoryString = providerData.category.rawValue
                    existingFilterList.downloadUrl = providerData.downloadUrl
                    existingFilterList.homepageUrl = providerData.homepageUrl
                    existingFilterList.informationUrl = providerData.informationUrl
                    // *DO NOT* update isEnabled here.  Keep the user's choice.
                    // *DO NOT* update downloaded here. Keep existing state.

                } else {
                    // Add new FilterList from provider, using provider's isEnabled
                    let newFilterList = FilterList(
                        name: providerData.name,
                        version: "N/A",
                        desc: providerData.description,
                        category: providerData.category,
                        isEnabled: providerData.isSelected,  // Use provider's value for new entries
                        order: FilterListProvider.filterListData.firstIndex(where: { $0.id == providerData.id }) ?? 0,
                        downloadUrl: providerData.downloadUrl,
                        homepageUrl: providerData.homepageUrl,
                        informationUrl: providerData.informationUrl,
                        downloaded: false,
                        needsRefresh: true
                    )
                    newFilterList.id = providerData.id
                    context.insert(newFilterList)
                }
            } catch {
                await WebShieldLogger.shared.log("Error updating data from provider: \(error)")
            }
        }

        // 2. Handle deletions (lists removed from FilterListProvider)
        do {
            let fetchDescriptor = FetchDescriptor<FilterList>()
            let allFilterLists = try context.fetch(fetchDescriptor)

            for filterList in allFilterLists {
                // If a FilterList exists in the database but *not* in the provider,
                // and it's *not* a custom list, delete it.  Custom lists are preserved.
                if !FilterListProvider.filterListData.contains(where: { $0.id == filterList.id })
                    && filterList.category != .custom
                {
                    context.delete(filterList)
                }
            }

            try context.save()

        } catch {
            await WebShieldLogger.shared.log("Error removing old filter lists: \(error)")
        }
    }

}
