import AppKit
import SwiftUI

struct CaptureAISettings: View {
    @Environment(\.theme) private var theme
    @AppStorage(CaptureAI.analyzeKey) private var analyzesScreenshots = false
    @AppStorage(CaptureAI.summaryKey) private var summarizesMeetings = false
    @AppStorage(CaptureAI.credentialKey) private var credential = CaptureAI.Credential.apiKey
    @AppStorage(CaptureAI.modelKey) private var model = CaptureAI.defaultModel
    @ObservedObject private var chatGPT = CaptureChatGPT.shared
    @ObservedObject private var analysis = CaptureAI.shared
    @State private var message: String?
    @State private var models: [CaptureChatGPT.Model] = []
    @State private var loadingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Screenshot and Meeting Analysis", systemImage: "text.viewfinder")
                .font(self.theme.typography.bodyStrong)

            self.option(
                "Analyze Screenshots",
                help: "Send each screenshot and available meeting captions through capture time to OpenAI. Show the result in a floating panel.",
                isOn: self.$analyzesScreenshots
            )
            self.option(
                "Summarize Meetings Automatically",
                help: "After transcription, send the full transcript, screenshots, and available image analyses to OpenAI. Save the summary in the meeting folder.",
                isOn: self.$summarizesMeetings
            )

            HStack {
                Text("OpenAI connection")
                Spacer()
                FluidDropdownPicker("OpenAI connection", selectedTitle: self.credential == .chatGPT ? "ChatGPT plan" : "OpenAI API key", selection: self.$credential) {
                    Text("OpenAI API key").tag(CaptureAI.Credential.apiKey)
                    Text("ChatGPT plan").tag(CaptureAI.Credential.chatGPT)
                }
                .fluidDropdownStyle()
            }
            if self.credential == .chatGPT {
                self.accountControls
            } else {
                Text("Uses the OpenAI key configured in AI settings.")
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            HStack {
                Text("Vision model")
                Spacer()
                if self.credential == .chatGPT, self.chatGPT.email != nil {
                    Button("Load Models") { self.loadModels() }
                        .fluidOutlinedButton()
                        .disabled(self.loadingModels || self.chatGPT.isBusy)
                }
                if self.models.isEmpty || self.credential != .chatGPT {
                    TextField("Model ID", text: self.$model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                } else {
                    Menu(self.models.first(where: { $0.slug == self.model })?.display_name ?? self.model) {
                        ForEach(self.models) { model in
                            Button(model.display_name) { self.model = model.slug }
                        }
                    }
                }
            }

            HStack {
                Button("Edit Image Prompt") { self.openPrompt(.image) }
                    .fluidOutlinedButton()
                Button("Edit Summary Prompt") { self.openPrompt(.summary) }
                    .fluidOutlinedButton()
                if let summary = self.analysis.latestSummary {
                    Button("Open Latest Summary") { NSWorkspace.shared.open(summary) }
                        .fluidOutlinedButton()
                }
            }
            if let status = self.analysis.summaryStatus {
                Text(status).foregroundStyle(self.theme.palette.secondaryText)
            }
            if let message {
                Text(message).foregroundStyle(self.theme.palette.warning)
            }
        }
        .font(self.theme.typography.bodySmall)
        .task {
            if self.credential == .chatGPT {
                do { try self.chatGPT.load() } catch { self.message = error.localizedDescription }
            }
        }
        .onChange(of: self.credential) { _, value in
            self.models = []
            self.message = nil
            if value == .chatGPT {
                do { try self.chatGPT.load() } catch { self.message = error.localizedDescription }
            }
        }
    }

    private var accountControls: some View {
        HStack {
            if let email = self.chatGPT.email {
                Text(email).lineLimit(1).foregroundStyle(self.theme.palette.secondaryText)
                Button("Reconnect") { self.connect() }.fluidOutlinedButton()
                Button("Sign Out") {
                    Task {
                        self.message = nil
                        self.models = []
                        do { try await self.chatGPT.signOut() } catch { self.message = error.localizedDescription }
                    }
                }
                .fluidOutlinedButton()
            } else {
                Button("Continue with ChatGPT") { self.connect() }.fluidOutlinedButton()
                Button("Use Another Account") { self.connect(useSavedAccount: false) }.fluidOutlinedButton()
            }
            if self.chatGPT.isBusy { ProgressView().controlSize(.small) }
        }
        .disabled(self.chatGPT.isBusy)
    }

    private func option(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(self.theme.typography.bodyStrong)
                Text(help).foregroundStyle(self.theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private func connect(useSavedAccount: Bool = true) {
        Task {
            self.message = nil
            self.models = []
            do { try await self.chatGPT.signIn(useSavedAccount: useSavedAccount) } catch { self.message = error.localizedDescription }
        }
    }

    private func loadModels() {
        Task {
            self.loadingModels = true
            self.message = nil
            defer { self.loadingModels = false }
            do { self.models = try await self.chatGPT.models() } catch { self.message = error.localizedDescription }
        }
    }

    private func openPrompt(_ prompt: CapturePrompt) {
        Task {
            do {
                let url = try prompt.file()
                if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init())
                } else if !NSWorkspace.shared.open(url) {
                    throw CocoaError(.fileReadUnknown)
                }
                self.message = nil
            } catch {
                self.message = error.localizedDescription
            }
        }
    }
}
