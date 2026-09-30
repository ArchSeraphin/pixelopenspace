import Foundation
import Testing
import PixelIPC

@Suite struct SocketPathTests {
    @Test func usualHomeUsesTheApplicationSupportPath() {
        let path = HookWire.socketPath(home: "/Users/seraphin", temporaryDirectory: "/var/folders/ab/xyz/T/", uid: 501)
        #expect(path == "/Users/seraphin/Library/Application Support/PixelOpenSpace/run/hook.sock")
        #expect(path.utf8.count <= HookWire.preferredSocketPathBytes)
    }

    @Test func longHomeFallsBackToTheTemporaryDirectory() {
        let home = "/Users/" + String(repeating: "n", count: 60)
        #expect(HookWire.socketPath(home: home, temporaryDirectory: "/var/folders/ab/xyz/T/", uid: 501)
            == "/var/folders/ab/xyz/T/pos-501/hook.sock")
        #expect(HookWire.socketPath(home: home, temporaryDirectory: nil, uid: 501) == "/tmp/pos-501/hook.sock")
        #expect(HookWire.socketPath(home: home, temporaryDirectory: "", uid: 0) == "/tmp/pos-0/hook.sock")
        #expect(HookWire.socketPath(home: home, temporaryDirectory: "/", uid: 7) == "/tmp/pos-7/hook.sock")
    }

    @Test func tokenFileSitsNextToTheSocket() {
        #expect(HookWire.tokenPath(socketPath: "/Users/seraphin/Library/Application Support/PixelOpenSpace/run/hook.sock")
            == "/Users/seraphin/Library/Application Support/PixelOpenSpace/run/token")
        #expect(HookWire.tokenPath(socketPath: "/tmp/pos-501/hook.sock") == "/tmp/pos-501/token")
        #expect(HookWire.tokenPath(socketPath: "/hook.sock") == "/token")
    }

    @Test func boundaryIsInclusive() {
        let suffix = "/Library/Application Support/PixelOpenSpace/run/hook.sock"
        let home = "/" + String(repeating: "h", count: HookWire.preferredSocketPathBytes - suffix.utf8.count - 1)
        #expect(HookWire.socketPath(home: home, temporaryDirectory: "/t", uid: 1) == home + suffix)
        #expect(HookWire.socketPath(home: home + "h", temporaryDirectory: "/t", uid: 1) == "/t/pos-1/hook.sock")
    }
}
