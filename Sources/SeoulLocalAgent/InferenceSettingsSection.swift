import SwiftUI

/// 설정 › 브리핑 안에서 "판단을 어디에 맡길지"를 고르는 자리.
///
/// 이 앱에서 가장 조심스러운 설정이라 화면이 조금 길다. 밖으로 내보내는 쪽을 켜면
/// 무엇이 나가고 무엇이 남는지를 **켜기 전에** 같은 화면에서 읽을 수 있어야 한다.
struct InferenceLocationSection: View {
    @AppStorage("inferenceBackend") private var backendRaw = InferenceBackend.local.rawValue
    @AppStorage("inferencePreset") private var presetID = RemoteInferencePreset.upstage.id
    @AppStorage("inferenceBaseURL") private var baseURL = ""
    @AppStorage("inferenceRemoteModel") private var remoteModel = ""
    /// 비워 두면 기계를 따라간다. 이름을 적으면 그 선택이 이긴다.
    @AppStorage("preferredLocalModel") private var preferredLocalModel = ""

    @State private var apiKeyDraft = ""
    @State private var keyStatus = ""

    private var backend: InferenceBackend { InferenceBackend(rawValue: backendRaw) ?? .local }
    private var preset: RemoteInferencePreset {
        RemoteInferencePreset.all.first { $0.id == presetID } ?? .custom
    }

    var body: some View {
        Section("판단 위치") {
            Picker("어디서 판단할까요", selection: $backendRaw) {
                ForEach(InferenceBackend.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)

            Label(backend.privacyNote, systemImage: backend == .local ? "lock.fill" : "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(backend == .local ? Color.secondary : Color.orange)

            if backend == .local { localFields } else { remoteFields }
        }
    }

    // MARK: - 이 Mac 안에서

    @ViewBuilder private var localFields: some View {
        LabeledContent("이 Mac", value: MachineCapability.current.summary).font(.caption)
        LabeledContent("지금 쓰는 모델", value: AppConfig.model).font(.caption)
        TextField("직접 지정", text: $preferredLocalModel, prompt: Text("비워 두면 이 Mac에 맞춰 고릅니다"))

        // 한국어 공지와 메일이 입력의 대부분이라, 한국어로 학습된 모델을 쓰고 싶다는
        // 선택에는 근거가 있다. 자동 선택이 MoE만 고르는 이유는 속도라, 이 선택은
        // 사용자가 직접 눌러야만 켜진다.
        VStack(alignment: .leading, spacing: 6) {
            Text("국산 모델로 바꾸기").font(.caption).bold()
            ForEach(LocalModelCatalog.koreanEntries) { entry in
                let fits = entry.gigabytes <= MachineCapability.current.modelBudgetGigabytes
                HStack(spacing: 8) {
                    Button(entry.tag) { preferredLocalModel = entry.tag }
                        .buttonStyle(.link)
                        .disabled(!fits)
                    Text("\(String(format: "%.1f", entry.gigabytes))GB · \(entry.summary)")
                        .font(.caption2)
                        .foregroundStyle(fits ? .secondary : .tertiary)
                }
            }
            Text("고른 뒤 터미널에서 `ollama pull <태그>`를 한 번 실행해야 합니다. 이 Mac에 버거운 것은 흐리게 둡니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }

        Text("가중치가 물리 메모리의 절반을 넘으면 실패하는 대신 **조용히 느려지기만** 하므로, 기본값은 그 선을 넘지 않는 가장 큰 모델입니다. 여기에 Ollama 태그를 적으면 그 판단을 덮어씁니다 — 받아 두지 않은 이름을 적으면 브리핑이 시작할 때 그렇게 말합니다.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - API로

    @ViewBuilder private var remoteFields: some View {
        Picker("제공처", selection: $presetID) {
            ForEach(RemoteInferencePreset.all) { Text($0.name).tag($0.id) }
        }
        .onChange(of: presetID) { _, _ in
            // 프리셋을 바꿨는데 예전 주소가 남아 있으면, 사용자는 바꾼 적 없는 곳으로
            // 요청이 가는 것을 보게 된다. 비워서 새 프리셋의 기본값이 드러나게 한다.
            baseURL = ""
            remoteModel = ""
        }

        TextField("API 주소", text: $baseURL, prompt: Text(preset.baseURL.isEmpty ? "https://…/v1" : preset.baseURL))
        TextField("모델 이름", text: $remoteModel, prompt: Text(preset.defaultModel.isEmpty ? "모델 이름" : preset.defaultModel))

        HStack {
            SecureField("API 키", text: $apiKeyDraft, prompt: Text("입력한 뒤 저장을 누르세요"))
            Button("Keychain에 저장") {
                do {
                    try InferenceSettings.saveAPIKey(apiKeyDraft)
                    apiKeyDraft = ""
                    keyStatus = "저장했습니다."
                } catch {
                    keyStatus = "저장하지 못했습니다: \(error.localizedDescription)"
                }
            }
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !keyStatus.isEmpty {
            Text(keyStatus).font(.caption).foregroundStyle(.secondary)
        } else if (InferenceSettings.apiKey ?? "").isEmpty {
            Text("아직 키가 없습니다.").font(.caption).foregroundStyle(.orange)
        } else {
            Text("키가 Keychain에 저장되어 있습니다. 저장소나 설정 파일에는 남지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Text(preset.note).font(.caption).foregroundStyle(.secondary)
        Text("이 설정은 **브리핑 분류와 전사 정리에만** 적용됩니다. 파일 변환, 문서 인식, 배경 제거, 화질 개선은 모델을 쓰지 않거나 이 Mac 안의 것만 쓰므로 어떤 경우에도 파일이 밖으로 나가지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
