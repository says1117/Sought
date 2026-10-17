#!/bin/sh
# Integration check without Xcode: (1) typecheck every pure-Swift source of ios/Recall together as ONE
# module (the way the app target compiles them, so duplicate type names surface), (2) compile them with
# every test file against the XCTest stand-in and run every test method.
# Excluded from the typecheck (app glue): files needing ARKit, SwiftUI, CoreBluetooth, NearbyInteraction,
# MultipeerConnectivity or Vision (they only build with the iOS SDK).
# Usage: tools/swift_standin/run_all.sh
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R="$ROOT/ios/Recall"
OUT=$(mktemp -d)
cd "$OUT"
FLAGS=""
echo 'import Foundation' > probe.swift
if ! swiftc -typecheck probe.swift >/dev/null 2>&1; then
  : > empty.modulemap
  printf '{"version":0,"case-sensitive":"false","roots":[{"name":"%s","type":"file","external-contents":"%s"}]}' \
    "$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift/module.modulemap" "$OUT/empty.modulemap" > vfs.yaml
  FLAGS="-Xcc -ivfsoverlay -Xcc $OUT/vfs.yaml -vfsoverlay $OUT/vfs.yaml"
fi
ls "$R"/Sources/*/*.swift | grep -vE 'Sources/(App/|DriveLink/DriveLink\.swift|DriveLink/DriveView|Pose/PoseTracker|Controller/ControllerAdapters|Pose/PoseOverlay|ObstacleGuard/DepthAdapter|SelfTest/SelfTestRunner|SelfTest/SelfTestView|ComeToMe/(NIRanging|CompanionLink|VisionPersonDetector|ComeToMeCoordinator))' > srcs.txt
echo "typecheck: $(wc -l < srcs.txt) source files as one module"
swiftc $FLAGS -swift-version 5 -typecheck $(cat srcs.txt)
echo "typecheck OK"
swiftc $FLAGS -parse-as-library -emit-module -emit-library -module-name XCTest "$ROOT/tools/swift_standin/XCTest.swift" -o libXCTest.dylib
python3 - "$R/Tests" > main.swift <<'PY'
import re, sys, glob
print("import Foundation\nimport XCTest\nsetvbuf(stdout, nil, _IONBF, 0)\nvar total = 0\n")
print("func run(_ name: String, _ body: @escaping () async throws -> Void) {\n  print(name); total += 1\n  let sem = DispatchSemaphore(value: 0)\n  Task { do { try await body() } catch { print(\"  FAIL threw \\(error)\"); __failures += 1 }; sem.signal() }\n  sem.wait()\n}")
for f in sorted(glob.glob(sys.argv[1] + "/*/*.swift")):
    src = open(f).read()
    for cls in re.finditer(r"final class (\w+): XCTestCase \{(.*?)\n\}\n", src, re.S):
        for m in re.finditer(r"func (test\w+)\(\)(?: async)?(?: throws)?", cls.group(2)):
            a = " async" in m.group(0); t = " throws" in m.group(0)
            call = ("try " if t else "") + ("await " if a else "") + f"c.{m.group(1)}()"
            print(f"run(\"{cls.group(1)}.{m.group(1)}\") {{ let c = {cls.group(1)}(); c.setUp(); {call}; c.tearDown() }}")
print("print(\"\\(total) tests, \\(__failures) failures\")\nexit(__failures == 0 ? 0 : 1)")
PY
swiftc $FLAGS -swift-version 5 -I . -L . -lXCTest -Xlinker -rpath -Xlinker . -module-name RecallStandin \
  $(cat srcs.txt) "$R"/Tests/*/*.swift main.swift -o run_tests
./run_tests
