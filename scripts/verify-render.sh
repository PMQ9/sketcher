#!/bin/sh
# End-to-end pixel-fidelity check through the REAL export pipeline.
#
# The binary runs headless: main.swift exits into TestRenderMode before
# NSApplication is touched, so this needs no window server, no run loop, and no
# app bundle. It is runnable in CI exactly as-is.
set -eu

cd "$(dirname "$0")/.."

CONFIG=${1:-debug}
BIN=".build/$CONFIG/Sketcher"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c "$CONFIG" >/dev/null

echo "==> generating fixtures"
swift scripts/make-fixture.swift "$WORK" >/dev/null

echo "==> rendering through the export pipeline"
for fixture in shapes transparent offcanvas text; do
	"$BIN" --test-render "$WORK/$fixture.json" "$WORK/$fixture.png" \
		| sed "s/^/    $fixture: /"
done

echo "==> round-tripping the scene codec"
# Deterministic re-encode, and — the assertion everyone skips — an object whose
# `type` this build does not recognize must survive byte-identically rather than
# being silently dropped.
"$BIN" --test-roundtrip "$WORK/shapes.json" "$WORK/shapes-again.json" \
	| sed 's/^/    /'
"$BIN" --test-roundtrip "$WORK/shapes-again.json" "$WORK/shapes-third.json" >/dev/null
if ! cmp -s "$WORK/shapes-again.json" "$WORK/shapes-third.json"; then
	echo "    FAIL codec is not stable across successive round trips"
	exit 1
fi
echo "    ok   codec is byte-stable across round trips"

if ! grep -q "hyperbolicSpline" "$WORK/shapes-again.json"; then
	echo "    FAIL unknown object type was dropped on re-encode"
	exit 1
fi
if ! grep -q "from-the-future" "$WORK/shapes-again.json"; then
	echo "    FAIL unknown object payload was not preserved verbatim"
	exit 1
fi
echo "    ok   unknown object type round-tripped with its payload"

echo "==> asserting pixels"
swift scripts/verify-render.swift "$WORK"
