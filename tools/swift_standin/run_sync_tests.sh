#!/bin/sh
# Compile Sources/Sync + Tests/SyncTests against the XCTest stand-in and run every test method.
# Usage: tools/swift_standin/run_sync_tests.sh   (needs swiftc; no Xcode required)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
cd "$OUT"
# Some Command Line Tools installs ship two modulemaps defining SwiftBridging, which breaks every
# swiftc run. If a trivial compile fails, hide the duplicate with a VFS overlay (no system files touched).
FLAGS=""
echo 'import Foundation' > probe.swift
if ! swiftc -typecheck probe.swift >/dev/null 2>&1; then
  : > empty.modulemap
  printf '{"version":0,"case-sensitive":"false","roots":[{"name":"%s","type":"file","external-contents":"%s"}]}' \
    "$(xcrun --show-sdk-path >/dev/null 2>&1; dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift/module.modulemap" "$OUT/empty.modulemap" > vfs.yaml
  FLAGS="-Xcc -ivfsoverlay -Xcc $OUT/vfs.yaml -vfsoverlay $OUT/vfs.yaml"
fi
swiftc $FLAGS -parse-as-library -emit-module -emit-library -module-name XCTest "$ROOT/tools/swift_standin/XCTest.swift" -o libXCTest.dylib
python3 - "$ROOT/ios/Recall/Tests/SyncTests" > main.swift <<'PY'
import re, sys, glob
src = open(glob.glob(sys.argv[1] + "/*Tests.swift")[0]).read()
print("import Foundation\nimport XCTest\nsetvbuf(stdout, nil, _IONBF, 0)\nvar total = 0\n")
print("func run(_ name: String, _ body: @escaping () async throws -> Void) {\n  print(name); total += 1\n  let sem = DispatchSemaphore(value: 0)\n  Task { do { try await body() } catch { print(\"  FAIL threw \\(error)\"); __failures += 1 }; sem.signal() }\n  sem.wait()\n}")
for cls in re.finditer(r"final class (\w+): XCTestCase \{(.*?)\n\}\n", src, re.S):
    for m in re.finditer(r"func (test\w+)\(\)(?: async)?(?: throws)?", cls.group(2)):
        a = " async" in m.group(0); t = " throws" in m.group(0)
        call = ("try " if t else "") + ("await " if a else "") + f"c.{m.group(1)}()"
        print(f"run(\"{cls.group(1)}.{m.group(1)}\") {{ let c = {cls.group(1)}(); c.setUp(); {call}; c.tearDown() }}")
print("print(\"\\(total) tests, \\(__failures) failures\")\nexit(__failures == 0 ? 0 : 1)")
PY
swiftc $FLAGS -I . -L . -lXCTest -Xlinker -rpath -Xlinker . -module-name SyncStandin \
  "$ROOT"/ios/Recall/Sources/Sync/*.swift "$ROOT"/ios/Recall/Tests/SyncTests/SyncTests.swift main.swift -o run_tests
./run_tests
