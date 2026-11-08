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
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier.contains("segments") {
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
