import OatcakeCore
import SwiftUI

extension SettingsView {
    @ViewBuilder var general: some View {
        let config = model.config
        Section("You") {
            TextField(text: bind(\.myName), prompt: Text("Your name")) {
                Text("Your name")
                Text("Labels your microphone track in every transcript.")
            }
        }

        Section("App") {
            Toggle(isOn: bind(\.runInBackground)) {
                Text("Run in the background")
                Text("Keeps Oatcake in the menu bar, but not running in the Dock, after you close its last window. Turn this off to quit when the last window closes and any work has finished.")
            }
        }

        Section("Recording") {
            LabeledContent {
                // At the right-hand edge, where the switches and After a call's pop-up end.
                MicPicker(devices: devices ?? []).frame(width: 270, alignment: .trailing)
            } label: {
                Text("Microphone")
                if let devices {
                    let hint = micHint(config.mic, devices)
                    Text(hint.text).foregroundStyle(hint.color)
                }
            }
            Toggle(isOn: bind(\.liveTranscript)) {
                Text("Live transcript")
                Text("Shows what’s being said beside your notes during the call, transcribed on your Mac.")
            }
            Toggle(isOn: bind(\.liveVoices)) {
                Text("Name voices during the call")
                Text("Names the people Oatcake knows by voice in the live transcript, and lets you click a line to say who said it. Who’s who starts from the names you give. Turned off, a call uses about 180 MB less memory and a little less CPU.")
            }
            .disabled(!config.liveTranscript)
            Picker(selection: bind(\.afterCall)) {
                Text("Wait for me to check who’s who").tag(AfterCall.review)
                Text("Save with a summary").tag(AfterCall.saveWithSummary)
                Text("Save the transcript only").tag(AfterCall.saveTranscript)
            } label: {
                Text("After a call")
                Text(afterCallHint(config.afterCall))
            }
        }

        Section {
            Toggle(isOn: bind(\.callNotice)) {
                Text("Offer to record when a call starts")
                Text("A notification with a Start recording button when a calling app or browser starts using your microphone.")
            }
            if model.config.callNotice { notificationsHint }
            Toggle(isOn: bind(\.autoStop)) {
                Text("Stop recording when the call ends")
                Text("Once the calling app has let go of your microphone and the call audio has been quiet for 15 seconds, Oatcake says the call seems to have ended. It stops recording 30 seconds later, unless you choose Keep recording or the call comes back.")
            }
        } header: {
            Text("Calls")
        } footer: {
            Text("Oatcake notices a call by which apps have the microphone open. It doesn’t listen until you record.").settingsHint()
        }

        Section("To-dos") {
            Toggle(isOn: bind(\.todosEnabled)) {
                Text("Collect to-dos")
                Text("Each summary comes with the to-dos agreed in the call. Turned off, none are collected and the To-dos page is hidden; saved ones stay in each meeting’s todo.md.")
            }
        }
    }

    private func afterCallHint(_ choice: AfterCall) -> String {
        switch choice {
        case .review: "Each call waits under Who’s who until you’ve named its voices and saved it."
        case .saveWithSummary: "Each call is saved once it’s transcribed, and summarised. Voices Oatcake is sure it recognises keep their names; the rest are “Voice 1”, “Voice 2”… until you name them from the meeting."
        case .saveTranscript: "Each call is saved once it’s transcribed, with no summary or to-dos. Voices Oatcake is sure it recognises keep their names; the rest are “Voice 1”, “Voice 2”… until you name them from the meeting."
        }
    }
}
