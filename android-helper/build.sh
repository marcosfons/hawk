#!/bin/sh
#
# build.sh - builds hawk-helper.dex from src/ with javac and the SDK's d8.
# The dex is checked in, so building Hawk never needs the Android SDK; run this
# only after changing the Java sources, then commit the new dex.
#
#   ANDROID_HOME (default ~/Library/Android/sdk), PLATFORM (android-36),
#   BUILD_TOOLS (37.0.0)

set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAR="$SDK/platforms/${PLATFORM:-android-36}/android.jar"
D8="$SDK/build-tools/${BUILD_TOOLS:-37.0.0}/d8"
[ -f "$JAR" ] || { echo "build.sh: no $JAR" >&2; exit 1; }
[ -x "$D8" ] || { echo "build.sh: no $D8" >&2; exit 1; }

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
javac --release 11 -Xlint:-options -cp "$JAR" -d "$OUT/classes" src/hawk/*.java 2>&1 | grep -v '^Note:' || true
[ -f "$OUT/classes/hawk/Helper.class" ] || { echo "build.sh: javac failed" >&2; exit 1; }
"$D8" --release --min-api 31 --lib "$JAR" --output "$OUT" "$OUT"/classes/hawk/*.class
cp "$OUT/classes.dex" hawk-helper.dex
echo "hawk-helper.dex: $(wc -c <hawk-helper.dex | tr -d ' ') bytes, sha256 $(shasum -a 256 hawk-helper.dex | cut -c1-16)"
