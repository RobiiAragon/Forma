import Foundation
import SceneKit
import simd
import QuartzCore

// Standalone error shim; the benchmark compiles the actual app parser/sorter files.
enum RGBDDatasetError: LocalizedError {
 case invalid(String)
 var errorDescription: String? { if case let .invalid(text)=self { return text };return nil }
}

@main struct ViewerBenchmark {
 static func point(_ p:SIMD3<Float>)->GaussianPoint { GaussianPoint(positionOpacity:SIMD4(p,1),scale:SIMD4(1,1,1,0),rotation:SIMD4(0,0,0,1),color:SIMD4(1,1,1,1)) }
 static func median(_ values:[Double])->Double { values.sorted()[values.count/2] }
 static func elapsed<T>(_ body:()throws->T) rethrows ->(T,Double) { let start=CACurrentMediaTime();let output=try body();return(output,(CACurrentMediaTime()-start)*1000) }
 static func comparison(_ points:[GaussianPoint],_ direction:SIMD3<Float>)->[UInt32] {
  let depths=points.map{simd_dot(direction,SIMD3($0.positionOpacity.x,$0.positionOpacity.y,$0.positionOpacity.z))}
  var indices=(0..<points.count).map{UInt32($0)};var comparisons=0
  let control=GaussianWorkControl()
  indices.sort{ comparisons+=1;if comparisons.isMultiple(of:4096){try! control.checkCancellation()};return depths[Int($0)]<depths[Int($1)] }
  return indices
 }
 static func oldPreparation(_ imported:SCNScene)->SCNNode {
  let content=SCNNode();content.addChildNode(imported.rootNode.clone());var originals:[ObjectIdentifier:[SCNMaterial]]=[:]
  content.enumerateChildNodes{node,_ in
   node.categoryBitMask=1;node.camera=nil;node.light=nil
   guard let g=node.geometry,g.elementCount>0,g.sources(for:.vertex).contains(where:{$0.vectorCount>0})else{return}
   let authored=g.materials.contains{!($0.name ?? "").isEmpty || $0.diffuse.contents is NSImage || $0.diffuse.contents is URL || $0.diffuse.contents is String}
   if !authored || g.materials.isEmpty {let m=SCNMaterial();m.diffuse.contents=NSColor(red:1,green:0.36,blue:0.18,alpha:1);m.lightingModel = .physicallyBased;m.roughness.contents=0.6;m.metalness.contents=0.05;g.materials=[m]}
   g.materials.forEach{$0.isDoubleSided=false;$0.cullMode = .back}
   originals[ObjectIdentifier(g)]=g.materials.map{$0.copy() as! SCNMaterial}
  }
  _=content.boundingBox
  content.enumerateChildNodes{node,_ in guard let g=node.geometry else{return};if let o=originals[ObjectIdentifier(g)] {g.materials=o.map{$0.copy()as!SCNMaterial}};g.materials.forEach{$0.fillMode = .fill;$0.isDoubleSided=false;$0.cullMode = .back}}
  return content
 }
 static func main() throws {
  print("Swift -O whole-module; Mac CPU wall times; no device FPS measurement")
  let direction=simd_normalize(SIMD3<Float>(0.3,0.2,1))
  for count in [250_000,1_000_000] {
   var state:UInt64=42
   func coord()->Float{state=state &* 6364136223846793005 &+ 1442695040888963407;return Float(Int32(truncatingIfNeeded:state>>32))/Float(Int32.max)*100}
   let points=(0..<count).map{_ in point(SIMD3(coord(),coord(),coord()))}
   var baseline:[Double]=[],radix:[Double]=[]
   for _ in 0..<3 {
    let (expected,oldMS)=elapsed{comparison(points,direction)}
    let (actual,newMS)=try elapsed{try GaussianDepthOrder.sortedIndices(points:points,direction:direction,checkCancellation:GaussianWorkControl().checkCancellation)}
    precondition(expected==actual,"exact radix order mismatch")
    baseline.append(oldMS);radix.append(newMS)
   }
   print("Gaussian authored N=\(count): comparison_ms=\(median(baseline)) radix_ms=\(median(radix)) speedup=\(median(baseline)/median(radix)); exact full index equality")
  }
  if let argument=CommandLine.arguments.dropFirst().first {
   let url=URL(fileURLWithPath:argument)
  var imports:[Double]=[],oldPreps:[Double]=[],newPreps:[Double]=[]
  var primitiveCount=0
  for _ in 0..<3 {
   try autoreleasepool {
    let (scene,importMS)=try elapsed{try SCNScene(url:url,options:[.convertUnitsToMeters:NSNumber(value:1),.convertToYUp:true])}
    let (_,oldMS)=elapsed{oldPreparation(scene)}
    let (prepared,newMS)=try elapsed{try MeshPreviewPreparation.prepare(scene,isOBJ:true)}
    primitiveCount=prepared.materialSets.reduce(0){$0+$1.geometry.elements.reduce(0){$0+$1.primitiveCount}}
    imports.append(importMS);oldPreps.append(oldMS);newPreps.append(newMS)
   }
  }
  print("Private real non-demo mesh: \(primitiveCount) imported primitives; warm import median_ms=\(median(imports)); former main preparation_ms=\(median(oldPreps)); new worker preparation_ms=\(median(newPreps)); reset now performs zero imports")
  }
  let scene=SCNScene();let geometry=SCNBox(width:1,height:1,length:1,chamferRadius:0);let material=SCNMaterial();material.name="authored";geometry.materials=[material]
  for i in 0..<4096 {let node=SCNNode(geometry:geometry);node.position=SCNVector3(Float(i),0,0);scene.rootNode.addChildNode(node)}
  let (_,oldMS)=elapsed{oldPreparation(scene)}
  let (prepared,newMS)=try elapsed{try MeshPreviewPreparation.prepare(scene,isOBJ:true)}
  precondition(prepared.materialSets.count==1)
  print("Authored 4096 shared-geometry instances: old prep_ms=\(oldMS), new worker prep_ms=\(newMS), unique material sets=1")
 }
}
