import UIKit

/// 运行时方向锁：播放页强制横屏，退出后恢复跟随设备
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .all

    static func apply(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
            print("[OrientationLock] request failed: \(error.localizedDescription)")
        }

        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}
