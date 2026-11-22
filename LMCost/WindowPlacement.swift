import Foundation
import CoreGraphics

// Geometry only, shared by the native panel and regression tests.
struct WindowPlacement {
    static let compactSize=NSSize(width:188,height:40)
    static let expandedSize=NSSize(width:640,height:610)
    private(set) var compactFrame:NSRect?

    static func alignedCompactFrame(_ expanded:NSRect)->NSRect {
        NSRect(x:expanded.minX,y:expanded.maxY-compactSize.height,width:compactSize.width,height:compactSize.height)
    }
    static func clamped(_ frame:NSRect,to screens:[NSRect])->NSRect {
        guard !screens.isEmpty else{return frame}
        // Use the greatest overlap, including screens left/below the main display.
        let screen=screens.max {a,b in
            func score(_ screen:NSRect)->CGFloat {
                let intersection=frame.intersection(screen)
                return intersection.isNull ? 0:intersection.width*intersection.height
            }
            let overlapA=score(a),overlapB=score(b)
            if overlapA != overlapB {return overlapA<overlapB}
            func distance(_ screen:NSRect)->CGFloat {
                pow(frame.midX-screen.midX,2)+pow(frame.midY-screen.midY,2)
            }
            return distance(a)>distance(b)
        }!
        let origin=NSPoint(x:max(screen.minX,min(frame.minX,screen.maxX-frame.width)),
                           y:max(screen.minY,min(frame.minY,screen.maxY-frame.height)))
        return NSRect(origin:origin,size:frame.size)
    }
    mutating func expand(from frame:NSRect,screens:[NSRect])->NSRect {
        compactFrame=Self.clamped(frame,to:screens)
        return Self.clamped(NSRect(x:frame.minX,y:frame.maxY-Self.expandedSize.height,
            width:Self.expandedSize.width,height:Self.expandedSize.height),to:screens)
    }
    mutating func movedExpanded(to frame:NSRect,screens:[NSRect]) {
        // A deliberate drag establishes a new top-left anchor for the small window.
        compactFrame=Self.clamped(Self.alignedCompactFrame(frame),to:screens)
    }
    mutating func collapse(from frame:NSRect,screens:[NSRect])->NSRect {
        let result=Self.clamped(compactFrame ?? Self.alignedCompactFrame(frame),to:screens)
        compactFrame=nil
        return result
    }
    func savedOrigin(for frame:NSRect,expanded:Bool)->NSPoint {
        expanded ? (compactFrame ?? Self.alignedCompactFrame(frame)).origin:frame.origin
    }
}
