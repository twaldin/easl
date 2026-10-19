import Testing
import CanvasCore

struct SurfaceFrameRasterTests {
    @Test func requestedDownscaleKeepsTheSourceAspect() {
        let pixels = SurfaceEvent.Frame.fittedPixels(width: 1600, height: 900, ratio: 0.5, format: .jpeg)
        #expect(pixels.width == 800)
        #expect(pixels.height == 450)

        let fractional = SurfaceEvent.Frame.fittedPixels(width: 801, height: 603, ratio: 0.375, format: .jpeg)
        #expect(Double(fractional.width) <= 801 * 0.375)
        #expect(Double(fractional.height) <= 603 * 0.375)
        #expect(abs(Double(fractional.width) - 801 * 0.375) <= 1)
        #expect(abs(Double(fractional.height) - 603 * 0.375) <= 1)
    }

    @Test func requestedUpscaleFitsWhenBelowTheBudget() {
        let pixels = SurfaceEvent.Frame.fittedPixels(width: 640, height: 360, ratio: 2, format: .jpeg)
        #expect(pixels.width == 1280)
        #expect(pixels.height == 720)
    }

    @Test func exactBudgetImagesKeepTheirDimensions() {
        for (width, height) in [(2000, 2000), (4000, 1000), (1000, 4000)] {
            let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: 1, format: .jpeg)
            #expect(pixels.width == width)
            #expect(pixels.height == height)
            #expect(pixels.width * pixels.height == 4_000_000)
        }
    }

    @Test func fractionalSixteenByNineCapNeverExceedsTheViewerBudget() {
        // Nearest rounding of the continuous cap gives 2667 by 1500, above the viewer's limit.
        for (width, height) in [(3840, 2160), (2160, 3840)] {
            let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: 1, format: .jpeg)
            #expect(pixels.width * pixels.height <= 4_000_000)
            #expect(pixels.width * pixels.height >= 3_990_000)
            let aspectError = abs(Double(pixels.width) * Double(height) - Double(pixels.height) * Double(width))
            #expect(aspectError <= Double(width + height))
        }
    }

    @Test func thinImagesAccountForTheMinimumOnePixelAxis() {
        let wide = SurfaceEvent.Frame.fittedPixels(width: 8_000_000, height: 1, ratio: 1, format: .jpeg)
        #expect(wide.width == 4_000_000)
        #expect(wide.height == 1)
        let tall = SurfaceEvent.Frame.fittedPixels(width: 1, height: 8_000_000, ratio: 1, format: .jpeg)
        #expect(tall.width == 1)
        #expect(tall.height == 4_000_000)

        for (width, height) in [(Int.max, 1), (1, Int.max)] {
            let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: 1, format: .jpeg)
            #expect(pixels.width * pixels.height <= 4_000_000)
            #expect(pixels.width * pixels.height >= 3_999_999)
            #expect(min(pixels.width, pixels.height) == 1)
        }
    }

    @Test func extremeRatiosAndDimensionsAlwaysReturnSafeRasterSizes() {
        let dimensions = [(1, 1), (1, Int.max), (Int.max, 1), (Int.max, Int.max), (4033, 3025)]
        for (width, height) in dimensions {
            for ratio in [Double.leastNonzeroMagnitude, 0.125, 1, 2, Double.greatestFiniteMagnitude] {
                let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: ratio, format: .jpeg)
                #expect(pixels.width >= 1)
                #expect(pixels.height >= 1)
                #expect(pixels.width <= 4_000_000 / pixels.height)
                #expect(Double(pixels.width) <= max(1, Double(width) * ratio))
                #expect(Double(pixels.height) <= max(1, Double(height) * ratio))
            }
        }
        let minimum = SurfaceEvent.Frame.fittedPixels(width: 3840, height: 2160, ratio: Double.leastNonzeroMagnitude, format: .jpeg)
        #expect(minimum.width == 1)
        #expect(minimum.height == 1)
    }

    @Test func videoCaptureRasterFitsTheCodedBudgetBeforeSharpEncoding() {
        let boundary = SurfaceEvent.Frame.fittedPixels(width: 2530, height: 1581, ratio: 1, format: .h264)
        #expect(boundary.width == 2530 && boundary.height == 1580)
        let viewport = SurfaceEvent.Frame.fittedPixels(width: 2560, height: 1600, ratio: 1, format: .h264)
        #expect(viewport.width == 2528 && viewport.height == 1580)
        let jpeg = SurfaceEvent.Frame.fittedPixels(width: 2530, height: 1581, ratio: 1, format: .jpeg)
        #expect(jpeg.width == 2530 && jpeg.height == 1581)
    }

    @Test func videoCaptureKeepsOddPixelsWhenPaddingFitsTheBudget() {
        for (width, height) in [(1801, 1325), (1, 64), (1, 1)] {
            let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: 1, format: .h264)
            #expect(pixels.width == width && pixels.height == height)
        }
    }

    @Test func videoCaptureRasterReservesTheMinimumCodedAxis() {
        for dimension in [8_000_000, Int.max] {
            let wide = SurfaceEvent.Frame.fittedPixels(width: dimension, height: 1, ratio: 1, format: .h264)
            #expect(wide.width == 250_000 && wide.height == 1)
            let tall = SurfaceEvent.Frame.fittedPixels(width: 1, height: dimension, ratio: 1, format: .h264)
            #expect(tall.width == 1 && tall.height == 250_000)
        }
        for ratio in [Double.leastNonzeroMagnitude, 0.125, 1] {
            let minimum = SurfaceEvent.Frame.fittedPixels(width: 1, height: 1, ratio: ratio, format: .h264)
            #expect(minimum.width == 1 && minimum.height == 1)
        }
        for (width, height) in [(1, Int.max), (Int.max, 1), (Int.max, Int.max), (4033, 3025)] {
            for ratio in [Double.leastNonzeroMagnitude, 0.125, 1, 2, Double.greatestFiniteMagnitude] {
                let pixels = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: ratio, format: .h264)
                #expect(pixels.width >= 1 && pixels.height >= 1)
                let codedWidth = max(16, (pixels.width + 1) / 2 * 2)
                let codedHeight = max(16, (pixels.height + 1) / 2 * 2)
                #expect(codedWidth <= 4_000_000 / codedHeight)
            }
        }
    }
}
