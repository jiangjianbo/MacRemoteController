import UIKit
import SwiftUI

/// iOS 13 生命周期入口（不用 SwiftUI @main App——那是 iOS 14+，为了低版本部署目标）。
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let session = SessionModel.shared
        let root = RootView().environmentObject(session).environmentObject(AppSettings.shared)
        window?.rootViewController = UIHostingController(rootView: root)
        window?.makeKeyAndVisible()
        return true
    }
}

/// 根视图：投屏页 or 连接页（对齐 Android：ScreenActivity vs MainActivity 的路由）。
struct RootView: View {
    @EnvironmentObject var session: SessionModel

    var body: some View {
        if session.inViewer {
            ScreenViewer()
        } else {
            ConnectView()
        }
    }
}
