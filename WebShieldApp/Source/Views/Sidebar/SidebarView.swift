// WebShieldApp/Source/Views/Sidebar/SidebarView.swift
import SwiftData
import SwiftUI

struct SidebarView: View {
    @Binding var selectedCategory: FilterListCategory?

    var body: some View {
        List(selection: $selectedCategory) {
            // Consider putting "Enabled" in its own section for clarity
            Section(header: Text("Status")) {  // Optional: New Section Header
                NavigationLink(value: FilterListCategory.enabled) {
                    Label(
                        FilterListCategory.enabled.rawValue,
                        systemImage: FilterListCategory.enabled.systemImage
                    )
                }
            }

            Section(header: Text("Categories")) {
                // Original categories (excluding .enabled if placed above)
                let categories: [FilterListCategory] = [
                    .all, .ads, .privacy, .security, .multipurpose, .cookies, .social, .annoyances, .regional,
                    .experimental, .custom,
                ]
                ForEach(categories, id: \.self) { category in
                    NavigationLink(value: category) {
                        Label(
                            category.rawValue,
                            systemImage: category.systemImage
                        )
                    }
                }
            }
        }
        .navigationTitle("WebShield")
        // Optional: Set default selection if needed
        .onAppear {
            if selectedCategory == nil {
                selectedCategory = .all  // Or .all, etc.
            }
        }
    }
}
