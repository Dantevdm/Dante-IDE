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

- Replies use the Mac’s natural voice and speed when Natural Voice is enabled and set up there. The Mac generates short audio chunks and sends them over the paired connection; the phone plays them, including in walk mode. If natural speech is unavailable or the connection drops, the phone uses its installed system voice. Pressing the microphone interrupts either voice.
- Tap the microphone and speak; two seconds of quiet sends it. Say "status", "yes" or "no" to a waiting step, "stop", "say that again", "switch to <project>", "start a job to …", or ask anything: it goes to the agent in charge of that project.
- Walk mode keeps the audio session alive with the screen locked: press your Beats or another headset’s play/pause button to talk, and press again or pause speaking to send. It selects the Bluetooth microphone, shows the active audio route, and recovers the audio session after route changes or interruptions that permit resuming. The phone asks for microphone and speech recognition access when Walk mode is first enabled.
- Walk mode uses a looping local silent audio item and an explicit Now Playing session to request headset controls. Idle time and replies use the playback audio category; microphone capture temporarily uses the Bluetooth call-audio route, waiting for the input to settle before starting recognition. Its handlers and metadata belong to that session. If another audio app owns the controls, tap **Reconnect controls** in Dante; Control Center should show Dante before testing the play/pause button. The phone shows session activation and counts received presses. Volume buttons do not start recording. Test this on the updated phone build, first unlocked and then locked; a successful compile cannot verify Bluetooth routing on real Beats hardware.
- Spoken replies focus on the result and next step in everyday English. Permission prompts describe the purpose (such as reading a project file or running tests); exact commands and diffs stay on screen.
- Use the Approvals selector, or say “auto-approve”, “auto-edit”, or “ask me first”, to change the selected project’s main conversation. Eligible waiting steps are released too. This uses the Mac’s existing approval policy: questions, flagged changes and explicit job restrictions still wait. Jobs retain their own approval rules. A setting change is confirmed only after the Mac accepts it, and both apps need a build with this feature.
- While a paired device is connected, the Mac holds a user-initiated activity to prevent App Nap and idle system sleep; the display can still sleep. Heartbeats remove unresponsive devices after about 45 seconds, releasing the activity when the last device leaves. Turning the companion off releases it immediately. Closing the Mac's lid or explicitly putting it to sleep can still interrupt a session.
- The phone checks connection health every 15 seconds and on return to the foreground, reconnects when a ping fails or takes over eight seconds, and briefly waits for voice availability before using the system voice. A fallback message explains whether the Mac was unreachable, voice generation failed, or audio could not play.
- With no project open on the Mac, the phone lists its recent projects to open there, and anything you ask goes to the most recent one, which the Mac opens first. "Switch to <project>" opens a recent one too.
- Waiting steps show their diff or command with Approve and Decline; jobs show their state with Stop; New Job starts one on its own branch, optionally in away mode.

## Layout

- `Common/`: the app, the connection (`CompanionConnection`: WebSocket, challenge, reconnecting with back-off), the Keychain store and the colours.
- `Phone/`: pairing (camera scanner or a pasted link), the home screen and the voice loop.
- `Pad/` (to come, step 7): the desk layout.

Things the simulator can't show: the camera, the microphone, headset buttons and the locked screen. Try those on a phone with your Beats or other headset connected.
