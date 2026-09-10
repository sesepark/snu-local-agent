import Foundation

/// 판단을 어디에 맡길지.
///
/// 이 앱은 "전부 이 기계 안에서"라는 전제 위에 만들어졌다. 그 전제는 만든 사람의
/// 맥(64GB)에서는 옳았지만, 받아 쓰는 사람의 맥이 16GB이면 앱을 켤 수조차 없다는
/// 뜻이기도 했다 — `MachineCapability`가 "이 맥에서는 버겁습니다"를 띄우고 거기서
/// 끝난다. 판단의 자리를 하나 더 열어 두면 같은 앱이 두 기계 모두에서 돈다.
///
/// 기본값은 여전히 `.local`이다. 이 앱이 존재하는 이유가 성적표와 장학금 서류를
/// 낯선 서비스에 올리지 않는 것이므로, **밖으로 내보내는 쪽은 사용자가 직접 고를
/// 때만 켜진다.** 고른 뒤에도 무엇이 나가는지는 설정 화면이 그대로 말한다.
enum InferenceBackend: String, CaseIterable, Sendable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "이 Mac 안에서 (Ollama)"
        case .remote: "API로 연결 (OpenAI 호환)"
        }
    }

    /// 오류 문구가 "로컬 모델 …"로 시작하면 API를 쓰는 사람은 자기 이야기가 아니라고
    /// 읽는다. 실패를 말할 때 쓰는 이름은 실제로 고른 쪽을 가리켜야 한다.
    var noun: String {
        switch self {
        case .local: "로컬 모델"
        case .remote: "API 모델"
        }
    }

    var privacyNote: String {
        switch self {
        case .local:
            "메일·문자·공지의 본문이 이 Mac을 떠나지 않습니다."
        case .remote:
            "분류할 항목의 제목과 본문이 아래 주소로 전송됩니다. 파일 변환·전사·문서 인식은 이 설정과 무관하게 계속 이 Mac 안에서만 처리됩니다."
        }
    }
}

/// 자주 쓰는 주소를 미리 적어 둔다. 직접 입력해도 되지만, 주소 한 글자가 틀리면
/// 사용자는 "연결 실패"만 보고 어디가 틀렸는지 알 수 없다.
struct RemoteInferencePreset: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let defaultModel: String
    let note: String

    /// 업스테이지 Solar. 국산 파운데이션 모델이고 OpenAI 호환 경로를 그대로 낸다.
    static let upstage = RemoteInferencePreset(
        id: "upstage", name: "업스테이지 Solar (국산)",
        baseURL: "https://api.upstage.ai/v1", defaultModel: "solar-pro2",
        note: "한국어 문서에 맞춰 학습된 국산 모델입니다. console.upstage.ai에서 키를 발급합니다."
    )
    static let openAI = RemoteInferencePreset(
        id: "openai", name: "OpenAI",
        baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini",
        note: "platform.openai.com에서 키를 발급합니다."
    )
    static let custom = RemoteInferencePreset(
        id: "custom", name: "직접 입력",
        baseURL: "", defaultModel: "",
        note: "OpenAI 호환 `/chat/completions`를 내는 곳이면 어디든 됩니다. 사내 게이트웨이나 다른 기기의 Ollama도 여기에 적습니다."
    )

    static let all: [RemoteInferencePreset] = [upstage, openAI, custom]
}

/// API 키가 Keychain에 놓이는 자리. 저장소에도, 설정 파일에도 남지 않는다.
enum RemoteInferenceCredential {
    static let service = "kr.ac.snu.local-agent.inference"
    static let account = "api-key"
}

enum InferenceSettings {
    private static let backendKey = "inferenceBackend"
    private static let baseURLKey = "inferenceBaseURL"
    private static let modelKey = "inferenceRemoteModel"
    private static let presetKey = "inferencePreset"

    static var backend: InferenceBackend {
        get { InferenceBackend(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }

    static var presetID: String {
        get { UserDefaults.standard.string(forKey: presetKey) ?? RemoteInferencePreset.upstage.id }
        set { UserDefaults.standard.set(newValue, forKey: presetKey) }
    }

    static var preset: RemoteInferencePreset {
        RemoteInferencePreset.all.first { $0.id == presetID } ?? .custom
    }

    /// 비어 있으면 고른 프리셋의 주소를 쓴다. 프리셋을 바꿨는데 예전 주소가 남아
    /// 있으면 사용자는 바꾼 적 없는 곳으로 요청이 가는 것을 보게 된다.
    static var baseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? preset.baseURL : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var remoteModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? preset.defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey) }
    }

    /// 화면과 오류 문구가 같은 이름을 부르게 한다.
    static var activeModelName: String {
        backend == .local ? AppConfig.model : remoteModel
    }

    static var apiKey: String? {
        try? Keychain.string(service: RemoteInferenceCredential.service,
                             account: RemoteInferenceCredential.account,
                             missing: "API 키가 없습니다.")
    }

    static func saveAPIKey(_ value: String) throws {
        try Keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines),
                          service: RemoteInferenceCredential.service,
                          account: RemoteInferenceCredential.account)
    }

    /// 켜기 전에 막는다. 요청을 보내고 401을 받아 보는 것보다, 무엇이 비었는지
    /// 이름으로 말해 주는 편이 사용자가 고칠 수 있다.
    static func remoteConfigurationProblem() -> String? {
        guard backend == .remote else { return nil }
        if baseURL.isEmpty { return "API 주소가 비어 있습니다. 설정 › 판단 위치에서 주소를 적어 주세요." }
        if URL(string: baseURL) == nil { return "API 주소 형식이 올바르지 않습니다: \(baseURL)" }
        if remoteModel.isEmpty { return "모델 이름이 비어 있습니다. 설정 › 판단 위치에서 적어 주세요." }
        if (apiKey ?? "").isEmpty { return "API 키가 Keychain에 없습니다. 설정 › 판단 위치에서 저장해 주세요." }
        return nil
    }
}

/// 한 번의 요청 = 시스템 프롬프트 + 사용자 프롬프트 + "JSON으로만 답하라".
///
/// 두 백엔드가 요구하는 모양이 다르다. Ollama는 `format`에 JSON 스키마를 그대로
/// 받고, OpenAI 호환 API는 `response_format`으로 "객체 하나"까지만 약속한다. 그래서
/// 원격 쪽에서는 스키마를 시스템 프롬프트 끝에 글로 붙여 준다 — 강제는 아니지만,
/// 이 파이프라인은 어차피 스키마를 어긴 응답을 항목별 폴백으로 받아 낼 수 있다.
enum StructuredInference {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    /// - Returns: 모델이 낸 원문 텍스트. JSON만 있는 것이 보장되지는 않으므로,
    ///   호출자가 지금까지 하던 대로 중괄호 범위를 잘라 쓰면 된다.
    static func generateJSON(
        system: String,
        prompt: String,
        schema: [String: Any],
        maxTokens: Int,
        temperature: Double = 0.1,
        contextTokens: Int = 16_384,
        label: String
    ) async throws -> String {
        try await generate(system: system, prompt: prompt, schema: schema, maxTokens: maxTokens,
                           temperature: temperature, contextTokens: contextTokens, label: label)
    }

    /// 스키마 없이 글을 받는 자리 — 전사 정리처럼 결과가 Markdown인 경우.
    static func generateText(
        system: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double = 0.1,
        contextTokens: Int = 32_768,
        label: String
    ) async throws -> String {
        try await generate(system: system, prompt: prompt, schema: nil, maxTokens: maxTokens,
                           temperature: temperature, contextTokens: contextTokens, label: label)
    }

    private static func generate(
        system: String,
        prompt: String,
        schema: [String: Any]?,
        maxTokens: Int,
        temperature: Double,
        contextTokens: Int,
        label: String
    ) async throws -> String {
        switch InferenceSettings.backend {
        case .local:
            return try await generateWithOllama(system: system, prompt: prompt, schema: schema,
                                                maxTokens: maxTokens, temperature: temperature,
                                                contextTokens: contextTokens, label: label)
        case .remote:
            if let problem = InferenceSettings.remoteConfigurationProblem() {
                throw AgentError.processFailed(problem)
            }
            return try await generateWithOpenAICompatible(system: system, prompt: prompt, schema: schema,
                                                          maxTokens: maxTokens, temperature: temperature,
                                                          label: label)
        }
    }

    // MARK: - 이 Mac 안에서

    private static func generateWithOllama(
        system: String, prompt: String, schema: [String: Any]?,
        maxTokens: Int, temperature: Double, contextTokens: Int, label: String
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": AppConfig.model, "system": system, "prompt": prompt,
            "stream": false, "think": false, "keep_alive": "5m",
            "options": [
                "num_ctx": contextTokens, "temperature": temperature, "top_p": 0.8,
                "top_k": 20, "repeat_penalty": 1.0, "num_predict": maxTokens,
            ],
        ]
        if let schema { payload["format"] = schema }
        var request = URLRequest(url: AppConfig.ollamaURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await requestWithRetry(request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AgentError.processFailed(LocalClassifier.modelFailure(status: (response as? HTTPURLResponse)?.statusCode, body: data))
        }
        struct OllamaReply: Decodable { let response: String?; let error: String? }
        let reply: OllamaReply
        do { reply = try JSONDecoder().decode(OllamaReply.self, from: data) }
        catch { throw AgentError.processFailed("로컬 모델 API 응답 형식 오류 (\(label))") }
        if let error = reply.error { throw AgentError.processFailed("로컬 모델 오류: \(error)") }
        guard let text = reply.response else {
            throw AgentError.processFailed("로컬 모델이 응답 본문을 반환하지 않았습니다 (\(label)).")
        }
        return text
    }

    // MARK: - API로

    private static func generateWithOpenAICompatible(
        system: String, prompt: String, schema: [String: Any]?,
        maxTokens: Int, temperature: Double, label: String
    ) async throws -> String {
        // Ollama는 스키마를 강제하지만 OpenAI 호환 쪽은 "JSON 객체"까지만 약속한다.
        // 모양을 글로 알려 주지 않으면 필드 이름이 매번 조금씩 달라진다.
        let systemWithSchema: String
        if let schema,
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            systemWithSchema = """
            \(system)

            Reply with a single JSON object and nothing else. It must match this JSON Schema exactly, including every field name:
            \(String(decoding: data, as: UTF8.self))
            """
        } else {
            systemWithSchema = system
        }

        func body(includeResponseFormat: Bool) -> [String: Any] {
            var payload: [String: Any] = [
                "model": InferenceSettings.remoteModel,
                "messages": [
                    ["role": "system", "content": systemWithSchema],
                    ["role": "user", "content": prompt],
                ],
                "temperature": temperature,
                "max_tokens": maxTokens,
                "stream": false,
            ]
            if includeResponseFormat, schema != nil { payload["response_format"] = ["type": "json_object"] }
            return payload
        }

        func send(includeResponseFormat: Bool) async throws -> (Data, URLResponse) {
            guard let base = URL(string: InferenceSettings.baseURL) else {
                throw AgentError.processFailed("API 주소 형식이 올바르지 않습니다: \(InferenceSettings.baseURL)")
            }
            var request = URLRequest(url: base.appending(path: "chat/completions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(InferenceSettings.apiKey ?? "")", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body(includeResponseFormat: includeResponseFormat))
            return try await requestWithRetry(request)
        }

        var (data, response) = try await send(includeResponseFormat: true)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `response_format`을 모르는 호환 서버가 적지 않고, 그때 오는 것은 400이다.
        // 그 한 필드 때문에 "연결은 되는데 계속 실패"로 끝나면 원인을 찾기 어렵다.
        if status == 400 {
            (data, response) = try await send(includeResponseFormat: false)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard 200..<300 ~= status else {
            throw AgentError.processFailed(remoteFailure(status: status, body: data))
        }

        struct ChatReply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        let reply: ChatReply
        do { reply = try JSONDecoder().decode(ChatReply.self, from: data) }
        catch { throw AgentError.processFailed("API 응답 형식 오류 (\(label))") }
        guard let text = reply.choices?.first?.message?.content, !text.isEmpty else {
            throw AgentError.processFailed("API가 응답 본문을 반환하지 않았습니다 (\(label)).")
        }
        return text
    }

    /// 401과 429는 고치는 방법이 완전히 다르다. 상태 코드만 던지면 사용자는 둘을
    /// 구별하지 못하고, 키를 다시 발급하며 시간을 쓴다.
    static func remoteFailure(status: Int, body: Data) -> String {
        let reported = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401, 403:
            return "API 키가 거부되었습니다 (HTTP \(status)). 설정 › 판단 위치에서 키를 다시 저장해 주세요."
        case 404:
            return "모델 \(InferenceSettings.remoteModel)을 찾지 못했습니다 (HTTP 404). 모델 이름이나 주소를 확인해 주세요."
        case 429:
            return "요청이 한도를 넘었습니다 (HTTP 429). 잠시 뒤에 다시 시도하거나 설정 › 분석 품질을 '빠르게'로 낮춰 주세요."
        default:
            if let reported, !reported.isEmpty { return "API 오류 HTTP \(status): \(reported)" }
            return "API 오류 HTTP \(status)."
        }
    }

    private static func requestWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...2 {
            do { return try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                if attempt == 1 { try await Task.sleep(for: .milliseconds(350)) }
            }
        }
        if let urlError = lastError as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut].contains(urlError.code) {
            switch InferenceSettings.backend {
            case .local:
                throw AgentError.processFailed("Ollama에 연결하지 못했습니다 (\(AppConfig.ollamaURL.absoluteString)). 터미널에서 `ollama serve`로 실행 중인지 확인해 주세요.")
            case .remote:
                throw AgentError.processFailed("API에 연결하지 못했습니다 (\(InferenceSettings.baseURL)). 주소와 네트워크를 확인해 주세요.")
            }
        }
        throw lastError ?? AgentError.processFailed("\(InferenceSettings.backend.noun) 요청 실패")
    }
}
