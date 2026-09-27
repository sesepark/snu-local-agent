import Foundation
import SwiftUI

enum SummaryModelAPI {
    static func request(_ path: String, body: [String: String]? = nil, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: AppConfig.ollamaURL.appending(path: path))
        request.timeoutInterval = 15
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentError.processFailed("Ollama 모델을 확인하지 못했습니다. 로컬 실행 상태와 설치된 모델을 확인해 주세요.")
        }
        return data
    }

    static func list() async throws -> [String] {
        struct Model: Decodable { var name: String; var remote_model: String? }
        struct Models: Decodable { var models: [Model] }
        let data = try await request("api/tags")
        let result = try JSONDecoder().decode(Models.self, from: data)
        return result.models.filter { $0.remote_model == nil && !$0.name.hasSuffix("-cloud") && !$0.name.contains(":cloud") }
            .map(\.name).sorted()
    }

    static func contextLength(for model: String, session: URLSession = .shared) async throws -> Int {
        guard !model.isEmpty, !model.hasSuffix("-cloud"), !model.contains(":cloud") else {
            throw AgentError.processFailed("자동요약에는 설치된 로컬 모델만 사용할 수 있습니다.")
        }
        return try validatedContextLength(await request("api/show", body: ["model": model], session: session))
    }

    static func validatedContextLength(_ data: Data) throws -> Int {
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              info["remote_model"] == nil, info["remote_host"] == nil else {
            throw AgentError.processFailed("클라우드 모델 대신 로컬 요약 모델을 선택해 주세요.")
        }
        if let capabilities = info["capabilities"] as? [String], !capabilities.contains("completion") {
            throw AgentError.processFailed("이 모델은 텍스트 요약을 지원하지 않습니다.")
        }
        let lengths = (info["model_info"] as? [String: Any] ?? [:]).filter { $0.key.hasSuffix(".context_length") }
            .compactMap { ($0.value as? NSNumber)?.intValue }
        let length = min(32_768, lengths.min() ?? 8_192)
        guard length >= 8_192 else { throw AgentError.processFailed("요약에는 문맥 길이 8192 이상인 모델이 필요합니다.") }
        return length
    }
}

@MainActor
final class SummaryModelCatalog: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do { models = try await SummaryModelAPI.list(); error = nil }
            catch { self.error = "로컬 모델 목록을 읽지 못했습니다: \(error.localizedDescription)" }
        }
    }
}
