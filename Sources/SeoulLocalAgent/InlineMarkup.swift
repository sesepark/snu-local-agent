import Foundation

/// 실행 중에 만들어진 문장 안의 `코드`와 **굵게**를 그린다.
///
/// SwiftUI의 `Text("리터럴")`은 마크다운을 해석하지만 `Text(변수)`는 글자 그대로 그린다.
/// 서버 문구 번역, 점검표 요약, 확인 시트, 큐 안내처럼 실행 중에 조립되는 문장에는 단추
/// 이름을 백틱으로 감싼 것이 많았고, 그것이 화면에 백틱째 찍혔다 — "먼저 `학습 서버로
/// 전송`을 눌러야…"가 그 모양 그대로 보였다.
///
/// 마크다운 전체를 해석하지 않는 이유가 있다. `AttributedString(markdown:)`은 파일 이름의
/// 밑줄을 기울임으로, 별표 하나를 강조로 바꾼다. 오류 문구에는 경로와 명령이 그대로 실리므로
/// 그 변형은 뜻을 바꾼다. 여기서는 두 표기만 알고, 짝이 맞지 않는 표식은 글자로 남긴다.
enum InlineMarkup {
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = text[...]
        while let (open, marker) = nextMarker(in: rest) {
            result.append(AttributedString(String(rest[rest.startIndex..<open])))
            let afterOpen = rest.index(open, offsetBy: marker.count)
            guard let close = rest[afterOpen...].range(of: marker), close.lowerBound > afterOpen else {
                // 닫는 짝이 없으면 표식을 글자 그대로 두고 지나간다.
                result.append(AttributedString(String(rest[open..<afterOpen])))
                rest = rest[afterOpen...]
                continue
            }
            var inner = AttributedString(String(rest[afterOpen..<close.lowerBound]))
            inner.inlinePresentationIntent = marker == "`" ? .code : .stronglyEmphasized
            result.append(inner)
            rest = rest[close.upperBound...]
        }
        result.append(AttributedString(String(rest)))
        return result
    }

    /// 꾸밈을 그릴 수 없는 자리(툴팁, 접근성 문구)를 위한 평문. 백틱은 홑따옴표가 되고
    /// 굵게 표식은 사라진다.
    static func plain(_ text: String) -> String {
        var out = ""
        var inCode = false
        var rest = text[...]
        while let index = rest.firstIndex(where: { $0 == "`" || $0 == "*" }) {
            out += rest[rest.startIndex..<index]
            if rest[index] == "`" {
                out += inCode ? "’" : "‘"
                inCode.toggle()
                rest = rest[rest.index(after: index)...]
            } else if rest[index...].hasPrefix("**") {
                rest = rest[rest.index(index, offsetBy: 2)...]
            } else {
                out.append(rest[index])
                rest = rest[rest.index(after: index)...]
            }
        }
        out += rest
        return out
    }

    private static func nextMarker(in text: Substring) -> (Substring.Index, String)? {
        let tick = text.firstIndex(of: "`")
        let bold = text.range(of: "**")?.lowerBound
        switch (tick, bold) {
        case (nil, nil): return nil
        case (let tick?, nil): return (tick, "`")
        case (nil, let bold?): return (bold, "**")
        case (let tick?, let bold?): return tick < bold ? (tick, "`") : (bold, "**")
        }
    }
}
