import Foundation

@main struct DateRangeSelectionTests {
    static func main() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(secondsFromGMT:0)!;calendar.firstWeekday=2
        func day(_ year:Int,_ month:Int,_ day:Int,_ c:Calendar?=nil)->Date {
            (c ?? calendar).date(from:DateComponents(year:year,month:month,day:day))!
        }
        let start=day(2026,10,15),end=day(2026,11,5)
        let first=DateRangeSelection.choose(start,start:end,choosingEnd:false,calendar:calendar)
        precondition(first.start==start && first.end==start && first.choosingEnd)
        let second=DateRangeSelection.choose(end,start:first.start,choosingEnd:first.choosingEnd,calendar:calendar)
        precondition(second.start==start && second.end==end && !second.choosingEnd)
        print("PASS: two clicks select an inclusive cross-month range")
        let reverse=DateRangeSelection.choose(start,start:end,choosingEnd:true,calendar:calendar)
        precondition(reverse.start==start && reverse.end==end && !reverse.choosingEnd)
        print("PASS: reverse clicks normalize the endpoints")
        let same=DateRangeSelection.choose(start,start:start,choosingEnd:true,calendar:calendar)
        precondition(same.start==same.end && !same.choosingEnd)
        print("PASS: the same day can be both endpoints")
        let reset=DateRangeSelection.choose(end,start:start,choosingEnd:false,calendar:calendar)
        precondition(reset.start==end && reset.end==end && reset.choosingEnd)
        print("PASS: choosing again starts a fresh range")
        let leap=DateRangeSelection.days(in:day(2024,2,15),calendar:calendar)
        precondition(leap.count==42 && leap.compactMap{$0}.count==29 && leap[3]==day(2024,2,1))
        print("PASS: leap February aligns with Monday-first weekdays")
        let november=DateRangeSelection.days(in:day(2026,11,1),calendar:calendar)
        precondition(november[6]==day(2026,11,1) && november.compactMap{$0}.last==day(2026,11,30))
        print("PASS: a Sunday month start keeps all days in six rows")
        let crossYear=DateRangeSelection.choose(day(2027,1,2),start:day(2026,12,30),choosingEnd:true,calendar:calendar)
        precondition(calendar.dateComponents([.day],from:crossYear.start,to:crossYear.end).day==3)
        print("PASS: range selection crosses year boundaries")
        var local=calendar;local.timeZone=TimeZone(identifier:"America/Los_Angeles")!
        let dst=DateRangeSelection.choose(day(2026,3,10,local),start:day(2026,3,7,local),choosingEnd:true,calendar:local)
        precondition(local.dateComponents([.day],from:dst.start,to:dst.end).day==3)
        precondition(dst.end.timeIntervalSince(dst.start)==71*3600)
        print("PASS: local days survive daylight-saving transitions")
        print("8 date-range selection regressions passed.")
    }
}
