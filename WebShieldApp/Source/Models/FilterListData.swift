import Foundation

struct FilterListData {
    let id: String
    let name: String
    let downloadUrl: String
    let category: FilterListCategory
    let isSelected: Bool
    let description: String
    let homepageUrl: String?
    let informationUrl: String?

    init(
        id: String,
        name: String,
        downloadUrl: String,
        category: FilterListCategory,
        isSelected: Bool,
        description: String,
        homepageUrl: String? = nil,
        informationUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.downloadUrl = downloadUrl
        self.category = category
        self.isSelected = isSelected
        self.description = description
        self.homepageUrl = homepageUrl
        self.informationUrl = informationUrl
    }
}
