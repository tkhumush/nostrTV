// Render the phone starter's wordmark using the same colors and rounded type as the app.
// Run from the repository root: swift assets/generate-ios-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = CGSize(width: 1024, height: 1024)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(srgbRed: 0.063, green: 0.098, blue: 0.118, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
let descriptor = NSFont.systemFont(ofSize: 250, weight: .bold).fontDescriptor.withDesign(.rounded)!
let font = NSFont(descriptor: descriptor, size: 250)!
let wordmark = NSAttributedString(string: "cove", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -12])
let bounds = wordmark.size()
let origin = CGPoint(x: (1024 - bounds.width - 48) / 2, y: (1024 - bounds.height) / 2)
wordmark.draw(at: origin)
NSColor(srgbRed: 0.706, green: 0.875, blue: 0.804, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: origin.x + bounds.width + 14, y: origin.y + font.descender.magnitude + 10,
                         width: 36, height: 36)).fill()
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "CoveIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Could not save the icon")
