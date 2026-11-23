import Foundation

@main struct TrendScaleTests {
    static func main() {
        precondition(TrendScale.selected("").isEmpty)
        precondition(TrendScale.toggling("amount",in:"amount").isEmpty)
        print("PASS: the last metric can be turned off and empty selection stays empty")
        let restored=TrendScale.toggling("tokens",in:"")
        precondition(TrendScale.selected(restored)==["tokens"])
        print("PASS: a metric can be restored after hiding every line")
        precondition(TrendScale.selected("count,tokens,amount,tokens,invalid")==["amount","tokens","count"])
        print("PASS: duplicate and obsolete preferences do not create extra series")
        let cost=TrendScale.plot(2.0,peak:10,relative:true)!
        let tokens=TrendScale.plot(500_000_000,peak:1_000_000_000,relative:true)!
        let requests=TrendScale.plot(7500,peak:10000,relative:true)!
        precondition(cost==20 && tokens==50 && requests==75)
        print("PASS: dollars, tokens and requests remain visible on one relative scale")
        precondition(TrendScale.plot(nil,peak:10,relative:true)==nil)
        precondition(TrendScale.plot(0,peak:10,relative:true)==0)
        print("PASS: an unpriced value stays missing while a known zero stays zero")
        precondition(TrendScale.plot(0,peak:0,relative:true)==0)
        print("PASS: a zero-only series produces no infinite or invalid coordinates")
        let precise=0.0000123456789
        precondition(TrendScale.plot(precise,peak:1,relative:false)==precise)
        print("PASS: single-series absolute values retain their original precision")
        print("7 trend-selection and scale regressions passed.")
    }
}
