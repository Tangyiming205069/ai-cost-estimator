import Cocoa
import SwiftUI
import Carbon
import CoreServices

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
    if x>0 && x<0.01 {return "<$0.01"}
    return "$"+x.formatted(.number.precision(.fractionLength(2)).grouping(.automatic).locale(Locale(identifier:"en_US")))
}
func number(_ x:Any?)->Double {(x as? NSNumber)?.doubleValue ?? 0}
func tokenText(_ x:Any?)->String {guard let n=x as? NSNumber else{return "未知"};return n.stringValue}
func tokenBrief(_ x:Any?)->String {guard let n=x as? NSNumber else{return "未知"};return compactNumber(n.doubleValue)}
func mixBrief(_ value:Any?)->String {
    let mix=value as? [String:Any] ?? [:]
    return tokenBrief(mix["total"])
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
    @Published var tab = "用量"
    @Published var agent = "全部"
    @Published var month = ""
    @Published var selectedModel = "全部模型"
    @Published var error = ""
    @Published var selectedRow = ""
    @Published var codexPlan = ""
    @Published var claudePlan = ""
    @Published var timezone = "UTC"
    @Published var prefsLoaded = false
    @Published var metric = "month_cost"
    @Published var loading = false
    @Published var sourceWatcherActive = false
    var backend: Process?
    var input: FileHandle?
    var buffer = Data()
    var queue = DispatchQueue(label: "lm.bridge")
    var onChange: (() -> Void)?
    var onDrag: ((CGSize,Bool) -> Void)?
    var lastDragAt: TimeInterval = 0
    let resource = Bundle.main.resourceURL!
    let dataURL:URL = {
        // Preserve the original user's opted-in ledger without moving or copying it.
        let legacy=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("LM Cost Data",isDirectory:true)
        if FileManager.default.fileExists(atPath:legacy.appendingPathComponent("usage.sqlite3").path) {return legacy}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AI Cost Companion",isDirectory:true)
    }()
    func start() {
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
        do { try p.run(); backend = p; send() }
        catch { self.error = "本机 Python 服务未能启动。此版本需要 /opt/homebrew/bin/python3。" }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.send() }
    }
    func receive(_ obj: [String:Any]) {
        if let e = obj["error"] as? String { error = e }
        if let s = obj["snapshot"] as? [String:Any] {
            guard (month.isEmpty || s["month"] as? String == month),
                  (s["selected_agent"] as? String ?? "全部") == agent,
                  (s["selected_model"] as? String ?? "全部模型") == selectedModel else { return }
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
        var q: [String:Any] = ["action":action,"month":month,"agent":agent,"model":selectedModel]
        q.merge(extras) { _,new in new }
        if let data = try? JSONSerialization.data(withJSONObject:q) {
            do { try input?.write(contentsOf: data + Data([10])) }
            catch { self.error = "本机服务已断开，请重新打开 AI Cost Companion。" }
        }
    }
    func filter() { selectedRow = ""; loading = true; send() }
    var demo: Bool { (snapshot["mode"] as? String ?? "live") == "demo" }
    var activity:[[String:Any]] {snapshot["activity"] as? [[String:Any]] ?? []}
    func timeOnly(_ value:Any?)->String {String(localTime(value).suffix(8))}
    var rows: [[String:Any]] { snapshot["rows"] as? [[String:Any]] ?? [] }
    var history: [String:Any] { snapshot["history"] as? [String:Any] ?? [:] }
    var historySync: [String:Any] {snapshot["history_sync"] as? [String:Any] ?? [:]}
    var historyActive: Bool {historySync["active"] as? Bool == true}
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
        alert.informativeText=L("AI Cost Companion 打开期间，收到此 Mac 的 Codex 历史文件变化通知就检查新增用量，另每 5 秒补查。Codex 将请求用量写入本机后才会显示，不是逐 token 流。\n\n仅保存时间、模型、token 桶、档位与散列去重 ID；不保存对话正文或账户身份，不上传。不会修改 Codex 配置、hook 或遥测。\n\n这个选择会记住；以后打开 AI Cost Companion 会继续同步，退出即停止，可随时暂停。不会创建登录项。")
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
            file.message=L("常见位置未找到 Claude Code。请选官方 CLI；AI Cost Companion 不会自动安装。")
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
    func stop() { try? input?.close(); if backend?.isRunning == true {backend?.terminate()} }
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

struct CostView: View {
    @ObservedObject var model: Model
    var expand: () -> Void
    var hide: () -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var statusColor:Color {model.demo ? .orange:(model.historyActive ? .green:.secondary)}
    var body:some View {
        Group {
            if model.expanded {
                VStack(spacing:0) {
                    HStack(spacing:10) {
                        LText("AI Cost Companion").font(.system(size:14,weight:.semibold))
                        Spacer()
                        HStack(spacing:5) {
                            Circle().fill(statusColor).frame(width:5,height:5)
                            LText(model.demo ? "演示":(model.snapshot.isEmpty ? "载入中":(model.historyActive ? "正在跟进":"已暂停")))
                        }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Menu {
                            Menu("Language / 语言") {
                                Button("English") {model.setLanguage("en")}
                                Button("中文") {model.setLanguage("zh-Hans")}
                            }
                            Button(L("显示与月费")) {model.tab="设置"}
                            Button(L("官方定价与口径")) {model.tab="价格"}
                            Divider()
                            if model.historyActive {Button(L("暂停同步")) {model.send("disable-history-sync")}}
                            else {Button(L("连接自动同步…")) {model.connectHistory()}}
                            Button(L("补录到现在")) {model.send("sync-history-once",["consent":true])}
                            Divider()
                            Button(L(model.demo ? "返回真实账本":"试用虚构演示")) {
                                model.month="";model.selectedModel="全部模型"
                                model.send("mode",["value":model.demo ? "live":"demo"])
                            }
                        } label:{Image(systemName:"ellipsis").frame(width:22,height:22)}
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().localizedAccessibilityLabel("更多选项")
                        Button(action:hide) {Image(systemName:"minus").frame(width:22,height:22)}.localizedHelp("隐藏 · ⌃⌥L 唤回").localizedAccessibilityLabel("隐藏浮窗")
                        Button(action:expand) {Image(systemName:"arrow.down.right.and.arrow.up.left").frame(width:22,height:22)}.localizedHelp("收起为小浮窗").localizedAccessibilityLabel("收起")
                    }.buttonStyle(.plain).padding(.horizontal,22).padding(.top,16).padding(.bottom,12)
                    HStack {
                        Picker(L("页面"),selection:$model.tab) {
                            LText("总账单").tag("用量");LText("最近用量").tag("活动");LText("连接").tag("连接")
                            if model.tab == "价格" {LText("定价").tag("价格")}
                            if model.tab == "设置" {LText("设置").tag("设置")}
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width:model.tab == "价格" || model.tab == "设置" ? 350:280)
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
            if model.tab == "用量" {usage}
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
    var usage:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Picker(L("月份"),selection:$model.month) {ForEach(model.snapshot["months"] as? [String] ?? [],id:\.self){LText($0)}}
                    .labelsHidden().frame(width:128).onChange(of:model.month){model.selectedModel="全部模型";model.filter()}
                Picker(L("Agent"),selection:$model.agent) {ForEach(["全部","Codex","Claude Code"],id:\.self){LText($0 == "全部" ? "全部 Agent":$0).tag($0)}}
                    .labelsHidden().frame(width:136).onChange(of:model.agent){model.selectedModel="全部模型";model.filter()}
                Spacer()
                LText("USD · \(model.snapshot["timezone"] as? String ?? "UTC") 自然月").font(.system(size:10)).foregroundStyle(.secondary)
            }.controlSize(.small).font(.system(size:11))
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:6) {
                    LText("按 API 官方价格折算").font(.system(size:11)).foregroundStyle(.secondary)
                    LText(model.loading ? "汇总中…":(number(model.snapshot["count"]) > number(model.snapshot["unpriced"]) ? money(number(model.snapshot["amount"])):"—"))
                        .font(.system(size:34,weight:.medium,design:.rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment:.trailing,spacing:6) {
                    LText(mixBrief(model.snapshot["mix"])+" tokens").font(.system(size:15,weight:.medium,design:.rounded))
                    LText("\(Int(number(model.snapshot["count"]))) 次模型请求").font(.system(size:10)).foregroundStyle(.secondary)
                }.padding(.bottom,4)
            }
            HStack(spacing:5) {
                Image(systemName:"info.circle").font(.system(size:10))
                LText(number(model.snapshot["unpriced"]) > 0 ? "\(Int(number(model.snapshot["unpriced"]))) 次暂未定价 · 当前金额仅含已定价部分":"当前已收录请求均可估算")
                Spacer()
                Button(L("计算口径")) {model.tab="价格"}.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size:10)).foregroundStyle(.secondary)
                .localizedHelp("按历史配置模型、档位及当前官网价格估算。不是实际扣款，历史覆盖可能不完整。")
            MixBar(mix:model.snapshot["mix"] as? [String:Any] ?? [:]).id(model.language).padding(.vertical,3)
            Divider().opacity(0.4)
            HStack {
                LText("模型明细").font(.system(size:12,weight:.semibold))
                Spacer()
                Picker(L("模型"),selection:$model.selectedModel) {
                    LText("全部模型").tag("全部模型")
                    ForEach(model.snapshot["models"] as? [String] ?? [],id:\.self){LText($0)}
                }.labelsHidden().frame(width:190).controlSize(.small).font(.system(size:10)).onChange(of:model.selectedModel){model.filter()}
            }
            ScrollView {
                LazyVStack(spacing:0) {
                    if model.rows.isEmpty {LText("这个月尚无已收录的用量").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:120)}
                    ForEach(Array(model.rows.enumerated()),id:\.offset) {_,row in modelRow(row)}
                }
            }.frame(minHeight:0,maxHeight:.infinity)
        }
    }
    func modelRow(_ row:[String:Any])->some View {
        let id=row["model"] as? String ?? ""
        let opened=model.selectedRow == id
        return VStack(alignment:.leading,spacing:10) {
            Button {model.selectedRow=opened ? "":id} label:{
                HStack(spacing:12) {
                    VStack(alignment:.leading,spacing:4) {
                        LText(id).font(.system(size:12,weight:.medium))
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
                MixBar(mix:row["mix"] as? [String:Any] ?? [:],detailed:false).id(model.language)
                bucketTable(row)
                if let reason=row["reason"] as? String,!reason.isEmpty {LText(reason).font(.system(size:10)).foregroundStyle(.orange)}
                if let url=URL(string:row["source"] as? String ?? "") {Link(L("API 等价参考价 · \(model.snapshot["checked"] as? String ?? "") ↗"),destination:url).font(.system(size:10))}
            }
            Divider().opacity(0.25)
        }.padding(.vertical,9)
    }
    var activity:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    LText("每一次模型请求").font(.system(size:22,weight:.semibold,design:.rounded))
                    LText("此 Mac 的全部已落盘对话 · 最新 40 条").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing:5) {Circle().fill(statusColor).frame(width:5,height:5);LText(model.historyActive ? "正在跟进":"已暂停")}
                    .font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            }
            LText("请求用量写入本机后自动更新；未定价请求也会显示 token。").font(.system(size:10)).foregroundStyle(.secondary)
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing:0) {
                    ForEach(Array(model.activity.enumerated()),id:\.offset) {index,e in
                        HStack(alignment:.top,spacing:12) {
                            VStack(spacing:6) {
                                Circle().fill(index == 0 && model.historyActive ? Color.green:Color.secondary.opacity(0.3)).frame(width:5,height:5)
                                Rectangle().fill(Color.secondary.opacity(0.12)).frame(width:1,height:36)
                            }.padding(.top,5)
                            VStack(alignment:.leading,spacing:5) {
                                HStack {
                                    LText(e["model"] as? String ?? "未知模型").font(.system(size:12,weight:.medium))
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
                                    LText((e["agent"] as? String ?? "")+" · "+((e["conversation"] as? String).map{"会话 "+String($0.prefix(8))} ?? "历史请求"))
                                    Spacer()
                                    LText(e["amount"] is NSNumber ? usd(number(e["amount"])):"未定价").monospacedDigit()
                                }.font(.system(size:9)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical,9).accessibilityElement(children:.combine)
                        .localizedHelp("\(model.localTime(e["timestamp"])) 北京时间\n普通输入 \(tokenText(e["input"])) · 输出 \(tokenText(e["output"])) · 缓存读 \(tokenText(e["read"])) · 缓存写 \(tokenText(e["write"]))\n\(e["reason"] as? String ?? "")")
                    }
                }
            }
        }
    }
    func bucketTable(_ row:[String:Any]) -> some View {
        let buckets=row["buckets"] as? [String:Any] ?? [:]
        let rates=row["rates"] as? [String:Any] ?? [:]
        let costs=row["cost_buckets"] as? [String:Any] ?? [:]
        let noWrite=row["cache_accounting"] as? String == "no_write_premium"
        let codex=row["agent"] as? String == "Codex"
        let keys=noWrite ? ["input","read","output"]:["input","read","write_short","write_long","output"]
        let names=["input":"普通输入","read":"缓存读取","write_short":codex ? "缓存写入 · 30m":"缓存写入 · 5m","write_long":codex ? "缓存写入 · 12h":"缓存写入 · 1h","output":"输出（含推理）"]
        return VStack(spacing:6) {
            Divider().opacity(0.35)
            HStack {LText("Token 桶");Spacer();LText("数量").frame(width:95,alignment:.trailing);LText("基础价 / 百万").frame(width:100,alignment:.trailing);LText("已定价费用").frame(width:100,alignment:.trailing)}.foregroundStyle(.secondary)
            ForEach(keys,id:\.self) {k in
                HStack {
                    LText(names[k] ?? k);Spacer()
                    LText(tokenText(buckets[k])).frame(width:95,alignment:.trailing)
                    LText(rates[k] == nil ? "—":String(format:"$%.3g",number(rates[k]))).frame(width:100,alignment:.trailing)
                    LText(number(row["count"]) > number(row["unpriced"]) ? usd(number(costs[k])):"—").frame(width:100,alignment:.trailing)
                }.monospacedDigit()
            }
            if number(row["unpriced"]) > 0 {LText("数量含未定价请求；费用只合计已完整定价的请求。").foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)}
            LText(noWrite ? "缓存写入包含在普通输入中，无独立写入费。":"基础价列为 Standard；费用按每条请求已确认的档位计算，写入总量不再累加。")
                .foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }.font(.system(size:10))
    }
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
                ForEach(["Codex","Claude Code"],id:\.self) {provider in
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
                        if let source=item["source"] as? String,let url=URL(string:source),!source.isEmpty {
                            Link(L("官方套餐价格 · 核对 \(item["checked"] as? String ?? "")"),destination:url).font(.system(size:10))
                        }
                    }.padding(10).background(Color.white.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                }.font(.system(size:11))
                LText("识别本机 CLI 的套餐类型；官网参考价不等于实际扣款。订阅与用量接收状态分别显示。").font(.system(size:10)).foregroundStyle(.secondary)
                DisclosureGroup(L("特殊价格 / 手动调整（可选）")) {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            LText("Codex $");TextField(L("自动"),text:$model.codexPlan).frame(width:80)
                            LText("Claude $");TextField(L("自动"),text:$model.claudePlan).frame(width:80)
                            Button(L("保存调整")){model.savePrefs()}
                            Button(L("恢复自动")){model.codexPlan="";model.claudePlan="";model.send("reset-plan-overrides")}
                        }.textFieldStyle(.roundedBorder)
                        LText("用于折扣、年付折算或自定义参考；这是你的调整值，不是自动识别结果。").foregroundStyle(.secondary)
                    }.padding(.top,8)
                }.font(.system(size:11))
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
            infoCard("Codex · 自动同步",model.historyLabel,"自动跟进此 Mac 保存的用量；文件变化时更新，另每 5 秒补查。不会上传或保存对话正文。")
            HStack {
                if model.historyActive {Button(L("暂停自动同步")) {model.send("disable-history-sync")}}
                else {Button(L("连接自动同步…")) {model.connectHistory()}}
                Button(L("补录到现在")) {model.send("sync-history-once",["consent":true])}
            }
            LText("最近检查：\(model.localTime(model.historySync["last_scan"])) 北京时间")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if let error=model.historySync["error"] as? String,!error.isEmpty {LText(error).font(.system(size:11)).foregroundStyle(.orange)}
            Divider()
            infoCard("Claude Code",number(model.snapshot["received"]) > 0 ? "已收到 API request 事件 · 仅覆盖新会话":"实验支持 · 尚未验证真实会话","仅收集从这里启动的新 CLI 会话。已有会话和历史用量不包含。")
            HStack {
                Button(L("连接 Claude 新会话…")) {model.connectClaude()}
                if model.snapshot["receiving"] as? Bool == true {Button(L("断开采集")) {model.send("disconnect")}}
            }
            if let message=model.snapshot["message"] as? String,message != "尚未连接真实来源 · 空账本不代表零消费" {LText(message).font(.system(size:10)).foregroundStyle(.secondary)}
            DisclosureGroup(L("高级：Codex hook")) {
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
    var savedFrame: NSRect?
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
        panel.title="AI Cost Companion"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent=true
        panel.isMovableByWindowBackground=false; panel.level = .floating
        panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque=false; panel.hasShadow=true
        panel.appearance=nil
        panel.delegate=self
        model.onDrag = { [weak self] delta,ended in
            guard let self=self,!self.model.expanded else{return}
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
            if ended {self.dragOrigin=nil;self.dragMouseOrigin=nil;self.clamp()}
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
            self.status.button?.toolTip=L("AI Cost Companion · \(self.model.metricLabel) · API 等价估算，仅已定价部分")
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
        let appItem=NSMenuItem(title:"AI Cost Companion",action:nil,keyEquivalent:"")
        let appMenu=NSMenu(title:"AI Cost Companion")
        appMenu.addItem(withTitle:L("显示 / 隐藏浮窗"),action:#selector(menuToggle),keyEquivalent:"l").target=self
        appMenu.addItem(withTitle:L("退出 AI Cost Companion"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
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
        if #available(macOS 26.0,*),!model.expanded {
            let glass=NSGlassEffectView(frame:NSRect(origin:.zero,size:panel.frame.size))
            glass.style = .regular;glass.cornerRadius=20
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
        if let data=try? Data(contentsOf:path),let d=try? JSONSerialization.jsonObject(with:data) as? [String:Double],let x=d["x"],let y=d["y"] {
            panel.setFrameOrigin(NSPoint(x:x,y:y))
        } else if let screen=NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x:screen.maxX-380,y:screen.maxY-180))
        }
        clamp()
    }
    func clamp() {
        guard let screen=NSScreen.screens.first(where:{$0.visibleFrame.intersects(panel.frame)}) ?? NSScreen.main else{return}
        let s=screen.visibleFrame, f=panel.frame
        panel.setFrameOrigin(NSPoint(x:max(s.minX,min(f.minX,s.maxX-f.width)),y:max(s.minY,min(f.minY,s.maxY-f.height))))
    }
    func windowDidMove(_ n:Notification) {
        guard let panel=panel else{return}
        let origin=model.expanded ? (savedFrame?.origin ?? panel.frame.origin):panel.frame.origin
        let values=["x":origin.x,"y":origin.y]
        try? FileManager.default.createDirectory(at:model.dataURL,withIntermediateDirectories:true)
        if let d=try? JSONSerialization.data(withJSONObject:values) {try? d.write(to:model.dataURL.appendingPathComponent("window.json"),options:.atomic)}
    }
    func toggleExpanded() {
        if !model.expanded {savedFrame=panel.frame}
        let top=panel.frame.maxY
        model.expanded.toggle()
        panel.allowsKeyboard=model.expanded
        panel.isMovableByWindowBackground=model.expanded
        let size=model.expanded ? NSSize(width:640,height:610) : NSSize(width:188,height:40)
        panel.setFrame(NSRect(x:panel.frame.minX,y:top-size.height,width:size.width,height:size.height),display:true,animate:false)
        if !model.expanded,let old=savedFrame {panel.setFrameOrigin(old.origin)}
        clamp()
        updateSurface()
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
            menu.addItem(withTitle:L("退出 AI Cost Companion"),action:#selector(quit),keyEquivalent:"q").target=self
            status.menu=menu; status.button?.performClick(nil); status.menu=nil
        } else {toggleVisible()}
    }
    @objc func menuToggle(){toggleVisible()}
    @objc func reveal(){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
    @objc func quit(){NSApp.terminate(nil)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {panel.orderFrontRegardless();return true}
    func applicationWillTerminate(_ n:Notification){sourceWatcher.stop();model.stop()}
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

let app=NSApplication.shared
let delegate=AppDelegate()
app.delegate=delegate
app.run()
