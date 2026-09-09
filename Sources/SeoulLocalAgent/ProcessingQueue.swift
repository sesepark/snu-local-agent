import Foundation

enum ProcessingJobKind: String, Hashable {
    case transcription
    case organization

    var title: String {
        switch self {
        case .transcription: "전사"
        case .organization: "AI 자동요약"
        }
    }

    var symbol: String {
        switch self {
        case .transcription: "waveform"
        case .organization: "sparkles"
        }
    }
}

struct ProcessingQueueItem: Identifiable, Hashable {
    let id: UUID
    let kind: ProcessingJobKind
    let title: String
    let detail: String
    let enqueuedAt: Date
}

struct TranscriptionQueuePayload {
    let recording: RecordingItem
    let asrModel: ASRModelChoice
    let diarization: DiarizationChoice
    let timestampMode: TranscriptionTimestampMode
    let language: TranscriptionLanguage
}

struct OrganizationQueuePayload {
    let transcript: TranscriptRun
    let recordingTitle: String
    let kind: TranscriptOrganizationKind
    let detail: TranscriptOrganizationDetail
    let prompt: String
}

enum ProcessingQueuePayload {
    case transcription(TranscriptionQueuePayload)
    case organization(OrganizationQueuePayload)
}

struct QueuedProcessingWork: Identifiable {
    let item: ProcessingQueueItem
    let payload: ProcessingQueuePayload

    var id: UUID { item.id }
}

struct ProcessingQueueState {
    private(set) var work: [QueuedProcessingWork] = []

    var items: [ProcessingQueueItem] { work.map(\.item) }

    mutating func enqueue(_ queuedWork: QueuedProcessingWork) {
        work.append(queuedWork)
    }

    func next(activeID: UUID?) -> QueuedProcessingWork? {
        guard activeID == nil else { return nil }
        return work.first
    }

    mutating func remove(_ id: UUID) {
        work.removeAll { $0.id == id }
    }

    mutating func clearWaiting(activeID: UUID?) {
        work.removeAll { $0.id != activeID }
    }
}
