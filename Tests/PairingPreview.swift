import SwiftUI
import AppKit

// Synthetic UI preview only: no clipboard monitoring, NAS connection or pairing helper.
@main enum PairingPreview {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Only construct view state; never call start(), pairingCode() or join().
        let cloud = NASController()
        cloud.pairCode = "123456"; cloud.pairExpires = Date().addingTimeInterval(30)
        cloud.pairMessage = "在另一台电脑输入这 6 位数字"; cloud.pairingActive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "轻贴配对界面测试（合成数字，不连接 NAS）"
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("配对另一台电脑").font(.title2).bold()
            PairingCodeCard(cloud: cloud)
        }.padding(24).frame(width: 500))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in app.terminate(nil) }
        withExtendedLifetime((window, cloud)) { app.run() }
    }
}
