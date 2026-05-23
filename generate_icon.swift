import AppKit
import CoreGraphics
import Foundation

// Generate a modern macOS app icon (1024x1024) for ClipboardVault.
// Style: squircle (continuous corner) gradient background, glassy clipboard
// with a vault dial — flat, modern, Big Sur era.

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))

canvas.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// macOS Big Sur icon: rounded square with continuous corners.
// Apple icon body sits within ~824/1024 of canvas with corner radius ~185/824.
let inset: CGFloat = 100
let bodyRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius: CGFloat = (size - inset * 2) * 0.2237 // squircle-ish radius

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// --- Background gradient (deep indigo -> violet) ---
ctx.saveGState()
ctx.addPath(roundedPath(bodyRect, radius: cornerRadius))
ctx.clip()

let bgColors = [
    CGColor(red: 0.10, green: 0.13, blue: 0.32, alpha: 1.0),
    CGColor(red: 0.30, green: 0.20, blue: 0.62, alpha: 1.0),
    CGColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1.0)
] as CFArray
let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: bgColors,
                            locations: bgLocations)!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
                       end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
                       options: [])

// Soft highlight bloom upper-left
let bloomColors = [
    CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.25),
    CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
] as CFArray
let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: bloomColors,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom,
                       startCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.25,
                                            y: bodyRect.maxY - bodyRect.height * 0.15),
                       startRadius: 0,
                       endCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.25,
                                          y: bodyRect.maxY - bodyRect.height * 0.15),
                       endRadius: bodyRect.width * 0.55,
                       options: [])

ctx.restoreGState()

// --- Clipboard glass card ---
let clipW = bodyRect.width * 0.62
let clipH = bodyRect.height * 0.74
let clipX = bodyRect.midX - clipW / 2
let clipY = bodyRect.midY - clipH / 2 - bodyRect.height * 0.02
let clipRect = CGRect(x: clipX, y: clipY, width: clipW, height: clipH)
let clipRadius: CGFloat = clipW * 0.10

// Drop shadow under clipboard
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -20),
              blur: 50,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.addPath(roundedPath(clipRect, radius: clipRadius))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
ctx.fillPath()
ctx.restoreGState()

// Glass fill (subtle gradient + border)
ctx.saveGState()
ctx.addPath(roundedPath(clipRect, radius: clipRadius))
ctx.clip()

let glassColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)
] as CFArray
let glass = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: glassColors,
                       locations: [0, 1])!
ctx.drawLinearGradient(glass,
                       start: CGPoint(x: clipRect.minX, y: clipRect.maxY),
                       end: CGPoint(x: clipRect.minX, y: clipRect.minY),
                       options: [])

// Inner subtle horizontal lines (clipboard text rows)
let lineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
let dimLineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.30)
let lineHeight: CGFloat = clipH * 0.045
let lineRadius: CGFloat = lineHeight / 2
let leftPad: CGFloat = clipW * 0.12
let topStart: CGFloat = clipRect.maxY - clipH * 0.22

// Top lines
for i in 0..<3 {
    let y = topStart - CGFloat(i) * (lineHeight + clipH * 0.04)
    let w = clipW * (i == 0 ? 0.55 : (i == 1 ? 0.70 : 0.40))
    let r = CGRect(x: clipRect.minX + leftPad, y: y - lineHeight, width: w, height: lineHeight)
    ctx.addPath(roundedPath(r, radius: lineRadius))
    ctx.setFillColor(i == 1 ? lineColor : dimLineColor)
    ctx.fillPath()
}

// Bottom lines
let bottomStart = clipRect.minY + clipH * 0.16
for i in 0..<2 {
    let y = bottomStart + CGFloat(i) * (lineHeight + clipH * 0.04)
    let w = clipW * (i == 0 ? 0.60 : 0.45)
    let r = CGRect(x: clipRect.minX + leftPad, y: y, width: w, height: lineHeight)
    ctx.addPath(roundedPath(r, radius: lineRadius))
    ctx.setFillColor(i == 0 ? lineColor : dimLineColor)
    ctx.fillPath()
}

ctx.restoreGState()

// Border stroke on clipboard
ctx.saveGState()
ctx.addPath(roundedPath(clipRect, radius: clipRadius))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// --- Clip (top metal clip) ---
let clipBarW = clipW * 0.36
let clipBarH = clipH * 0.10
let clipBarRect = CGRect(x: clipRect.midX - clipBarW / 2,
                         y: clipRect.maxY - clipBarH * 0.45,
                         width: clipBarW,
                         height: clipBarH)
let clipBarRadius: CGFloat = clipBarH * 0.35

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6),
              blur: 16,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.addPath(roundedPath(clipBarRect, radius: clipBarRadius))
ctx.clip()
let metalColors = [
    CGColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1.0),
    CGColor(red: 0.70, green: 0.74, blue: 0.82, alpha: 1.0)
] as CFArray
let metal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: metalColors,
                       locations: [0, 1])!
ctx.drawLinearGradient(metal,
                       start: CGPoint(x: clipBarRect.minX, y: clipBarRect.maxY),
                       end: CGPoint(x: clipBarRect.minX, y: clipBarRect.minY),
                       options: [])
ctx.restoreGState()

// --- Lock/Vault overlay (centered, modern glyph) ---
// Soft glow disc behind the lock
let glowRadius = clipW * 0.22
let glowCenter = CGPoint(x: clipRect.midX, y: clipRect.midY - clipH * 0.02)
let glowColors = [
    CGColor(red: 0.40, green: 0.85, blue: 1.0, alpha: 0.55),
    CGColor(red: 0.40, green: 0.85, blue: 1.0, alpha: 0.0)
] as CFArray
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: glowColors,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: glowCenter,
                       startRadius: 0,
                       endCenter: glowCenter,
                       endRadius: glowRadius * 1.6,
                       options: [])

// Lock body
let lockBodyW = clipW * 0.28
let lockBodyH = clipH * 0.22
let lockBodyRect = CGRect(x: glowCenter.x - lockBodyW / 2,
                          y: glowCenter.y - lockBodyH / 2,
                          width: lockBodyW,
                          height: lockBodyH)
let lockBodyRadius = lockBodyW * 0.18

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8),
              blur: 22,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.addPath(roundedPath(lockBodyRect, radius: lockBodyRadius))
ctx.clip()
let lockColors = [
    CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    CGColor(red: 0.85, green: 0.93, blue: 1.0, alpha: 1.0)
] as CFArray
let lockGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: lockColors,
                              locations: [0, 1])!
ctx.drawLinearGradient(lockGradient,
                       start: CGPoint(x: lockBodyRect.minX, y: lockBodyRect.maxY),
                       end: CGPoint(x: lockBodyRect.minX, y: lockBodyRect.minY),
                       options: [])
ctx.restoreGState()

// Lock shackle (the U-shape above)
let shackleW = lockBodyW * 0.62
let shackleH = lockBodyH * 0.82
let shackleX = glowCenter.x - shackleW / 2
let shackleY = lockBodyRect.maxY - shackleH * 0.15
let shackleThickness: CGFloat = lockBodyW * 0.11

let shacklePath = CGMutablePath()
let shackleRect = CGRect(x: shackleX, y: shackleY, width: shackleW, height: shackleH)
// Build a "U" by stroking an arc + verticals (open at bottom)
shacklePath.move(to: CGPoint(x: shackleRect.minX, y: shackleRect.minY))
shacklePath.addLine(to: CGPoint(x: shackleRect.minX, y: shackleRect.midY))
shacklePath.addArc(center: CGPoint(x: shackleRect.midX, y: shackleRect.midY),
                   radius: shackleW / 2,
                   startAngle: .pi,
                   endAngle: 0,
                   clockwise: true)
shacklePath.addLine(to: CGPoint(x: shackleRect.maxX, y: shackleRect.minY))

ctx.saveGState()
ctx.setLineWidth(shackleThickness)
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0))
ctx.addPath(shacklePath)
ctx.strokePath()
ctx.restoreGState()

// Keyhole dot + slot
let keyholeR = lockBodyW * 0.075
let keyholeCenter = CGPoint(x: lockBodyRect.midX, y: lockBodyRect.midY + lockBodyH * 0.06)
ctx.saveGState()
ctx.setFillColor(CGColor(red: 0.20, green: 0.30, blue: 0.65, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: keyholeCenter.x - keyholeR,
                           y: keyholeCenter.y - keyholeR,
                           width: keyholeR * 2,
                           height: keyholeR * 2))
let slotW = keyholeR * 0.7
let slotH = lockBodyH * 0.18
ctx.addPath(roundedPath(CGRect(x: keyholeCenter.x - slotW / 2,
                               y: keyholeCenter.y - slotH,
                               width: slotW,
                               height: slotH),
                        radius: slotW / 2))
ctx.fillPath()
ctx.restoreGState()

// --- Top edge highlight on the whole icon (glassy sheen) ---
ctx.saveGState()
ctx.addPath(roundedPath(bodyRect, radius: cornerRadius))
ctx.clip()
let sheenColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
] as CFArray
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: sheenColors,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
                       end: CGPoint(x: bodyRect.minX, y: bodyRect.midY),
                       options: [])
ctx.restoreGState()

canvas.unlockFocus()

// Save PNG
guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}

let outURL = URL(fileURLWithPath: "app_icon.png")
try png.write(to: outURL)
print("Wrote \(outURL.path)")
