import SwiftUI

struct YouTubeAdBlockStatusView: View {
    @ObservedObject var adBlock: YouTubeAdBlock
    var retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if adBlock.status == .loading { ProgressView().controlSize(.small) }
                Label(adBlock.status.title, systemImage: adBlock.status == .active ? "shield.lefthalf.filled" : "exclamationmark.shield")
                    .foregroundStyle(adBlock.status == .active ? Color.green : Color.secondary)
            }
            if case .failed(let message) = adBlock.status {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("광고 차단 다시 시도", action: retry).buttonStyle(.bordered)
            }
            if !adBlock.enabled { Text("광고 차단을 끈 상태에서는 YouTube 광고가 나올 수 있습니다.").foregroundStyle(.orange) }
        }.font(.caption)
    }
}

struct YouTubeAdBlockSettingsView: View {
    @ObservedObject var adBlock: YouTubeAdBlock
    var retry: () -> Void
    var body: some View {
        Section("YouTube 광고 차단") {
            Toggle("uBlock Origin Lite 광고 차단", isOn: Binding(get: { adBlock.enabled }, set: { adBlock.setEnabled($0) }))
            YouTubeAdBlockStatusView(adBlock: adBlock, retry: retry)
            Text("앱 안의 YouTube 플레이어에 공식 확장을 적용합니다. 브라우저로 이동하거나 다른 음원으로 대체하지 않습니다. 차단 준비에 실패하면 재생을 중단합니다. 설정을 바꾸면 현재 YouTube 재생이 멈춥니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("필터 버전 \(YouTubeAdBlockArchive.version) · YouTube 변경에 따라 차단이 일시적으로 실패할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Link("확장 정보·소스·GPL 라이선스", destination: URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/tag/2026.907.2003")!)
        }
    }
}
