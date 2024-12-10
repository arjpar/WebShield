import Foundation
import SwiftData

// MARK: - Model
@Model
final class FilterList {
    @Attribute(.unique) var id: String
    var name: String = "No Name"
    var version: String = "No Version"
    var desc: String = "No Description"
    var categoryString: String = FilterListCategory.custom.rawValue
    var isEnabled: Bool = false
    var order: Int = 0
    var urlString: String?
    var homepageURL: String?
    var standardRuleCount: Int = 0
    var advancedRuleCount: Int = 0
    var lastUpdated: Date = Date()
    var informationURL: String?

    // Initializer
    init(
        name: String = "No Name",
        version: String = "No Version",
        desc: String = "No Description",
        category: FilterListCategory,
        isEnabled: Bool = false,
        order: Int = 0,
        homepageURL: String? = nil,
        informationURL: String? = nil
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.version = version
        self.desc = desc
        self.categoryString = category.rawValue
        self.isEnabled = isEnabled
        self.order = order
        self.urlString = nil
        self.homepageURL = homepageURL
        self.informationURL = informationURL
    }
}

// MARK: - Identifiable & Hashable
extension FilterList: Identifiable, Hashable {
    static func == (lhs: FilterList, rhs: FilterList) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Computed Properties
extension FilterList {
    var category: FilterListCategory? {
        FilterListCategory(rawValue: categoryString)
    }

    var totalRuleCount: Int {
        standardRuleCount + advancedRuleCount
    }
}
