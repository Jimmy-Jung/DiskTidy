import Foundation

final class AppNavigationState: ObservableObject {
    @Published var selectedTab: Int? = 0
}
