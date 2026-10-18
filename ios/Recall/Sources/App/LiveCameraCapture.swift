import ARKit
import CoreImage
import ImageIO

/// Reads the existing ARSession on the main actor; no second camera session or permission prompt.
@MainActor
final class LiveCameraCapture {
    private let session: ARSession
    private let publisher: LiveCameraPublisher
    private let encoder = LiveCameraJPEGEncoder()
    private var timer: Timer?

    init(session: ARSession, config: SyncConfig) {
        self.session = session
        publisher = LiveCameraPublisher(transport: URLSessionLiveCameraTransport(config: config))
    }

    func start() {
        guard timer == nil else { return }
        publisher.start()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        capture()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        publisher.stop()
    }

    private func capture() {
        guard let frame = session.currentFrame else { return }
        let timestamp = frame.timestamp
        let pixels = frame.capturedImage
        let encoder = encoder
        // The worker retains the pixel buffer only. ARFrames (and their depth/pose buffers) stay on this actor.
        publisher.offer(timestamp: timestamp) { encoder.jpeg(pixels) }
    }
}

/// All expensive image work is run by LiveCameraPublisher's single background worker.
private final class LiveCameraJPEGEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        autoreleasepool {
            // ARKit sensor landscape -> upright portrait for the mounted robot phone.
            let image = CIImage(cvPixelBuffer: pixels).oriented(.right)
            let longest = max(image.extent.width, image.extent.height)
            guard longest > 0 else { return nil }
            let scale = min(1, 640 / longest)
            let width = max(1, floor(image.extent.width * scale))
            let height = max(1, floor(image.extent.height * scale))
            let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let scaled = upright.transformed(by: CGAffineTransform(scaleX: width / image.extent.width,
                                                                  y: height / image.extent.height))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let jpeg = context.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: [quality: 0.65]),
                  jpeg.count <= LiveCameraPublisher.maxBytes else { return nil }
            return jpeg
        }
    }
}
