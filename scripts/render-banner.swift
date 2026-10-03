#!/usr/bin/env swift
// Renders the README banner, docs/banner.png, at 2x.
// The icon comes from Skillscout/AppIcon.icon through Icon Composer's ictool, so it has the
// real Liquid Glass. The window is docs/screenshot-dark.png, made by scripts/screenshot.sh.
// Usage: swift scripts/render-banner.swift

import AppKit
import SwiftUI

let name = "Skillscout Mod"
let tagline = "Your agent skills in one place,\nchecked before your agents follow them."
let chips = ["10 coding agents", "Skill Library", "Skillsets"]
let size = CGSize(width: 1280, height: 560)

let backgroundTop = Color(hex: 0x2A2F66)
let backgroundBottom = Color(hex: 0x0E1024)
let purple = Color(hex: 0x8C88FF)
let teal = Color(hex: 0x34C7C0)
let orange = Color(hex: 0xFF9A3D)
let muted = Color.white.opacity(0.72)

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSource = root.appending(path: "Skillscout/AppIcon.icon")
let screenshot = root.appending(path: "docs/screenshot-dark.png")
let output = root.appending(path: "docs/banner.png")

extension Color {
  init(hex: UInt32) {
    self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}

func run(_ tool: String, _ arguments: [String]) -> String {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(filePath: tool)
  process.arguments = arguments
  process.standardOutput = pipe
  try! process.run()
  process.waitUntilExit()
  return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderIcon() -> NSImage {
  let developer = run("/usr/bin/xcode-select", ["-p"])
  let ictool = URL(filePath: developer).deletingLastPathComponent()
    .appending(path: "Applications/Icon Composer.app/Contents/Executables/ictool").path
  let file = FileManager.default.temporaryDirectory.appending(path: "\(name)-banner-icon.png")
  _ = run(ictool, [
    iconSource.path, "--export-image", "--output-file", file.path, "--platform", "macOS",
    "--rendition", "Default", "--width", "512", "--height", "512", "--scale", "2",
  ])
  return NSImage(contentsOf: file)!
}

/// A faint dot grid that fades out toward the window.
struct Dots: View {
  var body: some View {
    Canvas { context, canvasSize in
      for x in stride(from: CGFloat(24), to: canvasSize.width, by: 28) {
        for y in stride(from: CGFloat(24), to: canvasSize.height, by: 28) {
          let fade = max(0, 1 - x / 900)
          context.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.09 * fade)))
        }
      }
    }
  }
}

struct Banner: View {
  let icon: NSImage
  let window: NSImage

  var body: some View {
    ZStack(alignment: .topLeading) {
      LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(colors: [purple.opacity(0.4), purple.opacity(0)], center: UnitPoint(x: 0.14, y: 0.3), startRadius: 0, endRadius: 420)
      RadialGradient(colors: [teal.opacity(0.28), teal.opacity(0)], center: UnitPoint(x: 0.62, y: 1.05), startRadius: 0, endRadius: 460)
      RadialGradient(colors: [orange.opacity(0.18), orange.opacity(0)], center: UnitPoint(x: 1, y: 0), startRadius: 0, endRadius: 380)
      Dots()

      // The screenshot is 2x with a 48pt shadow margin. It runs off the right and bottom edges.
      Image(nsImage: window)
        .resizable()
        .interpolation(.high)
        .frame(width: CGFloat(window.representations[0].pixelsWide) / 2 * 0.78, height: CGFloat(window.representations[0].pixelsHigh) / 2 * 0.78)
        .offset(x: 612 - 48 * 0.78, y: 92 - 48 * 0.78)

      VStack(alignment: .leading, spacing: 0) {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: 132, height: 132)
          .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        Text(name)
          .font(.system(size: 76, weight: .bold))
          .tracking(-1.8)
          .foregroundStyle(.white)
          .padding(.top, 26)
        Text(tagline)
          .font(.system(size: 27, weight: .regular))
          .lineSpacing(4)
          .foregroundStyle(muted)
          .padding(.top, 8)
        HStack(spacing: 10) {
          ForEach(chips, id: \.self) { chip in
            Text(chip)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white.opacity(0.9))
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(.white.opacity(0.1), in: .capsule)
              .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
          }
        }
        .padding(.top, 26)
      }
      .offset(x: 72, y: 84)
    }
    .frame(width: size.width, height: size.height)
    .clipShape(.rect(cornerRadius: 28))
  }
}

MainActor.assumeIsolated {
  let renderer = ImageRenderer(content: Banner(icon: renderIcon(), window: NSImage(contentsOf: screenshot)!))
  renderer.scale = 2
  // ImageRenderer produces 16 bits per channel. Redraw at 8 bits for a small PNG.
  let image = renderer.cgImage!
  let context = CGContext(
    data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: output)
  print("Wrote \(output.path)")
}
