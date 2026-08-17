import Foundation
import UtterCore

// The process entry point runs on the main thread; make that explicit
// for the MainActor-isolated bootstrap.
MainActor.assumeIsolated {
    UtterMain.run()
}
