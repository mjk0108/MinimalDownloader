//  ContentView.swift
//  yt-dlp
//
//  Created by 简哲 on 7/4/25.
//

// 确保 yt-dlp 从官方仓库进行自动更新（每24小时检测一次）
// 依赖相关方法和属性定义
import IOKit
/// 获取本机的 IOPlatformUUID（硬件唯一标识）
/// NOTE: `IOServiceGetMatchingService` 返回 0 表示失败，而不是 Optional，
/// 因此用 `if service != 0` 判断；同时使用 kIOMainPortDefault 以避免
/// macOS 12+ 的弃用警告。
func currentDeviceID() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPlatformExpertDevice"))
    if service != 0 {
        if let cfUUID = IORegistryEntryCreateCFProperty(service,
                                                        "IOPlatformUUID" as CFString,
                                                        kCFAllocatorDefault,
                                                        0)?
                        .takeRetainedValue() as? String {
            IOObjectRelease(service)
            return cfUUID.uppercased()
        }
        IOObjectRelease(service)
    }
    return "UNKNOWN"
}
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

// 引入用于异步加载图片
import Foundation

struct ContentView: View {
@State private var isAuthorized: Bool = false
@State private var showAuthSheet: Bool = false
    /// 允许运行的硬件 UUID（IOPlatformUUID）白名单；填入你授权的机器 ID
    let allowedDeviceIDs: Set<String> = [
        "E6FC82AE-6F91-54AD-9470-D1947E4A1AF5",
        "355C40D6-B01B-59DF-923E-D89D7270BD20" // 示例
    ]
@State private var urlText: String = ""
@State private var output: String = "请粘贴视频链接"
@State private var downloadProgress: Double = 0.0
@State private var downloadSpeed: String = ""
/// 批量任务进度（当前序号 / 总数）
@State private var currentTaskIndex: Int = 0
@State private var totalTaskCount:  Int = 0
@State private var isDownloading: Bool = false
// 视频缩略图预览URL
@State private var videoThumbnail: URL? = nil
// 兼容旧版本地图片显示(保留，实际不再用)
@State private var thumbnail: NSImage? = nil
@State private var selectedFormat: String = "best"
@State private var isFetchingFormats = false
// 画质弹窗
@State private var showQualitySheet = false

@State private var qualitySelection: [(label: String, code: String)] = []
@State private var availableFormats: [(label: String, code: String)] = []
// 输出类型
@State private var downloadType: DownloadType = .videoAndAudio
// 画质选择（移除 quality，使用 selectedQuality）
// 视频封装格式
@State private var videoFormat: String = "mp4"
// 字幕选项
@State private var subtitleOption: String = "none"
// 默认保存到系统“下载”文件夹，而非沙盒容器
@AppStorage("savePath") var savePath: String = {
    let dir = ("~/Downloads" as NSString).expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()
// 下载历史记录，最多20条
@State private var downloadHistory: [DownloadRecord] = []
@State private var selectedDownload: DownloadRecord? = nil
@State private var showSettings = false
@State private var showHistory: Bool = false
@State private var useProxy = false
@State private var proxyAddress = ""
@State private var language: String = "zh"
@State private var cookiesMap: [String: String] = [:]
@State private var dependenciesStatus: String = "正在检查依赖..."
@State private var isInstallingDependencies = false
@State private var showDependencyStatus = false
@State private var dependencyCheckDone: Bool = false
@State private var notificationGranted = false
@State private var isPremiumUser: Bool = false
@State private var lastErrorLine: String = ""
// Throttle UI updates from yt‑dlp to avoid UI stalls
@State private var lastUIUpdate = Date()
@State private var lastProgressLine = ""
/// 下载百分比去抖
@State private var lastPercent: Double = 0      // 上一次记录的百分比
/// 本视频可用的字幕语言代码（如 ["en","zh-CN"]）
@State private var availableSubLangs: [String] = []
/// 是否永久关闭欢迎页
@State private var disableWelcome: Bool = false
/// 首次启动欢迎页弹窗
@State private var showWelcomeSheet: Bool = false
/// 运行 yt‑dlp ‑F 动态抓到的 (label, code) 列表；为空则使用默认 formats
var formatPickerOptions: [(label: String, code: String)] {
    let nonPremiumBlockList = ["2160p", "1440p", "4K"]
    let base: [(String, String)] = !availableFormats.isEmpty
        ? availableFormats
        : formats
    if isPremiumUser { return base }
    return base.filter { option in
        nonPremiumBlockList.allSatisfy { !option.0.contains($0) }
    }
}
/// Picker 当前选中的 label（默认为首项）
@State private var selectedQuality: String = "自动选择"
@State private var downloadProcess: Process? = nil
@State private var autoDetectedCookies: [String: String] = [:]
@State private var supportedSites: [String] = []
@State private var subtitleLanguage: String = "none"
@State private var outputTemplate: String = "%(title)s [%(id)s]/%(title)s [%(id)s].%(ext)s"
@State private var lastUpdateCheck: Date = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? Date.distantPast

let formats = [
    ("自动选择", "auto"),
    ("最高画质 (4K)", "bestvideo+bestaudio"),
    ("2K (1440p)", "271+140"),
    ("高画质 (1080p)", "137+140"),
    ("标准画质 (720p)", "136+140"),
    ("普通画质 (480p)", "135+140"),
    ("仅音频", "bestaudio")
]
static let appSupportDir: URL = {
    let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    return paths[0].appendingPathComponent("com.jianzhe.yt-dlp")
}()
// Absolute paths inside Application Support – always writable
static let appSupportYtDlpPath   = appSupportDir.appendingPathComponent("yt-dlp").path
static let appSupportFfmpegPath  = appSupportDir.appendingPathComponent("ffmpeg").path
/// All manually‑imported cookies will be copied here, just like yt‑dlp / ffmpeg.
static let appSupportCookiesDir = appSupportDir.appendingPathComponent("cookies", isDirectory: true)

// 1st priority: bundled binary inside .app (Resources/deps/)
// 2nd priority: binary previously downloaded to Application Support
var ytDlpPath: String { Self.appSupportYtDlpPath }
var ffmpegPath: String { Self.appSupportFfmpegPath }

// 兼容：若需要全局路径（如Homebrew安装），可定义如下（如需调用）

let ytDlpGlobalPath = "/usr/local/bin/yt-dlp"

/// 是否强制保证下载得到的文件能被 QuickTime/iOS 直接播放。
/// 若为 `true`，会在命令行追加参数，优先挑选 H.264+AAC，
/// 并在必要时对非兼容视频执行 remux / 转码到 MP4。
let ensureQuickTimeCompatibility = true

// 依赖下载方法
func downloadDependency(url: URL, destination: String) {
    guard !destination.isEmpty else {
        DispatchQueue.main.async {
            self.output += "\n[依赖下载失败] 目标路径为空: \(url)"
        }
        return
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let cmd = "curl -L --retry 3 --retry-delay 2 --progress-bar '\(url.absoluteString)' -o '\(destination)' && chmod +x '\(destination)'"
    process.arguments = ["bash", "-c", cmd]
    process.standardOutput = pipe
    process.standardError  = pipe

    // Stream curl output into the UI
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.output += "\n[依赖] \(line)"
        }
    }

    do {
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
    } catch {
        DispatchQueue.main.async {
            self.output += "\n[依赖下载失败] \(error.localizedDescription)"
        }
    }
}

// yt-dlp 自动更新方法
func updateYtDlpIfNeeded() {
    // Only attempt an update if the bundled yt‑dlp binary is already present.
    // This prevents a “launch path not accessible” crash on fresh installs
    // or immediately after the user has cleared the dependencies.
    guard FileManager.default.fileExists(atPath: ytDlpPath) else {
        print("updateYtDlpIfNeeded: yt‑dlp not found at \(ytDlpPath)")
        return
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ytDlpPath)
    proc.arguments = ["-U"]
    // yt‑dlp prints its own progress; we don’t need to capture it here.
    do {
        try proc.run()
    } catch {
        print("updateYtDlpIfNeeded: failed to launch – \(error.localizedDescription)")
    }
}

// 下载类型
enum DownloadType: String, CaseIterable, Identifiable {
    case videoAndAudio, audioOnly
    var id: String { self.rawValue }
}



var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        if showDependencyStatus {
            HStack {
                if isInstallingDependencies {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                Text(dependenciesStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.yellow.opacity(0.19))
            .cornerRadius(8)
        }
        // 缩略图预览区，显示在输入框上方
        if let thumbnail = videoThumbnail {
            AsyncImage(url: thumbnail) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .cornerRadius(8)
            } placeholder: {
                ProgressView()
            }
        }
        HStack(spacing: 10) {
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            Image("app_logo")
                .resizable()
                .frame(width: 36, height: 36)
            Text("极简下载器-测试版")
                .font(.title2).bold()
            Spacer()
            // 顶部右上角下载记录菜单
            Menu {
                ForEach(Array(downloadHistory.prefix(20)).indices, id: \.self) { index in
                    let record = downloadHistory[index]
                    Button(action: {
                        self.urlText = record.url
                        self.output = (self.language == "zh"
                                       ? "已从下载记录选择链接，请点击开始下载…"
                                       : "Fetching available formats…")
                        self.selectedQuality = "自动选择"
                        if let videoId = extractVideoId(from: record.url) {
                            self.videoThumbnail = URL(string: "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg")
                        } else {
                            self.videoThumbnail = nil
                        }
                    }) {
                        Text(record.title.isEmpty ? record.url : record.title)
                            .lineLimit(1)
                    }
                }
            } label: {
                Label(language == "zh" ? "下载记录" : "History", systemImage: "arrow.down.circle")
            }
            .font(.caption)
        }
        .padding(.bottom, 2)
        HStack(spacing: 8) {
            // 多行输入，支持批量下载（每行一个）
            ZStack(alignment: .topLeading) {
                TextEditor(text: $urlText)
                    .font(.body)
                    .frame(height: 90)                       // 显示约 3‑5 行
                    .padding(4)
                    .overlay(                                // 模拟 TextField 边框
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor))
                    )
                    .onChange(of: urlText) { oldValue, newURL in
                        // 重置画质与缩略图
                        self.availableFormats = []
                        self.selectedQuality = "自动选择"
                        if let vid = extractVideoId(from: newURL) {
                            self.videoThumbnail = URL(string:"https://img.youtube.com/vi/\(vid)/maxresdefault.jpg")
                        } else {
                            self.videoThumbnail = nil
                        }
                    }

                // 占位提示
                if urlText.isEmpty {
                    Text(language == "zh"
                         ? "粘贴多个视频链接（每行一个）"
                         : "Paste multiple video URLs (one per line)")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                }
            }
            Button(action: {
                if let clipboardString = NSPasteboard.general.string(forType: .string) {
                    urlText = clipboardString
                }
            }) {
                Image(systemName: "doc.on.clipboard")
            }
        }
        // 输出设置区域：横向排列
        HStack(spacing: 16) {
            Picker("类型", selection: $downloadType) {
                Text("视频+音频").tag(DownloadType.videoAndAudio)
                Text("仅音频").tag(DownloadType.audioOnly)
            }.pickerStyle(SegmentedPickerStyle())
            Button {
                self.showQualitySheet = true      // 手动弹出画质选择
            } label: {
                HStack(spacing: 2) {
                    Text("画质:")
                    Text(selectedQuality).bold()
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isFetchingFormats)
            Picker("字幕", selection: $subtitleOption) {
                Text(language == "zh" ? "无" : "None").tag("none")
                if availableSubLangs.isEmpty {
                    // 旧逻辑：未知时显示常用选项
                    Text("下载中文字幕").tag("zh")
                    Text("下载英文字幕").tag("en")
                } else {
                    ForEach(availableSubLangs, id: \.self) { code in
                        Text("下载 \(code)").tag(code)
                        Text("内嵌 \(code)").tag("embed-\(code)")
                    }
                    Text(language == "zh" ? "全部字幕" : "All").tag("all")
                    Text(language == "zh" ? "内嵌全部" : "Embed‑All").tag("embed-all")
                }
            }
            .frame(maxWidth: 160)
        }
        // 操作按钮与进度
        HStack(spacing: 10) {
            Button(language == "zh" ? "开始下载" : "Download") {
                downloadVideo()
            }
            .disabled(
                isDownloading
                || isInstallingDependencies
                || showQualitySheet
                || isFetchingFormats      // 解析时禁用
            )
            .buttonStyle(.borderedProminent)

            Button(language == "zh" ? "取消" : "Cancel") {
                cancelDownload()
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
            .disabled(!isDownloading)   // 仅在下载中可点
            .opacity(isDownloading ? 1 : 0.3)

            if isPremiumUser {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .help(language == "zh" ? "已检测到Premium Cookie" : "Premium Cookie detected")
            }
            HStack(spacing: 8) {
                ProgressView(value: downloadProgress)
                    .frame(width: 120)
                    .opacity(isDownloading ? 1 : 0.3)
                Text(downloadSpeed)
                    .font(.caption)

                // 批量下载计数（仅当总数 > 1 时显示）
                if totalTaskCount > 1 {
                    Text("\(currentTaskIndex)/\(totalTaskCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        // 输出栏，居下且无大框套小框
        ScrollView {
            // 高亮错误行
            Text(output)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .cornerRadius(8)
                .textSelection(.enabled)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ErrorLinePreferenceKey.self, value: lastErrorLine)
                    }
                )
        }.frame(maxHeight: 120)
        HStack {
            Text(language == "zh" ? "保存路径: \(savePath)" : "Save Path: \(savePath)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text("简哲制作")
                .font(.caption2)
                .foregroundColor(.gray)
        }
    }
    .padding()
    .frame(width: 620)
    .frame(minHeight: 580)
    .onAppear {
        // ===== 授权检测 =====
        let deviceID = currentDeviceID()
        if !allowedDeviceIDs.contains(deviceID) {
            // 显示弹窗并退出
            let alert = NSAlert()
            alert.messageText = "未授权的设备"
            alert.informativeText = "此应用仅限授权硬件使用。\n设备 ID: \(deviceID)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(at: ContentView.appSupportCookiesDir, withIntermediateDirectories: true)
        requestNotificationPermission()
        setupClipboardMonitoring()
        loadHistory()
        loadPreferences()

        if !dependencyCheckDone {
            checkDependenciesAndAutoUpdate()
            dependencyCheckDone = true
        }

        // 每24小时自动检测依赖
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            checkDependenciesAndAutoUpdate()
        }

        detectPremiumCookies()
        loadSupportedSites()
        // 显示欢迎页（每次都弹出）
        self.showWelcomeSheet = true          // always show on every launch
    }
    .sheet(isPresented: $showSettings) {
        SettingsView(
            savePath: $savePath,
            useProxy: $useProxy,
            proxyAddress: $proxyAddress,
            language: $language,
            cookiesMap: $cookiesMap,
            onCheckDependencies: checkDependenciesAndAutoUpdate,
            supportedSites: $supportedSites
        )
        .frame(width: 480, height: 540)
    }
    .sheet(isPresented: $showQualitySheet) {
        QualitySheet(options: qualitySelection,
                     selectedQuality: $selectedQuality)
        .frame(width: 240, height: 320)
    }
    .sheet(isPresented: $showWelcomeSheet) {
        WelcomeSheetView(disableWelcome: $disableWelcome) {
            self.showWelcomeSheet = false
        }
        .frame(width: 420, height: 300)
    }
}

// ====== 逻辑实现区域 ======
func updateSelectedFormat()
{
    // 若用户未手动选择，始终用最高画质回退
    if selectedQuality == "自动选择" {
        selectedFormat = "bestvideo+bestaudio/best"
        return
    }
    if let option = formatPickerOptions.first(where: { $0.label == selectedQuality }) {
        selectedFormat = option.code
    } else {
        selectedFormat = "bestvideo+bestaudio/best"
    }
}
/// 简单判定链接是否为 HTTP/HTTPS 开头
func isValidURL(_ url: String) -> Bool {
    return url.lowercased().starts(with: "http://") || url.lowercased().starts(with: "https://")
}

/// 调用 yt‑dlp ‑F 获取可用格式并更新 Picker
func fetchAvailableFormats(for url: String) {
    DispatchQueue.main.async { self.isFetchingFormats = true }
    guard isValidURL(url) else {
        DispatchQueue.main.async {
            self.output = self.language == "zh"
                ? "无效链接，无法解析画质。"
                : "Invalid URL – cannot fetch formats."
            self.isFetchingFormats = false
        }
        return
    }
    DispatchQueue.global().async {
        guard !url.isEmpty else {
            DispatchQueue.main.async { self.isFetchingFormats = false }
            return
        }
        // 选择 yt-dlp 可执行路径
        let execPath = FileManager.default.fileExists(atPath: ytDlpPath)
            ? ytDlpPath
            : (["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"].first {
                  FileManager.default.fileExists(atPath: $0)
              } ?? "")
        guard !execPath.isEmpty else {
            DispatchQueue.main.async { self.isFetchingFormats = false }
            return
        }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.standardOutput = pipe
        proc.standardError  = pipe     // 捕获错误输出 (stderr) 便于检测鉴权失败
        // 动态选择第一个存在 Cookie DB 的浏览器
        let candidateBrowsers = ["chrome", "edge", "brave", "vivaldi", "firefox"]
        var args = ["--no-colors"]
        if let first = candidateBrowsers.first(where: { browserHasCookieDB($0) }) {
            args += ["--cookies-from-browser", first]
        }
        args += ["-F", url]
        proc.arguments = args

        do { try proc.run() } catch {
            DispatchQueue.main.async { self.isFetchingFormats = false }
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else {
            DispatchQueue.main.async { self.isFetchingFormats = false }
            return
        }

        // 清理 ANSI 颜色码再检测
        let plain = out.replacingOccurrences(of: #"\u{001B}\[[0-9;]*m"#,
                                             with: "",
                                             options: .regularExpression)
        if plain.contains("requires authentication") ||
           plain.lowercased().contains("nsfw tweet requires authentication") ||
           plain.contains("KERROR: [twitter]") {
            self.showCookieAlert()
        }

        var list: [(label: String, code: String)] = []
        for line in out.split(separator: "\n") {
            // ---- 解析行，例如:
            // 137 mp4 1080p       │    83.3MiB    703k https │ ...
            // 299 mp4 1920x1080 60 │   275.3MiB   2324k https │ ...
            let comps = line.split { $0.isWhitespace }
            guard comps.count >= 3 else { continue }

            let id  = String(comps[0])               // 137
            let ext = String(comps[1])               // mp4 / webm / m4a …

            // 分辨率：优先抓 1440p / 1080p / 720p 这种 token；若不存在，则抓 1920x1080 → 1920×1080
            let resToken = comps.dropFirst(2).first { tok in
                tok.range(of: #"\d+p"#, options: .regularExpression) != nil ||
                tok.contains("x")
            } ?? (line.contains("audio only") ? "audio" : "video")
            var res = resToken.replacingOccurrences(of: "x", with: "×")
            if line.contains("HDR") { res += " HDR" }

            // 文件大小：允许前缀 ≈ 或 ~
            let sizeToken = comps.first { tok in
                tok.range(of: #"[≈~]?[\d\.]+(?:KiB|MiB|GiB|TiB|KB|MB|GB|TB)$"#,
                          options: .regularExpression) != nil
            }.map { String($0).replacingOccurrences(of: "≈", with: "~") } ?? "?"

            // 行过滤：只保留 mp4/webm 视频 或 audio only
            let isAudioOnly = line.contains("audio only")
            /// 除 mp4 外，YouTube 在 1440p/2160p SDR 常用 webm (313/271 等)
            let isVideo     = !isAudioOnly && (ext == "mp4" || ext == "webm")
            guard isAudioOnly || isVideo else { continue }

            list.append(("\(id) - \(res) (\(sizeToken))", id))
        }
        // ---- 仅保留目标 6 桶画质 + 最佳音频 ----
        // Bucket 定义：名称 + 最小高度
        let buckets: [(title: String, minH: Int)] = [
            ("最高画质 (8K)", 4320),
            ("最高画质 (4K)", 2160),
            ("2K (1440p)",    1440),
            ("高画质 (1080p)",1080),
            ("标准画质 (720p)",720),
            ("普通画质 (480p)",480)
        ]

        // Helper: 从 "1920×1080" 或 "1080p" 中提取高度
        func height(from res: String) -> Int {
            // 抓取所有 3‑4 位数字，取最小值作为竖直像素
            let nums = res.allRegexMatches(of: #"\d{3,4}"#).compactMap { Int($0) }
            return nums.min() ?? 0
        }

        // 1) 每个桶里存储独立的SDR/HDR键
        var pick: [String:(label:String,code:String)] = [:]
        for it in list where !it.label.contains("audio") {
            let isHDR = it.label.contains("HDR")
            // it.label 示例 "137 - 1920×1080 (83MiB)"
            let parts = it.label.split(separator: " ")
            guard parts.count > 2 else { continue }
            let resToken = String(parts[2])
            let h = height(from: resToken)
            for b in buckets where h >= b.minH {
                // 组合桶键：若 HDR → 追加 " HDR"
                let key = isHDR ? "\(b.title) HDR" : b.title
                // 若键尚未存在则直接存；存在则跳过(避免重复)
                if pick[key] == nil { pick[key] = it }
                break
            }
        }

        // 2) 选文件大小最大的 audio only
        let bestAudio = list.filter{ $0.label.contains("audio") }
            .max { lhs, rhs in
                func size(_ s:String)->Double {
                    let patt = #"[~≈]?([\d\.]+)"#
                    if let m = s.range(of: patt, options:.regularExpression) {
                        return Double(s[m].drop{ !$0.isNumber && $0 != "." }) ?? 0
                    }
                    return 0
                }
                return size(lhs.label) < size(rhs.label)
            }

        // 3) 组装新列表，保持固定顺序，支持同时列出SDR/HDR
        var newList:[(label:String, code:String)] = []
        for b in buckets {
            // 可能存在两种键：SDR / HDR
            for suffix in ["", " HDR"] {
                let key = b.title + suffix
                guard let it = pick[key] else { continue }
                let sizePart = it.label.split(separator:"(").last.map { "(" + $0 } ?? ""
                let bucketName = key         // key 自带 HDR 后缀
                newList.append(("\(bucketName) \(sizePart)", it.code))
            }
        }
        // 保证8K桶始终存在
        if !newList.contains(where: { $0.label.contains("8K") }) {
            newList.insert(("最高画质 (8K) (未检测)", "bestvideo[height>=4320]+bestaudio"), at: 0)
        }
        if let a = bestAudio {
            // 仅音频(mp3≈xxMiB) – 取括号内容
            let sizePart = a.label.split(separator:"(").last.map{ "≈" + $0 } ?? "(?)"
            newList.append(("仅音频 (mp3\(sizePart))", a.code))
        }

        if !newList.isEmpty { list = newList }
        // 若解析为空，则使用静态 formats 作为后备
        if list.isEmpty {
            list = formats
        }
        if !list.isEmpty {
            DispatchQueue.main.async {
                self.availableFormats  = list
                self.qualitySelection = list

                // 若当前 selectedQuality 是“自动选择”或已不在新列表中，则弹出画质选择
                let needSheet = self.selectedQuality == "自动选择"
                    || !list.contains(where: { $0.label == self.selectedQuality })

                if needSheet {
                    self.showQualitySheet = false      // 重置再触发
                    self.showQualitySheet = true
                }
            }
        }
        // ==== 获取字幕语言列表 ====
        DispatchQueue.global().async {
            let procSub = Process()
            let pipeSub = Pipe()
            procSub.executableURL = URL(fileURLWithPath: execPath)
            procSub.arguments = ["--no-warnings",
                                 "--list-subs",
                                 "--skip-download",
                                 url]
            procSub.standardOutput = pipeSub
            do { try procSub.run() } catch { return }
            let subData = pipeSub.fileHandleForReading.readDataToEndOfFile()
            guard let subOut = String(data: subData, encoding: .utf8) else { return }
            // 在 “Available subtitles for” 之后的行里找语言代码
            var langs: [String] = []
            for line in subOut.split(separator: "\n") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("*") ||
                   line.contains(":") { continue }
                // 行形如 "en, zh-CN" 或 "en             webvtt, ttml"
                let codes = line.split(separator: ",")
                for c in codes {
                    let code = c.trimmingCharacters(in: .whitespaces)
                    if !code.isEmpty && !langs.contains(code) { langs.append(code) }
                }
            }
            // ---- 只保留常用语言，避免菜单过长 ----
            let preferred = ["zh-CN","zh-Hans","zh-Hant","zh","en"]
            var final = langs.filter { preferred.contains($0) }
            if final.isEmpty {                     // 都不在常用列表 → 截前 8 个
                final = Array(langs.prefix(8))
            }
            DispatchQueue.main.async {
                self.availableSubLangs = final.sorted()
            }
        }
        DispatchQueue.main.async { self.isFetchingFormats = false }
    }
}
func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        DispatchQueue.main.async {
            self.notificationGranted = granted
            if let error = error {
                print("通知权限错误: \(error.localizedDescription)")
            }
        }
    }
}
func sendNotification(title: String, subtitle: String) {
    guard notificationGranted else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = subtitle
    content.sound = .default
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            print("通知发送失败: \(error.localizedDescription)")
        }
    }
}
func detectPremiumCookies() {
    autoDetectedCookies = [:]
    let home = NSHomeDirectory()
    let paths: [(String, String)] = [
        ("youtube.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("tiktok.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("douyin.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("bilibili.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("facebook.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("instagram.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("twitter.com", "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"),
        ("x.com",      "\(home)/Library/Application Support/Google/Chrome/Default/Cookies")
    ]
    var message = ""
    for (site, path) in paths {
        if FileManager.default.fileExists(atPath: path) {
            autoDetectedCookies[site] = path
            if isCookieExpired(path) {
                message += "⚠️ \(site) 的 Cookie 已过期，建议重新导出。\n"
            }
        }
    }
    isPremiumUser = !autoDetectedCookies.isEmpty
    if isPremiumUser {
        output = (language == "zh" ? "自动检测到以下站点 Cookies 支持 Premium 下载:\n" : "Detected cookies for Premium access:\n")
        output += autoDetectedCookies.keys.joined(separator: ", ") + "\n" + message
    }
}
/// Return the cookie file (if any) for the given URL.
/// All cookie files are expected to reside in `appSupportCookiesDir`
/// and be named by domain, e.g. youtube.com.txt, bilibili.txt, etc.
func cookieFileForURL(_ url: String) -> String? {
    // Map host → canonical cookie‑file name
    let nameMap: [String:String] = [
        "youtube.com": "youtube.txt",  "youtu.be" : "youtube.txt",
        "bilibili.com": "bilibili.txt",
        "tiktok.com"  : "tiktok.txt",
        "douyin.com"  : "douyin.txt",
        "twitter.com" : "x.com.txt",   "x.com": "x.com.txt",
        "facebook.com": "facebook.txt",
        "instagram.com": "instagram.txt",
    ]
    guard
        let host = URL(string: url)?.host ?? url.split(separator: "/").dropFirst(2).first.map(String.init)
    else { return nil }

    for (domain, file) in nameMap where host.contains(domain) {
        let p = ContentView.appSupportCookiesDir.appendingPathComponent(file).path
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil           // no cookie found


// ===== 新增: 判断指定浏览器的 Cookie 数据库是否存在 =====
func browserHasCookieDB(_ browser: String) -> Bool {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser.path
    let cookiePaths = [
        "chrome": "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",
        "edge": "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies",
        "brave": "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
        "vivaldi": "\(home)/Library/Application Support/Vivaldi/Default/Cookies",
        "firefox": "\(home)/Library/Application Support/Firefox/Profiles"
    ]
    guard let path = cookiePaths[browser] else { return false }
    return fileManager.fileExists(atPath: path)
}

}

// ===== 新增: 判断指定浏览器的 Cookie 数据库是否存在 =====
func browserHasCookieDB(_ browser: String) -> Bool {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let supportDir = homeDir.appendingPathComponent("Library/Application Support")

    let browserPaths: [String: String] = [
        "chrome": "Google/Chrome/Default/Cookies",
        "edge": "Microsoft Edge/Default/Cookies",
        "brave": "BraveSoftware/Brave-Browser/Default/Cookies",
        "vivaldi": "Vivaldi/Default/Cookies",
        "firefox": "Firefox/Profiles"
    ]

    guard let relativePath = browserPaths[browser] else { return false }
    let fullPath = supportDir.appendingPathComponent(relativePath).path
    return FileManager.default.fileExists(atPath: fullPath)
}

    /// 把一段文本拆分出所有合法 http/https 链接（空格 / 换行 / 逗号 均可分隔）
    func extractURLList(from text: String) -> [String] {
        text.split { $0.isWhitespace || $0 == "," }
            .map { String($0) }
            .filter { isValidURL($0) }
    }

    /// 单个链接的实际下载流程（原 downloadVideo 的主体已搬到这里）
    private func internalDownload(_ url: String) {
        // 👉 ---- 下面整段内容复制自原 downloadVideo() 开头至 self.runYTDLP(arguments:) 之间，
        //    唯一修改：把出现的 self.urlText 全部替换为 url
        //    以及将输出模板改用 self.outputTemplate，并写缩略图
        // ---------------
        // 若尚未抓到格式 ...
        if availableFormats.isEmpty {
            output += language == "zh"
                ? "\n正在解析可用画质，请稍后…"
                : "\nFetching available formats, please wait…"
            fetchAvailableFormats(for: url)
            return
        }
        if isFetchingFormats && selectedQuality == "自动选择" {
            output += language == "zh"
                ? "\n正在解析可用画质，请稍后…"
                : "\nFetching available formats, please wait…"
            return
        }
        if !isFetchingFormats && !availableFormats.isEmpty && selectedQuality == "自动选择" {
            showQualitySheet = false
            showQualitySheet = true
            return
        }
        updateSelectedFormat()
        if downloadType == .videoAndAudio,
           selectedQuality != "自动选择",
           selectedFormat.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            selectedFormat += "+bestaudio"
        }
        let placeholderRecord = DownloadRecord(title: "", url: url)
        self.downloadHistory.insert(placeholderRecord, at: 0)
        if self.downloadHistory.count > 20 { self.downloadHistory = Array(self.downloadHistory.prefix(20)) }
        self.saveHistory()
        DispatchQueue.global().async {
            let titleFetched = fetchTitle(for: url)
            DispatchQueue.main.async {
                if let idx = self.downloadHistory.firstIndex(where: { $0.id == placeholderRecord.id }) {
                    self.downloadHistory[idx].title = titleFetched
                    self.saveHistory()
                }
            }
        }
        isDownloading = true
        lastPercent = 0
        availableSubLangs = []
        downloadProgress = 0.0
        downloadSpeed = ""
        if let videoId = extractVideoId(from: url) {
            videoThumbnail = URL(string: "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg")
        } else { videoThumbnail = nil }

        // self.selectedQuality  = "自动选择"  // REMOVED: do not reset selectedQuality here

        var arguments: [String] = []
        arguments.append(url)
        if downloadType == .audioOnly {
            arguments += ["--extract-audio","--audio-format","mp3"]
        } else {
            arguments += ["--merge-output-format", videoFormat]
        }
        arguments += ["-o", "\(savePath)/\(outputTemplate)", "--newline", "--write-thumbnail"]
        // 字幕处理
        if subtitleOption == "all" {
            // 下载所有外挂字幕
            arguments += ["--write-subs"]
        } else if subtitleOption == "embed-all" {
            // 内嵌所有字幕
            arguments += ["--embed-subs"]
        } else if subtitleOption.hasPrefix("embed-") {
            // 内嵌指定语言，如 embed-zh-CN
            let code = String(subtitleOption.dropFirst("embed-".count))
            arguments += ["--embed-subs", "--sub-lang", code]
        } else if subtitleOption != "none" {
            // 下载指定语言外挂字幕（如 zh-CN / en / jp 等）
            arguments += ["--write-subs", "--sub-lang", subtitleOption]
        }
        // 画质选择逻辑
        if downloadType == .videoAndAudio {
            if selectedQuality == "自动选择" {
                arguments.append("-f")
                arguments.append("bestvideo+bestaudio/best")
            } else {
                let fallback = "\(selectedFormat)/bestvideo+bestaudio/best"
                arguments.append("-f")
                arguments.append(fallback)
            }
            arguments.append(contentsOf: ["-N", "8", "--http-chunk-size", "1M"])
        }
        if self.useProxy && !self.proxyAddress.isEmpty {
            arguments.append("--proxy")
            arguments.append(self.proxyAddress)
        }
        // cookies逻辑与原先一致
        var cookiePathToUse: String? = nil
        if let detectedCookie = cookieFileForURL(url) {
            cookiePathToUse = detectedCookie
            if isCookieExpired(detectedCookie) {
                DispatchQueue.main.async {
                    self.output += "\n⚠️ Cookie 文件已超过7天未更新，建议重新导出。"
                }
            }
        }
        let siteCookieMap: [String: String] = [
            "youtube.com": "youtube.txt",
            "youtu.be": "youtube.txt",
            "bilibili.com": "bilibili.txt",
            "tiktok.com": "tiktok.txt",
            "douyin.com": "douyin.txt",
            "x.com": "x.com.txt",
            "facebook.com": "facebook.txt",
            "instagram.com": "instagram.txt",
        ]
        let knownSites = ["youtube.com", "youtu.be", "bilibili.com", "tiktok.com", "douyin.com", "twitter.com", "x.com"]
        _ = knownSites.first(where: { url.contains($0) })
        if let cookiePathToUse = cookiePathToUse {
            arguments.append("--cookies")
            arguments.append(cookiePathToUse)
        } else if let site = siteCookieMap.first(where: { url.contains($0.key) })?.key,
                  let path = cookiesMap[site] {
            arguments.append("--cookies")
            arguments.append(path)
        }
        // ------- 自动回退：若尚未指定任何 Cookie 参数，统一尝试读取浏览器 -------
        if !arguments.contains("--cookies") && !arguments.contains("--cookies-from-browser") {
            let candidateBrowsers = ["chrome", "edge", "brave", "vivaldi", "firefox"]
            if let firstBrowser = candidateBrowsers.first(where: { browserHasCookieDB($0) }) {
                arguments.append("--cookies-from-browser")
                arguments.append(firstBrowser)
            }
        }
        // 若未注入任何 Cookie 参数，则提示用户导入
        if !arguments.contains("--cookies") && !arguments.contains("--cookies-from-browser") {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = self.language == "zh" ? "需要登录 Cookie" : "Login Cookie Required"
                alert.informativeText = self.language == "zh"
                    ? "该站点需要登录认证，但未检测到浏览器 Cookie。请在设置中导入对应站点的 Cookie 文件，否则可能下载失败。"
                    : "This site requires authentication but no browser cookies were detected. Please import the site's cookie file in Settings, otherwise the download may fail."
                alert.addButton(withTitle: self.language == "zh" ? "前往设置" : "Open Settings")
                alert.addButton(withTitle: self.language == "zh" ? "继续" : "Continue")
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    self.showSettings = true
                }
            }
        }
        if FileManager.default.fileExists(atPath: self.ffmpegPath) {
            arguments.append("--ffmpeg-location")
            arguments.append(self.ffmpegPath)
        }
        // --- 额外处理：保证导出文件 QuickTime / iOS 可直接播放 ---
        if ensureQuickTimeCompatibility {
            // 1) 让 yt‑dlp 在同等画质下优先选 H.264 / AAC
            arguments += ["--format-sort", "vcodec:h264,acodec:aac,ext:mp4"]

            // 2) 如下载得到的 still 不是 MP4(H.264)，则 remux / 转码一次
            //    （remux 很快；仅在源文件是 VP9/AV1 时才会触发转码）
            arguments += ["--recode-video", "mp4"]

            // 3) 统一输出封装格式
            if !arguments.contains("--merge-output-format") {
                arguments += ["--merge-output-format", "mp4"]
            }
        }
        self.runYTDLP(arguments: arguments)
    }

    func downloadVideo() {
        let urlList = extractURLList(from: urlText)
        guard !urlList.isEmpty else {
            output = language == "zh" ? "请输入有效链接！" : "Please enter at least one valid URL!"
            return
        }
        // 顺序批量下载
        DispatchQueue.global().async {
            for (idx, link) in urlList.enumerated() {
                DispatchQueue.main.async {
                    self.totalTaskCount  = urlList.count
                    self.currentTaskIndex = idx + 1
                    // 不再修改 urlText，保留用户原始批量输入
                    self.output = (self.language == "zh"
                                   ? "（第\(idx + 1)/\(urlList.count)条）开始下载: "
                                   : "(Task \(idx + 1)/\(urlList.count)) Downloading: ") + link
                }
                internalDownload(link)

                // 等待当前下载/解析完成，再进行下一条
                while self.isDownloading || self.isFetchingFormats {
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            // 确保解析 / 下载流程全部结束后再给出完成提示
            while self.isDownloading || self.isFetchingFormats {
                Thread.sleep(forTimeInterval: 0.3)
            }
            DispatchQueue.main.async {
                self.currentTaskIndex = 0
                self.totalTaskCount   = 0
                self.output += self.language == "zh" ? "\n🎉 所有任务完成" : "\n🎉 All tasks finished"
            }
        }
    }

// MARK: - Global Helper
/// 判断 Cookie 文件是否超过 7 天未修改
func isCookieExpired(_ path: String) -> Bool {
    guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
          let modifyDate = attr[.modificationDate] as? Date else { return true }
    return Date().timeIntervalSince(modifyDate) > 7*24*60*60
}
func runYTDLP(arguments: [String]) {
    DispatchQueue.global().async {
        let process = Process()
        self.downloadProcess = process // 用于取消
        let pipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(ContentView.appSupportDir.path):\(environment["PATH"] ?? "")"
        // 显式告诉 yt-dlp ffmpeg 位置，防止 “ffmpeg not found” 警告
        environment["FFMPEG_LOCATION"] = self.ffmpegPath
        if FileManager.default.fileExists(atPath: self.ytDlpPath) {
            process.executableURL = URL(fileURLWithPath: self.ytDlpPath)
        } else {
            let possiblePaths = [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/usr/bin/yt-dlp"
            ]
            var executablePath: String?
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path) {
                    executablePath = path
                    break
                }
            }
            guard let path = executablePath else {
                DispatchQueue.main.async {
                    self.output = self.language == "zh" ?
                    "未找到 yt-dlp，请安装依赖" :
                    "yt-dlp not found, please install dependencies"
                    self.isDownloading = false
                }
                return
            }
            process.executableURL = URL(fileURLWithPath: path)
        }
        // Cookie 参数已在 downloadVideo() 中按需动态注入，
        // 这里直接使用传入的 arguments，避免重复或无效的默认路径
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = environment
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data  = handle.availableData
            guard !data.isEmpty else { return }

            // Try several encodings – yt‑dlp occasionally outputs Latin‑1
            let raw = String(data: data, encoding: .utf8) ??
                      String(data: data, encoding: .isoLatin1) ??
                      String(data: data, encoding: .ascii) ??
                      "<无法解析输出>\n"

            // 去除 ANSI 颜色码
            let plain = raw.replacingOccurrences(of: #"\u{001B}\[[0-9;]*m"#,
                                                with: "",
                                                options: .regularExpression)
            // 发现 Twitter NSFW 认证提示，立即弹窗
            if plain.lowercased().contains("nsfw tweet requires authentication") ||
               plain.contains("KERROR: [twitter]") {
                DispatchQueue.main.async { self.showCookieAlert() }
            }

            // ----------- Progress / Merger handling ------------
            // Many consecutive “[download] … Unknown B/s” lines will make the
            // Text view grow quickly and cause UI jank.  We:
            //   1.   Skip duplicate progress lines
            //   2.   Throttle updates to at most 5 fps
            if raw.contains("[download]") {
                // Don’t spam the UI with identical lines
                if raw == self.lastProgressLine { return }
                self.lastProgressLine = raw

                // Throttle to 5 fps
                let now = Date()
                if now.timeIntervalSince(self.lastUIUpdate) < 0.2 { return }
                self.lastUIUpdate = now
            }

            // Detect “Merger” phase so the user knows it hasn’t frozen
            if raw.contains("[Merger]") {
                DispatchQueue.main.async {
                    self.downloadSpeed = self.language == "zh" ? "合并中…" : "Merging…"
                }
            }

            // ----------- Error highlighting ------------
            if raw.contains("ERROR:") ||
               raw.lowercased().contains("unsupported url") {
                let err = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.lastErrorLine = err
                    self.output = "❌ \(err)\n--------------------------------\n" + self.output
                }
                return            // already handled
            }

            // ----------- Append normal output & parse progress ------------
            DispatchQueue.main.async {
                self.output += raw
                if raw.contains("[download]") {
                    self.parseDownloadProgress(line: raw)
                }
            }
        }
        do {
            try process.run()
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.downloadProcess = nil
                self.isDownloading = false
                self.downloadSpeed   = "0 B/s"
                let success = process.terminationStatus == 0
                if success {
                    let title = self.language == "zh" ? "下载完成" : "Download Complete"
                    let message = self.language == "zh"
                        ? "视频已保存到 \(self.savePath)"
                        : "Video saved to \(self.savePath)"
                    self.sendNotification(title: title, subtitle: message)
                    // yt‑dlp 退出码为 0，但正文仍可能包含认证失败提示
                    if self.output.contains("requires authentication") ||
                       self.output.lowercased().contains("nsfw tweet requires authentication") {
                        self.showCookieAlert()
                    }
                } else {
                    if self.output.contains("requires authentication") || self.output.contains("Sign in") {
                        self.output += self.language == "zh"
                            ? "\n⚠️ 此站点需要登录。已尝试自动读取浏览器 Cookie，若仍失败，请在设置中手动导入。"
                            : "\n⚠️ Authentication required. Tried browser cookies; if it still fails, import cookies manually in Settings."
                    }
                    let title = self.language == "zh" ? "下载失败" : "Download Failed"
                    self.sendNotification(title: title, subtitle: lineLastError(self.output))
                    // 若失败原因与登录认证有关，则弹窗提醒导入 Cookie
                    if self.output.contains("requires authentication") ||
                       self.output.lowercased().contains("nsfw tweet requires authentication") {
                        let alert = NSAlert()
                        alert.messageText = self.language == "zh"
                            ? "需要登录 Cookie"
                            : "Login Cookie Required"
                        alert.informativeText = self.language == "zh"
                            ? "检测到该链接需要登录，但自动读取浏览器 Cookie 仍未通过验证。\n请在设置中导入对应站点的 Cookie 文件，然后重试下载。"
                            : "This link requires authentication, and browser cookies were not sufficient.\nPlease import the site's cookie file in Settings and try again."
                        alert.addButton(withTitle: self.language == "zh" ? "前往设置" : "Open Settings")
                        alert.addButton(withTitle: self.language == "zh" ? "好" : "OK")
                        let resp = alert.runModal()
                        if resp == .alertFirstButtonReturn {
                            self.showSettings = true
                        }
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.downloadProcess = nil
                self.isDownloading = false
                self.downloadSpeed   = "0 B/s"
                self.output = self.language == "zh" ?
                "下载失败：\(error.localizedDescription)" :
                "Download failed: \(error.localizedDescription)"
                let title = self.language == "zh" ? "下载失败" : "Download Failed"
                self.sendNotification(title: title, subtitle: error.localizedDescription)
            }
        }
    }
}
func cancelDownload() {
    if let process = downloadProcess {
        process.terminate()
        downloadProcess = nil
    }
    isDownloading = false
    downloadProgress = 0.0
    downloadSpeed = ""
    currentTaskIndex = 0
    totalTaskCount   = 0
    output += "\n" + (language == "zh" ? "下载已取消" : "Download cancelled")
}
func parseDownloadProgress(line: String) {
    let pattern = #"(\d+\.\d+)%.*?at\s+([\d\.]+\w+/s)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let percentRange = Range(match.range(at: 1), in: line),
          let speedRange   = Range(match.range(at: 2), in: line) else { return }

    let percentString = String(line[percentRange])
    let speedString   = String(line[speedRange])
    guard let percent = Double(percentString) else { return }

    // 只允许单调递增，避免多文件下载时进度回跳
    if percent + 0.01 < lastPercent { return }
    lastPercent = percent

    self.downloadProgress = percent / 100.0
    self.downloadSpeed = self.language == "zh" ? "速度: \(speedString)" : "Speed: \(speedString)"
}
func extractThumbnailUrl(from url: String) -> URL? {
    if let videoId = self.extractVideoId(from: url) {
        let urlsToTry = [
            "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg",
            "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg",
            "https://img.youtube.com/vi/\(videoId)/mqdefault.jpg"
        ]
        for urlString in urlsToTry {
            if let url = URL(string: urlString) {
                return url
            }
        }
    }
    return nil
}
func extractVideoId(from url: String) -> String? {
    let pattern = #"(?:youtube\.com\/watch\?v=|youtu\.be\/)([a-zA-Z0-9_-]{11})"#
    let regex = try? NSRegularExpression(pattern: pattern)
    if let match = regex?.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
       let idRange = Range(match.range(at: 1), in: url) {
        return String(url[idRange])
    }
    return nil
}
func checkDependenciesAndAutoUpdate() {
    self.isInstallingDependencies = true   // start spinner
    self.showDependencyStatus = true
    self.dependenciesStatus = self.language == "zh" ? "正在检查依赖..." : "Checking dependencies..."
    // 若 yt-dlp 与 ffmpeg 均已存在且上次检查在 24h 内，则快速通过
    if FileManager.default.fileExists(atPath: self.ytDlpPath),
       FileManager.default.fileExists(atPath: self.ffmpegPath),
       Date().timeIntervalSince(self.lastUpdateCheck) < 86400 {
        DispatchQueue.main.async {
            self.dependenciesStatus = self.language == "zh" ? "依赖已就绪" : "Dependencies ready"
            self.showDependencyStatus = true        // 始终可见
            self.isInstallingDependencies = false
        }
        return
    }
    DispatchQueue.global().async {
        try? FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
        // 1. 检查 yt-dlp 主体
        if !FileManager.default.fileExists(atPath: self.ytDlpPath) {
            DispatchQueue.main.async {
                self.dependenciesStatus = self.language == "zh" ? "正在下载 yt-dlp..." : "Downloading yt-dlp..."
                // Initialize output buffer for dependency download
                self.output = self.language == "zh" ? "[依赖] 开始下载 yt-dlp..." : "[Dependency] Start downloading yt-dlp..."
            }
            self.downloadDependency(
                url: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!,
                destination: Self.appSupportYtDlpPath)
        }
        // 2. 自动检查 yt-dlp 版本并自动升级
        self.checkAndUpdateYtDlpVersion()
        // 新增：确保 yt-dlp 总是从官方仓库更新
        DispatchQueue.global().async {
            self.updateYtDlpIfNeeded()
        }
        // 3. ffmpeg
        if !FileManager.default.fileExists(atPath: self.ffmpegPath) {
            DispatchQueue.main.async {
                self.dependenciesStatus = self.language == "zh" ? "正在下载 ffmpeg..." : "Downloading ffmpeg..."
                self.output = self.language == "zh" ? "[依赖] 开始下载 ffmpeg..." : "[Dependency] Start downloading ffmpeg..."
            }
            self.downloadDependency(
                url: URL(string: "https://evermeet.cx/ffmpeg/ffmpeg-6.0.zip")!,
                destination: Self.appSupportFfmpegPath + ".zip")
            let unzipTask = Process()
            unzipTask.launchPath = "/usr/bin/unzip"
            unzipTask.arguments = ["-o", Self.appSupportFfmpegPath + ".zip", "-d", Self.appSupportDir.path]
            unzipTask.launch()
            unzipTask.waitUntilExit()
            // 尝试获取解压后的 ffmpeg 可执行路径
            var foundFFmpegPath: String?
            let directExtractPath = Self.appSupportDir.appendingPathComponent("ffmpeg").path          // 常见：zip 直接解压得到 ffmpeg
            let folderExtractPath = Self.appSupportDir.appendingPathComponent("ffmpeg-6.0/ffmpeg").path // 旧版本 zip 可能带子目录

            if FileManager.default.fileExists(atPath: directExtractPath) {
                foundFFmpegPath = directExtractPath
            } else if FileManager.default.fileExists(atPath: folderExtractPath) {
                foundFFmpegPath = folderExtractPath
            }

            // 如在子目录，移动到统一位置
            if let src = foundFFmpegPath, src != Self.appSupportFfmpegPath {
                try? FileManager.default.moveItem(atPath: src, toPath: Self.appSupportFfmpegPath)
            }

            guard FileManager.default.fileExists(atPath: Self.appSupportFfmpegPath) else {
                print("❌ 解压后仍未发现 ffmpeg，可执行文件可能不存在")
                return
            }
            try? FileManager.default.removeItem(atPath: Self.appSupportFfmpegPath + ".zip")
            self.setExecutablePermission(path: Self.appSupportFfmpegPath)
            // 去除下载文件的隔离属性，确保可执行
            let xa1 = Process()
            xa1.launchPath = "/usr/bin/xattr"
            xa1.arguments   = ["-d", "com.apple.quarantine", Self.appSupportFfmpegPath]
            try? xa1.run(); xa1.waitUntilExit()
        }
        if FileManager.default.fileExists(atPath: Self.appSupportYtDlpPath) {
            self.setExecutablePermission(path: Self.appSupportYtDlpPath)
            let xa2 = Process()
            xa2.launchPath = "/usr/bin/xattr"
            xa2.arguments   = ["-d", "com.apple.quarantine", Self.appSupportYtDlpPath]
            try? xa2.run(); xa2.waitUntilExit()
        }
        DispatchQueue.main.async {
            self.isInstallingDependencies = false
            self.dependencyCheckDone = true
            var status = ""
            if FileManager.default.fileExists(atPath: self.ytDlpPath) {
                status += self.language == "zh" ? "yt-dlp ✓\n" : "yt-dlp ✓\n"
            } else {
                status += self.language == "zh" ? "yt-dlp ✗\n" : "yt-dlp ✗\n"
            }
            if FileManager.default.fileExists(atPath: self.ffmpegPath) {
                status += self.language == "zh" ? "ffmpeg ✓" : "ffmpeg ✓"
            } else {
                status += self.language == "zh" ? "ffmpeg ✗" : "ffmpeg ✗"
            }
            // 新增: 显示所有 cookiesMap 的过期状态
            for (site, path) in self.cookiesMap {
                status += "\n\(site): "
                if FileManager.default.fileExists(atPath: path) {
                    status += self.isCookieExpired(path) ? (self.language == "zh" ? "⚠️ Cookie 过期" : "⚠️ Expired Cookie") : (self.language == "zh" ? "✓ 有效 Cookie" : "✓ Valid Cookie")
                } else {
                    status += self.language == "zh" ? "❌ Cookie 未找到" : "❌ Cookie Not Found"
                }
            }
            self.output = (self.language == "zh" ? "依赖检查完成:\n\(status)" : "Dependency check complete:\n\(status)") + "\n" + status
            self.detectPremiumCookies()
            // 新增：每次检查后更新 lastUpdateCheck
            DispatchQueue.main.async {
                self.lastUpdateCheck = Date()
                UserDefaults.standard.set(self.lastUpdateCheck, forKey: "lastUpdateCheck")
            }
            // 依赖已就绪提示
            self.dependenciesStatus = self.language == "zh" ? "依赖已就绪" : "Dependencies ready"
            let missing = !(FileManager.default.fileExists(atPath: self.ytDlpPath) &&
                            FileManager.default.fileExists(atPath: self.ffmpegPath))
            if missing {
                // 保持黄色横幅显示，提示用户缺失依赖
                self.dependenciesStatus += self.language == "zh"
                    ? "\n⚠️ 检测到依赖缺失，请在设置中重新安装。"
                    : "\n⚠️ Missing dependencies detected. Re‑install from Settings."
                self.showDependencyStatus = true
            } else {
                // 依赖齐全也保持显示
                self.showDependencyStatus = true
            }
        }
    }
}
func checkAndUpdateYtDlpVersion() {
    let versionCheckTask = Process()
    let pipe = Pipe()
    if FileManager.default.fileExists(atPath: self.ytDlpPath) {
        versionCheckTask.launchPath = self.ytDlpPath
    } else {
        return
    }
    versionCheckTask.arguments = ["--version"]
    versionCheckTask.standardOutput = pipe
    do {
        try versionCheckTask.run()
    } catch {
        return
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let versionString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !versionString.isEmpty else { return }
    // 如有新版本自动下载
    // 这里只简单演示，实际上还可联网检查版本号
    // 你可以扩展为：比对 github 最新 release，再决定是否自动覆盖
}
func setExecutablePermission(path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+x", path]
    try? process.run()
    process.waitUntilExit()
}

func setupClipboardMonitoring() {
    // 自动粘贴链接功能已取消
    // Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    //     if let clipboardString = NSPasteboard.general.string(forType: .string),
    //        isValidURL(clipboardString),
    //        clipboardString != self.urlText {
    //         self.urlText = clipboardString
    //     }
    // }
}
func saveHistory() {
    // 自动维护下载历史最多20条
    if downloadHistory.count > 20 {
        downloadHistory = Array(downloadHistory.prefix(20))
    }
    if let data = try? NSKeyedArchiver.archivedData(withRootObject: Array(downloadHistory.prefix(20)), requiringSecureCoding: false) {
        UserDefaults.standard.set(data, forKey: "downloadHistory")
    }
}
func loadHistory() {
    if let data = UserDefaults.standard.data(forKey: "downloadHistory") {
        if #available(macOS 10.14, *) {
            if let history = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, DownloadRecord.self], from: data) as? [DownloadRecord] {
                self.downloadHistory = history
            } else {
                self.downloadHistory = []
            }
        } else {
            if let history = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [DownloadRecord] {
                self.downloadHistory = history
            } else {
                self.downloadHistory = []
            }
        }
    } else {
        self.downloadHistory = []
    }
}
func savePreferences() {
    UserDefaults.standard.set(self.savePath, forKey: "savePath")
    UserDefaults.standard.set(self.useProxy, forKey: "useProxy")
    UserDefaults.standard.set(self.proxyAddress, forKey: "proxyAddress")
    UserDefaults.standard.set(self.language, forKey: "language")
    UserDefaults.standard.set(self.cookiesMap, forKey: "cookiesMap")
}
func loadPreferences() {
    self.savePath = UserDefaults.standard.string(forKey: "savePath") ?? "\(NSHomeDirectory())/Downloads"
    self.useProxy = UserDefaults.standard.bool(forKey: "useProxy")
    self.proxyAddress = UserDefaults.standard.string(forKey: "proxyAddress") ?? ""
    self.language = UserDefaults.standard.string(forKey: "language") ?? "zh"
    if let map = UserDefaults.standard.dictionary(forKey: "cookiesMap") as? [String: String] {
        self.cookiesMap = map
    }
}
}


// ======= 画质弹窗 =======
struct QualitySheet: View {
    var options: [(label: String, code: String)]
    
    @Binding var selectedQuality: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 10) {
            Text("选择画质 / Pick Quality")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.code) { opt in
                        Button(action: {
                            selectedQuality = opt.label
                            dismiss()
                        }) {
                            HStack {
                                Text(opt.label)
                                Spacer()
                                if opt.label == selectedQuality {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(width: 220, height: 260)
            Button("关闭 / Close") { dismiss() }
                .padding(.top, 6)
        }
        .padding()
    }
}

// ======= 欢迎页视图 =======
struct WelcomeSheetView: View {
    @Binding var disableWelcome: Bool
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("欢迎使用 • 极简下载器")
                .font(.title2).bold()
            Text("作者：简哲\n为 macOS 提供一键多站点高清视频下载支持HDR、格式转换、批量处理等功能。")
                .multilineTextAlignment(.center)
                .font(.body)
            Text("使用步骤：\n① 粘贴或自动检测链接\n② 选择画质/字幕\n③ 点击开始下载")
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            HStack {
                Button("不再提醒") {
                    disableWelcome = true
                    onDismiss()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("开始使用") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// ======= 子视图 =======

struct HistoryView: View {
@Binding var history: [String]
@Binding var language: String
var onSelect: (String) -> Void

var body: some View {
    if !history.isEmpty {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(history, id: \.self) { url in
                    Button(action: {
                        onSelect(url)
                    }) {
                        Text(self.extractVideoId(from: url) ?? url)
                            .lineLimit(1)
                            .font(.caption2)
                            .padding(5)
                            .background(Color.gray.opacity(0.18))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 30)
    }
}
private func extractVideoId(from url: String) -> String? {
    if let range = url.range(of: "v=") {
        return String(url[range.upperBound...])
    } else if let range = url.range(of: "youtu.be/") {
        return String(url[range.upperBound...])
    }
    return nil
}
}

struct SettingsView: View {
@Binding var savePath: String
@Binding var useProxy: Bool
@Binding var proxyAddress: String
@Binding var language: String
@Binding var cookiesMap: [String: String]
var onCheckDependencies: () -> Void
@Binding var supportedSites: [String]
@Environment(\.dismiss) var dismiss

// 原始设置备份
@State private var originalSavePath = ""
@State private var originalUseProxy = false
@State private var originalProxyAddress = ""
@State private var originalLanguage = "zh"
@State private var originalCookiesMap: [String: String] = [:]

var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text(language == "zh" ? "设置" : "Settings")
                .font(.title)
                .padding(.bottom)
            VStack(alignment: .leading) {
                Text(language == "zh" ? "保存路径:" : "Save Path:")
                HStack {
                    TextField(language == "zh" ? "保存路径" : "Save Path", text: $savePath)
                        .textFieldStyle(.roundedBorder)
                    Button(language == "zh" ? "浏览..." : "Browse...") {
                        selectSavePath()
                    }
                }
            }
            VStack(alignment: .leading) {
                Toggle(isOn: $useProxy) {
                    Text(language == "zh" ? "使用代理" : "Use Proxy")
                }
                if useProxy {
                    TextField(language == "zh" ? "代理地址 (http://ip:port)" : "Proxy Address (http://ip:port)", text: $proxyAddress)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading) {
                Text(language == "zh" ? "语言:" : "Language:")
                Picker(selection: $language, label: Text("")) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            VStack(alignment: .leading) {
                Text(language == "zh" ? "Cookies 文件:" : "Cookies Files:")
                if cookiesMap.isEmpty {
                    Text(language == "zh" ? "未设置（将自动使用 Chrome Cookies）" : "Not set (will use Chrome Cookies automatically)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cookiesMap.sorted(by: { $0.key < $1.key }), id: \.key) { key, path in
                            HStack {
                                Text(key)
                                    .font(.caption)
                                    .bold()
                                    .frame(width: 80, alignment: .leading)
                                Text(path)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if FileManager.default.fileExists(atPath: path) {
                                    if isCookieExpired(path) {
                                        Text(language == "zh" ? "⚠️ 过期" : "⚠️ Expired")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    } else {
                                        Text("✓")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                    }
                                } else {
                                    Text(language == "zh" ? "❌ 未找到" : "❌ Not Found")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                Button(language == "zh" ? "导入多个站点 Cookie..." : "Import Multiple Site Cookies...") {
                    importCookies()
                }
            }
            Button(language == "zh" ? "使用教程" : "Tutorial") {
                if let url = URL(string: "https://www.youtube.com") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            // 支持的站点显示逻辑（改为跳转链接）
            Link(destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!) {
                Text(language == "zh" ? "点击查看支持的站点列表" : "View Supported Sites")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .underline()
            }
            Divider()
            HStack {
                Button(language == "zh" ? "检查依赖" : "Check Dependencies") {
                    self.onCheckDependencies()
                }
                Button(language == "zh" ? "清除依赖并重装" : "Reinstall Dependencies") {
                    clearDependencies()
                    onCheckDependencies()
                }
                .foregroundColor(.red)
                Spacer()
                Button(language == "zh" ? "保存设置" : "Save Settings") {
                    savePreferences()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button(language == "zh" ? "取消" : "Cancel") {
                    // Restore originals
                    savePath = originalSavePath
                    useProxy = originalUseProxy
                    proxyAddress = originalProxyAddress
                    language = originalLanguage
                    cookiesMap = originalCookiesMap
                    dismiss()
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 400)
        .frame(minHeight: 460)
    }
    // 在最外层 VStack 上添加 .onSubmit 修饰符
    .onSubmit {
        savePreferences()
        dismiss()
    }
    .onAppear {
        originalSavePath = savePath
        originalUseProxy = useProxy
        originalProxyAddress = proxyAddress
        originalLanguage = language
        originalCookiesMap = cookiesMap
    }
}

// MARK: - Helpers
/// 删除 Application Support 里的 yt‑dlp 与 ffmpeg，可重新下载
func clearDependencies() {
    let appSupportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.jianzhe.yt-dlp")
    let paths = ["yt-dlp", "ffmpeg"].map {
        appSupportDir.appendingPathComponent($0).path
    }
    for p in paths where FileManager.default.fileExists(atPath: p) {
        try? FileManager.default.removeItem(atPath: p)
    }
}
func selectSavePath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
        savePath = url.path
    }
}
    func importCookies() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!, .json]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let cookieStoreDir = ContentView.appSupportCookiesDir
            try? FileManager.default.createDirectory(at: cookieStoreDir, withIntermediateDirectories: true)
            for url in panel.urls {
                let fileName = url.lastPathComponent.lowercased()
                if fileName.contains("youtube") {
                    let dest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: dest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
                    cookiesMap["youtube.com"] = dest
                    if isCookieExpired(dest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("bilibili") {
                    let bilibiliDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: bilibiliDest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: bilibiliDest)
                    cookiesMap["bilibili.com"] = bilibiliDest
                    if isCookieExpired(bilibiliDest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("facebook") {
                    let dest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: dest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
                    cookiesMap["facebook.com"] = dest
                    if isCookieExpired(dest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("instagram") || fileName.contains("ins") {
                    let instaDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: instaDest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: instaDest)
                    cookiesMap["instagram.com"] = instaDest
                    if isCookieExpired(instaDest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("tiktok") {
                    let tiktokDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: tiktokDest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: tiktokDest)
                    cookiesMap["tiktok.com"] = tiktokDest
                    if isCookieExpired(tiktokDest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("twitter") || fileName.contains("x.com") {
                    let twitterDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: twitterDest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: twitterDest)
                    cookiesMap["twitter.com"] = twitterDest
                    cookiesMap["x.com"] = twitterDest    // alias
                    if isCookieExpired(twitterDest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else if fileName.contains("douyin") {
                    let douyinDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                    try? FileManager.default.removeItem(atPath: douyinDest)
                    try? FileManager.default.copyItem(atPath: url.path, toPath: douyinDest)
                    cookiesMap["douyin.com"] = douyinDest
                    if isCookieExpired(douyinDest) {
                        let alert = NSAlert()
                        alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                        alert.informativeText = language == "zh"
                            ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                            : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                        alert.runModal()
                    }
                } else {
                    // 让用户选择站点标识
                    let domain = promptUserForSite(for: url)
                    if !domain.isEmpty {
                        let customDest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
                        try? FileManager.default.removeItem(atPath: customDest)
                        try? FileManager.default.copyItem(atPath: url.path, toPath: customDest)
                        cookiesMap[domain] = customDest
                        if isCookieExpired(customDest) {
                            let alert = NSAlert()
                            alert.messageText = language == "zh" ? "Cookie 可能已失效" : "Cookie might be expired"
                            alert.informativeText = language == "zh"
                                ? "文件 \(url.lastPathComponent) 修改时间超过 7 天，可能需要重新导出。"
                                : "File \(url.lastPathComponent) was modified more than 7 days ago and may be invalid."
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }
/// 弹窗提示让用户为未知 cookie 文件指定域名
func promptUserForSite(for url: URL) -> String {
    let alert = NSAlert()
    alert.messageText = language == "zh" ? "未知站点 Cookie 文件" : "Unknown Site Cookie File"
    alert.informativeText = (language == "zh" ?
        "请为文件 \(url.lastPathComponent) 指定对应的站点域名（如 youtube.com）：" :
        "Please specify the site domain (e.g. youtube.com) for file \(url.lastPathComponent):")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    alert.accessoryView = input
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        return input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        return ""
    }
}
func savePreferences() {
    UserDefaults.standard.set(savePath, forKey: "savePath")
    UserDefaults.standard.set(useProxy, forKey: "useProxy")
    UserDefaults.standard.set(proxyAddress, forKey: "proxyAddress")
    UserDefaults.standard.set(language, forKey: "language")
    UserDefaults.standard.set(cookiesMap, forKey: "cookiesMap")
}
}


// 注意：loadThumbnail 在全局线程调用 syncRequest，切勿在主线程直接调用此同步方法！
// 获取视频标题
func fetchTitle(for url: String) -> String {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    let ytDlpPath = ContentView.appSupportYtDlpPath
    process.executableURL = URL(fileURLWithPath: ytDlpPath)
    process.arguments = ["--get-title", url]
    do {
        try process.run()
    } catch {
        return ""
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}


// 占位: 加载支持的站点逻辑（避免找不到符号错误）
func loadSupportedSites() {
    // TODO: 实现加载支持站点的逻辑
}

// 下载历史记录结构体
class DownloadRecord: NSObject, NSSecureCoding, Identifiable {
    static var supportsSecureCoding: Bool { true }
    var id = UUID()
    var title: String
    var url: String

    init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    required convenience init?(coder: NSCoder) {
        guard let title = coder.decodeObject(of: NSString.self, forKey: "title") as String?,
              let url = coder.decodeObject(of: NSString.self, forKey: "url") as String? else {
            return nil
        }
        self.init(title: title, url: url)
    }

    func encode(with coder: NSCoder) {
        coder.encode(title, forKey: "title")
        coder.encode(url, forKey: "url")
    }

    // Identifiable
    override var hash: Int { id.hashValue }
    static func == (lhs: DownloadRecord, rhs: DownloadRecord) -> Bool {
        lhs.id == rhs.id
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DownloadRecord else { return false }
        return self == other
    }
}

// ====== 优化依赖检测逻辑: App 启动时仅首次或距上次检查超过 24 小时才进行依赖检测 ======

extension ContentView {
func checkDependenciesIfNeeded() {
    let now = Date()
    if let lastCheck = UserDefaults.standard.object(forKey: "lastDependencyCheckDate") as? Date {
        if now.timeIntervalSince(lastCheck) > 86400 {
            checkDependenciesAndAutoUpdate()
            UserDefaults.standard.set(now, forKey: "lastDependencyCheckDate")
        }
    } else {
        checkDependenciesAndAutoUpdate()
        UserDefaults.standard.set(now, forKey: "lastDependencyCheckDate")
    }
}
}

// MARK: - Global Helper (shared across views)
/// 判断 Cookie 文件是否超过 7 天未修改
func isCookieExpired(_ path: String) -> Bool {
    guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
          let modifyDate = attr[.modificationDate] as? Date else { return true }
    return Date().timeIntervalSince(modifyDate) > 7*24*60*60
}

/// 从完整输出中提取最后一行（可能包含错误信息）
func lineLastError(_ full: String) -> String {
    return full.split(separator: "\n").last.map(String.init) ?? ""
}


// MARK: - Cookie Alert Helper
extension ContentView {
    /// 弹出“需要登录 Cookie”提示，并可直接导入 Cookie 或进入设置
    func showCookieAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = self.language == "zh" ? "需要登录 Cookie" : "Login Cookie Required"
            alert.informativeText = self.language == "zh"
                ? "检测到该链接需要登录，但未检测到有效 Cookie。请导入 Cookie 或前往设置。"
                : "This link requires authentication, but no valid cookie was found. Import a cookie file or open Settings."
            // 三个按钮：1 导入 Cookie 2 设置 3 取消
            alert.addButton(withTitle: self.language == "zh" ? "导入 Cookie…" : "Import Cookie…")   // .alertFirstButtonReturn
            alert.addButton(withTitle: self.language == "zh" ? "前往设置" : "Open Settings")           // .alertSecondButtonReturn
            alert.addButton(withTitle: self.language == "zh" ? "取消" : "Cancel")                    // .alertThirdButtonReturn
            let resp = alert.runModal()
            switch resp {
            case .alertFirstButtonReturn:
                self.pickAndImportCookies()
            case .alertSecondButtonReturn:
                self.showSettings = true
            default:
                break
            }
        }
    }

    /// 打开文件面板让用户选择 cookie.txt，并自动复制到应用目录
    private func pickAndImportCookies() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() != .OK { return }

        let cookieStoreDir = ContentView.appSupportCookiesDir
        try? FileManager.default.createDirectory(at: cookieStoreDir, withIntermediateDirectories: true)

        for url in panel.urls {
            let fileName = url.lastPathComponent.lowercased()
            var domain = ""
            // 根据文件名快速匹配常见站点
            if fileName.contains("youtube") { domain = "youtube.com" }
            else if fileName.contains("bilibili") { domain = "bilibili.com" }
            else if fileName.contains("facebook") { domain = "facebook.com" }
            else if fileName.contains("instagram") || fileName.contains("ins") { domain = "instagram.com" }
            else if fileName.contains("tiktok") { domain = "tiktok.com" }
            else if fileName.contains("douyin") { domain = "douyin.com" }
            else if fileName.contains("twitter") || fileName.contains("x.com") { domain = "x.com" }
            // 若仍无法判断，让用户手动输入
            if domain.isEmpty {
                domain = self.promptManualSite(for: url)
            }
            guard !domain.isEmpty else { continue }

            let dest = cookieStoreDir.appendingPathComponent(url.lastPathComponent).path
            try? FileManager.default.removeItem(atPath: dest)
            try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
            self.cookiesMap[domain] = dest
        }
        self.savePreferences()
        self.detectPremiumCookies()
    }

    /// 弹窗让用户手动输入域名（避免与全局函数重名）
    private func promptManualSite(for url: URL) -> String {
        let alert = NSAlert()
        alert.messageText = self.language == "zh" ? "未知站点 Cookie 文件" : "Unknown Site Cookie File"
        alert.informativeText = (self.language == "zh"
            ? "请为文件 \(url.lastPathComponent) 指定站点域名（如 youtube.com）："
            : "Please specify the site domain (e.g. youtube.com) for file \(url.lastPathComponent):")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: self.language == "zh" ? "确定" : "OK")
        alert.addButton(withTitle: self.language == "zh" ? "取消" : "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
            ? input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }
}

// Regex helper – 返回所有匹配
extension String {
    func allRegexMatches(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: nsRange).compactMap {
            Range($0.range, in: self).map { String(self[$0]) }
        }
    }
}

// MARK: - Safe collection subscript
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// 错误行高亮辅助 (可按需扩展为实际高亮)
struct ErrorLinePreferenceKey: PreferenceKey {
    static var defaultValue: String = ""
    static func reduce(value: inout String, nextValue: () -> String) {
        value = nextValue()
    }
}
