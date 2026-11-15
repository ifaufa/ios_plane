import SwiftUI
import UIKit
import WebKit
import AVFoundation

// MARK: - 候选

/// 一次合并操作的结果回执
struct AddSummary {
    var added = 0          // 新增条数
    var duplicated = 0     // URL 已存在条数
    var titleUpdated = 0   // 其中标题被更新的条数

    var hasVisibleChange: Bool { added > 0 || titleUpdated > 0 }

    var feedback: String {
        if added == 0 && titleUpdated == 0 {
            return duplicated > 0 ? "全部重复，无变化（\(duplicated) 条）" : "没有发现 m3u8 链接"
        }
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added) 条") }
        if duplicated > 0 { parts.append("重复 \(duplicated) 条") }
        if titleUpdated > 0 { parts.append("更新标题 \(titleUpdated) 条") }
        return parts.joined(separator: "，")
    }
}

struct Candidate: Identifiable, Equatable {
    enum Source: String, CaseIterable {
        case network = "网络"
        case page = "页面"
        case selection = "选中"
        case manual = "手动"
        case clipboard = "剪贴板"
    }

    enum State: Equatable {
        case checking
        case available
        case invalid(String)
        case unreachable(String)
    }

    let id: String
    var url: URL
    var title: String
    var sources: Set<Source>
    var state: State = .checking
    var info: M3U8Info?
    var selected = false
    /// 编辑中的地址（提交后才写回 url）
    var urlDraft: String
    /// 标题是否被用户手动改过（改过则地址变更时不覆盖标题）
    var titleEditedByUser = false

    init(id: String, url: URL, title: String? = nil, sources: Set<Source>) {
        self.id = id
        self.url = url
        self.title = title ?? LinkParser.defaultTitle(for: url)
        self.sources = sources
        self.urlDraft = url.absoluteString
    }

    /// 校验编辑中的地址
    var draftError: String? {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "地址不能为空" }
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              (parsed.host ?? "").isEmpty == false else {
            return "请输入完整的 http/https 地址"
        }
        return nil
    }

    var draftURL: URL? {
        guard draftError == nil else { return nil }
        return URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 地址是否与当前生效地址不同
    var hasDraftChange: Bool {
        urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) != url.absoluteString
    }

    var subtitle: String {
        switch state {
        case .checking:
            return "检查中…"
        case .invalid(let reason):
            return "不可用：\(reason)"
        case .unreachable(let reason):
            return "无法访问：\(reason)"
        case .available:
            guard let info else { return "可用" }
            if info.isMaster {
                let best = info.variants.max { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }
                let res = best?.resolution ?? "未知"
                return "主列表 · \(info.variants.count) 个码率 · 默认最高 \(res)"
            }
            var parts = ["\(info.segmentCount) 段"]
            if info.duration > 0 {
                parts.append(Self.durationText(info.duration))
            }
            if info.drm { parts.append("DRM 不支持") }
            else if info.encrypted { parts.append("已加密(AES-128)") }
            return parts.joined(separator: " · ")
        }
    }

    var isSelectable: Bool {
        if case .available = state { return true }
        return false
    }

    var readySubtitle: String { state == .checking ? "检查中…" : subtitle }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "约 \(h) 小时 \(m) 分" : "约 \(m) 分"
    }
}

// MARK: - 浏览器模型

final class BrowserModel: NSObject, ObservableObject {
    @Published var candidates: [Candidate] = []
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""

    let webView: WKWebView
    private var pollTimer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var isTornDown = false

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.hookScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(self, name: "sniff")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        let defaultUA = RequestSettings.defaultProfile?.userAgent ?? ""
        webView.customUserAgent = defaultUA.isEmpty ? nil : defaultUA

        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.progress = view.estimatedProgress }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.currentURL = view.url?.absoluteString ?? "" }
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.pageTitle = view.title ?? "" }
        })

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.pollResourceEntries()
        }
    }

    deinit {
        pollTimer?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sniff")
        webView.stopLoading()
    }

    /// 关闭浏览器时彻底停止网页播放并断开引用环，避免"关掉界面声音还在"
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true

        pollTimer?.invalidate()
        pollTimer = nil

        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.evaluateJavaScript("""
        (function(){
          try {
            var media = document.querySelectorAll('video,audio');
            for (var i = 0; i < media.length; i++) {
              try { media[i].pause(); media[i].removeAttribute('src'); media[i].load(); } catch (e) {}
            }
          } catch (e) {}
        })();
        """, completionHandler: nil)

        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // 断开 BrowserModel ↔ WKUserContentController 的强引用环
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sniff")
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: 导航

    func load(_ url: URL) {
        var request = URLRequest(url: url)
        // 按域名匹配对应规则（精确 > 后缀通配 > 全局默认）
        for (key, value) in RequestSettings.headers(for: url) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        webView.load(request)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    // MARK: 候选管理

    func addManual(_ url: URL) {
        addCandidates([LinkParser.Entry(title: nil, url: url.absoluteString)], source: .manual, inspect: true)
    }

    @discardableResult
    /// 应用编辑后的地址：去重 → 重置状态 → 重新检测
    func commitCandidateURL(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              let newURL = candidates[index].draftURL else { return }

        if let dupIndex = candidates.firstIndex(where: { $0.id != id && $0.url.absoluteString == newURL.absoluteString }) {
            candidates[dupIndex].selected = candidates[dupIndex].selected || candidates[index].selected
            candidates.remove(at: index)
            DiagnosticsLog.write("[候选] 地址修改后与已有项重复，已合并")
            return
        }

        candidates[index].url = newURL
        candidates[index].urlDraft = newURL.absoluteString
        candidates[index].sources.insert(.manual)
        if !candidates[index].titleEditedByUser {
            candidates[index].title = LinkParser.defaultTitle(for: newURL)
        }
        candidates[index].state = .checking
        candidates[index].info = nil
        DiagnosticsLog.write("[候选] 地址已修改 → 重新检测 \(newURL.absoluteString)")

        Task { @MainActor in
            let result = await M3U8Inspector.inspect(newURL)
            guard let target = self.candidates.firstIndex(where: { $0.url == newURL }) else { return }
            switch result {
            case .available(let info):
                self.candidates[target].state = .available
                self.candidates[target].info = info
            case .invalid(let message):
                self.candidates[target].state = .invalid(message)
            case .unreachable(let message):
                self.candidates[target].state = .unreachable(message)
            }
        }
    }
    func addCandidates(_ entries: [LinkParser.Entry], source: Candidate.Source, inspect: Bool) -> AddSummary {
        var summary = AddSummary()
        var changed = false

        for entry in entries {
            let trimmed = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let id = url.absoluteString

            if let index = candidates.firstIndex(where: { $0.id == id }) {
                summary.duplicated += 1

                if !candidates[index].sources.contains(source) {
                    candidates[index].sources.insert(source)
                    changed = true
                }

                // 新标题覆盖旧标题；页面/网络来的条目没有标题，不会覆盖用户自定义的
                if let newTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !newTitle.isEmpty,
                   newTitle != candidates[index].title {
                    candidates[index].title = newTitle
                    summary.titleUpdated += 1
                    changed = true
                }
                continue
            }

            candidates.append(Candidate(id: id, url: url, title: entry.title, sources: [source]))
            summary.added += 1
            changed = true
            if inspect { startInspect(id) }
        }

        if changed { sortCandidates() }
        return summary
    }

    func toggle(_ id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].selected.toggle()
    }

    func selectAllAvailable() {
        for index in candidates.indices where candidates[index].isSelectable {
            candidates[index].selected = true
        }
    }

    func clearSelection() {
        for index in candidates.indices { candidates[index].selected = false }
    }

    var selectedCount: Int { candidates.filter { $0.selected }.count }

    var availableCount: Int { candidates.filter { $0.isSelectable }.count }

    /// 把已选候选交给下载队列，返回实际提交的地址
    func submitSelected() -> [(url: URL, title: String)] {
        var result: [(URL, String)] = []
        for candidate in candidates where candidate.selected && candidate.isSelectable {
            var target = candidate.url
            var title = candidate.title
            if let info = candidate.info, info.isMaster,
               let best = info.variants.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }),
               let variantURL = URL(string: best.url) {
                target = variantURL
                if let resolution = best.resolution { title += " \(resolution)" }
            }
            result.append((target, title))
        }
        return result
    }

    // MARK: 页面提取

    func extractFromPage(completion: ((AddSummary, Bool, String) -> Void)? = nil) {
        let script = """
        (function(){
          try {
            var urls = {};
            function add(u){ if (u && typeof u === 'string' && u.indexOf('http') === 0) { urls[u] = 1; } }
            var nodes = document.querySelectorAll('a[href]');
            for (var i = 0; i < nodes.length; i++) { add(nodes[i].href); }
            var media = document.querySelectorAll('video, source');
            for (var j = 0; j < media.length; j++) { add(media[j].src); add(media[j].currentSrc); }
            var live = window.getSelection ? String(window.getSelection()) : '';
            var cached = window.__planeSelection || '';
            // 实时选区优先级最高；点按钮时选区可能已被系统清空，回退到复制/选中时缓存的内容
            var sel = (live && live.trim().length > 0) ? live : cached;
            return JSON.stringify({ urls: Object.keys(urls), selection: sel, usedCache: !(live && live.trim().length > 0) });
          } catch (e) { return JSON.stringify({ urls: [], selection: '' }); }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion?(AddSummary(), false, ""); return }

            let pageURLs = (object["urls"] as? [String] ?? []).filter { $0.lowercased().contains(".m3u8") }
            let selection = object["selection"] as? String ?? ""
            let usedCache = (object["usedCache"] as? Bool) ?? false
            let pageEntries = pageURLs.map { LinkParser.Entry(title: nil, url: $0) }
            let selectionEntries = LinkParser.parse(selection).filter { $0.url.lowercased().contains(".m3u8") }
            let preview = String(selection.prefix(30))

            DispatchQueue.main.async {
                let pageSummary = self.addCandidates(pageEntries, source: .page, inspect: true)
                let selectionSummary = self.addCandidates(selectionEntries, source: .selection, inspect: true)
                var total = AddSummary()
                total.added = pageSummary.added + selectionSummary.added
                total.duplicated = pageSummary.duplicated + selectionSummary.duplicated
                total.titleUpdated = pageSummary.titleUpdated + selectionSummary.titleUpdated
                completion?(total, usedCache, preview)
            }
        }
    }

    /// 从系统剪贴板提取 m3u8（会触发系统"允许粘贴"提示）
    func addFromClipboard() -> AddSummary {
        let text = UIPasteboard.general.string ?? ""
        guard !text.isEmpty else { return AddSummary() }
        let entries = LinkParser.parse(text).filter { $0.url.lowercased().contains(".m3u8") }
        guard !entries.isEmpty else { return AddSummary() }
        return addCandidates(entries, source: .clipboard, inspect: true)
    }

    static func extractLinks(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>，。、）】\\]]+", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}）"))
        }
    }

    // MARK: 私有

    private func sortCandidates() {
        let order: (Candidate) -> Int = { candidate in
            if candidate.isSelectable { return 0 }
            if candidate.state == .checking { return 1 }
            return 2
        }
        candidates.sort { lhs, rhs in
            let l = order(lhs), r = order(rhs)
            return l == r ? lhs.title < rhs.title : l < r
        }
    }

    private func startInspect(_ id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            let result = await M3U8Inspector.inspect(candidate.url)
            DispatchQueue.main.async { self?.apply(result, to: id) }
        }
    }

    private func apply(_ result: M3U8InspectResult, to id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .available(let info):
            candidates[index].info = info
            candidates[index].state = info.drm ? .invalid("受 DRM 保护") : .available
            if info.drm { candidates[index].selected = false }
        case .invalid(let reason):
            candidates[index].state = .invalid(reason)
        case .unreachable(let reason):
            candidates[index].state = .unreachable(reason)
        }
        sortCandidates()
    }

    private func pollResourceEntries() {
        let script = """
        (function(){
          try {
            return JSON.stringify(performance.getEntriesByType('resource')
              .map(function(e){ return e.name; })
              .filter(function(u){ return u.indexOf('.m3u8') >= 0; }));
          } catch (e) { return '[]'; }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let urls = try? JSONDecoder().decode([String].self, from: data),
                  !urls.isEmpty else { return }
            DispatchQueue.main.async {
                self.addCandidates(urls.map { LinkParser.Entry(title: nil, url: $0) }, source: .network, inspect: true)
            }
        }
    }

    private static let hookScript = """
    (function(){
      try {
        function report(u){
          try {
            if (u && typeof u === 'string' && u.indexOf('.m3u8') >= 0) {
              window.webkit.messageHandlers.sniff.postMessage(u);
            }
          } catch (e) {}
        }
        var open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url){ report(url); return open.apply(this, arguments); };
        if (window.fetch) {
          var originalFetch = window.fetch;
          window.fetch = function(input){
            try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
            return originalFetch.apply(this, arguments);
          };
        }
        // 缓存选区 / 复制内容：点按钮时选区常被系统清空，这里提前留一份
        try {
          document.addEventListener('selectionchange', function(){
            try {
              var t = String(window.getSelection());
              if (t && t.trim().length > 0) { window.__planeSelection = t; }
            } catch (e) {}
          }, true);
          document.addEventListener('copy', function(){
            try {
              var t = String(window.getSelection());
              if (t) { window.__planeSelection = t; }
            } catch (e) {}
          }, true);
        } catch (e) {}
        // window.open 一律在当前页打开
        window.open = function(u){
          try {
            if (u && typeof u === 'string' && u.indexOf('about:') !== 0 && u.indexOf('javascript:') !== 0) {
              window.location.href = u;
            }
          } catch (e) {}
          return window;
        };
      } catch (e) {}
    })();
    """
}

extension BrowserModel: WKUIDelegate {
    /// target="_blank" 等新建窗口请求：一律在当前页打开
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            // about:blank / javascript: 这类弹窗没有实际地址，加载会把当前页变空白，直接忽略
            if scheme != "about" && scheme != "javascript" && scheme != "data" {
                webView.load(navigationAction.request)
                DispatchQueue.main.async { self.currentURL = url.absoluteString }
            }
        }
        return nil
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { self.currentURL = webView.url?.absoluteString ?? "" }
        pollResourceEntries()
    }
}

extension BrowserModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sniff", let url = message.body as? String else { return }
        DispatchQueue.main.async {
            self.addCandidates([LinkParser.Entry(title: nil, url: url)], source: .network, inspect: true)
        }
    }
}

// MARK: - WKWebView 包装

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 页面

struct WebSnifferBrowser: View {
    @ObservedObject private var playback = PlaybackStore.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var model = BrowserModel()
    @StateObject private var bookmarks = BookmarkStore.shared

    @State private var address = ""
    @State private var showCandidates = false
    @State private var showHeaders = false
    @State private var showBookmarks = false
    @State private var showQueue = false
    @State private var extractHint: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                addressBar
                ZStack(alignment: .top) {
                    WebViewContainer(webView: model.webView)
                    if model.isLoading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                }
                bottomBar
            }
            // 浏览网页时悬浮播放窗保持可见（与主界面共享同一个播放器）
            if playback.isActive, !playback.isFullscreen {
                MiniPlayerWindow(store: playback)
            }
            }
            .onDisappear { playback.ensurePlaying() }
            .navigationTitle("找视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { toggleBookmark() } label: {
                        Image(systemName: isBookmarked ? "star.fill" : "star")
                            .foregroundStyle(isBookmarked ? Color.yellow : Color.accentColor)
                    }
                    Button { showBookmarks = true } label: {
                        Image(systemName: "book")
                    }
                    Button { showHeaders = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksSheet(store: bookmarks) { url in
                    address = url
                    guard let parsed = URL(string: url) else { return }
                    if url.lowercased().contains(".m3u8") {
                        // 收藏的是直链：直接进候选，而不是把播放列表当网页显示
                        model.addManual(parsed)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showCandidates = true
                        }
                    } else {
                        model.load(parsed)
                    }
                }
            }
            .sheet(isPresented: $showCandidates) {
                CandidateSheet(model: model) { items in
                    for item in items {
                        Task {
                        let verdict = await CodecProbe.probe(playlistURL: item.url, codecsHint: nil)
                        DiagnosticsLog.write("[编码预检] \(item.title) \(verdict.detail) 支持=\(verdict.supported)")
                        await MainActor.run {
                            downloads.start(url: item.url,
                                            title: item.title,
                                            codecStatus: AddDownloadView.codecStatusText(verdict))
                        }
                    }
                    }
                    model.clearSelection()
                    showCandidates = false
                    showToast("已加入下载队列 \(items.count) 个")
                }
            }
            .sheet(isPresented: $showQueue) {
                QueueOverviewSheet()
            }
            .sheet(isPresented: $showHeaders) {
                HeadersSettingsView()
            }
            .alert("提取结果", isPresented: Binding(
                get: { extractHint != nil },
                set: { if !$0 { extractHint = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(extractHint ?? "")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 56)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onDisappear { model.teardown() }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("网页地址或 m3u8 链接", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { submit() }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            Button {
                address = UIPasteboard.general.string ?? address
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 34, height: 34)
            }

            Button("打开") { submit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }

            Spacer()

            Button(action: extractFromPage) {
                Label("提取", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                pasteFromClipboard()
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }

            if !downloads.tasks.isEmpty {
                Button {
                    showQueue = true
                } label: {
                    Label("下载中 \(downloads.activeCount)", systemImage: "arrow.down.circle")
                }
            }

            Button {
                showCandidates = true
            } label: {
                Label("\(model.candidates.count)", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(model.candidates.isEmpty)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var currentLink: String {
        let live = model.currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return live.isEmpty ? address.trimmingCharacters(in: .whitespacesAndNewlines) : live
    }

    private var isBookmarked: Bool {
        let link = currentLink
        return !link.isEmpty && bookmarks.contains(link)
    }

    private func extractFromPage() {
        model.extractFromPage { summary, usedCache, preview in
            if summary.hasVisibleChange {
                showCandidates = true
            }
            var text = summary.feedback
            if usedCache, !preview.isEmpty {
                text += "（已使用上次选中：\(preview)…）"
            }
            showToast(text)
        }
    }

    private func pasteFromClipboard() {
        let summary = model.addFromClipboard()
        if summary.hasVisibleChange {
            showCandidates = true
        }
        showToast(summary.feedback)
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    private func toggleBookmark() {
        let link = currentLink
        guard let parsed = URL(string: link), parsed.scheme != nil else {
            extractHint = "当前没有可收藏的地址"
            return
        }
        let title = model.pageTitle.isEmpty ? BookmarkStore.fallbackTitle(link) : model.pageTitle
        bookmarks.toggle(url: link, title: title)
    }

    private func submit() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            extractHint = "请输入 http(s) 开头的地址"
            return
        }
        if text.lowercased().contains(".m3u8") {
            model.addManual(url)
            showCandidates = true
        } else {
            model.load(url)
        }
    }
}

// MARK: - 候选行

struct CandidateRow: View {
    @Binding var candidate: Candidate
    let onToggle: () -> Void
    var onCommitURL: () -> Void = {}

    @FocusState private var urlFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(candidate.isSelectable ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!candidate.isSelectable)

            VStack(alignment: .leading, spacing: 3) {
                TextField("标题", text: Binding(
                    get: { candidate.title },
                    set: { candidate.title = $0; candidate.titleEditedByUser = true }
                ))
                .font(.subheadline.weight(.medium))
                .textFieldStyle(.plain)
                .submitLabel(.done)

                Text(candidate.subtitle)
                    .font(.caption)
                    .foregroundStyle(candidate.isSelectable ? Color.secondary : Color.red)

                Text("来源：" + candidate.sources.map { $0.rawValue }.sorted().joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)

                TextField("下载地址", text: $candidate.urlDraft, axis: .vertical)
                    .font(.caption2)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1...3)
                    .focused($urlFocused)
                    .onSubmit { commit() }

                if let error = candidate.draftError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if candidate.hasDraftChange {
                    Button("应用新地址并重新检测") { commit() }
                        .font(.caption2.weight(.semibold))
                } else if !candidate.url.absoluteString.lowercased().contains(".m3u8") {
                    Text("注意：该地址不是 m3u8 播放列表，可能无法下载")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: urlFocused) { focused in
            if !focused, candidate.hasDraftChange, candidate.draftError == nil {
                commit()
            }
        }
    }

    private func commit() {
        guard candidate.draftError == nil, candidate.hasDraftChange else { return }
        urlFocused = false
        onCommitURL()
    }
}

// MARK: - 候选面板

private struct CandidateSheet: View {
    @ObservedObject var model: BrowserModel
    let onAdd: ([(url: URL, title: String)]) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.candidates.isEmpty {
                    Text("暂未发现视频，试试播放页面里的视频后再看。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.candidates.indices, id: \.self) { index in
                    CandidateRow(candidate: $model.candidates[index],
                                 onToggle: { model.toggle(model.candidates[index].id) },
                                 onCommitURL: { model.commitCandidateURL(id: model.candidates[index].id) })
                }
            }
            .navigationTitle("候选（\(model.selectedCount)/\(model.candidates.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(model.selectedCount == model.availableCount && model.availableCount > 0 ? "取消全选" : "全选可用") {
                            if model.selectedCount == model.availableCount && model.availableCount > 0 {
                                model.clearSelection()
                            } else {
                                model.selectAllAvailable()
                            }
                        }
                        Spacer()
                        Button("添加 \(model.selectedCount) 个") {
                            onAdd(model.submitSelected())
                        }
                        .disabled(model.selectedCount == 0)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - 请求头设置

struct HeadersSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [RequestProfile] = RequestSettings.profiles
    @State private var editing: RequestProfile?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(profiles.indices, id: \.self) { index in
                        Button {
                            editing = profiles[index]
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(profiles[index].name.isEmpty ? "未命名" : profiles[index].name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { profiles[index].enabled },
                                        set: { profiles[index].enabled = $0 }
                                    ))
                                    .labelsHidden()
                                }
                                HStack(spacing: 6) {
                                    Text(profiles[index].displayName)
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                    let hits = profiles[index].hitCount ?? 0
                                    if hits > 0 {
                                        Text("命中 \(hits) 次")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                if !profiles[index].userAgent.isEmpty {
                                    Text("UA: \(profiles[index].userAgent.prefix(48))…")
                                        .font(.caption2)
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                profiles.remove(at: index)
                            }
                        }
                    }
                } header: {
                    Text("规则")
                } footer: {
                    Text("匹配规则：精确域名 play.abc.com；后缀 .abc.com 匹配该域名及所有子域；域名留空表示对所有网址生效。优先级：精确 > 后缀 > 默认。")
                }

                Section {
                    Button {
                        editing = RequestProfile(id: UUID(), name: "", hostPattern: "",
                                                  referer: "", userAgent: "", enabled: true)
                    } label: {
                        Label("新增规则…", systemImage: "plus.circle")
                    }
                }

                Section {
                    Button("重置命中计数") {
                        RequestSettings.resetHitCounts()
                        profiles = RequestSettings.profiles
                    }
                    Button("恢复默认（清空所有规则）", role: .destructive) {
                        profiles = []
                    }
                }
            }
            .navigationTitle("请求头")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                RequestSettings.flushHitCounts()
                profiles = RequestSettings.profiles
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        RequestSettings.profiles = profiles
                        dismiss()
                    }
                }
            }
            .sheet(item: $editing) { profile in
                HeaderRuleEditor(profile: profile, existing: profiles.filter { $0.id != profile.id }) { updated in
                    if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
                        profiles[index] = updated
                    } else {
                        profiles.append(updated)
                    }
                }
            }
        }
    }
}

/// 单条规则编辑（含 UA 预设）
private struct HeaderRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RequestProfile
    @State private var presetSelection: String = "自定义"
    @State private var duplicatePattern: String?
    let onSave: (RequestProfile) -> Void
    private let existingPatterns: [String]

    init(profile: RequestProfile, existing: [RequestProfile], onSave: @escaping (RequestProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
        self.existingPatterns = existing.map {
            $0.hostPattern.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("如 HHUUS", text: $draft.name)
                }
                Section {
                    TextField("play.abc.com 或 .abc.com", text: $draft.hostPattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("域名匹配")
                } footer: {
                    Text("留空 = 对所有网址生效；以 . 开头 = 该域名及所有子域")
                }
                Section("Referer") {
                    TextField("https://example.com/", text: $draft.referer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("预设", selection: $presetSelection) {
                        Text("自定义").tag("自定义")
                        ForEach(RequestSettings.userAgentPresets, id: \.title) { preset in
                            Text(preset.title).tag(preset.title)
                        }
                    }
                    .onChange(of: presetSelection) { selection in
                        if let preset = RequestSettings.userAgentPresets.first(where: { $0.title == selection }) {
                            draft.userAgent = preset.value
                        }
                    }
                    TextField("Mozilla/5.0 …", text: $draft.userAgent, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                    if !draft.userAgent.isEmpty {
                        Button("清空（使用系统默认）", role: .destructive) {
                            draft.userAgent = ""
                            presetSelection = "自定义"
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("User-Agent")
                } footer: {
                    Text("选预设会自动填入，仍可手动修改；留空则使用系统默认 UA。")
                }
                Section {
                    Toggle("启用该规则", isOn: $draft.enabled)
                }
            }
            .alert("域名重复", isPresented: Binding(
                get: { duplicatePattern != nil },
                set: { if !$0 { duplicatePattern = nil } }
            )) {
                Button("知道了", role: .cancel) { duplicatePattern = nil }
            } message: {
                Text("已存在相同域名的规则：\(duplicatePattern ?? "")。同一域名只会命中第一条启用的规则，请改用不同的域名，或先删除旧规则。")
            }
            .navigationTitle("规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                }
            }
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.hostPattern = draft.hostPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.referer = draft.referer.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.userAgent = draft.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)

        let key = draft.hostPattern.lowercased()
        if !key.isEmpty, existingPatterns.contains(key) {
            duplicatePattern = draft.hostPattern
            return
        }
        onSave(draft)
        dismiss()
    }
}

// MARK: - 下载队列概览

struct QueueOverviewSheet: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if downloads.tasks.isEmpty {
                    Text("当前没有下载任务")
                        .foregroundStyle(.secondary)
                }
                ForEach(downloads.tasks) { task in
                    DownloadRow(task: task)
                }
            }
            .navigationTitle("下载队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
