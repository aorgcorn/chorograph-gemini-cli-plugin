// ModelsDevClient.swift
// Fetches the models.dev catalogue and extracts ProviderModel lists.

import Foundation
import ChorographPluginSDK

// MARK: - ModelsDevClient

actor ModelsDevClient {

    static let shared = ModelsDevClient()

    private static let apiURL = URL(string: "https://models.dev/api.json")!
    private static let cacheTTL: TimeInterval = 3600

    private var cache: [String: Any]?
    private var cacheDate: Date?
    private var fetchTask: Task<[String: Any], Error>?

    func models(
        forProvider providerKey: String,
        filter: (([String: Any]) -> Bool)? = nil
    ) async throws -> [ProviderModel] {
        let catalogue = try await fetchCatalogue()

        guard let providerEntry = catalogue[providerKey] as? [String: Any],
              let modelsDict = providerEntry["models"] as? [String: Any]
        else { return [] }

        var result: [ProviderModel] = []
        for (modelID, rawValue) in modelsDict {
            guard let modelDict = rawValue as? [String: Any] else { continue }
            if let predicate = filter, !predicate(modelDict) { continue }
            let name = modelDict["name"] as? String ?? modelID
            result.append(ProviderModel(id: modelID, displayName: name))
        }

        return result.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    private func fetchCatalogue() async throws -> [String: Any] {
        if let cached = cache, let date = cacheDate,
           Date().timeIntervalSince(date) < Self.cacheTTL {
            return cached
        }

        if let existing = fetchTask {
            return try await existing.value
        }

        let task = Task<[String: Any], Error> {
            let (data, response) = try await URLSession.shared.data(from: Self.apiURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw ModelsDevError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelsDevError.invalidJSON
            }
            return json
        }

        fetchTask = task
        do {
            let json = try await task.value
            cache = json
            cacheDate = Date()
            fetchTask = nil
            return json
        } catch {
            fetchTask = nil
            throw error
        }
    }
}

// MARK: - ModelsDevError

enum ModelsDevError: Error, LocalizedError {
    case httpError(Int)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "models.dev returned HTTP \(code)."
        case .invalidJSON:         return "models.dev returned unexpected JSON."
        }
    }
}

// MARK: - Gemini model filter

extension ModelsDevClient {
    static func geminiCLIFilter(_ model: [String: Any]) -> Bool {
        guard let id = model["id"] as? String else { return true }
        let excluded = ["embedding", "tts", "image", "live"]
        return !excluded.contains(where: { id.lowercased().contains($0) })
    }
}
