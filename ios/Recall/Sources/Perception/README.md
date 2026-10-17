# Perception (T-011)

Turns a keyframe (image, depth, intrinsics, pose, floor_y) into Memory `Observation`s.

Pure core (SwiftPM target `PerceptionCore`, unit tested): `PerceptionTypes`, `KeyframeGate`, `ProposalMath`
(grid, NMS, union, cap 24), `DepthLift` (median depth over central 30%, reject > 5 m, unproject, height above floor),
`PerceptionPipeline`. Platform adapters (`PerceptionAdapters.swift`: Vision saliency, CoreImage crops/JPEG, ARFrame
extraction) are app-target only and are not run in tests.

Conventions: boxes are normalised, origin top-left. Camera frame is ARKit's (forward = -z); world is y up.
`ARKitKeyframeAdapter` passes the raw depth map; ARKit depth is in the sensor's orientation, so if the captured
image is rotated for display, boxes must be given in the same (unrotated) orientation as the depth map.

## Plugging in YOLO
No model file is committed. Export a nano/small model with `yolo export format=coreml nms=True`, add it to the app
target, wrap it in a function `(CVPixelBuffer) -> [Proposal]` (Vision `VNCoreMLRequest`, any class, flip y to
top-left), and pass it as `YOLOProposalSource(detector:)`. Without it the source returns nothing.

## Plugging in the image encoder
Implement `CropEmbedder` (Crop = `CIImage`) around the MobileCLIP-class Core ML model; return unit vectors in
crop order. The same model backs FindExecutor's camera-level `ImageEmbedder`.

## Not verified
No device, no LiDAR, no real Core ML model, so adapters and real-world accuracy/latency are untested.
