import AppKit
@main struct PrepareLogo {
 static func main() throws {
  let input = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
  let w=input.pixelsWide, h=input.pixelsHigh
  let cut = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:0,bitsPerPixel:0)!
  var left=w,right=0,top=h,bottom=0
  for y in 0..<h { for x in 0..<w {
   let c=input.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
   let peak=max(c.redComponent,c.greenComponent,c.blueComponent)
   let a=min(1, max(0, (peak-0.025)*8))
   if a>0.10 {left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)}
   let v: CGFloat = 1
   cut.setColor(NSColor(deviceRed:c.redComponent*v,green:c.greenComponent*v,blue:c.blueComponent*v,alpha:a),atX:x,y:y)
  }}
  let source=NSImage(size:NSSize(width:w,height:h));source.addRepresentation(cut)
  let crop=NSRect(x:max(0,left-12),y:max(0,h-bottom-13),width:min(w,right-left+25),height:min(h,bottom-top+25))
  let output=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:output)
  let width:CGFloat=920;let height=width*crop.height/crop.width
  source.draw(in:NSRect(x:(1024-width)/2,y:(1024-height)/2,width:width,height:height),from:crop,operation:.sourceOver,fraction:1)
  NSGraphicsContext.restoreGraphicsState()
  try output.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  print("Prepared transparent icon; object bounds: \(crop)")
 }
}
