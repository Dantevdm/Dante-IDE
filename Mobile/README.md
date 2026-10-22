# Dante for iPhone and iPad

The companion app (docs/plans/walk-and-work.md, step 5): the voice in your ear on a walk, and the agents' waiting steps, jobs and replies at a glance. The Mac does the work; the phone listens, speaks and answers.

## Build it

1. Open `Mobile/DanteCompanion.xcodeproj` in Xcode.
2. Select the DanteCompanion target › Signing & Capabilities and pick your team. A free Apple ID works: Xcode makes a Personal Team for it.
3. If Xcode says the bundle id `dev.dante.companion` is taken, change it to something of your own (`dev.dante.companion.<you>`).
4. Plug in the iPhone (or pair it over Wi-Fi in Window › Devices and Simulators), choose it as the destination and press Run. The first time, trust the developer on the phone in Settings › General › VPN & Device Management.

With a free team the app stops opening after seven days; run it from Xcode again to reinstall. A paid developer account makes that a year.

The app compiles `Sources/DanteCore` straight into its target (the project points at those files), so the wire protocol, the foreman and the speech helpers are the same code the Mac uses. There is no Swift package to add.

## Pair it

1. Install Tailscale on the Mac and the phone, signed in to the same account.
2. On the Mac: Dante › Settings › Agents › iPhone and iPad, turn it on and choose Show Pairing Code….
3. On the phone: Scan, and point the camera at the code. The key stays in the phone's Keychain (this device only) and is never sent; the Mac checks it with a challenge.

## Use it

- Tap the microphone and speak; two seconds of quiet sends it. Say "status", "yes" or "no" to a waiting step, "stop", "say that again", "switch to <project>", "start a job to …", or ask anything: it goes to the agent in charge of that project.
- Walk mode keeps the audio session alive with the screen locked: press an AirPod stem to talk, and it reads out replies, finished jobs and steps waiting on you.
- Waiting steps show their diff or command with Approve and Decline; jobs show their state with Stop; New Job starts one on its own branch, optionally in away mode.

## Layout

- `Common/`: the app, the connection (`CompanionConnection`: WebSocket, challenge, reconnecting with back-off), the Keychain store and the colours.
- `Phone/`: pairing (camera scanner or a pasted link), the home screen and the voice loop.
- `Pad/` (to come, step 7): the desk layout.

Things the simulator can't show: the camera, the microphone, AirPods presses and the locked screen. Try those on a phone.
