import SwiftUI

@main
struct PlaneM3U8App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VideoLibrary()
    @StateObject private var downloads = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(downloads)
                .onAppear { downloads.library = library }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 未捕获的 ObjC 异常（如 AVAssetWriter 校验失败）会直接闪退，
        // 这里把异常原因写入诊断日志，供事后定位
        NSSetUncaughtExceptionHandler { exception in
            let text = "[未捕获异常] \(exception.name.rawValue)：\(exception.reason ?? "-")\n"
                + exception.callStackSymbols.prefix(12).joined(separator: "\n")
            DiagnosticsLog.write(text)
        }
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier.contains("segments") {
            SegmentRunner.shared.prepareForBackgroundEvents()
            SegmentRunner.backgroundCompletion = completionHandler
        } else {
            DownloadManager.backgroundCompletionHandler = completionHandler
        }
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
