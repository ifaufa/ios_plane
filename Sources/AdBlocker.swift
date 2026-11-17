import Foundation
import WebKit

/// 内置浏览器广告拦截：网络规则 + DOM 遮罩识别 + 弹窗治理
@MainActor
final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "adBlockEnabled")
            if isEnabled { compileIfNeeded() }
        }
    }
    @Published private(set) var disabledHosts: Set<String> = []
    @Published private(set) var blockedOverlays: Int = 0
    @Published private(set) var rulesReady = false

    private var compiled: WKContentRuleList?
    private var compiling = false
    private var pendingControllers: [WKUserContentController] = []
    private let defaults = UserDefaults.standard

    private init() {
        isEnabled = (defaults.object(forKey: "adBlockEnabled") as? Bool) ?? true
        if let hosts = defaults.stringArray(forKey: "adBlockDisabledHosts") {
            disabledHosts = Set(hosts)
        }
    }

    // MARK: - 站点开关

    func isBlocking(host: String?) -> Bool {
        guard isEnabled else { return false }
        guard let host = host?.lowercased(), !host.isEmpty else { return true }
        return !disabledHosts.contains(host)
    }

    func setBlocking(_ on: Bool, forHost host: String) {
        let key = host.lowercased()
        guard !key.isEmpty else { return }
        if on { disabledHosts.remove(key) } else { disabledHosts.insert(key) }
        defaults.set(Array(disabledHosts), forKey: "adBlockDisabledHosts")
    }

    func noteBlocked(_ count: Int, host: String) {
        guard count > 0 else { return }
        blockedOverlays += count
        DiagnosticsLog.write("[浏览器] 拦截 host=\(host) 遮罩=\(count)")
    }

    // MARK: - 安装到 WebView

    /// DOM 层脚本（documentEnd 注入，主框架与 iframe 都生效）
    /// 注意：始终注入，是否生效由页面里的 window.__planeAdBlockOff 决定（这样开关无需重建 WebView）
    func installScript(on controller: WKUserContentController) {
        let script = WKUserScript(source: Self.scriptSource,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: false)
        controller.addUserScript(script)
    }

    /// 网络层规则（异步编译，编译完成后挂到同一 controller）
    func installRules(on controller: WKUserContentController) {
        if let compiled {
            controller.add(compiled)
            return
        }
        pendingControllers.append(controller)
        if compiling { return }
        compiling = true

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "plane-adblock-v1",
            encodedContentRuleList: Self.rulesJSON
        ) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                self.compiling = false
                if let list {
                    self.compiled = list
                    self.rulesReady = true
                    for target in self.pendingControllers { target.add(list) }
                    self.pendingControllers.removeAll()
                    DiagnosticsLog.write("[浏览器] 广告拦截已启用 规则=\(Self.ruleCount)条")
                } else {
                    self.pendingControllers.removeAll()
                    DiagnosticsLog.write("[浏览器] 广告规则编译失败：\(error?.localizedDescription ?? "-")")
                }
            }
        }
    }

    private func compileIfNeeded() {
        for controller in pendingControllers { installRules(on: controller) }
    }

    // MARK: - 网络规则

    private static let ruleCount = 30

    private static let rulesJSON = #"""
    [
      {"trigger":{"url-filter":"doubleclick\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagmanager\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googletagservices\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adservice\\.google"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"amazon-adsystem\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adnxs\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adsrvr\\.org"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"criteo\\.(com|net)"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"taboola\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"outbrain\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popads\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popcash\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"propellerads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"onclickads\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adsterra\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"exoclick\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"juicyads\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"trafficjunky\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"prebid\\.js"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/ads?/","resource-type":["script","image","subdocument","media"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"adserver","resource-type":["script","image","subdocument","media"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/advert","resource-type":["script","image","subdocument","media"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"popunder","resource-type":["script","subdocument"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/banner","resource-type":["script","image","subdocument"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"analytics\\.","resource-type":["script"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/track\\?","resource-type":["image"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/pixel\\?","resource-type":["image"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/stat\\?","resource-type":["image"]},"action":{"type":"block"}}
    ]
    """#

    // MARK: - DOM 脚本

    static let scriptSource = #"""
    (function(){
      if (window.__planeAdBlockInstalled) { return; }
      window.__planeAdBlockInstalled = true;

      var pending = 0;
      function report(){
        if (pending <= 0) { return; }
        try { window.webkit.messageHandlers.adblock.postMessage(pending); } catch(e){}
        pending = 0;
      }

      function classAndId(el){
        var cls = (el.className && el.className.toString) ? el.className.toString() : "";
        return (cls + " " + (el.id || "")).toLowerCase();
      }

      function isPlayerish(el){
        try {
          if (el.querySelector && el.querySelector("video,audio")) { return true; }
          var s = classAndId(el);
          if (/player|dplayer|video-js|jwplayer|plyr|artplayer|xgplayer|h5player/.test(s)) { return true; }
        } catch(e){}
        return false;
      }

      function isAdNamed(el){
        var s = classAndId(el);
        return /(^|[\s_-])(ad|ads|advert|advertisement|banner|gg|pop|popup|popunder|sponsor|tuiguang)([\s_-]|$)/.test(s);
      }

      function isTransparent(el, cs){
        var bg = (cs.backgroundColor || "").replace(/\s+/g, "");
        if (bg === "transparent" || bg === "rgba(0,0,0,0)") { return true; }
        if (parseFloat(cs.opacity || "1") < 0.05) { return true; }
        return false;
      }

      function scan(){
        if (window.__planeAdBlockOff) { return; }
        var vw = window.innerWidth || 0;
        var vh = window.innerHeight || 0;
        if (vw < 100 || vh < 100) { return; }

        var nodes = document.querySelectorAll("div,a,iframe,section,ins,span");
        var limit = Math.min(nodes.length, 2000);
        for (var i = 0; i < limit; i++) {
          var el = nodes[i];
          if (el.getAttribute("data-plane-ab")) { continue; }
          if (el === document.documentElement || el === document.body) { continue; }

          if (el.tagName === "IFRAME") {
            var src = ((el.getAttribute("src") || "") + " " + (el.getAttribute("data-src") || "")).toLowerCase();
            if (/doubleclick|googlesyndication|adservice|popads|adsterra|exoclick|juicyads|\/ads?\/|adserver/.test(src)) {
              if (isPlayerish(el)) { continue; }
              el.setAttribute("data-plane-ab", "1");
              el.style.display = "none";
              pending++;
            }
            continue;
          }

          if (isPlayerish(el)) { continue; }
          var cs = getComputedStyle(el);
          if (cs.position !== "fixed" && cs.position !== "absolute") { continue; }

          var rect = el.getBoundingClientRect();
          if (rect.width < vw * 0.7 || rect.height < vh * 0.7) { continue; }
          if (parseInt(cs.zIndex || "0", 10) < 100) { continue; }
          if (!isTransparent(el, cs)) { continue; }
          if ((el.innerText || "").trim().length > 0) { continue; }
          if (!el.querySelector("a[href]")) { continue; }
          if (el.querySelector("video,audio,button,input,textarea,select")) { continue; }

          el.setAttribute("data-plane-ab", "1");
          if (isAdNamed(el)) {
            el.style.display = "none";
          } else {
            el.style.pointerEvents = "none";
          }
          pending++;
        }
        report();
      }

      var scheduled = false;
      function schedule(){
        if (scheduled) { return; }
        scheduled = true;
        setTimeout(function(){ scheduled = false; scan(); }, 200);
      }

      // 弹窗治理
      try { window.open = function(){ pending++; report(); return null; }; } catch(e){}

      // 整页被 <a> 包裹：拦截跳转，但不影响真实控件
      document.addEventListener("click", function(ev){
        if (window.__planeAdBlockOff) { return; }
        var t = ev.target;
        while (t && t !== document) {
          if (t.tagName === "A" && t.getAttribute("href")) {
            var r = t.getBoundingClientRect();
            var vw = window.innerWidth || 0;
            var vh = window.innerHeight || 0;
            if (r.width >= vw * 0.7 && r.height >= vh * 0.7) {
              var real = ev.target.closest && ev.target.closest("button,input,textarea,select,video,audio,[contenteditable]");
              if (!real) {
                ev.preventDefault();
                ev.stopPropagation();
                pending++;
                report();
              }
            }
            break;
          }
          t = t.parentElement;
        }
      }, true);

      try {
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
      } catch(e){}

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function(){ scan(); });
      } else {
        scan();
      }
      setInterval(scan, 1500);
    })();
    """#
}
