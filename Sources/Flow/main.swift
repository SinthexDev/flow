import Cocoa

let app = NSApplication.shared
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    app.setActivationPolicy(.accessory)
    Snapshot.run(into: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    exit(0)
}

if let hudIndex = arguments.firstIndex(of: UpdateProgressHud.argument) {
    let version = hudIndex + 1 < arguments.count ? arguments[hudIndex + 1] : L10n.appVersion
    var parentPid: pid_t?
    if let pIndex = arguments.firstIndex(of: UpdateProgressHud.parentPidArgument),
       pIndex + 1 < arguments.count {
        parentPid = pid_t(arguments[pIndex + 1])
    }
    UpdateProgressHud.runStandalone(version: version, parentPid: parentPid)
    exit(0)
}

if LegacyName.relocateIfNeeded() { exit(0) }
LegacyName.removeOldBundle()

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
