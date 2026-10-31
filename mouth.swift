// Prints "seconds,mouth-open" for every frame of a webcam video, using Apple's face landmarks.
// Mouth open is the inner lips' height as a fraction of the face, or -1 when no face is found.
// Usage: swift mouth.swift <webcam.mp4> [max seconds]   (used by avsync.py)
import AVFoundation
import Vision

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let track = asset.tracks(withMediaType: .video).first else { exit(1) }
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
reader.add(output)
let limit = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? .infinity : .infinity
reader.startReading()
while let sb = output.copyNextSampleBuffer() {
    if sb.presentationTimeStamp.seconds > limit { break }
    guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
    let req = VNDetectFaceLandmarksRequest()
    try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
    var open = -1.0
    if let face = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
       let lips = face.landmarks?.innerLips, lips.pointCount > 0 {
        let ys = lips.normalizedPoints.map { Double($0.y) }
        open = ys.max()! - ys.min()!
    }
    print(String(format: "%.4f,%.5f", sb.presentationTimeStamp.seconds, open))
}
