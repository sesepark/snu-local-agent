import Foundation
import CoreGraphics
import PDFKit

/// 실제로 나올 종이를 이 Mac에서 미리 만들어 둔다.
///
/// ## 왜 서버에 맡기지 않는가
///
/// 모아찍기와 쪽 범위는 CUPS도 할 수 있다(`-o number-up`, `-o page-ranges`). 그렇게 하면
/// 화면은 **원본 쪽**을 보여 주고 종이에는 **네 쪽이 한 장에** 나온다. 그 둘이 다른 순간
/// 미리보기는 미리보기가 아니라 다른 그림이다.
///
/// 그래서 여기서 종이를 만든다. 화면에 그리는 것과 서버로 보내는 것이 **같은 파일**이 되고,
/// 미리보기는 근사가 아니라 그 파일을 그대로 그린 것이 된다. 서버로 갈 때는 모아찍기와
/// 범위를 옵션에서 빼서 두 번 적용되지 않게 한다.
///
/// 바꿀 것이 없으면(한 쪽에 한 장, 범위 전체) 아무것도 만들지 않고 원본을 그대로 쓴다.
enum PrintComposition {

    struct Composed: Sendable {
        /// 서버로 보낼 파일. 원본 그대로일 수 있다.
        let url: URL
        /// 실제로 나올 종이 수(한 부 기준).
        let sheets: Int
        /// 우리가 만든 파일인가. 원본은 지우지 않는다.
        let isTemporary: Bool
        /// 쪽 범위와 모아찍기를 여기서 적용했는가. 서버로 보낼 때 그것을 빼기 위한 표.
        let appliedLocally: Bool
    }

    /// `1-4,8,11-`을 0부터 세는 쪽 번호로 편다. 문서 밖의 번호는 조용히 빠진다.
    static func selectedPages(count: Int, range: String) -> [Int] {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        guard count > 0 else { return [] }
        guard !trimmed.isEmpty, PrintOptions.isValidRange(trimmed) else { return Array(0..<count) }
        var pages: [Int] = []
        var seen = Set<Int>()
        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            let low: Int
            let high: Int
            if bounds.count == 1 {
                low = Int(bounds[0]) ?? 0
                high = low
            } else {
                low = bounds[0].isEmpty ? 1 : (Int(bounds[0]) ?? 1)
                high = bounds[1].isEmpty ? count : (Int(bounds[1]) ?? count)
            }
            // 문서 밖만 가리키는 조각(3쪽짜리에 적힌 `50-60`)은 빈 구간이다. 그대로
            // 범위를 만들면 `50...3`이 되어 그 자리에서 앱이 죽는다.
            let lower = max(1, low)
            let upper = min(max(1, high), count)
            guard lower <= upper else { continue }
            for page in lower...upper {
                if seen.insert(page - 1).inserted { pages.append(page - 1) }
            }
        }
        return pages
    }

    /// 모아찍기 칸 나누기. 종이를 세로로 몇 칸, 가로로 몇 칸 쪼갤지 정한다.
    ///
    /// 쪽이 세로로 길면 두 장은 **가로로 나란히** 놓는 것이 크게 나오고, 쪽이 가로로 길면
    /// 위아래로 쌓는 것이 크게 나온다. 두 배치를 모두 재어 더 크게 나오는 쪽을 고른다 —
    /// 어느 쪽이 맞는지는 문서가 정하는 것이지 우리가 정할 일이 아니다.
    static func grid(numberUp: Int, paper: CGSize, page: CGSize) -> (columns: Int, rows: Int) {
        let candidates: [(Int, Int)] = switch max(1, numberUp) {
        case 2: [(2, 1), (1, 2)]
        case 4: [(2, 2)]
        case 6: [(3, 2), (2, 3)]
        case 9: [(3, 3)]
        case 16: [(4, 4)]
        default: [(1, 1)]
        }
        guard page.width > 0, page.height > 0 else { return candidates[0] }
        return candidates.max { first, second in
            scale(paper: paper, page: page, columns: first.0, rows: first.1)
                < scale(paper: paper, page: page, columns: second.0, rows: second.1)
        } ?? candidates[0]
    }

    private static func scale(paper: CGSize, page: CGSize, columns: Int, rows: Int) -> CGFloat {
        let cell = CGSize(width: paper.width / CGFloat(columns), height: paper.height / CGFloat(rows))
        return min(cell.width / page.width, cell.height / page.height)
    }

    /// 종이 한 장에 몇 쪽이 들어가는지까지 셈에 넣은 종이 수.
    static func sheetCount(pages: Int, numberUp: Int) -> Int {
        guard pages > 0 else { return 0 }
        return Int(ceil(Double(pages) / Double(max(1, numberUp))))
    }

    /// 쪽 하나를 주어진 자리에 **꽉 차게** 앉히는 변환.
    ///
    /// `CGPDFPage.getDrawingTransform`을 쓰지 않는다. 그것은 자리가 쪽보다 클 때 **키우지
    /// 않고** 가운데에 1:1로 놓기만 한다(Apple 문서의 "scaled down if necessary"가 그 뜻이다).
    /// 미리보기를 화면 크기로 그릴 때가 정확히 그 경우여서, 화면에는 작게 그려지고 종이에는
    /// 크게 나오는 일이 실제로 있었다 — 서버가 같은 파일을 그린 것과 맞대 보고서야 드러났다.
    /// 여기서는 줄이기도 하고 키우기도 한다.
    ///
    /// 쪽 자신이 지닌 회전(스캔본이 흔히 갖고 있다)과 사람이 고른 회전을 합쳐서 함께 적용한다.
    static func transform(for page: CGPDFPage, into rect: CGRect, rotation: Int) -> CGAffineTransform {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return .identity }
        let total = ((Int(page.rotationAngle) + rotation) % 360 + 360) % 360
        // 90°와 270°는 가로세로를 바꾼다.
        let source = total % 180 == 0
            ? CGSize(width: box.width, height: box.height)
            : CGSize(width: box.height, height: box.width)
        let scale = min(rect.width / source.width, rect.height / source.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        transform = transform.scaledBy(x: scale, y: scale)
        // PDF의 회전값은 시계 방향이고, CoreGraphics의 좌표계는 위로 자란다. 시계 방향은 음수다.
        transform = transform.rotated(by: -CGFloat(total) * .pi / 180)
        transform = transform.translatedBy(x: -box.midX, y: -box.midY)
        return transform
    }

    static func compose(_ source: URL, options: PrintOptions) throws -> Composed {
        guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0 else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        let count = document.numberOfPages
        let pages = selectedPages(count: count, range: options.pageRange)
        guard !pages.isEmpty else {
            throw AgentError.processFailed("고른 쪽 범위에 해당하는 쪽이 없습니다 (문서는 \(count)쪽입니다).")
        }
        let numberUp = max(1, options.numberUp)
        // 바꿀 것이 없으면 만들지 않는다. 멀쩡한 PDF를 다시 굽는 것은 시간과 용량만 쓰고,
        // 원본이 지닌 것(글꼴·책갈피·주석)을 잃을 위험만 더한다.
        if numberUp == 1, pages.count == count, options.rotation == .none {
            return Composed(url: source, sheets: count, isTemporary: false, appliedLocally: false)
        }

        let paper = PaperGeometry.size(for: options.paper)
        let destination = ToolWorkspace.outputURL(
            for: source, extension: "pdf", in: try PrintPreparation.directory()
        )
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw AgentError.processFailed("미리보기를 만들지 못했습니다: \(source.lastPathComponent)")
        }

        let firstBox = document.page(at: pages[0] + 1)
            .map { $0.getBoxRect(.cropBox) } ?? CGRect(origin: .zero, size: paper)
        // 돌린 뒤의 모양으로 칸을 나눈다. 눕힌 쪽을 세운 쪽 기준으로 나누면 칸에 맞지 않아
        // 작게 들어간다.
        let shape = options.rotation.swapsAxes
            ? CGSize(width: max(1, firstBox.height), height: max(1, firstBox.width))
            : CGSize(width: max(1, firstBox.width), height: max(1, firstBox.height))
        let layout = grid(numberUp: numberUp, paper: paper, page: shape)
        // 한 장에 한 쪽일 때는 여백을 두지 않는다 — 원본이 이미 자기 여백을 갖고 있고,
        // 여기서 또 줄이면 두 번 줄어든다. 모아찍기일 때만 칸 사이가 붙지 않게 띄운다.
        let margin: CGFloat = numberUp > 1 ? 18 : 0
        let gutter: CGFloat = numberUp > 1 ? 8 : 0
        let cellWidth = (paper.width - margin * 2 - gutter * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
        let cellHeight = (paper.height - margin * 2 - gutter * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)

        var sheets = 0
        for start in stride(from: 0, to: pages.count, by: numberUp) {
            context.beginPDFPage(nil)
            for slot in 0..<numberUp {
                let index = start + slot
                guard index < pages.count, let page = document.page(at: pages[index] + 1) else { break }
                // 왼쪽에서 오른쪽으로, 위에서 아래로. 사람이 종이를 읽는 순서다.
                let column = slot % layout.columns
                let row = slot / layout.columns
                let cell = CGRect(
                    x: margin + CGFloat(column) * (cellWidth + gutter),
                    y: paper.height - margin - CGFloat(row + 1) * cellHeight - CGFloat(row) * gutter,
                    width: cellWidth, height: cellHeight
                )
                context.saveGState()
                context.clip(to: cell)
                context.concatenate(transform(for: page, into: cell, rotation: options.rotation.rawValue))
                context.drawPDFPage(page)
                context.restoreGState()
            }
            context.endPDFPage()
            sheets += 1
        }
        context.closePDF()
        return Composed(url: destination, sheets: sheets, isTemporary: true, appliedLocally: true)
    }
}

/// 만들어 둔 종이를 화면에 그린다.
enum PrintPreviewRenderer {
    static func pageCount(of url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    /// - Parameter grayscale: 흑백으로 보낼 때는 회색으로 그린다. 컬러 슬라이드를 흑백으로
    ///   보내 놓고 화면만 컬러로 보여 주면, 정작 확인해야 할 것(글자가 배경에 묻히는가)을
    ///   확인할 수 없다.
    static func render(_ url: URL, sheet index: Int, grayscale: Bool, maxPixel: CGFloat) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL),
              index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1)
        else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        // 쪽 자신이 회전을 지니고 있으면 그린 그림도 가로세로가 바뀐다.
        let rotated = Int(page.rotationAngle) % 180 != 0
        let shown = rotated
            ? CGSize(width: box.height, height: box.width)
            : CGSize(width: box.width, height: box.height)
        let scale = max(1, maxPixel) / max(shown.width, shown.height)
        let width = max(1, Int((shown.width * scale).rounded()))
        let height = max(1, Int((shown.height * scale).rounded()))
        let space = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ) else { return nil }
        // 종이는 희다. 칠하지 않으면 검은 바탕에 검은 글씨가 된다.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.concatenate(PrintComposition.transform(
            for: page, into: CGRect(x: 0, y: 0, width: width, height: height), rotation: 0
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
