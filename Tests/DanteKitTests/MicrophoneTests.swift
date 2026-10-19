import DanteKit
import Testing

struct MicrophoneTests {
    let headset = Microphone(id: 1, uid: "bt-headset", name: "Headset", transport: .bluetooth)
    let builtIn = Microphone(id: 2, uid: "built-in", name: "Built-in Microphone", transport: .builtIn)
    let usb = Microphone(id: 3, uid: "usb-mic", name: "USB Mic", transport: .usb)
    let teams = Microphone(id: 4, uid: "teams", name: "Meeting Audio", transport: .virtual)

    @Test func aBluetoothDefaultGivesWayToTheMacsMicrophone() {
        #expect(Microphone.pick(from: [headset, teams, builtIn], defaultID: 1, preferred: "") == builtIn)
    }

    @Test func thenAUSBMicrophone() {
        #expect(Microphone.pick(from: [headset, usb], defaultID: 1, preferred: "") == usb)
    }

    @Test func onlyTheHeadsetMeansTheHeadset() {
        #expect(Microphone.pick(from: [headset, teams], defaultID: 1, preferred: "") == headset)
    }

    @Test func aWiredDefaultStays() {
        #expect(Microphone.pick(from: [headset, builtIn, usb], defaultID: 3, preferred: "") == usb)
    }

    @Test func aChosenMicrophoneWinsWhileConnected() {
        #expect(Microphone.pick(from: [headset, builtIn], defaultID: 2, preferred: "bt-headset") == headset)
        #expect(Microphone.pick(from: [builtIn], defaultID: 2, preferred: "bt-headset") == builtIn)
    }
}
