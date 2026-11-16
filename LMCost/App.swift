import Cocoa
import SwiftUI
import Carbon
import CoreServices

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
    return (mix["incomplete"] as? Bool == true ? "≥":"")+tokenBrief(mix["total"])
}
func compactNumber(_ x:Double)->String {
    if x >= 1000000000 {return String(format:"%.2fB",x/1000000000)}
    if x >= 1000000 {return String(format:"%.2fM",x/1000000)}
    if x >= 1000 {return String(format:"%.1fK",x/1000)}
    return String(format:"%.0f",x)
}

final class Model: ObservableObject {
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
            return number(snapshot["current_count"]) > 0 ? ((mix["incomplete"] as? Bool == true ? "≥":"")+compactNumber(number(mix["total"]))):"—"
        }
        let today=metric == "today_cost"
        let count=number(snapshot[today ? "today_count":"current_count"])
        let unknown=number(snapshot[today ? "today_unpriced":"current_unpriced"])
        guard count > unknown else{return "—"}
        let amount=number(snapshot[today ? "today_amount":"current_amount"])
        let prefix=unknown > 0 ? "≥":""
        if metric == "plan_ratio" {
            let total=number(snapshot["current_plan"])
            return total > 0 ? prefix+String(format:"%.2f×",amount/total):"—"
        }
        return prefix+money(amount)
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
        alert.messageText="识别 \(provider) 登录套餐"
        alert.informativeText="通过本机官方 CLI 查询登录状态，只提取套餐类型。账户标识和邮箱只在内存中过滤，不保存；不读取会话或发起模型请求，不开启用量采集。官方命令可能查询其登录服务。\n\n本机 CLI 账户可能与桌面或云端不同；显示官网美元月付参考，不能获取实际扣款。"
        alert.addButton(withTitle:"识别套餐");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        send("detect-plan",["provider":provider,"consent":true])
    }
    func connectHistory() {
        let alert=NSAlert()
        alert.messageText="连接 Codex 本机用量自动同步"
        alert.informativeText="AI Cost Companion 打开期间，收到此 Mac 的 Codex 历史文件变化通知就检查新增用量，另每 5 秒补查。Codex 将请求用量写入本机后才会显示，不是逐 token 流。\n\n仅保存时间、模型、token 桶、档位与散列去重 ID；不保存对话正文或账户身份，不上传。不会修改 Codex 配置、hook 或遥测。\n\n这个选择会记住；以后打开 AI Cost Companion 会继续同步，退出即停止，可随时暂停。不会创建登录项。"
        alert.addButton(withTitle:"连接并自动同步");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        send("enable-history-sync",["consent":true])
    }
    func connectClaude() {
        let alert = NSAlert()
        alert.messageText = "连接一个新的 Claude Code 会话"
        alert.informativeText = "仅统计连接后在本机启动的新会话，不补齐历史或其他设备。新会话不载入个人和项目设置；已有会话与配置不变。只在内存中筛选 API request 事件，保存时间、模型、token 桶和散列去重 ID。关闭内容采集，不保存账户身份，不上传。受管理或已配置遥测存在时停止。\n\n连接后通过官方登录状态命令自动识别套餐，仅保留套餐类型，不保存邮箱或账户标识。官网月付参考不是实际扣款。\n\n需要已安装并登录的官方 Claude Code 2.1.300+；随后选择工作文件夹。"
        alert.addButton(withTitle:"同意并连接")
        alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let candidates = [NSHomeDirectory()+"/.local/bin/claude","/opt/homebrew/bin/claude","/usr/local/bin/claude"]
        var binary = candidates.first { FileManager.default.isExecutableFile(atPath:$0) }
        if binary == nil {
            let file = NSOpenPanel()
            file.title="选择已安装的 Claude Code 可执行文件"
            file.message="常见位置未找到 Claude Code。请选官方 CLI；AI Cost Companion 不会自动安装。"
            file.canChooseFiles=true; file.canChooseDirectories=false; file.allowsMultipleSelection=false
            guard file.runModal() == .OK else { return }
            binary=file.url?.path
        }
        let folder = NSOpenPanel()
        folder.title="选择新 Claude 会话的工作文件夹"
        folder.canChooseFiles=false; folder.canChooseDirectories=true; folder.allowsMultipleSelection=false
        guard folder.runModal() == .OK, let project=folder.url?.path, let binary=binary else { return }
        error=""
        send("connect", ["binary":binary,"project":project,"detect_plan":true])
    }
    func allowCodex() {
        let alert=NSAlert()
        alert.messageText="允许本次运行接收 Codex hook？"
        alert.informativeText="只接收你另行安装并在 Codex 中信任的 PostModelRequest；此按钮不安装 hook，不修改已有配置。只保存散列 ID、接收时间、模型和 token 桶，不读取会话内容，不上传。退出或停止即拒收。\n\n本机已验证事件能被识别，尚未验收桌面真实投递。缺可靠请求 ID 的投递会被拒收；缺档位或必要计费桶将未定价。月份按本机接收时间，仅覆盖连接后的请求。另通过本机 Codex 官方 account/read 读取登录套餐，不强制刷新登录，不保存邮箱或账户标识。CLI 与桌面账户可能不同，月费只是官网参考。"
        alert.addButton(withTitle:"同意本次接收")
        alert.addButton(withTitle:"取消")
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
                        Text(labels[i])
                        Text(total > 0 ? String(format:"%.1f%%",number(values[keys[i]])/total*100):"—").monospacedDigit()
                    }
                }
                Spacer(minLength:0)
                if mix["incomplete"] as? Bool == true {Text("仅已知部分").foregroundStyle(.orange)}
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
                        Text("AI Cost Companion").font(.system(size:14,weight:.semibold))
                        Spacer()
                        HStack(spacing:5) {
                            Circle().fill(statusColor).frame(width:5,height:5)
                            Text(model.demo ? "演示":(model.snapshot.isEmpty ? "载入中":(model.historyActive ? "正在跟进":"已暂停")))
                        }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Menu {
                            Button("显示与月费") {model.tab="设置"}
                            Button("官方定价与口径") {model.tab="价格"}
                            Divider()
                            if model.historyActive {Button("暂停同步") {model.send("disable-history-sync")}}
                            else {Button("连接自动同步…") {model.connectHistory()}}
                            Button("补录到现在") {model.send("sync-history-once",["consent":true])}
                            Divider()
                            Button(model.demo ? "返回真实账本":"试用虚构演示") {
                                model.month="";model.selectedModel="全部模型"
                                model.send("mode",["value":model.demo ? "live":"demo"])
                            }
                        } label:{Image(systemName:"ellipsis").frame(width:22,height:22)}
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("更多选项")
                        Button(action:hide) {Image(systemName:"minus").frame(width:22,height:22)}.help("隐藏 · ⌃⌥L 唤回").accessibilityLabel("隐藏浮窗")
                        Button(action:expand) {Image(systemName:"arrow.down.right.and.arrow.up.left").frame(width:22,height:22)}.help("收起为小浮窗").accessibilityLabel("收起")
                    }.buttonStyle(.plain).padding(.horizontal,22).padding(.top,16).padding(.bottom,12)
                    HStack {
                        Picker("页面",selection:$model.tab) {
                            Text("总账单").tag("用量");Text("最近用量").tag("活动");Text("连接").tag("连接")
                            if model.tab == "价格" {Text("定价").tag("价格")}
                            if model.tab == "设置" {Text("设置").tag("设置")}
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
                        Text(model.metricLabel).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
                        Spacer(minLength:2)
                        Text(model.headline).font(.system(size:16,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }.padding(.horizontal,14).frame(maxWidth:.infinity,maxHeight:.infinity)
                }.buttonStyle(.plain).contentShape(Capsule())
                    .highPriorityGesture(DragGesture(minimumDistance:4).onChanged {model.lastDragAt=Date().timeIntervalSince1970;model.onDrag?($0.translation,false)}.onEnded {model.lastDragAt=Date().timeIntervalSince1970;model.onDrag?($0.translation,true)})
                    .accessibilityElement(children:.combine).accessibilityLabel("\(model.metricLabel) \(model.headline)，\(model.demo ? "演示用量":"API 等价估算")，\(model.historyActive ? "自动跟进中":"同步暂停")，点击展开总账单")
                    .help("\(model.demo ? "虚构演示":model.historyLabel) · API 等价估算，非实际扣款 · 点击查看账单")
                    .contextMenu {
                        ForEach(metricChoices,id:\.0) {item in Button((model.metric == item.0 ? "✓ ":"")+item.1) {model.setMetric(item.0)}}
                        Divider();Button("打开总账单",action:expand);Button("隐藏浮窗",action:hide)
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
            if !model.error.isEmpty {Text(model.error).font(.system(size:11)).foregroundStyle(.orange)}
            Divider().opacity(0.35)
            HStack(spacing:6) {
                Circle().fill(statusColor).frame(width:4,height:4)
                Text(model.demo ? "虚构演示":(model.historyActive ? "本机 Codex · 自动跟进":"本机 Codex · 已暂停"))
                Spacer()
                Text("最近用量 \(model.timeOnly(model.historySync["last_event"]))")
                Text("· 北京时间").foregroundStyle(.tertiary)
            }.font(.system(size:9)).foregroundStyle(.secondary)
            .help(model.historyLabel+"；只覆盖已写入这台 Mac 的用量。")
        }
    }
    var usage:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Picker("月份",selection:$model.month) {ForEach(model.snapshot["months"] as? [String] ?? [],id:\.self){Text($0)}}
                    .labelsHidden().frame(width:128).onChange(of:model.month){model.selectedModel="全部模型";model.filter()}
                Picker("Agent",selection:$model.agent) {ForEach(["全部","Codex","Claude Code"],id:\.self){Text($0 == "全部" ? "全部 Agent":$0).tag($0)}}
                    .labelsHidden().frame(width:136).onChange(of:model.agent){model.selectedModel="全部模型";model.filter()}
                Spacer()
                Text("USD · \(model.snapshot["timezone"] as? String ?? "UTC") 自然月").font(.system(size:10)).foregroundStyle(.secondary)
            }.controlSize(.small).font(.system(size:11))
            HStack(alignment:.bottom) {
                VStack(alignment:.leading,spacing:6) {
                    Text("按 API 官方价格折算").font(.system(size:11)).foregroundStyle(.secondary)
                    Text(model.loading ? "汇总中…":(number(model.snapshot["count"]) > number(model.snapshot["unpriced"]) ? money(number(model.snapshot["amount"])):"—"))
                        .font(.system(size:34,weight:.medium,design:.rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment:.trailing,spacing:6) {
                    Text(mixBrief(model.snapshot["mix"])+" tokens").font(.system(size:15,weight:.medium,design:.rounded))
                    Text("\(Int(number(model.snapshot["count"]))) 次模型请求").font(.system(size:10)).foregroundStyle(.secondary)
                }.padding(.bottom,4)
            }
            HStack(spacing:5) {
                Image(systemName:"info.circle").font(.system(size:10))
                Text(number(model.snapshot["unpriced"]) > 0 ? "\(Int(number(model.snapshot["unpriced"]))) 次暂未定价 · 当前金额仅含已定价部分":"当前已收录请求均可估算")
                Spacer()
                Button("计算口径") {model.tab="价格"}.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size:10)).foregroundStyle(.secondary)
                .help("按历史配置模型、档位及当前官网价格估算。不是实际扣款，历史覆盖可能不完整。")
            MixBar(mix:model.snapshot["mix"] as? [String:Any] ?? [:]).padding(.vertical,3)
            Divider().opacity(0.4)
            HStack {
                Text("模型明细").font(.system(size:12,weight:.semibold))
                Spacer()
                Picker("模型",selection:$model.selectedModel) {
                    Text("全部模型").tag("全部模型")
                    ForEach(model.snapshot["models"] as? [String] ?? [],id:\.self){Text($0)}
                }.labelsHidden().frame(width:190).controlSize(.small).font(.system(size:10)).onChange(of:model.selectedModel){model.filter()}
            }
            ScrollView {
                LazyVStack(spacing:0) {
                    if model.rows.isEmpty {Text("这个月尚无已收录的用量").font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:120)}
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
                        Text(id).font(.system(size:12,weight:.medium))
                        HStack(spacing:6) {
                            Text(mixBrief(row["mix"])+" tokens")
                            Text("· \(Int(number(row["count"]))) 次请求")
                            if number(row["unpriced"]) > 0 {Text("· \(Int(number(row["unpriced"]))) 未定价").foregroundStyle(.orange)}
                        }.font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(number(row["count"]) > number(row["unpriced"]) ? money(number(row["amount"])):"未定价")
                        .font(.system(size:14,weight:.medium,design:.rounded)).monospacedDigit()
                    Image(systemName:opened ? "chevron.up":"chevron.down").font(.system(size:8)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(id) 明细")
            if opened {
                MixBar(mix:row["mix"] as? [String:Any] ?? [:],detailed:false)
                bucketTable(row)
                if let reason=row["reason"] as? String,!reason.isEmpty {Text(reason).font(.system(size:10)).foregroundStyle(.orange)}
                if let url=URL(string:row["source"] as? String ?? "") {Link("官方价格 · \(model.snapshot["checked"] as? String ?? "") ↗",destination:url).font(.system(size:10))}
            }
            Divider().opacity(0.25)
        }.padding(.vertical,9)
    }
    var activity:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("每一次模型请求").font(.system(size:22,weight:.semibold,design:.rounded))
                    Text("此 Mac 的全部已落盘对话 · 最新 40 条").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing:5) {Circle().fill(statusColor).frame(width:5,height:5);Text(model.historyActive ? "正在跟进":"已暂停")}
                    .font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            }
            Text("请求用量写入本机后自动更新；未定价请求也会显示 token。").font(.system(size:10)).foregroundStyle(.secondary)
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
                                    Text(e["model"] as? String ?? "未知模型").font(.system(size:12,weight:.medium))
                                    Text(model.timeOnly(e["timestamp"])).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(mixBrief(e["mix"])+" tokens").font(.system(size:12,weight:.medium,design:.rounded)).monospacedDigit()
                                }
                                HStack(spacing:7) {
                                    Text("输入 \(tokenBrief(e["input"]))")
                                    Text("输出 \(tokenBrief(e["output"]))")
                                    Text("缓存读 \(tokenBrief(e["read"]))")
                                    Text("缓存写 \(tokenBrief(e["write"]))")
                                }.font(.system(size:10)).foregroundStyle(.secondary)
                                HStack {
                                    Text((e["agent"] as? String ?? "")+" · "+((e["conversation"] as? String).map{"会话 "+String($0.prefix(8))} ?? "历史请求"))
                                    Spacer()
                                    Text(e["amount"] is NSNumber ? usd(number(e["amount"])):"未定价").monospacedDigit()
                                }.font(.system(size:9)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical,9).accessibilityElement(children:.combine)
                        .help("\(model.localTime(e["timestamp"])) 北京时间\n普通输入 \(tokenText(e["input"])) · 输出 \(tokenText(e["output"])) · 缓存读 \(tokenText(e["read"])) · 缓存写 \(tokenText(e["write"]))\n\(e["reason"] as? String ?? "")")
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
            HStack {Text("Token 桶");Spacer();Text("数量").frame(width:95,alignment:.trailing);Text("基础价 / 百万").frame(width:100,alignment:.trailing);Text("已定价费用").frame(width:100,alignment:.trailing)}.foregroundStyle(.secondary)
            ForEach(keys,id:\.self) {k in
                HStack {
                    Text(names[k] ?? k);Spacer()
                    Text(tokenText(buckets[k])).frame(width:95,alignment:.trailing)
                    Text(rates[k] == nil ? "—":String(format:"$%.3g",number(rates[k]))).frame(width:100,alignment:.trailing)
                    Text(number(row["count"]) > number(row["unpriced"]) ? usd(number(costs[k])):"—").frame(width:100,alignment:.trailing)
                }.monospacedDigit()
            }
            if number(row["unpriced"]) > 0 {Text("数量含未定价请求；费用只合计已完整定价的请求。").foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)}
            Text(noWrite ? "缓存写入包含在普通输入中，无独立写入费。":"基础价列为 Standard；费用按每条请求已确认的档位计算，写入总量不再累加。")
                .foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
        }.font(.system(size:10))
    }
    var settings:some View {
        ScrollView { VStack(alignment:.leading,spacing:22) {
            VStack(alignment:.leading,spacing:12) {
                Text("小浮窗显示什么").font(.system(size:16,weight:.semibold))
                Text("随时右键浮窗也能切换。仅改变显示，不开启采集。").font(.system(size:11)).foregroundStyle(.secondary)
                ForEach(metricChoices,id:\.0) {item in
                    Button {model.setMetric(item.0)} label:{
                        HStack {Image(systemName:model.metric == item.0 ? "checkmark.circle.fill":"circle").foregroundStyle(model.metric == item.0 ? Color.blue:Color.secondary);Text(item.1);Spacer()}
                            .padding(10).background(Color.white.opacity(model.metric == item.0 ? 0.65:0.25),in:RoundedRectangle(cornerRadius:10))
                    }.buttonStyle(.plain).font(.system(size:12))
                }
            }
            VStack(alignment:.leading,spacing:10) {
                Text("套餐 · 连接后自动识别").font(.system(size:16,weight:.semibold))
                ForEach(["Codex","Claude Code"],id:\.self) {provider in
                    let states=model.snapshot["subscriptions"] as? [String:[String:Any]] ?? [:]
                    let item=states[provider] ?? [:]
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text(provider).fontWeight(.medium)
                            Text(item["label"] as? String ?? "连接后自动识别").foregroundStyle(.secondary)
                            Spacer()
                            if item["reference_usd"] is NSNumber {Text(money(number(item["reference_usd"]))+" / 月参考").monospacedDigit()}
                            Button("识别套餐…"){model.detectPlan(provider)}.disabled(item["state"] as? String == "loading")
                        }
                        Text(item["detail"] as? String ?? "").font(.system(size:10)).foregroundStyle(.secondary)
                        let overrides=model.snapshot["plan_overrides"] as? [String:Any] ?? [:]
                        if overrides[provider] is NSNumber {
                            Text("比较使用你的调整值："+money(number(overrides[provider]))+" / 月").font(.system(size:10)).foregroundStyle(.blue)
                        }
                        if let source=item["source"] as? String,let url=URL(string:source),!source.isEmpty {
                            Link("官方套餐价格 · 核对 \(item["checked"] as? String ?? "")",destination:url).font(.system(size:10))
                        }
                    }.padding(10).background(Color.white.opacity(0.35),in:RoundedRectangle(cornerRadius:10))
                }.font(.system(size:11))
                Text("识别本机 CLI 的套餐类型；官网参考价不等于实际扣款。订阅与用量接收状态分别显示。").font(.system(size:10)).foregroundStyle(.secondary)
                DisclosureGroup("特殊价格 / 手动调整（可选）") {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Text("Codex $");TextField("自动",text:$model.codexPlan).frame(width:80)
                            Text("Claude $");TextField("自动",text:$model.claudePlan).frame(width:80)
                            Button("保存调整"){model.savePrefs()}
                            Button("恢复自动"){model.codexPlan="";model.claudePlan="";model.send("reset-plan-overrides")}
                        }.textFieldStyle(.roundedBorder)
                        Text("用于折扣、年付折算或自定义参考；这是你的调整值，不是自动识别结果。").foregroundStyle(.secondary)
                    }.padding(.top,8)
                }.font(.system(size:11))
            }
            HStack {
                Picker("月份时区",selection:$model.timezone) {Text("UTC").tag("UTC");Text("本机时区").tag("本机时区")}.frame(width:240)
                Button("保存时区"){model.month="";model.savePrefs()}
            }.font(.system(size:12))
            Text("拖动小浮窗可移动；点击打开账单；右键隐藏。点击菜单栏金额或重新打开应用可唤回。").font(.system(size:11)).foregroundStyle(.secondary)
            Button("打开本机数据文件夹") {NSWorkspace.shared.open(model.dataURL)}.font(.system(size:11))
            Spacer()
        }.padding(.top,6) }
    }
    var connections: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:20) {
            infoCard("Codex · 自动同步",model.historyLabel,"收到文件变化通知即检查新增用量，另每 5 秒补查。请求用量写入本机后入账；界面每秒刷新。保留响应去重，支持暂停及下次打开补录。仅包含这台 Mac 保存的记录，不包含其他设备及未同步到本机的云端用量。")
            Text(model.sourceWatcherActive ? "文件变化通知已启用 · 5 秒补查":"文件变化通知未启用 · 使用 5 秒检查").font(.system(size:10)).foregroundStyle(.secondary)
            HStack {
                if model.historyActive {Button("暂停自动同步") {model.send("disable-history-sync")}}
                else {Button("连接自动同步…") {model.connectHistory()}}
                Button("补录到现在") {model.send("sync-history-once",["consent":true])}
            }
            Text("最近检查：\(model.localTime(model.historySync["last_scan"])) 北京时间\n最近用量：\(model.localTime(model.historySync["last_event"])) 北京时间 · 本次新增 \(Int(number(model.historySync["added_this_run"]))) 条\n\(model.historySync["error"] as? String ?? "")")
                .font(.system(size:10)).foregroundStyle(.secondary)
            if !model.history.isEmpty {
                infoCard("Codex · 本机历史",model.historyLabel,"已提取这台 Mac 活跃与归档记录中的逐响应用量，并按响应身份去重。账本只保存时间、模型、处理档位、token 桶及散列 ID，不保存对话正文。模型和档位来自历史配置，无法保证请求未发生服务端回退。旧版缺逐响应用量、已删除记录及未同步到此 Mac 的用量不包含。自动同步使用本机历史增量，官方 hook 尚未接通。")
                Text("已检查 \(Int(number(model.history["completed_files"]))) / \(Int(number(model.history["candidate_files"]))) 个本机历史文件 · \(model.history["state"] as? String == "complete" ? "提取完成":"正在提取")")
                    .font(.system(size:10)).foregroundStyle(.secondary)
            }
            infoCard("Claude Code", number(model.snapshot["received"]) > 0 ? "已收到 API request 事件 · 仅覆盖新会话" : "本地 OTel 接收器已实现 · 真实会话尚未验收", "只收集主动连接后新启动的受控 CLI 会话。不会读取历史记录。开发验收时，本机常见位置没有 Claude CLI；可选择已安装的可执行文件。")
            HStack {
                Button("连接 Claude 新会话…") {model.connectClaude()}.tint(mint)
                if model.snapshot["receiving"] as? Bool == true { Button("断开采集") { model.send("disconnect") } }
            }
            if let message=model.snapshot["message"] as? String,message != "尚未连接真实来源 · 空账本不代表零消费" {
                Text(message).font(.system(size:11)).foregroundColor(mint)
            }
            if model.snapshot["receiving"] as? Bool == true {
                Text("本次收到 \(Int(number(model.snapshot["received"]))) 个去重请求 · 最近 \(model.snapshot["last"] as? String ?? "尚无")\n应用退出或断开即停止接收。新会话可继续使用，但其后用量不再进入账本。")
                    .font(.system(size:10)).foregroundColor(dim)
            }
            infoCard("Codex · PostModelRequest", "本机识别 hook 已验证 · 桌面真实投递未验收", "CLI 0.166.0-alpha.5.1 在隔离配置中识别此事件并保持未信任。官方桌面入口：Review hooks / Settings > Hooks。先准备接入片段，自行合并并审阅信任，再允许本次接收；不会修改现有配置。缺请求 ID 拒收；未知档位未定价，不能用演示数冒充真实消费。")
            HStack {
                Button("准备接入文件") {model.send("prepare-codex")}
                if model.snapshot["codex_enabled"] as? Bool == true {
                    Button("停止 Codex 接收") {model.send("disable-codex")}
                } else {
                    Button("允许本次接收…") {model.allowCodex()}
                }
                Button("模拟 hook") {
                    model.month="";model.agent="Codex";model.selectedModel="gpt-5.4-mini"
                    model.send("demo-codex-hook");model.tab="用量"
                }
            }.font(.system(size:11))
            Text("\(model.snapshot["codex_enabled"] as? Bool == true ? "本次接收已允许（不代表 hook 已接通）" : "真实接收已关闭") · 已存 \(Int(number(model.snapshot["codex_count"]))) 条 hook · 拒收 \(Int(number(model.snapshot["codex_rejected"]))) 次投递\nCodex 按本机收到 hook 的时间归月；应用退出后不接收。无独立写入费的模型不要求 TTL；公开 schema 未给出档位，当前 hook 记录仍会未定价。")
                .font(.system(size:10)).foregroundColor(dim).lineSpacing(3)
            Text("Copilot / OpenCode：尚未实现。") .font(.system(size:11)).foregroundColor(dim)
            HStack {
                Picker("月份时区",selection:$model.timezone) {Text("UTC").tag("UTC");Text("本机时区").tag("本机时区")}.frame(width:230)
                Button("应用时区") {model.month="";model.savePrefs()}
            }.font(.system(size:11))
            Text("覆盖：本机已明确导入的历史与已接入后收到的事件。未同步到此 Mac 的其他设备或云端记录、旧版未记录的用量及采集空档不在内。自然月不等于订阅账期。\n本机账本保存在本机；设置页可打开数据文件夹。没有自动登录项。")
                .font(.system(size:11)).foregroundColor(dim).lineSpacing(4)
        }
        }
    }
    func infoCard(_ title:String,_ status:String,_ detail:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.system(size:17,weight:.semibold))
            Text(status).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            Text(detail).font(.system(size:11)).foregroundColor(dim).lineSpacing(4)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,6)
    }
    var prices: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("官方报价核对：2026-11-15").font(.system(size:19,weight:.semibold))
                Text("USD / 100 万 token · 首方 API、global、非 Batch 的固定参考口径。只估算 token；工具、税费、实际地域附加费与订阅扣款不包含。历史月份也使用此快照重新估算，不伪装历史账单。")
                    .font(.system(size:12)).foregroundColor(dim).lineSpacing(4)
                Link("OpenAI 官方价表 ↗",destination:URL(string:"https://developers.openai.com/api/docs/pricing")!)
                Text("精确 ID：gpt-6-astra、gpt-6.1-sol、gpt-6.1-terra、gpt-6-luna、gpt-6-sol、gpt-5.6-sol。支持 Standard / Fast；完整输入 >272k 时，整次请求输入及缓存价 ×2、输出价 ×1.5。Flex / Ultrafast 只在逐模型官方价格已核验时适用；未知档位不计价。历史按当时配置档位估算，不证明实际 API 处理档位。")
                    .font(.system(size:11)).foregroundColor(dim)
                Link("OpenAI 缓存桶口径 ↗",destination:URL(string:"https://developers.openai.com/api/docs/guides/prompt-caching")!)
                Text("GPT-5.6+：普通输入 = input − cached − cache_write。30m / 12h 写入有差价，需分桶；推理已在输出内，不再加一次。") .font(.system(size:11)).foregroundColor(dim)
                Link("GPT-5.4 mini：输入 $0.75 / 缓存读 $0.075 / 输出 $4.50 ↗",destination:URL(string:"https://developers.openai.com/api/docs/models/gpt-5.4-mini")!)
                Link("GPT-5.3 Codex：输入 $1.75 / 缓存读 $0.175 / 输出 $14 ↗",destination:URL(string:"https://developers.openai.com/api/docs/models/gpt-5.3-codex")!)
                Text("精确 ID：gpt-5.4-mini、gpt-5.4-mini-2026-03-17、gpt-5.3-codex（官方已弃用）。这些模型无额外缓存写入费：普通输入 = input − cached，不要求 TTL；限 Standard、400k 上下文内。未知档位仍不计价。") .font(.system(size:11)).foregroundColor(dim)
                Link("Anthropic 官方价表 ↗",destination:URL(string:"https://platform.claude.com/docs/en/about-claude/pricing")!)
                Text("精确 ID：claude-fable-5-2、claude-opus-5-5、claude-sonnet-5-5、claude-haiku-5-5。Fable / Opus 支持 Fast；Haiku 按单次请求含缓存的完整输入量，在 >100,000 token 时切换长上下文费率。") .font(.system(size:11)).foregroundColor(dim)
                Link("Anthropic model ID ↗",destination:URL(string:"https://platform.claude.com/docs/en/models/overview")!)
                Text("Claude 普通 input 已排除缓存。5m / 1h 写入分别计价，不能再加 cache_creation 总量。旧版 TTL 缺失、speed 缺失、未知 ID 和非法计数均列为未定价。") .font(.system(size:11)).foregroundColor(dim)
                Link("Claude Code API request 事件 ↗",destination:URL(string:"https://code.claude.com/docs/en/monitoring-usage#api-request-event")!)
                Text("点击模型行可查看 token 桶。未定价事件不会按 $0 处理；总额始终仅为“已定价部分”。更多模型需要逐个核对后加入。") .font(.system(size:11)).foregroundColor(.orange)
                Button("打开逐模型价表") {NSWorkspace.shared.open(model.resource.appendingPathComponent("pricing.json"))}
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
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
        let mainMenu=NSMenu()
        let appItem=NSMenuItem(title:"AI Cost Companion",action:nil,keyEquivalent:"")
        let appMenu=NSMenu(title:"AI Cost Companion")
        appMenu.addItem(withTitle:"显示 / 隐藏浮窗",action:#selector(menuToggle),keyEquivalent:"l").target=self
        appMenu.addItem(withTitle:"退出 AI Cost Companion",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;mainMenu.addItem(appItem)
        let editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"")
        let edit=NSMenu(title:"编辑")
        edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        editItem.submenu=edit;mainMenu.addItem(editItem);NSApp.mainMenu=mainMenu
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
            self.status.button?.title=self.model.headline.replacingOccurrences(of:"≥",with:"")
            self.status.button?.toolTip="AI Cost Companion · \(self.model.metricLabel) · API 等价估算，仅已定价部分"
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
    func updateSurface() {
        if #available(macOS 26.0,*),let old=panel.contentView as? NSGlassEffectView {old.contentView=nil}
        hosting.removeFromSuperview()
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
            menu.addItem(withTitle:"显示 / 隐藏浮窗",action:#selector(menuToggle),keyEquivalent:"").target=self
            menu.addItem(withTitle:"打开应用所在文件夹",action:#selector(reveal),keyEquivalent:"").target=self
            menu.addItem(.separator())
            menu.addItem(withTitle:"退出 AI Cost Companion",action:#selector(quit),keyEquivalent:"q").target=self
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
