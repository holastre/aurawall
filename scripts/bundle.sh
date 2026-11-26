#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/build/AuraWall.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLIST_SRC="${ROOT_DIR}/Resources/Info.plist"
ICON_SRC="${ROOT_DIR}/Resources/AppIcon.icns"

generate_app_icon() {
    local out_icns="$1"
    local work_dir="${ROOT_DIR}/.build/aurawall_icon_tmp_$$"
    local base_png="${work_dir}/AppIcon-1024.png"
    local iconset_dir="${work_dir}/AppIcon.iconset"
    local swift_gen="${work_dir}/gen_icon.swift"

    trap 'rm -rf "${work_dir}"' RETURN
    mkdir -p "${iconset_dir}"

    cat > "${swift_gen}" << 'EOF'
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Failed to allocate bitmap")
}

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let rect = CGRect(x: 48, y: 48, width: size - 96, height: size - 96)
let radius: CGFloat = 210
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

cg.saveGState()
cg.addPath(path)
cg.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()

// Deep obsidian base gradient
let bgColors = [
    CGColor(red: 0.035, green: 0.035, blue: 0.055, alpha: 1.0),
    CGColor(red: 0.075, green: 0.085, blue: 0.145, alpha: 1.0),
    CGColor(red: 0.045, green: 0.045, blue: 0.070, alpha: 1.0)
] as CFArray
let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.52, 1.0])!
cg.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: rect.minX, y: rect.minY),
    end: CGPoint(x: rect.maxX, y: rect.maxY),
    options: []
)

// Aurora cyan-teal radial glow
let cyanGlow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.18, green: 0.82, blue: 0.96, alpha: 0.85),
        CGColor(red: 0.12, green: 0.56, blue: 0.88, alpha: 0.35),
        CGColor(red: 0.10, green: 0.35, blue: 0.72, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.45, 1.0]
)!
cg.drawRadialGradient(
    cyanGlow,
    startCenter: CGPoint(x: 370, y: 650),
    startRadius: 20,
    endCenter: CGPoint(x: 420, y: 580),
    endRadius: 440,
    options: []
)

// Aurora violet-magenta radial glow
let violetGlow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.58, green: 0.36, blue: 0.98, alpha: 0.82),
        CGColor(red: 0.42, green: 0.22, blue: 0.82, alpha: 0.32),
        CGColor(red: 0.24, green: 0.14, blue: 0.52, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 0.48, 1.0]
)!
cg.drawRadialGradient(
    violetGlow,
    startCenter: CGPoint(x: 680, y: 400),
    startRadius: 20,
    endCenter: CGPoint(x: 620, y: 440),
    endRadius: 430,
    options: []
)

// Stylized translucent glass ring / horizon wave
cg.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.32))
cg.setLineWidth(14)
let innerRing = CGRect(x: 292, y: 292, width: 440, height: 440)
cg.strokeEllipse(in: innerRing)

// Subtle play/prism glyph inside ring
let triangle = CGMutablePath()
triangle.move(to: CGPoint(x: 454, y: 392))
triangle.addLine(to: CGPoint(x: 624, y: 512))
triangle.addLine(to: CGPoint(x: 454, y: 632))
triangle.closeSubpath()
cg.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
cg.addPath(triangle)
cg.fillPath()

cg.restoreGState()

// Crisp outer glass border
cg.addPath(path)
cg.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24))
cg.setLineWidth(6)
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}
try pngData.write(to: URL(fileURLWithPath: outPath))
EOF

    swift "${swift_gen}" "${base_png}"

    /usr/bin/sips -z 16 16     "${base_png}" --out "${iconset_dir}/icon_16x16.png" >/dev/null
    /usr/bin/sips -z 32 32     "${base_png}" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null
    /usr/bin/sips -z 32 32     "${base_png}" --out "${iconset_dir}/icon_32x32.png" >/dev/null
    /usr/bin/sips -z 64 64     "${base_png}" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null
    /usr/bin/sips -z 128 128   "${base_png}" --out "${iconset_dir}/icon_128x128.png" >/dev/null
    /usr/bin/sips -z 256 256   "${base_png}" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null
    /usr/bin/sips -z 256 256   "${base_png}" --out "${iconset_dir}/icon_256x256.png" >/dev/null
    /usr/bin/sips -z 512 512   "${base_png}" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null
    /usr/bin/sips -z 512 512   "${base_png}" --out "${iconset_dir}/icon_512x512.png" >/dev/null
    /usr/bin/sips -z 1024 1024 "${base_png}" --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null

    mkdir -p "$(dirname "${out_icns}")"
    /usr/bin/iconutil -c icns "${iconset_dir}" -o "${out_icns}"
}

echo "[bundle] Building AuraWall (release, arm64)..."
cd "${ROOT_DIR}"
swift build -c release --arch arm64 --disable-sandbox --product AuraWall

BIN_DIR="$(swift build -c release --arch arm64 --disable-sandbox --show-bin-path)"
BIN_PATH="${BIN_DIR}/AuraWall"
if [ ! -x "${BIN_PATH}" ]; then
    echo "ERROR: Built executable not found at ${BIN_PATH}" >&2
    exit 1
fi

if [ ! -f "${PLIST_SRC}" ]; then
    echo "ERROR: Info.plist not found at ${PLIST_SRC}" >&2
    exit 1
fi

if [ ! -f "${ICON_SRC}" ]; then
    echo "[bundle] Generating Resources/AppIcon.icns..."
    generate_app_icon "${ICON_SRC}"
fi

echo "[bundle] Assembling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/AuraWall"
chmod +x "${MACOS_DIR}/AuraWall"

cp "${PLIST_SRC}" "${CONTENTS_DIR}/Info.plist"
cp "${ICON_SRC}" "${RESOURCES_DIR}/AppIcon.icns"

# Copy any SwiftPM resource bundles if present
for bundle_path in "${BIN_DIR}"/*.bundle; do
    if [ -d "${bundle_path}" ]; then
        cp -R "${bundle_path}" "${RESOURCES_DIR}/"
    fi
done

printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

xattr -cr "${APP_DIR}" 2>/dev/null || true

echo "[bundle] Code signing (ad-hoc)..."
/usr/bin/codesign --force --deep --sign - "${APP_DIR}"

echo "[bundle] Verifying Info.plist, Mach-O architecture, and signature..."
/usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist"
ARCHS="$(/usr/bin/lipo -archs "${MACOS_DIR}/AuraWall")"
echo "[bundle] lipo -archs: ${ARCHS}"
case " ${ARCHS} " in
    *" arm64 "*) ;;
    *)
        echo "ERROR: Expected arm64 architecture, got: ${ARCHS}" >&2
        exit 1
        ;;
esac

FILE_INFO="$(/usr/bin/file -b "${MACOS_DIR}/AuraWall")"
echo "[bundle] file: ${FILE_INFO}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "[bundle] Success: ${APP_DIR}"
