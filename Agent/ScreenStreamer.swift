import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Capture de l'écran principal en JPEG, pour le bureau à distance.
///
/// Exige l'autorisation « Enregistrement de l'écran ». ScreenCaptureKit ne livre
/// une image complète que quand l'écran change : un bureau immobile ne coûte
/// presque rien. Rien n'est écrit sur disque.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Appelé sur une file interne, une image JPEG à la fois.
    var onFrame: ((Data) -> Void)?
    /// Arrêt imposé par le système (autorisation retirée, écran débranché…).
    var onStop: ((Error) -> Void)?

    private let maxWidth: Int
    private let fps: Int
    private let quality: Double
    private let sampleQueue = DispatchQueue(label: "pilote.screen")
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `stream` et `stopped` sont touchés depuis plusieurs files.
    private let lock = NSLock()
    private var stream: SCStream?
    private var stopped = false

    init(maxWidth: Int?, fps: Int?, quality: Double?) {
        self.maxWidth = min(max(maxWidth ?? 1600, 480), 3840)
        self.fps = min(max(fps ?? 12, 1), 30)
        self.quality = min(max(quality ?? 0.55, 0.1), 0.95)
        super.init()
    }

    func start() async throws -> ScreenInfo {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
        else { throw AgentError("Aucun écran à capturer") }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // display.width/height sont en points ; en pixels, un écran Retina en a
        // deux fois plus. On plafonne à maxWidth en gardant les proportions.
        let pixelScale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        let pixelWidth = Double(display.width) * max(pixelScale, 1)
        let pixelHeight = Double(display.height) * max(pixelScale, 1)
        let scale = min(1, Double(maxWidth) / pixelWidth)

        let configuration = SCStreamConfiguration()
        configuration.width = Self.even(pixelWidth * scale)
        configuration.height = Self.even(pixelHeight * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        // stop() a pu être appelé pendant le démarrage : ne pas laisser une
        // capture orpheline tourner.
        let cancelled = lock.withLock { () -> Bool in
            if stopped { return true }
            self.stream = stream
            return false
        }
        if cancelled {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        return ScreenInfo(width: configuration.width, height: configuration.height)
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            stopped = true
            defer { self.stream = nil }
            return self.stream
        }
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(sampleBuffer), let pixels = sampleBuffer.imageBuffer else {
            return
        }
        let image = CIImage(cvPixelBuffer: pixels)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            return
        }
        onFrame?(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            stopped = true
            self.stream = nil
        }
        onStop?(error)
    }

    /// Les images « inactives » répètent la précédente : seules les complètes comptent.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }
}
