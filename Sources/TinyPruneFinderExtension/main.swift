import Foundation

// Finder Sync extensions are launched as XPC services whose entry point lives in
// Foundation. Without Xcode we build a plain executable that hands control to it.
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
