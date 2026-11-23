import SwiftUI

// Keep each page's intrinsic size inside the shared header/navigation/footer shell.
// In particular, a vertical scroller must not add its gutter to the shell's width.
struct PageViewport<Content:View>:View {
    @ViewBuilder let content:()->Content
    var body:some View {
        GeometryReader {viewport in
            content()
                .frame(width:viewport.size.width,height:viewport.size.height,alignment:.topLeading)
        }.clipped()
    }
}
