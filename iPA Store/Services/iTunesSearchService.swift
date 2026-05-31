import Foundation
import Combine

@MainActor
final class iTunesSearchService: ObservableObject {
    @Published var results: [AppResult] = []
    @Published var isLoading = false
    @Published var query: String = ""

    init() {}

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            isLoading = false
            return
        }

        isLoading = true

        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed

        guard let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=30") else {
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)

            results = response.results
        } catch {
            print("Search error: \(error)")
        }

        isLoading = false
    }

    func clear() {
        results = []
        isLoading = false
    }
}
