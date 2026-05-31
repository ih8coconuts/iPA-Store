// Models/AppResult.swift
import Foundation

struct SearchResponse: Codable {
    let resultCount: Int
    let results: [AppResult]
}

struct AppResult: Codable, Identifiable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let bundleId: String?
    let artworkUrl512: String
    let price: Double?
    let formattedPrice: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let description: String?
    let fileSizeBytes: String?
    let version: String?
    let genres: [String]
    
    var id: Int { trackId }
}
