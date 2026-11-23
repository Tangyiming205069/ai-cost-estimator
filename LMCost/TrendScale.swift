import Foundation

enum TrendScale {
    static let order=["amount","tokens","count","cumulative"]
    static func selected(_ stored:String)->[String] {
        let keys=Set(stored.split(separator:",").map(String.init))
        return order.filter{keys.contains($0)}
    }
    static func toggling(_ key:String,in stored:String)->String {
        var keys=Set(selected(stored))
        if keys.contains(key) {keys.remove(key)} else {keys.insert(key)}
        return order.filter{keys.contains($0)}.joined(separator:",")
    }
    static func plot(_ value:Double?,peak:Double,relative:Bool)->Double? {
        guard let value=value else{return nil}
        return relative ? (peak>0 ? value/peak*100:0):value
    }
}
