# Live camera snapshots

The robot phone sends a small JPEG from its existing ARKit camera session about once a second while the app is active and a backend is configured. The Companion Live View polls the configured backend while the view is open. This is a refreshed camera feed, with no audio, video recording, or saved frame history.

## Relay

Both routes use the existing API bearer token in the Authorization header:

- `PUT /api/camera/frame`: raw `image/jpeg`; at most 512 KiB and 640 pixels on the longest side. Success is 204. Malformed images are rejected; oversized request bodies are bounded during reading.
- `GET /api/camera/frame`: returns the latest JPEG with `Cache-Control: no-store` and `X-Frame-Age-Ms`. No received image returns 404; an image received more than five seconds ago returns 410.

The backend keeps one frame in process memory. It does not write camera frames to SQLite or the public media directory. Deploy with one worker, as already required by the existing process-local notification broker. Restarting the backend removes the frame. Uploading an invalid image preserves the prior valid image until it expires.

Freshness is time since backend receipt, plus elapsed time on the viewing phone. It is not a synchronized camera exposure timestamp or a guaranteed end-to-end latency. Frames traverse the configured server; it need not be on the home network. Existing HTTP/HTTPS and token deployment settings apply.

## Lifecycle

The publisher shares ARKit's existing session, drops duplicate/old frames, allows only one encode/upload at a time, and uses no durable upload queue. Pausing/backgrounding the robot app stops new publishing. A request already delivered to the server cannot be recalled; it expires normally.

Companion only polls while Live View is visible and active. Leaving or backgrounding the viewer stops polling and prevents late results from repainting it. Missing, invalid, or stale images do not become a thumbnail masquerading as live footage. Sample-mode imagery remains explicitly labeled as sample.

## Verification before device use

1. Run the backend suite, including `backend/tests/test_camera.py`, in the existing backend test environment.
2. Run `swift test` from `ios/Recall`, including LiveCameraPublisher tests.
3. Generate the existing Xcode project and build Recall and Companion for the iOS Simulator. Run Companion unit tests, including live-feed freshness/lifecycle cases.
4. On the phones, configure the same backend/token, start the robot app, and open Companion Live View. Check portrait orientation, replacement by newer frames, visible no-frame/offline behavior, and pause/resume on both phones.

This feature does not control rover motion or require a rover drive for camera verification. Swift/Xcode/device results must be reported separately from source inspection or Python-only checks. No physical camera performance is claimed by the code or synthetic tests.
