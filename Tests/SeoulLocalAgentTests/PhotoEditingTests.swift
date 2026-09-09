import Foundation
import CoreGraphics
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("사진 편집")
struct PhotoEditingTests {
    /// A 4×2 picture whose left half is red and right half is blue, so a flip or a
    /// crop can be checked by reading one pixel rather than by eye.
    private static func makeImage(width: Int = 4, height: Int = 2) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// Reads one pixel back as (r, g, b), with the origin at the top-left the same
    /// way `PhotoEdit` treats a crop.
    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = [UInt8](UnsafeBufferPointer(start: context.data?.assumingMemoryBound(to: UInt8.self), count: bytes.count))
        let offset = (y * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    @Test("아무것도 바꾸지 않으면 원본을 그대로 돌려준다")
    func identityReturnsTheSameImage() throws {
        let image = try Self.makeImage()
        let edit = PhotoEdit.identity
        #expect(edit.isIdentity)
        #expect(edit.summary == nil)
        // 같은 인스턴스여야 한다. 손대지 않은 사진을 다시 그리는 비용은 낭비다.
        #expect(edit.apply(to: image) === image)
    }

    @Test("자르기는 고른 부분만 남긴다")
    func cropKeepsTheSelectedArea() throws {
        let image = try Self.makeImage(width: 4, height: 2)
        var edit = PhotoEdit.identity
        // 오른쪽 절반(파란색)만 남긴다.
        edit.crop(toSelection: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let result = edit.apply(to: image)
        #expect(result.width == 2)
        #expect(result.height == 2)
        let (r, _, b) = try Self.pixel(result, x: 0, y: 0)
        #expect(b > 200 && r < 50)
        #expect(edit.isCropped)
        #expect(edit.summary?.contains("잘라냄") == true)
    }

    @Test("좌우 뒤집기는 왼쪽과 오른쪽을 바꾼다")
    func horizontalFlipSwapsSides() throws {
        let image = try Self.makeImage()
        var edit = PhotoEdit.identity
        edit.flipHorizontally()
        let result = edit.apply(to: image)
        #expect(result.width == image.width)
        // 원래 왼쪽 끝은 빨강이었다.
        let (r, _, b) = try Self.pixel(result, x: 0, y: 0)
        #expect(b > 200 && r < 50)
        #expect(edit.summary == "좌우 뒤집음")
    }

    @Test("상하 뒤집기는 위아래를 바꾼다")
    func verticalFlipSwapsRows() throws {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContext의 원점은 아래쪽이라, 아래 절반을 칠하면 화면상 아래가 초록이 된다.
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 2, height: 2))
        let image = try #require(context.makeImage())

        let (topR, topG, _) = try Self.pixel(image, x: 0, y: 0)
        var edit = PhotoEdit.identity
        edit.flipVertically()
        let (flippedR, flippedG, _) = try Self.pixel(edit.apply(to: image), x: 0, y: 0)
        #expect((topR, topG) != (flippedR, flippedG))
    }

    @Test("이미 자른 사진을 또 자르면 원본 기준으로 합쳐진다")
    func repeatedCropsCompose() {
        var edit = PhotoEdit.identity
        edit.crop(toSelection: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        // 남은 절반의 오른쪽 절반 → 원본 기준 마지막 4분의 1
        edit.crop(toSelection: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(abs(edit.crop.minX - 0.75) < 0.001)
        #expect(abs(edit.crop.width - 0.25) < 0.001)
    }

    @Test("뒤집힌 화면에서 고른 영역은 되비춰 저장된다")
    func selectionOnAMirroredPreviewIsReflectedBack() throws {
        let image = try Self.makeImage(width: 4, height: 2)
        var edit = PhotoEdit.identity
        edit.flipHorizontally()
        // 뒤집힌 화면의 왼쪽 절반은 원본의 오른쪽 절반(파랑)이다.
        edit.crop(toSelection: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(abs(edit.crop.minX - 0.5) < 0.001)
        let (r, _, b) = try Self.pixel(edit.apply(to: image), x: 0, y: 0)
        #expect(b > 200 && r < 50)
    }

    @Test("사진 밖으로 끌어도 안쪽으로 잘린다")
    func selectionIsClampedToThePicture() {
        let clamped = PhotoEdit.clamp(CGRect(x: -0.4, y: 0.5, width: 1.2, height: 1.2))
        #expect(clamped.minX == 0)
        #expect(clamped.maxX <= 1)
        #expect(clamped.maxY <= 1)
        var edit = PhotoEdit.identity
        // 손이 미끄러진 정도의 선택은 무시한다. 사진이 통째로 사라지면 곤란하다.
        edit.crop(toSelection: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        #expect(edit.isIdentity)
    }

    @Test("편집 결과 크기를 미리 알려준다")
    func reportsResultSize() {
        var edit = PhotoEdit.identity
        edit.crop(toSelection: CGRect(x: 0, y: 0, width: 0.5, height: 0.25))
        let size = edit.resultSize(of: CGSize(width: 4000, height: 3000))
        #expect(size == CGSize(width: 2000, height: 750))
    }

    @Test("되돌리면 편집이 사라진다")
    func resetClearsEverything() {
        var edit = PhotoEdit.identity
        edit.crop(toSelection: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        edit.flipHorizontally()
        edit.flipVertically()
        #expect(!edit.isIdentity)
        edit.reset()
        #expect(edit.isIdentity)
    }

    @Test("드래그가 시작된 자리로 무엇을 할지 정한다")
    func dragModeComesFromWhereItStarted() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)  // 화면상 50...150

        // 선택이 없으면 언제나 새로 그린다.
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 100, y: 100), selection: nil, in: frame) == .create)
        // 모서리
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 50, y: 50), selection: selection, in: frame) == .resize([.left, .top]))
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 150, y: 150), selection: selection, in: frame) == .resize([.right, .bottom]))
        // 변
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 100, y: 50), selection: selection, in: frame) == .resize([.top]))
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 50, y: 100), selection: selection, in: frame) == .resize([.left]))
        // 안쪽은 이동, 바깥은 새로 그리기
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 100, y: 100), selection: selection, in: frame) == .move)
        #expect(PhotoEditorSheet.mode(startingAt: CGPoint(x: 10, y: 10), selection: selection, in: frame) == .create)
    }

    @Test("이동은 크기를 지키고 사진 밖으로 나가지 않는다")
    func movingKeepsTheSizeInsideThePicture() {
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let moved = PhotoEditorSheet.moved(selection, by: CGSize(width: 0.1, height: -0.1))
        #expect(abs(moved.minX - 0.35) < 0.001)
        #expect(abs(moved.minY - 0.15) < 0.001)
        #expect(moved.size == selection.size)
        // 끝까지 밀어도 크기가 줄지 않고 가장자리에서 멈춘다.
        let pushed = PhotoEditorSheet.moved(selection, by: CGSize(width: 5, height: 5))
        #expect(pushed.size == selection.size)
        #expect(abs(pushed.maxX - 1) < 0.001 && abs(pushed.maxY - 1) < 0.001)
    }

    @Test("핸들을 끌면 그 변만 움직인다")
    func resizingMovesOnlyTheHeldEdges() {
        let selection = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let widened = PhotoEditorSheet.resized(selection, by: CGSize(width: 0.1, height: 0), handle: [.right])
        #expect(abs(widened.minX - 0.25) < 0.001)
        #expect(abs(widened.maxX - 0.85) < 0.001)
        #expect(abs(widened.height - 0.5) < 0.001)

        let corner = PhotoEditorSheet.resized(selection, by: CGSize(width: -0.1, height: -0.1), handle: [.left, .top])
        #expect(abs(corner.minX - 0.15) < 0.001)
        #expect(abs(corner.minY - 0.15) < 0.001)
        #expect(abs(corner.maxX - 0.75) < 0.001)

        // 너무 작아지는 조정은 무시한다. 선택이 사라지면 자를 수가 없다.
        let collapsed = PhotoEditorSheet.resized(selection, by: CGSize(width: 0.49, height: 0), handle: [.left])
        #expect(collapsed == selection)
        // 반대편을 넘어가면 접히지 않고 뒤집힌다.
        let flipped = PhotoEditorSheet.resized(selection, by: CGSize(width: 0.8, height: 0), handle: [.left])
        #expect(flipped.width > PhotoEditorSheet.minimumSelection)
    }

    @Test("비율 고정은 픽셀 기준이라 가로가 긴 사진에서도 정사각형이 나온다")
    func squareLockIsSquareInPixels() {
        // 4000×3000 사진에서 1:1은 선택 좌표로는 정사각형이 아니다.
        let image = CGSize(width: 4000, height: 3000)
        let ratio = try! #require(CropAspect.square.selectionRatio(of: image))
        #expect(abs(ratio - 0.75) < 0.001)

        let fitted = PhotoEdit.fitted(CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.9),
                                      toRatio: ratio, drivenByWidth: true, anchorX: 0, anchorY: 0)
        // 픽셀로 환산하면 정사각형이어야 한다.
        let pixelWidth = fitted.width * image.width
        let pixelHeight = fitted.height * image.height
        #expect(abs(pixelWidth - pixelHeight) < 1)
        #expect(fitted.minX == 0.1 && fitted.minY == 0.1)
    }

    @Test("원본 비율 고정은 사진과 같은 모양을 만든다")
    func originalLockMatchesThePicture() {
        let image = CGSize(width: 1600, height: 900)
        let ratio = try! #require(CropAspect.original.selectionRatio(of: image))
        // 원본 비율이면 선택 좌표에서는 정사각형이 된다.
        #expect(abs(ratio - 1) < 0.001)
        #expect(CropAspect.free.selectionRatio(of: image) == nil)
    }

    @Test("고정한 모양이 사진 밖으로 나가면 모양을 지키며 줄어든다")
    func lockedShapeShrinksInsteadOfLeavingThePicture() {
        let ratio = 2.0
        // 오른쪽 끝에 붙은 채 폭을 크게 요구하면, 비율을 지키며 남은 자리에 맞춘다.
        let fitted = PhotoEdit.fitted(CGRect(x: 0.8, y: 0.4, width: 0.6, height: 0.1),
                                      toRatio: ratio, drivenByWidth: true, anchorX: 0, anchorY: 0)
        #expect(fitted.maxX <= 1.0001)
        #expect(fitted.maxY <= 1.0001)
        #expect(abs(fitted.width / fitted.height - ratio) < 0.01)
    }

    @Test("고정한 채 변을 끌면 반대쪽이 제자리에 있는다")
    func lockedResizeHoldsTheOppositeSide() {
        let ratio = 1.0
        let fitted = PhotoEdit.fitted(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.3),
                                      toRatio: ratio, drivenByWidth: true, anchorX: 1, anchorY: 0.5)
        // 오른쪽 변이 고정이므로 maxX가 유지되어야 한다.
        #expect(abs(fitted.maxX - 0.7) < 0.001)
        #expect(abs(fitted.width - fitted.height) < 0.001)
        // 세로는 가운데 기준으로 늘어난다.
        #expect(abs(fitted.midY - 0.35) < 0.001)
    }

    @Test("보이는 사진의 위치를 그림 안의 좌표로 옮긴다")
    func mapsScreenPointsIntoThePicture() {
        // 가로가 남는 창: 사진은 가운데에 그려지고 양옆이 남는다.
        let frame = PhotoEditorSheet.drawnRect(container: CGSize(width: 400, height: 200),
                                               image: CGSize(width: 100, height: 100))
        #expect(frame.width == 200 && frame.height == 200)
        #expect(frame.minX == 100)
        let selection = PhotoEditorSheet.normalized(from: CGPoint(x: 150, y: 50),
                                                    to: CGPoint(x: 250, y: 150), in: frame)
        #expect(abs(selection.minX - 0.25) < 0.001)
        #expect(abs(selection.width - 0.5) < 0.001)
    }
}
#endif
