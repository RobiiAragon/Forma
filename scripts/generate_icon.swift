import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.055, green: 0.06, blue: 0.067, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
func polygon(_ points: [CGPoint], _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
    context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    context.beginPath(); context.move(to: points[0])
    points.dropFirst().forEach { context.addLine(to: $0) }
    context.closePath(); context.fillPath()
}
let top=CGPoint(x:512,y:790), left=CGPoint(x:282,y:657), right=CGPoint(x:742,y:657)
let center=CGPoint(x:512,y:524), bottom=CGPoint(x:512,y:250)
polygon([top,right,center,left], 1, 0.48, 0.28)
polygon([left,center,bottom,CGPoint(x:282,y:383)], 0.85, 0.23, 0.11)
polygon([center,right,CGPoint(x:742,y:383),bottom], 1, 0.36, 0.18)
context.setStrokeColor(CGColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1))
context.setLineWidth(19); context.setLineCap(.round); context.setLineJoin(.round)
for corner in [[CGPoint(x:160,y:726),CGPoint(x:160,y:854),CGPoint(x:288,y:854)],
               [CGPoint(x:736,y:854),CGPoint(x:864,y:854),CGPoint(x:864,y:726)],
               [CGPoint(x:864,y:298),CGPoint(x:864,y:170),CGPoint(x:736,y:170)],
               [CGPoint(x:288,y:170),CGPoint(x:160,y:170),CGPoint(x:160,y:298)]] {
    context.beginPath(); context.move(to: corner[0])
    for point in corner.dropFirst() { context.addLine(to: point) }
    context.strokePath()
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, context.makeImage()!, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Could not write app icon") }
