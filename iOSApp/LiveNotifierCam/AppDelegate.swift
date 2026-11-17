import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.isIdleTimerDisabled = true

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.overrideUserInterfaceStyle = .dark
        win.backgroundColor = .black
        win.rootViewController = CameraViewController()
        win.makeKeyAndVisible()
        self.window = win
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
    }
}
