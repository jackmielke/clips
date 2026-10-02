import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
  NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1).cgColor, NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// soft red glow
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
  NSColor(red: 1, green: 0.27, blue: 0.27, alpha: 0.45).cgColor, NSColor(red: 1, green: 0.27, blue: 0.27, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 360, options: [])
// ring
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor); ctx.setLineWidth(30)
ctx.strokeEllipse(in: CGRect(x: 512 - 215, y: 512 - 215, width: 430, height: 430))
// dot
let dot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
  NSColor(red: 1, green: 0.42, blue: 0.40, alpha: 1).cgColor, NSColor(red: 0.93, green: 0.18, blue: 0.20, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.addEllipse(in: CGRect(x: 512 - 150, y: 512 - 150, width: 300, height: 300)); ctx.clip()
ctx.drawLinearGradient(dot, start: CGPoint(x: 512, y: 662), end: CGPoint(x: 512, y: 362), options: [])
ctx.restoreGState()
// top sheen
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(3)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil)); ctx.strokePath()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
