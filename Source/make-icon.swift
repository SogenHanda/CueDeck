import AppKit
let base = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let k = CGFloat(size)/1024
    let transform = NSAffineTransform(); transform.scale(by:k); transform.concat()
    NSColor(red:0.045,green:0.05,blue:0.06,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:10,y:10,width:1004,height:1004),xRadius:220,yRadius:220).fill()
    NSColor(white:0.20,alpha:1).setStroke()
    let rim = NSBezierPath(roundedRect:NSRect(x:28,y:28,width:968,height:968),xRadius:202,yRadius:202); rim.lineWidth = 8; rim.stroke()
    NSColor(red:0.76,green:0.95,blue:0.48,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:190,y:210,width:58,height:604),xRadius:18,yRadius:18).fill()
    let arrow = NSBezierPath(); arrow.move(to:NSPoint(x:380,y:300)); arrow.line(to:NSPoint(x:380,y:724)); arrow.line(to:NSPoint(x:790,y:512)); arrow.close(); arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:base.appendingPathComponent("size\(size).png"))
}
