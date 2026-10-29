#!/usr/bin/env swift
// Renders the Quartermaster app icon into Skillscout/AppIcon.icon, an Icon Composer bundle:
// a ledger with one tab per agent and a check mark, for skills checked before agents follow them.
// Layers are flat 1024pt PNGs: macOS adds the Liquid Glass, and Xcode derives the
// icons for older macOS releases from the same bundle.
// Usage: swift scripts/render-icon.swift

import AppKit
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
// The ledger's cover, with a spine on the left and a page block on the right.
let ledger = CGRect(x: 184, y: 172, width: 560, height: 680)
let ledgerRadius: CGFloat = 70
let spineWidth: CGFloat = 112
// Three agent tabs behind the ledger, sticking out of its right edge.
let tabSize = CGSize(width: 176, height: 118)
let tabRadius: CGFloat = 40
let tabOrigins = [CGPoint(x: 668, y: 236), CGPoint(x: 668, y: 380), CGPoint(x: 668, y: 524)]
// Ruled entries on the page, the last one shorter.
let ruleInset: CGFloat = 70
let rules: [(y: CGFloat, width: CGFloat)] = [(318, 300), (412, 300), (506, 196)]
let ruleHeight: CGFloat = 30
// The check mark sits on the page's lower half, clear of the entries and the tabs.
let checkPoints = [CGPoint(x: 396, y: 688), CGPoint(x: 496, y: 788), CGPoint(x: 694, y: 590)]
let checkWidth: CGFloat = 104

let backgroundTop: UInt32 = 0x2B3A27
let backgroundBottom: UInt32 = 0x4D6340
let darkBackgroundTop: UInt32 = 0x121A11
let darkBackgroundBottom: UInt32 = 0x2A3A24
let pageColor: UInt32 = 0xF4EBD3
let spineColor: UInt32 = 0x9A6B3A
let ruleColor: UInt32 = 0x5B6B4A
let checkColor: UInt32 = 0xFFC247
let codexColor: UInt32 = 0x34C7C0
let claudeColor: UInt32 = 0xFF9A3D
let cursorColor: UInt32 = 0x8C88FF

func rgb(_ hex: UInt32) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
  (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
}

func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  let color = rgb(hex)
  return CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
}

func iconColor(_ hex: UInt32) -> String {
  let color = rgb(hex)
  return "\"extended-srgb:" + [color.red, color.green, color.blue, 1].map { String(format: "%.5f", $0) }.joined(separator: ",") + "\""
}

func layer(_ draw: (CGContext) -> Void) -> CGImage {
  let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.translateBy(x: 0, y: canvas)
  context.scaleBy(x: 1, y: -1)
  draw(context)
  return context.makeImage()!
}

func tab(_ index: Int, color: UInt32) -> CGImage {
  layer { context in
    context.setFillColor(cgColor(color))
    context.addPath(CGPath(roundedRect: CGRect(origin: tabOrigins[index], size: tabSize), cornerWidth: tabRadius, cornerHeight: tabRadius, transform: nil))
    context.fillPath()
  }
}

let page = layer { context in
  context.setFillColor(cgColor(pageColor))
  context.addPath(CGPath(roundedRect: ledger, cornerWidth: ledgerRadius, cornerHeight: ledgerRadius, transform: nil))
  context.fillPath()
}

// The spine follows the ledger's left corners and ends square against the page.
let spine = layer { context in
  context.setFillColor(cgColor(spineColor))
  context.addPath(CGPath(roundedRect: ledger, cornerWidth: ledgerRadius, cornerHeight: ledgerRadius, transform: nil))
  context.clip()
  context.fill(CGRect(x: ledger.minX, y: ledger.minY, width: spineWidth, height: ledger.height))
}

let ruled = layer { context in
  context.setFillColor(cgColor(ruleColor))
  for rule in rules {
    let rect = CGRect(x: ledger.minX + spineWidth + ruleInset, y: rule.y, width: rule.width, height: ruleHeight)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: ruleHeight / 2, cornerHeight: ruleHeight / 2, transform: nil))
  }
  context.fillPath()
}

let check = layer { context in
  context.setStrokeColor(cgColor(checkColor))
  context.setLineWidth(checkWidth)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  context.addLines(between: checkPoints)
  context.strokePath()
}

let manifest = """
{
  "fill-specializations" : [
    { "value" : { "linear-gradient" : [\(iconColor(backgroundTop)), \(iconColor(backgroundBottom))] } },
    { "appearance" : "dark", "value" : { "linear-gradient" : [\(iconColor(darkBackgroundTop)), \(iconColor(darkBackgroundBottom))] } }
  ],
  "groups" : [
    {
      "name" : "Check",
      "layers" : [
        { "name" : "Check", "image-name" : "check.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.6 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.15 }
    },
    {
      "name" : "Ledger",
      "layers" : [
        { "name" : "Rules", "image-name" : "rules.png", "glass" : true, "opacity" : 0.7 },
        { "name" : "Spine", "image-name" : "spine.png", "glass" : true },
        { "name" : "Page", "image-name" : "page.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.1 }
    },
    {
      "name" : "Tabs",
      "layers" : [
        { "name" : "Cursor", "image-name" : "cursor.png", "glass" : true },
        { "name" : "Claude", "image-name" : "claude.png", "glass" : true },
        { "name" : "Codex", "image-name" : "codex.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "specular" : true,
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : {
    "squares" : ["macOS"]
  }
}

"""

func write(_ image: CGImage, to url: URL) {
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("Skillscout/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: bundle)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
write(tab(0, color: codexColor), to: assets.appendingPathComponent("codex.png"))
write(tab(1, color: claudeColor), to: assets.appendingPathComponent("claude.png"))
write(tab(2, color: cursorColor), to: assets.appendingPathComponent("cursor.png"))
write(page, to: assets.appendingPathComponent("page.png"))
write(spine, to: assets.appendingPathComponent("spine.png"))
write(ruled, to: assets.appendingPathComponent("rules.png"))
write(check, to: assets.appendingPathComponent("check.png"))
try! manifest.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Wrote \(bundle.path)")
