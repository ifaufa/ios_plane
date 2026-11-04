import SwiftUI
import UIKit
import WebKit
import AVFoundation

// MARK: - 候选

struct Candidate: Identifiable, Equatable {
    enum Source: String, CaseIterable {
        case network = "网络"
        case page = "页面"
        case selection = "选中"
        case manual = "手动"
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

    init(id: String, url: URL, title: String? = nil, sources: Set<Source>) {
        self.id = id
        self.url = url
        self.title = title ?? LinkParser.defaultTitle(for: url)
        self.sources = sources
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
        webView.customUserAgent = RequestSettings.userAgent.isEmpty ? nil : RequestSettings.userAgent

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
        if !RequestSettings.userAgent.isEmpty {
            request.setValue(RequestSettings.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if !RequestSettings.referer.isEmpty {
            request.setValue(RequestSettings.referer, forHTTPHeaderField: "Referer")
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

    func addCandidates(_ entries: [LinkParser.Entry], source: Candidate.Source, inspect: Bool) {
        var changed = false
        for entry in entries {
            let trimmed = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let id = url.absoluteString
            if let index = candidates.firstIndex(where: { $0.id == id }) {
                if !candidates[index].sources.contains(source) {
                    candidates[index].sources.insert(source)
                    changed = true
                }
                continue
            }
            candidates.append(Candidate(id: id, url: url, title: entry.title, sources: [source]))
            changed = true
            if inspect { startInspect(id) }
        }
        if changed { sortCandidates() }
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

    func extractFromPage(completion: ((Int) -> Void)? = nil) {
        let script = """
        (function(){
          try {
            var urls = {};
            function add(u){ if (u && typeof u === 'string' && u.indexOf('http') === 0) { urls[u] = 1; } }
            var nodes = document.querySelectorAll('a[href]');
            for (var i = 0; i < nodes.length; i++) { add(nodes[i].href); }
            var media = document.querySelectorAll('video, source');
            for (var j = 0; j < media.length; j++) { add(media[j].src); add(media[j].currentSrc); }
            var sel = window.getSelection ? String(window.getSelection()) : '';
            return JSON.stringify({ urls: Object.keys(urls), selection: sel });
          } catch (e) { return JSON.stringify({ urls: [], selection: '' }); }
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion?(0); return }

            let pageURLs = (object["urls"] as? [String] ?? []).filter { $0.lowercased().contains(".m3u8") }
            let selection = object["selection"] as? String ?? ""
            let pageEntries = pageURLs.map { LinkParser.Entry(title: nil, url: $0) }
            let selectionEntries = LinkParser.parse(selection).filter { $0.url.lowercased().contains(".m3u8") }

            DispatchQueue.main.async {
                self.addCandidates(pageEntries, source: .page, inspect: true)
                self.addCandidates(selectionEntries, source: .selection, inspect: true)
                completion?(pageEntries.count + selectionEntries.count)
            }
        }
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var model = BrowserModel()
    @StateObject private var bookmarks = BookmarkStore.shared

    @State private var address = ""
    @State private var showCandidates = false
    @State private var showHeaders = false
    @State private var showBookmarks = false
    @State private var extractHint: String?

    var body: some View {
        NavigationStack {
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
                        downloads.start(url: item.url, title: item.title)
                    }
                    showCandidates = false
                    dismiss()
                }
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

            Button {
                model.extractFromPage { count in
                    if count > 0 {
                        showCandidates = true
                    } else {
                        extractHint = "页面里没有找到 m3u8 链接。可以试试：播放一下视频，等嗅探计数出现后再点「候选」。"
                    }
                }
            } label: {
                Label("提取", systemImage: "doc.text.magnifyingglass")
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
                TextField("标题", text: $candidate.title)
                    .font(.subheadline.weight(.medium))
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .disabled(!candidate.isSelectable)

                Text(candidate.subtitle)
                    .font(.caption)
                    .foregroundStyle(candidate.isSelectable ? Color.secondary : Color.red)

                Text(candidate.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
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
                    CandidateRow(candidate: $model.candidates[index]) {
                        model.toggle(model.candidates[index].id)
                    }
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
    @State private var referer = RequestSettings.referer
    @State private var userAgent = RequestSettings.userAgent

    var body: some View {
        NavigationStack {
            Form {
                Section("Referer（防盗链站点常用）") {
                    TextField("https://example.com/", text: $referer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("User-Agent（留空用系统默认）") {
                    TextField("Mozilla/5.0 …", text: $userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("这些请求头会同时用于网页加载、预检和下载。填错会导致正常的源也无法访问，不确定就留空。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("请求头")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        RequestSettings.referer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
                        RequestSettings.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}
