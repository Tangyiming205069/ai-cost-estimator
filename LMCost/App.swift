import Cocoa
import SwiftUI
import Carbon
import CoreServices
import Charts
import UniformTypeIdentifiers

// Localize presentation only: protocol keys, event IDs and stored usage are unchanged.
enum UIStrings {
    static var language=UserDefaults.standard.string(forKey:"displayLanguage") ?? "zh-Hans"
    static let catalog:[String:String] = {
        guard let path=Bundle.main.url(forResource:"localization.en",withExtension:"json"),
              let data=try? Data(contentsOf:path),let result=try? JSONSerialization.jsonObject(with:data) as? [String:String] else{return [:]}
        return result
    }()
    static let pattern:NSRegularExpression? = {
        let keys=catalog.keys.sorted{$0.count > $1.count}
        guard !keys.isEmpty else{return nil}
        return try? NSRegularExpression(pattern:keys.map{NSRegularExpression.escapedPattern(for:$0)}.joined(separator:"|"))
    }()
    static func text(_ source:String)->String {
        guard language == "en" else{return source}
        if let exact=catalog[source] {return exact}
        guard let pattern=pattern else{return source}
        var output=source
        for match in pattern.matches(in:source,range:NSRange(source.startIndex...,in:source)).reversed() {
            guard let original=Range(match.range,in:source),let range=Range(match.range,in:output),let replacement=catalog[String(source[original])] else{continue}
            output.replaceSubrange(range,with:replacement)
        }
        return output
    }
}
func L(_ value:String)->String {UIStrings.text(value)}
func LText(_ value:String)->Text {Text(L(value))}
extension View {
    func localizedHelp(_ value:String)->some View {help(L(value))}
    func localizedAccessibilityLabel(_ value:String)->some View {accessibilityLabel(L(value))}
}

let ink = Color.primary
let mint = Color.blue
let dim = Color.secondary
let base = Color.clear
let metricChoices=[("month_cost","本月 API 等价费用"),("today_cost","今日 API 等价费用"),("month_tokens","本月 Token 用量"),("plan_ratio","本月估算 / 参考月费")]
func usd(_ x:Double)->String {String(format:"$%.4f",x)}
func money(_ x:Double)->String {
    if x>0 && x<0.01 {return "$"+x.formatted(.number.precision(.fractionLength(2...10)).locale(Locale(identifier:"en_US")))}
    return "$"+x.formatted(.number.precision(.fractionLength(2)).grouping(.automatic).locale(Locale(identifier:"en_US")))
}
func number(_ x:Any?)->Double {(x as? NSNumber)?.doubleValue ?? 0}
func tokenText(_ x:Any?)->String {guard let n=x as? NSNumber else{return "未知"};return n.stringValue}
func tokenBrief(_ x:Any?)->String {guard let n=x as? NSNumber else{return "未知"};return compactNumber(n.doubleValue)}
func mixBrief(_ value:Any?)->String {
    let mix=value as? [String:Any] ?? [:]
    return tokenBrief(mix["total"])
}
func speedName(_ value:Any?)->String {
    switch value as? String {
    case "normal":return "Standard"
    case "fast":return "Fast"
    case "flex":return "Flex"
    case "ultrafast":return "Ultrafast"
    default:return "档位未知"
    }
}
func rateText(_ value:Any?)->String {
    guard let values=value as? [NSNumber],let first=values.first,let last=values.last else{return "—"}
    let low=String(format:"$%.3g",first.doubleValue)
    return values.count==1 ? low:low+"–"+String(format:"$%.3g",last.doubleValue)
}
func compactNumber(_ x:Double)->String {
    if x >= 1000000000 {return String(format:"%.2fB",x/1000000000)}
    if x >= 1000000 {return String(format:"%.2fM",x/1000000)}
    if x >= 1000 {return String(format:"%.1fK",x/1000)}
    return String(format:"%.0f",x)
}

final class Model: ObservableObject {
    @Published var language = UIStrings.language
    var onLanguageChange:(()->Void)?
    func setLanguage(_ value:String) {
        guard ["zh-Hans","en"].contains(value) else{return}
        UIStrings.language=value;UserDefaults.standard.set(value,forKey:"displayLanguage")
        language=value;onLanguageChange?();onChange?()
    }
    @Published var snapshot: [String: Any] = [:]
    @Published var expanded = false
    @Published var tab = "概览"
    @Published var agent = "全部"
    @Published var month = ""
    @Published var periodMode = "month"
    @Published var rangeStart = ""
    @Published var rangeEnd = ""
    @Published var draftStart = Calendar.current.date(from:Calendar.current.dateComponents([.year,.month],from:Date())) ?? Date()
    @Published var draftEnd = Date()
    @Published var selectedModel = "全部模型"
    @Published var selectedSpeed = "all"
    @Published var error = ""
    @Published var selectedRow = ""
    @Published var codexPlan = ""
    @Published var claudePlan = ""
    @Published var timezone = "UTC"
    @Published var prefsLoaded = false
    @Published var metric = "month_cost"
    @Published var loading = false
    @Published var sourceWatcherActive = false
    @Published var serviceUnavailable = false
    var stopping=false
    var backend: Process?
    var input: FileHandle?
    var buffer = Data()
    var queue = DispatchQueue(label: "lm.bridge")
    var requestInFlight=false
    var activeQuery:[String:Any]?
    var pendingSnapshot:[String:Any]?
    var pendingActions:[[String:Any]]=[]
    var filterWork:DispatchWorkItem?
    var onChange: (() -> Void)?
    var onDrag: ((CGSize,Bool) -> Void)?
    var lastDragAt: TimeInterval = 0
    let resource = Bundle.main.resourceURL!
    let dataURL:URL = {
        // Preserve the original user's opted-in ledger without moving or copying it.
        let legacy=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("LM Cost Data",isDirectory:true)
        if FileManager.default.fileExists(atPath:legacy.appendingPathComponent("usage.sqlite3").path) {return legacy}
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let previous=support.appendingPathComponent("AI Cost Companion",isDirectory:true)
        if FileManager.default.fileExists(atPath:previous.appendingPathComponent("usage.sqlite3").path) {return previous}
        return support.appendingPathComponent("AI Cost Estimator",isDirectory:true)
    }()
    func start() {
        stopping=false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey:"AICostPython") as? String ?? "/opt/homebrew/bin/python3")
        p.arguments = [resource.appendingPathComponent("engine.py").path, dataURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self = self else { return }
                self.buffer.append(bytes)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String:Any] {
                        DispatchQueue.main.async { self.receive(obj) }
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self=self,!self.stopping else{return}
                self.serviceUnavailable=true;self.loading=false
                self.error="本机服务已停止，请重新打开 AI Cost Estimator。"
                self.onChange?()
            }
        }
        do { try p.run(); backend = p; send() }
        catch { self.serviceUnavailable=true;self.error = "本机 Python 服务未能启动。此版本需要 /opt/homebrew/bin/python3。" }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.send() }
    }
    func receive(_ obj: [String:Any]) {
        // One outstanding command; replace queued polling/filter snapshots with the latest.
        // Actions remain ordered and are never dropped, including ACK-only commands.
        defer {requestInFlight=false;activeQuery=nil;flushRequests()}
        if let e = obj["error"] as? String { error = e }
        if let s = obj["snapshot"] as? [String:Any] {
            guard (month.isEmpty || s["month"] as? String == month),
                  (s["start_date"] as? String ?? "") == (usesCustomRange ? rangeStart:""),
                  (s["end_date"] as? String ?? "") == (usesCustomRange ? rangeEnd:""),
                  (s["selected_agent"] as? String ?? "全部") == agent,
                  (s["selected_model"] as? String ?? "全部模型") == selectedModel,
                  (s["selected_speed"] as? String ?? "all") == selectedSpeed else { return }
            snapshot = s
            loading = false
            if month.isEmpty { month = s["month"] as? String ?? "" }
            if !prefsLoaded, let p = s["plan_overrides"] as? [String:Any] {
                codexPlan = p["Codex"] is NSNumber ? String(format:"%.2f",number(p["Codex"])):""
                claudePlan = p["Claude Code"] is NSNumber ? String(format:"%.2f",number(p["Claude Code"])):""
                timezone = s["timezone"] as? String ?? "UTC"
                metric = s["primary_metric"] as? String ?? "month_cost"
                prefsLoaded = true
            }
            onChange?()
        }
        if let path = obj["launcher"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        if let path = obj["reveal"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath:path,isDirectory:true))
        }
    }
    func send(_ action: String = "snapshot", _ extras: [String:Any] = [:]) {
        guard !serviceUnavailable else{return}
        var q: [String:Any] = ["action":action,"month":month,"agent":agent,"model":selectedModel,"speed":selectedSpeed,
            "start_date":usesCustomRange ? rangeStart:"","end_date":usesCustomRange ? rangeEnd:""]
        q.merge(extras) { _,new in new }
        if action == "snapshot" {
            pendingSnapshot=q
            if let activeQuery=activeQuery,NSDictionary(dictionary:activeQuery).isEqual(to:q) {pendingSnapshot=nil}
        } else {
            pendingActions.append(q);pendingSnapshot=nil
        }
        flushRequests()
    }
    func flushRequests() {
        guard !requestInFlight,!serviceUnavailable,!stopping else{return}
        let q:[String:Any]
        if !pendingActions.isEmpty {q=pendingActions.removeFirst()}
        else if let next=pendingSnapshot {q=next;pendingSnapshot=nil}
        else {return}
        requestInFlight=true;activeQuery=q
        if let data = try? JSONSerialization.data(withJSONObject:q) {
            queue.async { [weak self] in
                do {try self?.input?.write(contentsOf:data+Data([10]))}
                catch {DispatchQueue.main.async {self?.serviceUnavailable=true;self?.loading=false;self?.error="本机服务已断开，请重新打开 AI Cost Estimator。"}}
            }
        }
    }
    func filter() {
        selectedRow="";loading=true;filterWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.send() }
        filterWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:work)
    }
    var usesCustomRange:Bool {tab == "用量" && periodMode == "custom"}
    var reportZone:TimeZone {timezone == "UTC" ? TimeZone(secondsFromGMT:0)!:TimeZone.current}
    func dayString(_ date:Date)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=reportZone;formatter.dateFormat="yyyy-MM-dd";return formatter.string(from:date)
    }
    var reportCalendar:Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=reportZone;return c}
    var draftRangeError:String? {
        let count=reportCalendar.dateComponents([.day],from:reportCalendar.startOfDay(for:draftStart),to:reportCalendar.startOfDay(for:draftEnd)).day ?? -1
        return count<0 ? "开始日期不能晚于结束日期。":count>3660 ? "时间区间请控制在十年以内。":nil
    }
    @discardableResult func applyRange()->Bool {
        let start=dayString(draftStart),end=dayString(draftEnd)
        if let message=draftRangeError {error=message;return false}
        error="";rangeStart=start;rangeEnd=end;periodMode="custom";resetPeriodFilters();return true
    }
    func prepareRange() {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=reportZone;formatter.dateFormat="yyyy-MM-dd"
        draftStart=formatter.date(from:usesCustomRange ? rangeStart:(snapshot["period_start"] as? String ?? "")) ?? Date()
        draftEnd=formatter.date(from:usesCustomRange ? rangeEnd:(snapshot["period_end"] as? String ?? "")) ?? Date()
    }
    func choosePeriod(_ preset:String) {
        let c=reportCalendar,today=c.startOfDay(for:Date())
        let first=c.date(from:c.dateComponents([.year,.month],from:today)) ?? today
        draftEnd=today
        switch preset {
        case "7":draftStart=c.date(byAdding:.day,value:-6,to:today) ?? today
        case "30":draftStart=c.date(byAdding:.day,value:-29,to:today) ?? today
        case "last":
            draftStart=c.date(byAdding:.month,value:-1,to:first) ?? first
            draftEnd=c.date(byAdding:.day,value:-1,to:first) ?? first
        case "all":
            let earliest=(snapshot["months"] as? [String] ?? []).filter{$0 != "未知月份"}.min() ?? dayString(first).prefix(7).description
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=reportZone;f.dateFormat="yyyy-MM-dd"
            draftStart=f.date(from:earliest+"-01") ?? first
            let latest=(snapshot["months"] as? [String] ?? []).filter{$0 != "未知月份"}.max() ?? dayString(today).prefix(7).description
            if let monthStart=f.date(from:latest+"-01"),let next=c.date(byAdding:.month,value:1,to:monthStart),latest>dayString(today).prefix(7).description {
                draftEnd=c.date(byAdding:.day,value:-1,to:next) ?? today
            }
        default:draftStart=first
        }
        applyRange()
    }
    var periodLabel:String {
        if usesCustomRange {return rangeStart+" — "+rangeEnd}
        return (snapshot["period_start"] as? String ?? month)+" — "+(snapshot["period_end"] as? String ?? "")
    }
    func resetPeriodFilters() {error="";agent="全部";selectedModel="全部模型";selectedSpeed="all";filter()}
    func switchMode() {
        let value=demo ? "live":"demo"
        month="";periodMode="month";rangeStart="";rangeEnd=""
        agent="全部";selectedModel="全部模型";selectedSpeed="all";selectedRow="";error="";loading=true
        send("mode",["value":value])
    }
    func exportDaily() {
        guard !loading else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.commaSeparatedText]
        panel.nameFieldStringValue="AI-Cost-Estimator-\(snapshot["period_start"] as? String ?? month)-\(snapshot["period_end"] as? String ?? month).csv"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        // Aggregates only: no request or conversation identifiers are exported.
        let columns=["date","timezone","agent_filter","model_filter","tier_filter","requests","unpriced_requests","api_value_usd","cumulative_api_value_usd","known_tokens","input_tokens","cache_read_tokens","cache_write_tokens","output_tokens","incomplete_tokens"]
        func cell(_ value:String)->String {"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        let records=(snapshot["daily"] as? [[String:Any]] ?? []).map {r -> String in
            let fields=[r["date"] as? String ?? "",snapshot["timezone"] as? String ?? "",agent,selectedModel,selectedSpeed,
                tokenText(r["count"]),tokenText(r["unpriced"]),(r["amount"] as? NSNumber)?.stringValue ?? "",
                (r["cumulative"] as? NSNumber)?.stringValue ?? "",tokenText(r["tokens"]),tokenText(r["input"]),tokenText(r["read"]),tokenText(r["write"]),tokenText(r["output"]),r["incomplete"] as? Bool == true ? "true":"false"]
            return fields.map(cell).joined(separator:",")
        }
        do {try ("\u{FEFF}"+([columns.joined(separator:",")]+records).joined(separator:"\r\n")+"\r\n").write(to:url,atomically:true,encoding:.utf8)}
        catch {self.error="导出失败，请选择可写入的位置。"}
    }
    var demo: Bool { (snapshot["mode"] as? String ?? "live") == "demo" }
    var activity:[[String:Any]] {snapshot["activity"] as? [[String:Any]] ?? []}
    func timeOnly(_ value:Any?)->String {String(localTime(value).suffix(8))}
    var rows: [[String:Any]] { snapshot["rows"] as? [[String:Any]] ?? [] }
    var history: [String:Any] { snapshot["history"] as? [String:Any] ?? [:] }
    var historySync: [String:Any] {snapshot["history_sync"] as? [String:Any] ?? [:]}
    var historyActive: Bool {!serviceUnavailable && historySync["active"] as? Bool == true}
    func localTime(_ value:Any?)->String {
        guard let raw=value as? String else{return "尚无"}
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var date=parser.date(from:raw)
        if date == nil {parser.formatOptions=[.withInternetDateTime];date=parser.date(from:raw)}
        guard let date=date else{return "未知"}
        let display=DateFormatter();display.timeZone=TimeZone(identifier:"Asia/Shanghai");display.dateFormat="MM-dd HH:mm:ss"
        return display.string(from:date)
    }
    var historyLabel: String {
        guard !history.isEmpty else{return "仅本机已连接来源 · 覆盖不完整"}
        if historySync["state"] as? String == "syncing" {return "正在补录本机 Codex 新增用量…"}
        let cutoff=historySync["last_scan"] ?? history["cutoff"]
        return "\(historyActive ? "自动同步":"历史快照 · 自动同步未开启") · 检查 \(localTime(cutoff)) 北京时间"
    }
    var metricLabel:String {
        let label=["month_cost":"本月","today_cost":"今日","month_tokens":"Token","plan_ratio":"月费比"][metric] ?? "本月"
        return demo ? label+"·演示":label
    }
    var headline:String {
        if metric == "month_tokens" {
            let mix=snapshot["current_mix"] as? [String:Any] ?? [:]
            return number(snapshot["current_count"]) > 0 ? compactNumber(number(mix["total"])):"—"
        }
        let today=metric == "today_cost"
        let count=number(snapshot[today ? "today_count":"current_count"])
        let unknown=number(snapshot[today ? "today_unpriced":"current_unpriced"])
        guard count > unknown else{return "—"}
        let amount=number(snapshot[today ? "today_amount":"current_amount"])
        if metric == "plan_ratio" {
            let total=number(snapshot["current_plan"])
            return total > 0 ? String(format:"%.2f×",amount/total):"—"
        }
        return money(amount)
    }
    func setMetric(_ value:String) {
        metric=value;send("display-preferences",["metric":value])
    }
    func savePrefs() {
        var plans:[String:Any]=[:]
        for (name,text) in [("Codex",codexPlan),("Claude Code",claudePlan)] {
            if text.trimmingCharacters(in:.whitespaces).isEmpty {plans[name]=NSNull();continue}
            guard let v=Double(text),v.isFinite,v >= 0,v <= 100000 else {error="调整金额请输入 0–100000 美元，或留空使用自动识别。";return}
            plans[name]=v
        }
        send("preferences",["plans":plans,"timezone":timezone])
    }
    func detectPlan(_ provider:String) {
        let alert=NSAlert()
        alert.messageText=L("识别 \(provider) 登录套餐")
        alert.informativeText=L("通过本机官方 CLI 查询登录状态，只提取套餐类型。账户标识和邮箱只在内存中过滤，不保存；不读取会话或发起模型请求，不开启用量采集。官方命令可能查询其登录服务。\n\n本机 CLI 账户可能与桌面或云端不同；显示官网美元月付参考，不能获取实际扣款。")
        alert.addButton(withTitle:L("识别套餐"));alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        send("detect-plan",["provider":provider,"consent":true])
    }
    func connectHistory() {
        let alert=NSAlert()
        alert.messageText=L("连接 Codex 本机用量自动同步")
        alert.informativeText=L("AI Cost Estimator 打开期间，收到此 Mac 的 Codex 历史文件变化通知就检查新增用量，另每 5 秒补查。Codex 将请求用量写入本机后才会显示，不是逐 token 流。\n\n仅保存时间、模型、token 桶、档位与散列去重 ID；不保存对话正文或账户身份，不上传。不会修改 Codex 配置、hook 或遥测。\n\n这个选择会记住；以后打开 AI Cost Estimator 会继续同步，退出即停止，可随时暂停。不会创建登录项。")
        alert.addButton(withTitle:L("连接并自动同步"));alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        send("enable-history-sync",["consent":true])
    }
    func connectClaude() {
        let alert = NSAlert()
        alert.messageText = L("连接一个新的 Claude Code 会话")
        alert.informativeText = L("仅统计连接后在本机启动的新会话，不补齐历史或其他设备。新会话不载入个人和项目设置；已有会话与配置不变。只在内存中筛选 API request 事件，保存时间、模型、token 桶和散列去重 ID。关闭内容采集，不保存账户身份，不上传。受管理或已配置遥测存在时停止。\n\n连接后通过官方登录状态命令自动识别套餐，仅保留套餐类型，不保存邮箱或账户标识。官网月付参考不是实际扣款。\n\n需要已安装并登录的官方 Claude Code 2.1.300+；随后选择工作文件夹。")
        alert.addButton(withTitle:L("同意并连接"))
        alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let candidates = [NSHomeDirectory()+"/.local/bin/claude","/opt/homebrew/bin/claude","/usr/local/bin/claude"]
        var binary = candidates.first { FileManager.default.isExecutableFile(atPath:$0) }
        if binary == nil {
            let file = NSOpenPanel()
            file.title=L("选择已安装的 Claude Code 可执行文件")
            file.message=L("常见位置未找到 Claude Code。请选官方 CLI；AI Cost Estimator 不会自动安装。")
            file.canChooseFiles=true; file.canChooseDirectories=false; file.allowsMultipleSelection=false
            guard file.runModal() == .OK else { return }
            binary=file.url?.path
        }
        let folder = NSOpenPanel()
        folder.title=L("选择新 Claude 会话的工作文件夹")
        folder.canChooseFiles=false; folder.canChooseDirectories=true; folder.allowsMultipleSelection=false
        guard folder.runModal() == .OK, let project=folder.url?.path, let binary=binary else { return }
        error=""
        send("connect", ["binary":binary,"project":project,"detect_plan":true])
    }
    func allowCodex() {
        let alert=NSAlert()
        alert.messageText=L("允许本次运行接收 Codex hook？")
        alert.informativeText=L("只接收你另行安装并在 Codex 中信任的 PostModelRequest；此按钮不安装 hook，不修改已有配置。只保存散列 ID、接收时间、模型和 token 桶，不读取会话内容，不上传。退出或停止即拒收。\n\n本机已验证事件能被识别，尚未验收桌面真实投递。缺可靠请求 ID 的投递会被拒收；缺档位或必要计费桶将未定价。月份按本机接收时间，仅覆盖连接后的请求。另通过本机 Codex 官方 account/read 读取登录套餐，不强制刷新登录，不保存邮箱或账户标识。CLI 与桌面账户可能不同，月费只是官网参考。")
        alert.addButton(withTitle:L("同意本次接收"))
        alert.addButton(withTitle:L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        send("enable-codex",["detect_plan":true])
    }
    func stop() { stopping=true;try? input?.close();if backend?.isRunning == true {backend?.terminate()} }
}

final class UsageFileWatcher {
    private var stream:FSEventStreamRef?
    private let changed:()->Void
    private var pending:DispatchWorkItem?
    var active:Bool {stream != nil}
    init(changed:@escaping ()->Void) {self.changed=changed}
    func start()->Bool {
        if active {return true}
        let paths=[NSHomeDirectory()+"/.codex/sessions",NSHomeDirectory()+"/.codex/archived_sessions"].filter {
            var directory:ObjCBool=false
            return FileManager.default.fileExists(atPath:$0,isDirectory:&directory) && directory.boolValue
        }
        guard !paths.isEmpty else{return false}
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        guard let created=FSEventStreamCreate(nil,{_,info,_,_,_,_ in
            guard let info=info else{return}
            Unmanaged<UsageFileWatcher>.fromOpaque(info).takeUnretainedValue().notify()
        },&context,paths as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.25,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot|kFSEventStreamCreateFlagNoDefer)) else {return false}
        FSEventStreamSetDispatchQueue(created,DispatchQueue.main)
        guard FSEventStreamStart(created) else {FSEventStreamInvalidate(created);FSEventStreamRelease(created);return false}
        stream=created;return true
    }
    private func notify() {
        // Coalesce bursts without postponing forever while a writer is active.
        guard pending == nil else{return}
        let work=DispatchWorkItem { [weak self] in
            guard let self=self else{return}
            self.pending=nil
            if self.active {self.changed()}
        }
        pending=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func stop() {
        pending?.cancel();pending=nil
        if let stream=stream {FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream)}
        stream=nil
    }
    deinit {stop()}
}

struct MixBar: View {
    let mix: [String:Any]
    var detailed = true
    let keys=["input","output","read","write"]
    let labels=["输入","输出","缓存读","缓存写"]
    let colors:[Color]=[.blue,.purple,.teal,.orange]
    var values:[String:Any] {mix["values"] as? [String:Any] ?? [:]}
    var total:Double {number(mix["total"])}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            GeometryReader { g in
                HStack(spacing:2) {
                    ForEach(0..<4,id:\.self) { i in
                        if number(values[keys[i]]) > 0 && total > 0 {
                            Capsule().fill(colors[i].opacity(0.8)).frame(width:max(0,(g.size.width-6)*number(values[keys[i]])/total))
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(height:detailed ? 7:4).background(Color.primary.opacity(0.05),in:Capsule())
            HStack(spacing:detailed ? 18:12) {
                ForEach(0..<4,id:\.self) { i in
                    HStack(spacing:4) {
                        Circle().fill(colors[i]).frame(width:5,height:5)
                        LText(labels[i])
                        LText(total > 0 ? String(format:"%.1f%%",number(values[keys[i]])/total*100):"—").monospacedDigit()
                    }
                }
                Spacer(minLength:0)
                if mix["incomplete"] as? Bool == true {LText("仅已知部分").foregroundStyle(.orange)}
            }.font(.system(size:detailed ? 10:9)).foregroundStyle(.secondary)
        }
    }
}

struct TrendPoint:Identifiable {
    let id:String
    let date:Date
    let value:Double
    let series:String
    let segment:String
}
struct TrendDay:Identifiable {
    let id:String
    let date:Date
    let values:[String:Double]
    let unpriced:Int
    let incomplete:Bool
}
struct UsageTrend:View {
    let days:[TrendDay]
    let language:String
    @AppStorage("trendMetrics") private var metricSelection="amount,tokens,count"
    @AppStorage("trendTokenBreakdown") private var tokenBreakdown=false
    @State private var selection:Date?
    init(days:[[String:Any]],language:String) {
        self.language=language
        let formatter=ISO8601DateFormatter()
        self.days=days.compactMap {day in
            guard let id=day["date"] as? String,let date=formatter.date(from:id+"T12:00:00Z") else{return nil}
            var values:[String:Double]=[:]
            for key in ["amount","tokens","count","cumulative","input","read","write","output"] {
                if let n=day[key] as? NSNumber {values[key]=n.doubleValue}
            }
            return TrendDay(id:id,date:date,values:values,unpriced:Int(number(day["unpriced"])),incomplete:day["incomplete"] as? Bool == true)
        }
    }
    private var metrics:[String] {
        let selected=Set(metricSelection.split(separator:",").map(String.init))
        let result=["amount","tokens","count","cumulative"].filter{selected.contains($0)}
        return result.isEmpty ? ["amount"]:result
    }
    private func enabled(_ key:String)->Binding<Bool> {
        Binding(get:{metrics.contains(key)},set:{on in
            var result=Set(metrics)
            if on {result.insert(key)} else if result.count>1 {result.remove(key)}
            metricSelection=["amount","tokens","count","cumulative"].filter{result.contains($0)}.joined(separator:",")
        })
    }
    private func title(_ metric:String)->String {
        metric == "tokens" ? "每日 Token":metric == "count" ? "每日请求":metric == "cumulative" ? "累计 API 等价值":"每日 API 等价值"
    }
    private func color(_ metric:String)->Color {
        metric == "tokens" ? .blue:metric == "count" ? .orange:metric == "cumulative" ? .purple:.teal
    }
    private var selectedDay:TrendDay? {
        guard !days.isEmpty else{return nil}
        guard let selection=selection else{return days.last}
        return days[nearestIndex(selection)]
    }
    private func nearestIndex(_ candidate:Date)->Int {
        guard let first=days.first else{return 0}
        return min(days.count-1,max(0,Int((candidate.timeIntervalSince(first.date)/86400).rounded())))
    }
    private func valueText(_ metric:String)->String {
        guard let value=selectedDay?.values[metric] else{return "—"}
        if metric == "amount" || metric == "cumulative" {return String(format:"$%.2f",value)}
        return value.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier:"en_US")))
    }
    private var domain:ClosedRange<Date> {
        let first=days.first?.date ?? Date(),last=days.last?.date ?? first
        return first==last ? first.addingTimeInterval(-43200)...last.addingTimeInterval(43200):first...last
    }
    private func points(_ metric:String)->[TrendPoint] {
        let fields=metric == "tokens" && tokenBreakdown ? [("input","输入"),("read","缓存读取"),("write","缓存写入"),("output","输出")]:[(metric,title(metric))]
        var result:[TrendPoint]=[]
        for (key,label) in fields {
            var segment=0
            for day in days {
                guard let value=day.values[key] else{segment+=1;continue}
                result.append(TrendPoint(id:day.id+key,date:day.date,value:value,series:L(label),segment:"\(key)-\(segment)"))
            }
        }
        return result
    }
    private func chart(_ metric:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                LText(title(metric)).foregroundStyle(.secondary)
                if metric == "tokens" {
                    Toggle(L("Token 分项"),isOn:$tokenBreakdown).toggleStyle(.checkbox).controlSize(.mini)
                }
                Spacer()
                Text(valueText(metric)).fontWeight(.semibold).monospacedDigit()
                if let day=selectedDay {
                    if day.unpriced>0 && (metric == "amount" || metric == "cumulative") {LText("含未定价").foregroundStyle(.orange)}
                    if day.incomplete && metric == "tokens" {LText("部分 Token 未知").foregroundStyle(.orange)}
                }
            }.font(.system(size:10))
            Chart {
                ForEach(points(metric)) {point in
                    LineMark(x:.value(L("日期"),point.date),y:.value(L(title(metric)),point.value),series:.value("Segment",point.segment))
                        .foregroundStyle(by:.value(L("用量"),point.series))
                        .lineStyle(StrokeStyle(lineWidth:2)).interpolationMethod(.linear)
                    if days.count==1 || point.date == selectedDay?.date {
                        PointMark(x:.value(L("日期"),point.date),y:.value(L(title(metric)),point.value))
                            .foregroundStyle(by:.value(L("用量"),point.series)).symbolSize(28)
                    }
                }
                if let date=selectedDay?.date {
                    RuleMark(x:.value(L("日期"),date)).foregroundStyle(Color.secondary.opacity(0.35)).lineStyle(StrokeStyle(dash:[3,3]))
                }
            }
            .chartForegroundStyleScale(range:metric == "tokens" && tokenBreakdown ? [Color.teal,.blue,.orange,.purple]:[color(metric)])
            .chartYScale(domain:.automatic(includesZero:true))
            .chartXScale(domain:domain,range:.plotDimension(padding:12))
            .chartXAxis {AxisMarks(values:.automatic(desiredCount:5)) {value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel {if let date=value.as(Date.self) {
                    Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))).font(.system(size:9)).fixedSize()
                }}
            }}
            .chartYAxis {AxisMarks(position:.leading,values:.automatic(desiredCount:3)) {value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {if let n=value.as(Double.self) {
                    Text((metric == "amount" || metric == "cumulative") ? String(format:"$%.2f",n):compactNumber(n)).font(.system(size:9)).frame(width:46,alignment:.trailing)
                }}
            }}
            .chartLegend(position:.bottom,alignment:.leading,spacing:8)
            .chartLegend(metric == "tokens" && tokenBreakdown ? .visible:.hidden)
            .chartOverlay {proxy in
                GeometryReader {geometry in
                    Rectangle().fill(Color.clear).contentShape(Rectangle()).onContinuousHover {phase in
                        if case .active(let location)=phase,let anchor=proxy.plotFrame {
                            let frame=geometry[anchor]
                            if location.x>=frame.minX && location.x<=frame.maxX,
                               let date=proxy.value(atX:location.x-frame.minX,as:Date.self) {selection=days[nearestIndex(date)].date}
                        }
                    }.gesture(SpatialTapGesture().onEnded {event in
                        if let anchor=proxy.plotFrame {
                            let frame=geometry[anchor]
                            if event.location.x>=frame.minX && event.location.x<=frame.maxX,
                               let date=proxy.value(atX:event.location.x-frame.minX,as:Date.self) {selection=days[nearestIndex(date)].date}
                        }
                    })
                }
            }
            .environment(\.timeZone,TimeZone(secondsFromGMT:0)!)
            .frame(height:metric == "tokens" && tokenBreakdown ? 140:112)
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:6) {
                LText("每日趋势").fontWeight(.semibold)
                Spacer()
                ForEach([("amount","费用"),("tokens","Token"),("count","请求"),("cumulative","累计费用")],id:\.0) {key,label in
                    Toggle(isOn:enabled(key)) {
                        Label(L(label),systemImage:metrics.contains(key) ? "checkmark.circle.fill":"circle")
                    }.toggleStyle(.button).controlSize(.small)
                        .tint(metrics.contains(key) ? .teal:.secondary)
                        .disabled(metrics.count==1 && metrics.contains(key))
                }
            }.font(.system(size:11))
            if days.isEmpty || days.allSatisfy({($0.values["count"] ?? 0)==0}) {
                LText("所选区间尚无已收录的用量").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:100)
            } else {
                HStack {
                    LText("移动鼠标或点击图表查看同一天的数据").foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedDay?.id ?? "").monospacedDigit()
                }.font(.system(size:10))
                ForEach(metrics,id:\.self) {metric in chart(metric)}
            }
            LText("按账本时区汇总 · 金额仅含已定价请求").font(.system(size:9)).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            .onChange(of:days.first?.id){selection=nil}
            .onChange(of:days.last?.id){selection=nil}
    }
}

struct CostView: View {
    @ObservedObject var model: Model
    @State private var activityView = "conversation"
    @State private var periodPopover=false
    var expand: () -> Void
    var hide: () -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var statusColor:Color {model.demo ? .orange:(model.historyActive ? .green:.secondary)}
    var body:some View {
        Group {
            if model.expanded {
                VStack(spacing:0) {
                    HStack(spacing:10) {
                        HStack {
                            LText("AI Cost Estimator").font(.system(size:14,weight:.semibold))
                            Spacer(minLength:0)
                        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:4)
                            .onChanged {model.onDrag?($0.translation,false)}
                            .onEnded {model.onDrag?($0.translation,true)})
                            .localizedHelp("拖动标题可移动窗口")
                        HStack(spacing:5) {
                            Circle().fill(statusColor).frame(width:5,height:5)
                            LText(model.demo ? "演示":(model.snapshot.isEmpty ? "载入中":(model.historyActive ? "正在跟进":"已暂停")))
                        }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Picker("Language / 语言",selection:Binding(get:{model.language},set:{model.setLanguage($0)})) {
                            Text("中").tag("zh-Hans");Text("EN").tag("en")
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width:70)
                            .accessibilityLabel("Language / 语言")
                        Menu {
                            Button(L("显示与月费")) {model.tab="设置"}
                            Button(L("官方定价与口径")) {model.tab="价格"}
                            Divider()
                            if model.historyActive {Button(L("暂停同步")) {model.send("disable-history-sync")}}
                            else {Button(L("连接自动同步…")) {model.connectHistory()}}
                            Button(L("补录到现在")) {model.send("sync-history-once",["consent":true])}
                            Divider()
                            Button(L(model.demo ? "返回真实账本":"试用虚构演示")) {model.switchMode()}
                        } label:{Image(systemName:"ellipsis").frame(width:22,height:22)}
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().localizedAccessibilityLabel("更多选项")
                        Button(action:hide) {Image(systemName:"minus").frame(width:22,height:22)}.localizedHelp("隐藏 · ⌃⌥L 唤回").localizedAccessibilityLabel("隐藏浮窗")
                        Button(action:expand) {Image(systemName:"arrow.down.right.and.arrow.up.left").frame(width:22,height:22)}.localizedHelp("收起为小浮窗").localizedAccessibilityLabel("收起")
                    }.buttonStyle(.plain).padding(.horizontal,22).padding(.top,16).padding(.bottom,12)
                    HStack {
                        Spacer()
                        Picker(L("页面"),selection:$model.tab) {
                            LText("概览").tag("概览");LText("明细").tag("用量");LText("最近用量").tag("活动");LText("连接").tag("连接")
                            if model.tab == "价格" {LText("定价").tag("价格")}
                            if model.tab == "设置" {LText("设置").tag("设置")}
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width:model.tab == "价格" || model.tab == "设置" ? 420:340).onChange(of:model.tab) {
                            if model.tab == "概览" || model.tab == "活动" {model.agent="全部";model.selectedModel="全部模型";model.selectedSpeed="all"}
                            model.filter()
                        }
                        Spacer()
                    }.padding(.horizontal,22).padding(.bottom,14)
                    Divider().opacity(0.5)
                    expandedBody.frame(maxWidth:.infinity,maxHeight:.infinity).padding(.horizontal,22).padding(.top,18).padding(.bottom,14)
                }
            } else {
                Button {if Date().timeIntervalSince1970-model.lastDragAt > 0.3 {expand()}} label:{
                    HStack(spacing:9) {
                        Circle().fill(statusColor).frame(width:5,height:5)
                        LText(model.metricLabel).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Spacer(minLength:2)
                        LText(model.headline).font(.system(size:16,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }.padding(.horizontal,14).frame(maxWidth:.infinity,maxHeight:.infinity)
                }.buttonStyle(.plain).contentShape(Capsule())
                    .highPriorityGesture(DragGesture(minimumDistance:4).onChanged {model.lastDragAt=Date().timeIntervalSince1970;model.onDrag?($0.translation,false)}.onEnded {model.lastDragAt=Date().timeIntervalSince1970;model.onDrag?($0.translation,true)})
                    .accessibilityElement(children:.combine).localizedAccessibilityLabel("\(model.metricLabel) \(model.headline)，\(model.demo ? "演示用量":"API 等价估算")，\(model.historyActive ? "自动跟进中":"同步暂停")，点击展开总账单")
                    .localizedHelp("\(model.demo ? "虚构演示":model.historyLabel) · API 等价估算，非实际扣款 · 点击查看账单")
                    .contextMenu {
                        ForEach(metricChoices,id:\.0) {item in Button(L((model.metric == item.0 ? "✓ ":"")+item.1)) {model.setMetric(item.0)}}
                        Divider();Button(L("打开总账单"),action:expand);Button(L("隐藏浮窗"),action:hide)
                    }
            }
        }.frame(width:model.expanded ? 640:188,height:model.expanded ? 610:40,alignment:.topLeading).foregroundStyle(Color.primary)
    }
    var expandedBody:some View {
        VStack(alignment:.leading,spacing:12) {
            if model.tab == "概览" {overview}
            else if model.tab == "用量" {usage}
            else if model.tab == "活动" {activity}
            else if model.tab == "连接" {connections}
            else if model.tab == "设置" {settings}
            else {prices}
            Spacer(minLength:0)
            if !model.error.isEmpty {LText(model.error).font(.system(size:11)).foregroundStyle(.orange)}
            Divider().opacity(0.35)
            HStack(spacing:6) {
                Circle().fill(statusColor).frame(width:4,height:4)
                LText(model.demo ? "虚构演示":(model.historyActive ? "本机 Codex · 自动跟进":"本机 Codex · 已暂停"))
                Spacer()
                LText("最近用量 \(model.timeOnly(model.historySync["last_event"]))")
                LText("· 北京时间").foregroundStyle(.tertiary)
            }.font(.system(size:9)).foregroundStyle(.secondary)
            .localizedHelp(model.historyLabel+"；只覆盖已写入这台 Mac 的用量。")
        }
    }
    var overview:some View {
        let s=model.snapshot
        let valid=number(s["count"])>number(s["unpriced"])
        let value=number(s["amount"])
        let plan=s["plan"] as? NSNumber
        let agents=s["agents"] as? [String] ?? []
        let subscriptions=s["subscriptions"] as? [String:[String:Any]] ?? [:]
        let detected=agents.compactMap {subscriptions[$0]?["state"] as? String == "detected" ? subscriptions[$0]?["label"] as? String:nil}
        return VStack(alignment:.leading,spacing:20) {
            HStack {
                Picker(L("月份"),selection:$model.month) {ForEach(s["months"] as? [String] ?? [],id:\.self){LText($0)}}.labelsHidden().frame(width:125).onChange(of:model.month){model.filter()}
                LText(agents.joined(separator:" + ")).font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                LText("每月回顾").font(.system(size:11)).foregroundStyle(.secondary)
            }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:10) {
                    LText("参考月费").font(.system(size:12)).foregroundStyle(.secondary)
                    LText(plan.map{money($0.doubleValue)} ?? (detected.isEmpty ? "未识别套餐":detected.joined(separator:" + "))).font(.system(size:plan == nil ? 21:30,weight:.medium,design:.rounded)).monospacedDigit()
                    if plan == nil && !detected.isEmpty {LText("月费金额未返回").font(.system(size:10)).foregroundStyle(.secondary)}
                    Button(L("查看套餐")){model.tab="设置"}.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(.blue)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(20).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:18))
                VStack(alignment:.leading,spacing:10) {
                    LText("已用 API 等价值").font(.system(size:12)).foregroundStyle(.secondary)
                    LText(valid ? money(value):"—").font(.system(size:30,weight:.medium,design:.rounded)).monospacedDigit()
                    LText("按已收录用量折算").font(.system(size:11)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(20).background(Color.teal.opacity(0.10),in:RoundedRectangle(cornerRadius:18))
            }
            VStack(alignment:.leading,spacing:9) {
                if let p=plan,p.doubleValue>0,valid {
                    HStack(alignment:.firstTextBaseline,spacing:8) {
                        LText(String(format:"%.1f×",value/p.doubleValue)).font(.system(size:34,weight:.medium,design:.rounded)).foregroundStyle(.teal)
                        LText("参考月费的 API 用量价值").font(.system(size:13))
                    }
                    LText("这是用量价值对比，不是实际节省金额。").font(.system(size:11)).foregroundStyle(.secondary)
                } else {
                    LText("这月的订阅值不值？").font(.system(size:19,weight:.medium))
                    LText("确认套餐月费后，就能在这里对比。").font(.system(size:12)).foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.35)
            HStack(alignment:.top,spacing:24) {
                summaryItem("本月 Token",mixBrief(s["mix"]))
                summaryItem("模型请求",tokenText(s["count"]))
                summaryItem("有记录的天数",tokenText(s["active_days"]))
            }
            HStack {
                Button(L("查看模型与费用明细")){model.tab="用量"}.buttonStyle(.borderedProminent).tint(.teal)
                Spacer()
                Button(L("查看最近用量")){model.tab="活动"}.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size:12))
            LText("仅本机已收录用量 · API 估算非账单 · 自然月非订阅账期").font(.system(size:10)).foregroundStyle(.secondary)
            if number(s["unpriced"])>0 {LText("仍有未定价记录，金额仅包含可定价部分。").font(.system(size:10)).foregroundStyle(.secondary)}
        }
    }
    func summaryItem(_ label:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:7) {
            LText(label).font(.system(size:11)).foregroundStyle(.secondary)
            LText(value).font(.system(size:19,weight:.medium,design:.rounded)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var rangeEditor:some View {
        RangeCalendar(start:$model.draftStart,end:$model.draftEnd,calendar:model.reportCalendar,language:model.language,
            cancel:{periodPopover=false},apply:{if model.applyRange(){periodPopover=false}})
    }
    var periodControls:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Button {model.prepareRange();periodPopover=true} label:{
                    Label(model.periodLabel,systemImage:"calendar").monospacedDigit()
                }.localizedAccessibilityLabel("选择时间区间").accessibilityValue(model.periodLabel)
                Spacer()
                Button {model.exportDaily()} label:{Label(L("导出 CSV"),systemImage:"square.and.arrow.up")}
                    .disabled(model.loading || (model.snapshot["daily"] as? [[String:Any]] ?? []).isEmpty)
            }.popover(isPresented:$periodPopover,arrowEdge:.bottom){rangeEditor}
            HStack(spacing:8) {
                ForEach([("7","近7天"),("30","近30天"),("month","本月"),("last","上月"),("all","全部")],id:\.0) {key,label in
                    Button(L(label)){model.choosePeriod(key)}
                }
                Spacer()
            }
            HStack(spacing:8) {
                Spacer(minLength:0)
                let agents=model.snapshot["agents"] as? [String] ?? []
                if agents.count>1 {
                    Picker(L("Agent"),selection:$model.agent) {
                        LText("全部 Agent").tag("全部");ForEach(agents,id:\.self){LText($0).tag($0)}
                    }.labelsHidden().frame(width:116).onChange(of:model.agent){model.selectedModel="全部模型";model.filter()}
                } else {LText(agents.first ?? "暂无来源").foregroundStyle(.secondary)}
                Picker(L("模型"),selection:$model.selectedModel) {
                    LText("全部模型").tag("全部模型")
                    ForEach(model.snapshot["models"] as? [String] ?? [],id:\.self){LText($0)}
                }.labelsHidden().frame(width:185).onChange(of:model.selectedModel){model.filter()}
                speedPicker
                LText("USD · \(model.snapshot["timezone"] as? String ?? "UTC")").font(.system(size:9)).foregroundStyle(.secondary)
                Spacer(minLength:0)
            }
        }.frame(maxWidth:.infinity).controlSize(.small).font(.system(size:11))
    }
    var usage:some View {
        VStack(alignment:.leading,spacing:12) {
            periodControls
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack(alignment:.bottom) {
                        VStack(alignment:.leading,spacing:6) {
                            LText("区间 API 等价值").font(.system(size:11)).foregroundStyle(.secondary)
                            LText(number(model.snapshot["count"]) > number(model.snapshot["unpriced"]) ? money(number(model.snapshot["amount"])):"—")
                                .font(.system(size:32,weight:.medium,design:.rounded)).monospacedDigit()
                        }
                        Spacer()
                        VStack(alignment:.trailing,spacing:6) {
                            LText(mixBrief(model.snapshot["mix"])+" tokens").font(.system(size:15,weight:.medium,design:.rounded))
                            LText("\(Int(number(model.snapshot["count"]))) 次模型请求").font(.system(size:10)).foregroundStyle(.secondary)
                        }.padding(.bottom,4)
                    }
                    if model.loading {
                        HStack(spacing:6) {
                            ProgressView().controlSize(.mini)
                            LText("正在更新至").foregroundStyle(.secondary)
                            Text(model.periodLabel).monospacedDigit()
                            Spacer()
                        }.font(.system(size:10))
                    }
                    HStack(spacing:4) {
                        LText(model.loading ? "下方仍显示":"统计区间").foregroundStyle(.secondary)
                        Text((model.snapshot["period_start"] as? String ?? "—")+" — "+(model.snapshot["period_end"] as? String ?? "—")).monospacedDigit()
                        Spacer()
                    }.font(.system(size:10))
                    UsageTrend(days:model.snapshot["daily"] as? [[String:Any]] ?? [],language:model.language).id(model.language)
                    HStack(spacing:5) {
                        Image(systemName:"info.circle").font(.system(size:10))
                        LText(number(model.snapshot["unpriced"]) > 0 ? "\(Int(number(model.snapshot["unpriced"]))) 次暂未定价 · 当前金额仅含已定价部分":"当前已收录请求均可估算")
                        Spacer()
                        Button(L("计算口径")) {model.tab="价格"}.buttonStyle(.plain)
                    }.font(.system(size:10)).foregroundStyle(.secondary)
                    if number(model.snapshot["standard_fallback"])>0 {
                        LText("\(Int(number(model.snapshot["standard_fallback"]))) 次 Fast 按普通价参考").font(.system(size:10)).foregroundStyle(.secondary)
                    }
                    MixBar(mix:model.snapshot["mix"] as? [String:Any] ?? [:]).id(model.language)
                    Divider().opacity(0.4)
                    LText("模型明细").font(.system(size:12,weight:.semibold))
                    VStack(spacing:0) {
                        if model.rows.isEmpty {LText("所选区间尚无已收录的用量").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:60)}
                        ForEach(Array(model.rows.enumerated()),id:\.offset) {_,row in modelRow(row)}
                    }
                    dailyTable
                }.frame(width:596,alignment:.leading).padding(.bottom,10)
            }
        }
    }
    var dailyTable:some View {
        let days=model.snapshot["daily"] as? [[String:Any]] ?? []
        return LazyVStack(alignment:.leading,spacing:10) {
            Divider().opacity(0.4)
            LText("逐日明细").font(.system(size:12,weight:.semibold))
            HStack {
                LText("日期").frame(width:94,alignment:.leading)
                LText("API 等价值").frame(width:106,alignment:.trailing)
                LText("Token").frame(width:100,alignment:.trailing)
                LText("请求").frame(width:70,alignment:.trailing)
                Spacer();LText("未定价").frame(width:75,alignment:.trailing)
            }.font(.system(size:10)).foregroundStyle(.secondary)
            ForEach(Array(days.reversed().enumerated()),id:\.offset) {_,day in
                HStack {
                    Text(day["date"] as? String ?? "").frame(width:94,alignment:.leading)
                    Text((day["amount"] as? NSNumber).map{usd($0.doubleValue)} ?? "—").frame(width:106,alignment:.trailing)
                    Text(tokenBrief(day["tokens"])).frame(width:100,alignment:.trailing)
                    Text(tokenText(day["count"])).frame(width:70,alignment:.trailing)
                    Spacer();Text(tokenText(day["unpriced"])).frame(width:75,alignment:.trailing)
                }.font(.system(size:11)).monospacedDigit().padding(.vertical,5)
                Divider().opacity(0.15)
            }
            LText("空白日期表示未收录请求；不代表没有使用。Token 仅含已知数量。").font(.system(size:10)).foregroundStyle(.secondary)
        }
    }
    var speedPicker:some View {
        Picker(L("档位"),selection:$model.selectedSpeed) {
            LText("全部档位").tag("all")
            LText("Standard").tag("normal")
            LText("Fast").tag("fast")
            LText("Ultrafast").tag("ultrafast")
            LText("Flex").tag("flex")
            LText("档位未知").tag("unknown")
        }.labelsHidden().frame(width:130).controlSize(.small).font(.system(size:10)).onChange(of:model.selectedSpeed){model.filter()}
    }
    func modelRow(_ row:[String:Any])->some View {
        let id=row["model"] as? String ?? ""
        let opened=model.selectedRow == id
        let speeds=row["speeds"] as? [[String:Any]] ?? []
        let fastCount=speeds.filter{["fast","ultrafast"].contains($0["speed"] as? String ?? "")}.reduce(0){$0+Int(number($1["count"]))}
        return VStack(alignment:.leading,spacing:10) {
            Button {model.selectedRow=opened ? "":id} label:{
                HStack(spacing:12) {
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:7) {
                            LText(id).font(.system(size:12,weight:.medium))
                            if fastCount>0 {LText("加速 \(fastCount) 次请求").font(.system(size:9,weight:.medium)).foregroundStyle(.blue).padding(.horizontal,6).padding(.vertical,2).background(Color.blue.opacity(0.08),in:Capsule())}
                        }
                        HStack(spacing:6) {
                            LText(mixBrief(row["mix"])+" tokens")
                            LText("· \(Int(number(row["count"]))) 次请求")
                            if number(row["unpriced"]) > 0 {LText("· \(Int(number(row["unpriced"]))) 未定价").foregroundStyle(.orange)}
                        }.font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    LText(number(row["count"]) > number(row["unpriced"]) ? money(number(row["amount"])):"未定价")
                        .font(.system(size:14,weight:.medium,design:.rounded)).monospacedDigit()
                    Image(systemName:opened ? "chevron.up":"chevron.down").font(.system(size:8)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).localizedAccessibilityLabel("\(id) 明细")
            if opened {
                speedTable(speeds)
                MixBar(mix:row["mix"] as? [String:Any] ?? [:],detailed:false).id(model.language)
                bucketTable(row)
                if let reason=row["reason"] as? String,!reason.isEmpty {LText(reason).font(.system(size:10)).foregroundStyle(.orange)}
                if let url=URL(string:row["source"] as? String ?? "") {Link(L("API 等价参考价 · \(model.snapshot["checked"] as? String ?? "") ↗"),destination:url).font(.system(size:10))}
            }
            Divider().opacity(0.25)
        }.padding(.vertical,9)
    }
    func speedTable(_ speeds:[[String:Any]])->some View {
        VStack(spacing:7) {
            HStack {
                LText("记录档位");Spacer()
                LText("请求 / 占比").frame(width:110,alignment:.trailing)
                LText("Token").frame(width:100,alignment:.trailing)
                LText("API 等价值").frame(width:100,alignment:.trailing)
            }.foregroundStyle(.secondary)
            ForEach(Array(speeds.enumerated()),id:\.offset) {_,s in
                HStack {
                    VStack(alignment:.leading,spacing:2) {
                        LText(speedName(s["speed"])).fontWeight(.medium)
                        if number(s["standard_fallback"])>0 {LText("普通价参考").font(.system(size:9)).foregroundStyle(.secondary)}
                    }
                    Spacer()
                    LText("\(Int(number(s["count"]))) · \(String(format:"%.1f%%",number(s["request_share"])*100))").frame(width:110,alignment:.trailing)
                    LText(mixBrief(s["mix"])).frame(width:100,alignment:.trailing)
                    LText(number(s["count"])>number(s["unpriced"]) ? usd(number(s["amount"])):"未定价").frame(width:100,alignment:.trailing)
                }.monospacedDigit()
            }
            LText("按记录档位分组；占比按请求数。Token 不翻倍；Fast 优先用官方 Fast 价，无已核验 Fast 价时用同模型普通价参考。")
                .foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }.font(.system(size:10)).padding(10).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9))
    }
    var activity:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    LText("最近用量").font(.system(size:22,weight:.semibold,design:.rounded))
                    LText(activityView == "conversation" ? "所选月份 · 所选档位 · 此 Mac 已收录用量":"此 Mac 的全部已落盘对话 · 最新 40 条").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment:.trailing,spacing:8) {
                    HStack(spacing:5) {Circle().fill(statusColor).frame(width:5,height:5);LText(model.historyActive ? "正在跟进":"已暂停")}
                        .font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker(L("用量视图"),selection:$activityView) {
                    LText("按对话").tag("conversation");LText("逐条请求").tag("requests")
                }.labelsHidden().pickerStyle(.segmented).frame(width:160)
                Spacer()
                if activityView == "conversation" {
                    Picker(L("月份"),selection:$model.month) {
                        ForEach(model.snapshot["months"] as? [String] ?? [],id:\.self){LText($0)}
                    }.labelsHidden().frame(width:125).onChange(of:model.month){model.resetPeriodFilters()}
                }
                speedPicker
            }.controlSize(.small)
            LText("请求用量写入本机后自动更新；未定价请求也会显示 token。").font(.system(size:10)).foregroundStyle(.secondary)
            if !model.demo {
                let info=model.snapshot["conversation_titles"] as? [String:Any] ?? [:]
                HStack {
                    if info["enabled"] as? Bool == true {
                        LText(info["state"] as? String == "loading" ? "正在读取对话标题…":info["state"] as? String == "unavailable" ? "标题暂时无法刷新，稍后可重试。":"对话标题仅在本机显示，不写入用量账本。")
                        Spacer()
                        Button(L("刷新标题")){model.send("refresh-conversation-titles")}
                            .disabled(info["state"] as? String == "loading" || model.serviceUnavailable)
                    } else {
                        Button(L("显示本机对话标题")){model.send("set-conversation-titles",["enabled":true,"consent":true])}
                        Spacer()
                        LText("可在设置中关闭")
                    }
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing:0) {
                    if activityView == "conversation" {
                        let conversations=model.snapshot["conversations"] as? [[String:Any]] ?? []
                        if conversations.isEmpty {
                            LText("所选月份暂无已收录对话用量").foregroundStyle(.secondary).font(.system(size:11)).frame(maxWidth:.infinity,minHeight:80)
                        }
                        ForEach(Array(conversations.enumerated()),id:\.offset) {index,row in conversationRow(row,index:index)}
                    } else {
                    ForEach(Array(model.activity.enumerated()),id:\.offset) {index,e in
                        HStack(alignment:.top,spacing:12) {
                            VStack(spacing:6) {
                                Circle().fill(index == 0 && model.historyActive ? Color.green:Color.secondary.opacity(0.3)).frame(width:5,height:5)
                                Rectangle().fill(Color.secondary.opacity(0.12)).frame(width:1,height:36)
                            }.padding(.top,5)
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    LText(e["model"] as? String ?? "未知模型").font(.system(size:12,weight:.medium))
                                    LText(speedName(e["speed"])+((e["standard_fallback"] as? Bool == true) ? " · 普通价参考":"")).font(.system(size:9,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,6).padding(.vertical,2).background(Color.primary.opacity(0.05),in:Capsule())
                                    LText(model.timeOnly(e["timestamp"])).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                                    Spacer()
                                    LText(mixBrief(e["mix"])+" tokens").font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit()
                                }
                                HStack(spacing:7) {
                                    LText("输入 \(tokenBrief(e["input"]))")
                                    LText("输出 \(tokenBrief(e["output"]))")
                                    LText("缓存读 \(tokenBrief(e["read"]))")
                                    LText("缓存写 \(tokenBrief(e["write"]))")
                                }.font(.system(size:10)).foregroundStyle(.secondary)
                                HStack {
                                    Text((e["agent"] as? String ?? "")+" · "+conversationTitle(e)).lineLimit(1).help(conversationTitle(e))
                                    Spacer()
                                    LText(e["amount"] is NSNumber ? usd(number(e["amount"])):"未定价").monospacedDigit()
                                }.font(.system(size:9)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical,9).accessibilityElement(children:.combine)
                        .localizedHelp("\(model.localTime(e["timestamp"])) 北京时间\n普通输入 \(tokenText(e["input"])) · 输出 \(tokenText(e["output"])) · 缓存读 \(tokenText(e["read"])) · 缓存写 \(tokenText(e["write"]))\n\(e["reason"] as? String ?? "")")
                    }
                    }
                }
            }.id("\(activityView)-\(model.language)")
        }
    }
    func conversationTitle(_ row:[String:Any])->String {
        if let title=row["title"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return title}
        if let key=row["conversation"] as? String {return L("标题暂不可用")+" · "+String(key.prefix(6))}
        return L("未关联用量")
    }
    func conversationRow(_ row:[String:Any],index:Int)->some View {
        let mix=row["mix"] as? [String:Any] ?? [:]
        let values=mix["values"] as? [String:Any] ?? [:]
        let names=(row["models"] as? [String] ?? []).joined(separator:", ")
        return VStack(alignment:.leading,spacing:7) {
            HStack(alignment:.firstTextBaseline) {
                Text(conversationTitle(row)).font(.system(size:12,weight:.medium)).lineLimit(2).help(conversationTitle(row))
                Spacer(minLength:10)
                LText(mixBrief(mix)+" tokens").font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit()
            }
            HStack(spacing:7) {
                LText("输入 \(tokenBrief(values["input"]))")
                LText("输出 \(tokenBrief(values["output"]))")
                LText("缓存读 \(tokenBrief(values["read"]))")
                LText("缓存写 \(tokenBrief(values["write"]))")
                if mix["incomplete"] as? Bool == true {LText("Token 不完整").foregroundStyle(.orange)}
            }.font(.system(size:10)).foregroundStyle(.secondary)
            HStack {
                LText((row["agent"] as? String ?? "")+" · \(Int(number(row["count"]))) 次请求")
                if !names.isEmpty {Text(names).lineLimit(1)}
                Spacer()
                LText(number(row["count"]) > number(row["unpriced"]) ? ((number(row["unpriced"]) > 0 ? L("已定价部分")+" ":"")+usd(number(row["amount"]))):"未定价").monospacedDigit()
                if number(row["unpriced"]) > 0 {LText("\(Int(number(row["unpriced"]))) 次未定价").foregroundStyle(.orange)}
            }.font(.system(size:9)).foregroundStyle(.secondary)
            Divider().opacity(0.25)
        }.padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
    }
    func bucketTable(_ row:[String:Any]) -> some View {
        let buckets=row["buckets"] as? [String:Any] ?? [:]
        let rates=row["applied_rates"] as? [String:Any] ?? [:]
        let costs=row["cost_buckets"] as? [String:Any] ?? [:]
        let noWrite=row["cache_accounting"] as? String == "no_write_premium"
        let codex=row["agent"] as? String == "Codex"
        let keys=noWrite ? ["input","read","output"]:["input","read","write_short","write_long","output"]
        let names=["input":"普通输入","read":"缓存读取","write_short":codex ? "缓存写入 · 30m":"缓存写入 · 5m","write_long":codex ? "缓存写入 · 12h":"缓存写入 · 1h","output":"输出（含推理）"]
        return VStack(spacing:6) {
            Divider().opacity(0.35)
            HStack {LText("Token 桶");Spacer();LText("数量").frame(width:95,alignment:.trailing);LText("适用单价 / 百万").frame(width:100,alignment:.trailing);LText("已定价费用").frame(width:100,alignment:.trailing)}.foregroundStyle(.secondary)
            ForEach(keys,id:\.self) {k in
                HStack {
                    LText(names[k] ?? k);Spacer()
                    LText(tokenText(buckets[k])).frame(width:95,alignment:.trailing)
                    LText(rateText(rates[k])).frame(width:100,alignment:.trailing)
                    LText(number(row["count"]) > number(row["unpriced"]) ? usd(number(costs[k])):"—").frame(width:100,alignment:.trailing)
                }.monospacedDigit()
            }
            if number(row["unpriced"]) > 0 {LText("数量含未定价请求；费用只合计已完整定价的请求。").foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)}
            LText("单价按记录档位与上下文计算；多种单价显示区间。普通价参考会单独标注。")
                .foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            if noWrite {LText("缓存写入包含在普通输入中，无独立写入费。").foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)}
        }.font(.system(size:10))
    }
    var connectedAgents:[String] {model.snapshot["connected_agents"] as? [String] ?? []}
    var settings:some View {
        ScrollView { VStack(alignment:.leading,spacing:22) {
            HStack {
                LText("语言 / Language").font(.system(size:13,weight:.medium))
                Spacer()
                Picker("Language",selection:Binding(get:{model.language},set:{model.setLanguage($0)})) {
                    Text("中文").tag("zh-Hans");Text("English").tag("en")
                }.labelsHidden().pickerStyle(.segmented).frame(width:180)
            }
            Divider().padding(.vertical,6)

            if connectedAgents.contains("Codex") {
                Toggle(L("显示本机 Codex 对话标题"),isOn:Binding(
                    get:{(model.snapshot["conversation_titles"] as? [String:Any])?["enabled"] as? Bool == true},
                    set:{model.send("set-conversation-titles",["enabled":$0,"consent":$0])}))
                    .toggleStyle(.switch).font(.system(size:12)).disabled(model.demo || model.serviceUnavailable)
                LText("标题只在本机显示，不写入用量账本，也不会上传。").font(.system(size:10)).foregroundStyle(.secondary)
            }

            VStack(alignment:.leading,spacing:12) {
                LText("小浮窗显示什么").font(.system(size:16,weight:.semibold))
                LText("随时右键浮窗也能切换。仅改变显示，不开启采集。").font(.system(size:11)).foregroundStyle(.secondary)
                ForEach(metricChoices,id:\.0) {item in
                    Button {model.setMetric(item.0)} label:{
                        HStack {Image(systemName:model.metric == item.0 ? "checkmark.circle.fill":"circle").foregroundStyle(model.metric == item.0 ? Color.blue:Color.secondary);LText(item.1);Spacer()}
                            .padding(10).background(Color.white.opacity(model.metric == item.0 ? 0.65:0.25),in:RoundedRectangle(cornerRadius:10))
                    }.buttonStyle(.plain).font(.system(size:12))
                }
            }
            VStack(alignment:.leading,spacing:10) {
                LText("套餐 · 连接后自动识别").font(.system(size:16,weight:.semibold))
                ForEach(connectedAgents,id:\.self) {provider in
                    let states=model.snapshot["subscriptions"] as? [String:[String:Any]] ?? [:]
                    let item=states[provider] ?? [:]
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            LText(provider).fontWeight(.medium)
                            LText(item["label"] as? String ?? "连接后自动识别").foregroundStyle(.secondary)
                            Spacer()
                            if item["reference_usd"] is NSNumber {LText(money(number(item["reference_usd"]))+" / 月参考").monospacedDigit()}
                            Button(L("识别套餐…")){model.detectPlan(provider)}.disabled(item["state"] as? String == "loading")
                        }
                        LText(item["detail"] as? String ?? "").font(.system(size:10)).foregroundStyle(.secondary)
                        let overrides=model.snapshot["plan_overrides"] as? [String:Any] ?? [:]
                        if overrides[provider] is NSNumber {
                            LText("比较使用你的调整值："+money(number(overrides[provider]))+" / 月").font(.system(size:10)).foregroundStyle(.blue)
                        }
                        HStack {
                            LText("你的月费（美元）")
                            if provider == "Codex" {TextField(L("输入月费"),text:$model.codexPlan).frame(width:90)}
                            if provider == "Claude Code" {TextField(L("输入月费"),text:$model.claudePlan).frame(width:90)}
                            Button(L("保存月费")){model.savePrefs()}
                        }.textFieldStyle(.roundedBorder)
                        if let source=item["source"] as? String,let url=URL(string:source),!source.isEmpty {
                            Link(L("官方套餐价格 · 核对 \(item["checked"] as? String ?? "")"),destination:url).font(.system(size:10))
                        }
                    }.padding(10).background(Color.white.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                }.font(.system(size:11))
                LText("识别本机 CLI 的套餐类型；官网参考价不等于实际扣款。订阅与用量接收状态分别显示。").font(.system(size:10)).foregroundStyle(.secondary)
                Button(L("恢复自动")){model.codexPlan="";model.claudePlan="";model.send("reset-plan-overrides")}.font(.system(size:11))
            }
            HStack {
                Picker(L("月份时区"),selection:$model.timezone) {LText("UTC").tag("UTC");LText("本机时区").tag("本机时区")}.frame(width:240)
                Button(L("保存时区")){model.month="";model.savePrefs()}
            }.font(.system(size:12))
            LText("拖动小浮窗可移动；点击打开账单；右键隐藏。点击菜单栏金额或重新打开应用可唤回。").font(.system(size:11)).foregroundStyle(.secondary)
            Button(L("打开本机数据文件夹")) {NSWorkspace.shared.open(model.dataURL)}.font(.system(size:11))
            Spacer()
        }.padding(.top,6) }
    }
    var connections: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            if connectedAgents.contains("Codex") {
            infoCard("Codex · 自动同步",model.historyLabel,"自动跟进此 Mac 保存的用量；文件变化时更新，另每 5 秒补查。不会上传或保存对话正文。")
            HStack {
                if model.historyActive {Button(L("暂停自动同步")) {model.send("disable-history-sync")}}
                else {Button(L("连接自动同步…")) {model.connectHistory()}}
                Button(L("补录到现在")) {model.send("sync-history-once",["consent":true])}
            }
            LText("最近检查：\(model.localTime(model.historySync["last_scan"])) 北京时间")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if let error=model.historySync["error"] as? String,!error.isEmpty {LText(error).font(.system(size:11)).foregroundStyle(.orange)}
            }
            if connectedAgents.contains("Claude Code") {
            infoCard("Claude Code",number(model.snapshot["received"]) > 0 ? "已收到 API request 事件 · 仅覆盖新会话":"实验支持 · 尚未验证真实会话","仅收集从这里启动的新 CLI 会话。已有会话和历史用量不包含。")
            HStack {
                Button(L("连接 Claude 新会话…")) {model.connectClaude()}
                if model.snapshot["receiving"] as? Bool == true {Button(L("断开采集")) {model.send("disconnect")}}
            }
            }
            Menu(L("添加连接")) {
                if !connectedAgents.contains("Codex") {Button("Codex"){model.connectHistory()}}
                if !connectedAgents.contains("Claude Code") {Button("Claude Code"){model.connectClaude()}}
            }.disabled(connectedAgents.contains("Codex") && connectedAgents.contains("Claude Code"))
            if let message=model.snapshot["message"] as? String,message != "尚未连接真实来源 · 空账本不代表零消费" {LText(message).font(.system(size:10)).foregroundStyle(.secondary)}
            if connectedAgents.contains("Codex") {DisclosureGroup(L("高级：Codex hook")) {
                VStack(alignment:.leading,spacing:10) {
                    LText("可选接入方式；不会替你安装或信任 hook。桌面真实投递尚未验收，当前本机同步不依赖它。")
                    HStack {
                        Button(L("准备接入文件")) {model.send("prepare-codex")}
                        if model.snapshot["codex_enabled"] as? Bool == true {Button(L("停止 Codex 接收")) {model.send("disable-codex")}}
                        else {Button(L("允许本次接收…")) {model.allowCodex()}}
                    }
                    LText("已收录 \(Int(number(model.snapshot["codex_count"]))) 条 hook · 拒收 \(Int(number(model.snapshot["codex_rejected"]))) 次投递")
                }.font(.system(size:11)).padding(.top,8)
            }
            }
            LText("仅覆盖这台 Mac 上已收录的记录。其他设备、未同步的云端记录及缺失用量不在内。自然月不等于订阅账期。")
                .font(.system(size:11)).foregroundStyle(.secondary)
        }}
    }
    func infoCard(_ title:String,_ status:String,_ detail:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            LText(title).font(.system(size:17,weight:.semibold))
            LText(status).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            LText(detail).font(.system(size:11)).foregroundColor(dim).lineSpacing(4)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,6)
    }
    var prices: some View {
        ScrollView { VStack(alignment:.leading,spacing:16) {
            LText("API 等价参考").font(.system(size:19,weight:.semibold))
            LText("用量按公开 API 单价折算，不是实际扣款。金额只包含可定价的记录；展开模型可查看输入、输出与缓存明细。")
                .font(.system(size:12)).foregroundStyle(.secondary)
            Link(L("OpenAI 官方价表 ↗"),destination:URL(string:"https://developers.openai.com/api/docs/pricing")!)
            Link(L("Anthropic 官方价表 ↗"),destination:URL(string:"https://platform.claude.com/docs/en/about-claude/pricing")!)
            LText("报价快照：2026-11-15 · USD / 百万 token").font(.system(size:11)).foregroundStyle(.secondary)
            LText("历史月份使用同一报价快照。工具费用、税费、地域附加费和订阅扣款不包含。缺少必要用量或未知模型保持未定价。")
                .font(.system(size:11)).foregroundStyle(.secondary)
            Button(L("打开逐模型价表")) {NSWorkspace.shared.open(model.resource.appendingPathComponent("pricing.json"))}
        }.frame(maxWidth:.infinity,alignment:.leading)}
    }

}

final class FloatingPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var panel: FloatingPanel!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var uiTest = CommandLine.arguments.contains("--ui-test")
    var placement=WindowPlacement()
    var changingFrame=false
    var dragOrigin: NSPoint?
    var dragMouseOrigin: NSPoint?
    var hosting:NSHostingView<CostView>!
    lazy var sourceWatcher=UsageFileWatcher { [weak self] in self?.model.send("history-change") }
    func applicationDidFinishLaunching(_ n:Notification) {
        NSApp.setActivationPolicy(.accessory)
        rebuildMenus()
        model.onLanguageChange = { [weak self] in self?.rebuildMenus() }
        panel=FloatingPanel(contentRect:NSRect(x:0,y:0,width:188,height:40),
            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title="AI Cost Estimator"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent=true
        panel.isMovableByWindowBackground=false; panel.level = .floating
        panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque=false; panel.hasShadow=true
        panel.appearance=nil
        panel.delegate=self
        model.onDrag = { [weak self] delta,ended in
            guard let self=self else{return}
            // Read pointer position only while the user is dragging this view.
            // Screen coordinates avoid feedback when the moving window changes local coordinates.
            let mouse=NSEvent.mouseLocation
            if self.dragOrigin == nil {
                self.dragOrigin=self.panel.frame.origin
                self.dragMouseOrigin=NSPoint(x:mouse.x-delta.width,y:mouse.y+delta.height)
            }
            if let origin=self.dragOrigin,let start=self.dragMouseOrigin {
                self.panel.setFrameOrigin(NSPoint(x:origin.x+mouse.x-start.x,y:origin.y+mouse.y-start.y))
            }
            if ended {
                self.dragOrigin=nil;self.dragMouseOrigin=nil;self.clamp()
                if self.model.expanded {self.placement.movedExpanded(to:self.panel.frame,screens:self.screens);self.savePosition()}
            }
        }
        hosting=NSHostingView(rootView:CostView(model:model,expand:{[weak self] in self?.toggleExpanded()},hide:{[weak self] in self?.hide()}))
        hosting.sizingOptions=[]
        updateSurface()
        restorePosition()
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.target=self;status.button?.action=#selector(statusClick)
        status.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        model.onChange={ [weak self] in
            guard let self=self else{return}
            self.status.button?.title=self.model.headline
            self.status.button?.toolTip=L("AI Cost Estimator · \(self.model.metricLabel) · API 等价估算，仅已定价部分")
            if self.model.historyActive {
                self.model.sourceWatcherActive=self.sourceWatcher.start()
            } else {self.sourceWatcher.stop();self.model.sourceWatcherActive=false}
        }
        var eventType=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,data in
            guard let data=data else{return noErr}
            let delegate=Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async {delegate.toggleVisible()}
            return noErr
        },1,&eventType,Unmanaged.passUnretained(self).toOpaque(),nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L),UInt32(controlKey|optionKey),EventHotKeyID(signature:0x4C4D4354,id:1),GetApplicationEventTarget(),0,&hotKey)
        model.start()
        panel.orderFrontRegardless()
        if uiTest { scheduleUITest() }
    }
    func rebuildMenus() {
        let mainMenu=NSMenu()
        let appItem=NSMenuItem(title:"AI Cost Estimator",action:nil,keyEquivalent:"")
        let appMenu=NSMenu(title:"AI Cost Estimator")
        appMenu.addItem(withTitle:L("显示 / 隐藏浮窗"),action:#selector(menuToggle),keyEquivalent:"l").target=self
        appMenu.addItem(withTitle:L("退出 AI Cost Estimator"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;mainMenu.addItem(appItem)
        let editItem=NSMenuItem(title:L("编辑"),action:nil,keyEquivalent:"")
        let edit=NSMenu(title:L("编辑"))
        edit.addItem(withTitle:L("全选"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        edit.addItem(withTitle:L("复制"),action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:L("粘贴"),action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:L("剪切"),action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        editItem.submenu=edit;mainMenu.addItem(editItem);NSApp.mainMenu=mainMenu
    }
    func updateSurface() {
        if #available(macOS 26.0,*),let old=panel.contentView as? NSGlassEffectView {old.contentView=nil}
        hosting.removeFromSuperview()
        // Each material owns a fresh hosting view. Reparenting a live SwiftUI layout
        // between vibrancy and Glass can leave a stale sizing transaction on collapse.
        hosting=NSHostingView(rootView:CostView(model:model,expand:{[weak self] in self?.toggleExpanded()},hide:{[weak self] in self?.hide()}))
        hosting.sizingOptions=[]
        hosting.frame=NSRect(origin:.zero,size:panel.frame.size)
        hosting.autoresizingMask=[]
        if #available(macOS 26.0,*) {
            let glass=NSGlassEffectView(frame:NSRect(origin:.zero,size:panel.frame.size))
            glass.style = .regular;glass.cornerRadius=model.expanded ? 22:20
            glass.wantsLayer=true;glass.layer?.masksToBounds=true;glass.layer?.cornerRadius=glass.cornerRadius
            hosting.wantsLayer=true;hosting.layer?.backgroundColor=NSColor.clear.cgColor
            glass.contentView=hosting;panel.contentView=glass
        } else {
            let material=NSVisualEffectView(frame:NSRect(origin:.zero,size:panel.frame.size))
            material.material = model.expanded ? .popover:.hudWindow
            material.blendingMode = .behindWindow;material.state = .active
            material.wantsLayer=true;material.layer?.cornerRadius=model.expanded ? 22:20;material.layer?.masksToBounds=true
            hosting.frame=material.bounds;hosting.autoresizingMask=[.width,.height]
            material.addSubview(hosting);panel.contentView=material
        }
    }
    func restorePosition() {
        let path=model.dataURL.appendingPathComponent("window.json")
        if let data=try? Data(contentsOf:path),let d=try? JSONSerialization.jsonObject(with:data) as? [String:Double],let x=d["x"],let y=d["y"],x.isFinite,y.isFinite {
            setPanelFrame(NSRect(origin:NSPoint(x:x,y:y),size:panel.frame.size))
        } else if let screen=NSScreen.main?.visibleFrame {
            setPanelFrame(NSRect(origin:NSPoint(x:screen.maxX-380,y:screen.maxY-180),size:panel.frame.size))
        }
        clamp()
    }
    var screens:[NSRect] {NSScreen.screens.map(\.visibleFrame)}
    func setPanelFrame(_ frame:NSRect) {
        let previous=changingFrame;changingFrame=true
        panel.setFrame(frame,display:true,animate:false)
        changingFrame=previous
    }
    func clamp() {
        setPanelFrame(WindowPlacement.clamped(panel.frame,to:screens))
        savePosition()
    }
    func windowDidMove(_ n:Notification) {
        guard let panel=panel,!changingFrame else{return}
        if model.expanded {placement.movedExpanded(to:panel.frame,screens:screens)}
        savePosition()
    }
    func savePosition() {
        guard let panel=panel else{return}
        let origin=placement.savedOrigin(for:panel.frame,expanded:model.expanded)
        let values=["x":origin.x,"y":origin.y]
        try? FileManager.default.createDirectory(at:model.dataURL,withIntermediateDirectories:true)
        if let d=try? JSONSerialization.data(withJSONObject:values) {try? d.write(to:model.dataURL.appendingPathComponent("window.json"),options:.atomic)}
    }
    func toggleExpanded() {
        let frame:NSRect
        if model.expanded {frame=placement.collapse(from:panel.frame,screens:screens)}
        else {
            frame=placement.expand(from:panel.frame,screens:screens)
            model.tab="概览";model.agent="全部";model.selectedModel="全部模型";model.selectedSpeed="all";model.filter()
        }
        changingFrame=true
        model.expanded.toggle()
        panel.allowsKeyboard=model.expanded
        panel.isMovableByWindowBackground=false
        setPanelFrame(frame)
        updateSurface()
        changingFrame=false
        savePosition()
        if !model.expanded {panel.resignKey()}
    }
    func hide() {panel.orderOut(nil);if uiTest {record("manual-hide",!panel.isVisible)}}
    func toggleVisible() {if panel.isVisible {hide()} else {panel.orderFrontRegardless();if uiTest {record("manual-reopen",panel.isVisible)}}}
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu()
            menu.addItem(withTitle:L("显示 / 隐藏浮窗"),action:#selector(menuToggle),keyEquivalent:"").target=self
            menu.addItem(withTitle:L("打开应用所在文件夹"),action:#selector(reveal),keyEquivalent:"").target=self
            menu.addItem(.separator())
            menu.addItem(withTitle:L("退出 AI Cost Estimator"),action:#selector(quit),keyEquivalent:"q").target=self
            status.menu=menu; status.button?.performClick(nil); status.menu=nil
        } else {toggleVisible()}
    }
    @objc func menuToggle(){toggleVisible()}
    @objc func reveal(){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
    @objc func quit(){NSApp.terminate(nil)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {panel.orderFrontRegardless();return true}
    func applicationWillTerminate(_ n:Notification){savePosition();sourceWatcher.stop();model.stop()}
    func scheduleUITest() {
        // Drives the exact production actions on the live NSPanel; never connects a vendor.
        let actions:[(Double,()->Void)] = [
            (2,{self.capture("01-compact")}),
            (3,{self.toggleExpanded()}),
            (5,{self.capture("02-expanded");self.model.send("demo-refresh")}),
            (7,{self.capture("03-refreshed");self.hide()}),
            (8,{self.record("hidden", !self.panel.isVisible);self.toggleVisible()}),
            (9,{self.record("reopened", self.panel.isVisible);self.capture("04-reopened")}),
            (10,{let months=self.model.snapshot["months"] as? [String] ?? [];if let last=months.last {self.model.month=last;self.model.filter()}}),
            (12,{self.capture("05-previous-month");self.model.selectedModel="claude-opus-5-5";self.model.filter()}),
            (14,{self.capture("06-model-filter");self.model.tab="连接"}),
            (16,{self.capture("07-coverage");self.model.tab="价格"}),
            (18,{self.capture("08-sources");self.model.tab="用量";self.model.month="";self.model.selectedModel="全部模型";self.model.send()}),
            (20,{self.toggleExpanded();self.record("nonactivating",self.panel.styleMask.contains(.nonactivatingPanel));self.capture("09-final-compact")})]
        for (delay,action) in actions {DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:action)}
    }
    func capture(_ name:String) {
        guard let view=panel.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let dir=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence/screenshots")
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        if let data=bitmap.representation(using:.png,properties:[:]) {try? data.write(to:dir.appendingPathComponent(name+".png"))}
        record(name,panel.isVisible)
    }
    func record(_ name:String,_ pass:Bool) {
        let dir=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("evidence")
        let url=dir.appendingPathComponent("ui-runtime.jsonl")
        let row:[String:Any] = ["check":name,"pass":pass,"visible":panel.isVisible,"key":panel.isKeyWindow,"main":panel.isMainWindow,"x":panel.frame.minX,"y":panel.frame.minY,"month":model.month,"model":model.selectedModel,"amount":number(model.snapshot["amount"]),"current_amount":number(model.snapshot["current_amount"]),"rows":model.rows.count]
        if let data=try? JSONSerialization.data(withJSONObject:row) {
            if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
            if let handle=try? FileHandle(forWritingTo:url) {_ = try? handle.seekToEnd();try? handle.write(contentsOf:data+Data([10]));try? handle.close()}
        }
    }
}

@main
struct LMCostApplication {
    static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate
        withExtendedLifetime(delegate) {app.run()}
    }
}
