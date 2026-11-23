import SwiftUI

struct RangeCalendar:View {
    @Binding var start:Date
    @Binding var end:Date
    let calendar:Calendar
    let language:String
    let cancel:()->Void
    let apply:()->Void
    @State private var visibleMonth:Date
    @State private var choosingEnd=false
    @State private var hovered:Date?

    init(start:Binding<Date>,end:Binding<Date>,calendar:Calendar,language:String,cancel:@escaping ()->Void,apply:@escaping ()->Void) {
        self._start=start;self._end=end
        var c=calendar;c.firstWeekday=2
        self.calendar=c;self.language=language;self.cancel=cancel;self.apply=apply
        self._visibleMonth=State(initialValue:DateRangeSelection.month(containing:start.wrappedValue,calendar:c))
    }
    private var year:Int {calendar.component(.year,from:visibleMonth)}
    private var month:Int {calendar.component(.month,from:visibleMonth)}
    private var range:ClosedRange<Date> {
        let first=calendar.startOfDay(for:start)
        let last=calendar.startOfDay(for:choosingEnd ? (hovered ?? start):end)
        return min(first,last)...max(first,last)
    }
    private var valid:Bool {
        let span=calendar.dateComponents([.day],from:start,to:end).day ?? -1
        return !choosingEnd && span>=0 && span<=3660
    }
    private func dateText(_ date:Date)->String {
        let f=DateFormatter();f.calendar=calendar;f.timeZone=calendar.timeZone
        f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd"
        return f.string(from:date)
    }
    private var monthNames:[String] {
        let f=DateFormatter();f.locale=Locale(identifier:language == "en" ? "en_US":"zh_CN")
        return f.monthSymbols
    }
    private func show(year:Int?=nil,month:Int?=nil) {
        if let date=calendar.date(from:DateComponents(year:year ?? self.year,month:month ?? self.month,day:1)) {
            visibleMonth=date;hovered=nil
        }
    }
    private func move(_ offset:Int) {
        if let next=calendar.date(byAdding:.month,value:offset,to:visibleMonth),
           (1...9999).contains(calendar.component(.year,from:next)) {visibleMonth=next;hovered=nil}
    }
    private func choose(_ day:Date) {
        let result=DateRangeSelection.choose(day,start:start,choosingEnd:choosingEnd,calendar:calendar)
        start=result.start;end=result.end;choosingEnd=result.choosingEnd;hovered=nil
    }
    private func cell(_ day:Date)->some View {
        let selected=range.contains(day)
        let first=day==range.lowerBound,last=day==range.upperBound
        return Button {choose(day)} label:{
            ZStack {
                if selected && range.lowerBound != range.upperBound {
                    HStack(spacing:0) {
                        (first ? Color.clear:Color.teal.opacity(0.15))
                        (last ? Color.clear:Color.teal.opacity(0.15))
                    }.frame(height:30)
                }
                if selected && (first || last) {Circle().fill(.teal).frame(width:30,height:30)}
                Text(String(calendar.component(.day,from:day)))
                    .font(.system(size:12,weight:calendar.isDateInToday(day) ? .bold:.medium))
                    .foregroundStyle(selected && (first || last) ? Color.white:Color.primary)
            }.frame(maxWidth:.infinity).frame(height:36).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(dateText(day))
            .accessibilityValue(selected ? L(first ? "开始日期":last ? "结束日期":"区间内"):"")
            .onHover {inside in if choosingEnd {hovered=inside ? day:nil}}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            LText("选择时间区间").font(.system(size:14,weight:.semibold))
            HStack(spacing:4) {
                Text(dateText(start)).foregroundStyle(.primary)
                Text("—").foregroundStyle(.secondary)
                if choosingEnd {LText("选择结束日期").foregroundStyle(.teal)}
                else {Text(dateText(end)).foregroundStyle(.primary)}
                Spacer()
            }.font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit()
            HStack(spacing:4) {
                Button {move(-1)} label:{Image(systemName:"chevron.left").frame(width:28,height:28)}
                    .localizedAccessibilityLabel("上一个月")
                Spacer(minLength:0)
                Picker(L("年份"),selection:Binding(get:{year},set:{show(year:$0)})) {
                    ForEach(max(1,year-10)...min(9999,year+10),id:\.self) {value in Text(String(value)).tag(value)}
                }.labelsHidden().frame(width:78)
                Picker(L("月份"),selection:Binding(get:{month},set:{show(month:$0)})) {
                    ForEach(1...12,id:\.self) {value in Text(monthNames[value-1]).tag(value)}
                }.labelsHidden().frame(width:language == "en" ? 112:80)
                Spacer(minLength:0)
                Button {move(1)} label:{Image(systemName:"chevron.right").frame(width:28,height:28)}
                    .localizedAccessibilityLabel("下一个月")
            }.buttonStyle(.plain).controlSize(.small)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:0),count:7),spacing:0) {
                ForEach(language == "en" ? ["Mo","Tu","We","Th","Fr","Sa","Su"]:["一","二","三","四","五","六","日"],id:\.self) {day in
                    Text(day).font(.system(size:10)).foregroundStyle(.secondary).frame(height:24)
                }
                ForEach(Array(DateRangeSelection.days(in:visibleMonth,calendar:calendar).enumerated()),id:\.offset) {_,day in
                    if let day=day {cell(day)} else {Color.clear.frame(height:36)}
                }
            }
            LText(choosingEnd ? "再点一天，确定结束日期":"先点开始日，再点结束日；中间日期自动选中")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if !choosingEnd && !valid {LText("时间区间请控制在十年以内。").font(.caption).foregroundStyle(.orange)}
            HStack {
                Spacer()
                Button(L("取消"),action:cancel).keyboardShortcut(.cancelAction)
                Button(L("应用"),action:apply).buttonStyle(.borderedProminent).tint(.teal)
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width:370)
    }
}
