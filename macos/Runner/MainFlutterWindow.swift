import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // ThriveWoo POS (Phase 6ZA): open at a till-sized window and never shrink
    // below the size the cashier layout needs (the sales screen, cart panel
    // and payment dialog stay in their desktop layout from 1024 x 700).
    self.contentMinSize = NSSize(width: 1024, height: 700)
    self.setContentSize(NSSize(width: 1366, height: 860))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
