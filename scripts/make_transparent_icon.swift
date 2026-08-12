import AppKit
import Foundation

if CommandLine.arguments.count != 3 {
    fputs("Usage: make_transparent_icon.swift input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let sourceImage = NSImage(contentsOf: inputURL),
      let sourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not read input image.\n", stderr)
    exit(1)
}

let width = sourceCG.width
let height = sourceCG.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
let count = bytesPerRow * height
var pixels = [UInt8](repeating: 0, count: count)

guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create image context.\n", stderr)
    exit(1)
}

context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

func pixelIndex(_ x: Int, _ y: Int) -> Int {
    (y * width + x) * bytesPerPixel
}

func isBackground(_ x: Int, _ y: Int) -> Bool {
    let i = pixelIndex(x, y)
    let r = Int(pixels[i])
    let g = Int(pixels[i + 1])
    let b = Int(pixels[i + 2])

    // Only remove very light, low-saturation pixels connected to the outside.
    // This keeps the white app title inside the black icon intact.
    let bright = r >= 235 && g >= 235 && b >= 235
    let lowSaturation = max(r, g, b) - min(r, g, b) <= 28
    return bright && lowSaturation
}

var visited = [Bool](repeating: false, count: width * height)
var queue: [(Int, Int)] = []
queue.reserveCapacity(width * 2 + height * 2)

func enqueue(_ x: Int, _ y: Int) {
    guard x >= 0, y >= 0, x < width, y < height else { return }
    let index = y * width + x
    guard !visited[index], isBackground(x, y) else { return }
    visited[index] = true
    queue.append((x, y))
}

for x in 0..<width {
    enqueue(x, 0)
    enqueue(x, height - 1)
}

for y in 0..<height {
    enqueue(0, y)
    enqueue(width - 1, y)
}

var cursor = 0
while cursor < queue.count {
    let (x, y) = queue[cursor]
    cursor += 1
    enqueue(x + 1, y)
    enqueue(x - 1, y)
    enqueue(x, y + 1)
    enqueue(x, y - 1)
}

for y in 0..<height {
    for x in 0..<width where visited[y * width + x] {
        let i = pixelIndex(x, y)
        pixels[i] = 255
        pixels[i + 1] = 255
        pixels[i + 2] = 255
        pixels[i + 3] = 0
    }
}

guard let outputContext = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
), let outputCG = outputContext.makeImage() else {
    fputs("Could not create output image.\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: outputCG)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG.\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
