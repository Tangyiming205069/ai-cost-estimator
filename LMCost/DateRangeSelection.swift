import Foundation

enum DateRangeSelection {
    static func month(containing date:Date,calendar:Calendar)->Date {
        calendar.date(from:calendar.dateComponents([.year,.month],from:date))!
    }
    static func days(in month:Date,calendar:Calendar)->[Date?] {
        let first=self.month(containing:month,calendar:calendar)
        let offset=(calendar.component(.weekday,from:first)-calendar.firstWeekday+7)%7
        let count=calendar.range(of:.day,in:.month,for:first)!.count
        return (0..<42).map {index in
            guard index>=offset,index<offset+count else{return nil}
            return calendar.date(byAdding:.day,value:index-offset,to:first)
        }
    }
    static func choose(_ date:Date,start:Date,choosingEnd:Bool,calendar:Calendar)->(start:Date,end:Date,choosingEnd:Bool) {
        let day=calendar.startOfDay(for:date),first=calendar.startOfDay(for:start)
        if !choosingEnd {return (day,day,true)}
        return (min(day,first),max(day,first),false)
    }
}
