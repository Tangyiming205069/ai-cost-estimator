import Foundation
import CoreGraphics

enum Failure:Error {case mismatch(String)}
func check(_ condition:Bool,_ message:String) throws {
    if !condition {throw Failure.mismatch(message)}
}

@main
struct WindowPlacementTests {
    static let screen=NSRect(x:0,y:0,width:1440,height:900)
    static func main() throws {
        let tests:[(String,() throws->Void)]=[
            ("expanded drag collapses at its new top-left",{
                var p=WindowPlacement()
                _=p.expand(from:NSRect(x:100,y:700,width:188,height:40),screens:[screen])
                let moved=NSRect(x:400,y:150,width:640,height:610)
                p.movedExpanded(to:moved,screens:[screen])
                try check(p.collapse(from:moved,screens:[screen])==NSRect(x:400,y:720,width:188,height:40),"collapse jumped to the pre-drag position")
            }),
            ("screen-edge expansion alone does not change compact placement",{
                var p=WindowPlacement()
                let compact=NSRect(x:1200,y:30,width:188,height:40)
                let expanded=p.expand(from:compact,screens:[screen])
                try check(expanded.minX==800 && expanded.minY==0,"expanded panel was not kept visible")
                try check(p.collapse(from:expanded,screens:[screen])==compact,"automatic fit caused position drift")
            }),
            ("many no-drag expand-collapse cycles do not drift",{
                var p=WindowPlacement();var frame=NSRect(x:1200,y:30,width:188,height:40)
                let expected=frame
                for _ in 0..<100 {frame=p.collapse(from:p.expand(from:frame,screens:[screen]),screens:[screen])}
                try check(frame==expected,"repeated resizing drifted")
            }),
            ("expanded moves are saved before collapse or quit",{
                var p=WindowPlacement()
                _=p.expand(from:NSRect(x:100,y:700,width:188,height:40),screens:[screen])
                let moved=NSRect(x:500,y:160,width:640,height:610)
                p.movedExpanded(to:moved,screens:[screen])
                try check(p.savedOrigin(for:moved,expanded:true)==NSPoint(x:500,y:730),"restart would restore an obsolete location")
            }),
            ("drag across monitors preserves negative coordinates",{
                let left=NSRect(x:-1440,y:-100,width:1440,height:900)
                var p=WindowPlacement()
                _=p.expand(from:NSRect(x:100,y:700,width:188,height:40),screens:[screen,left])
                let moved=NSRect(x:-1100,y:70,width:640,height:610)
                p.movedExpanded(to:moved,screens:[screen,left])
                try check(p.collapse(from:moved,screens:[screen,left]).origin==NSPoint(x:-1100,y:640),"move to left monitor was lost")
            }),
            ("partially overlapping monitors choose greatest overlap",{
                let right=NSRect(x:1440,y:0,width:1440,height:900)
                let frame=NSRect(x:1400,y:100,width:640,height:610)
                try check(WindowPlacement.clamped(frame,to:[screen,right]).minX==1440,"first intersecting monitor was used")
            }),
            ("disconnected monitor location is recovered on an available screen",{
                let old=NSRect(x:-2000,y:400,width:188,height:40)
                let recovered=WindowPlacement.clamped(old,to:[screen])
                try check(screen.contains(recovered),"reopened compact window is offscreen")
            }),
            ("small screen retains visible origin",{
                let tiny=NSRect(x:0,y:0,width:500,height:500)
                let frame=WindowPlacement.clamped(NSRect(x:400,y:400,width:640,height:610),to:[tiny])
                try check(frame.origin == .zero,"oversized panel origin is inaccessible")
            }),
            ("saved compact position follows subsequent compact drag",{
                let moved=NSRect(x:330,y:240,width:188,height:40)
                try check(WindowPlacement().savedOrigin(for:moved,expanded:false)==moved.origin,"compact position was stale")
            })]
        for (name,test) in tests {try test();print("PASS: \(name)")}
        print("\(tests.count) window placement regressions passed.")
    }
}
