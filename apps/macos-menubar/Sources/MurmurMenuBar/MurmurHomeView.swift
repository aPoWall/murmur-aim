import AppKit
import SwiftUI
import MurmurTrayCore

struct MurmurHomeView: View {
    @ObservedObject var model: TrayModel
    @ObservedObject private var window = AIMWindowState.shared
    @State private var navigation = AIMPanelNavigation()
    private var page: String { navigation.page }
    private var pageBinding: Binding<String> { Binding(get: { navigation.page }, set: { navigation.select($0) }) }
    @MurmurViewState private var entry = "welcome"
    @MurmurViewState private var showingNewConnection = false

    init(model: TrayModel, initialPage: String = "Overview") {
        self.model = model
        _navigation = State(initialValue: AIMPanelNavigation(page: initialPage))
    }

    var body: some View {
        VStack(spacing: 0) {
            AIMHeaderBridge(onSettings: { navigation.openSettings() }, status: model.isDemo ? "preview · synthetic data" : (["Overview", "People"].contains(page) ? "VM105 · agent-sasha" : (model.agentID ?? "encrypted agent connections")))
                .frame(width: 708, height: 40).padding(16)
            AIMTabsBridge(page: pageBinding).frame(width: 708, height: 40).padding(.horizontal, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if page == "Overview" {
                        AIMCompanionView(model: model.companion)
                    } else if page == "People" {
                        AIMPeopleView(model: model.companion)
                    } else if page == "Help" {
                        AIMCompanionHelp()
                        MurmurHelpView()
                    } else if page == "Settings" {
                        AIMCompanionSettings(model: model.companion)
                        settingsContent
                    } else if model.hasPendingSetup {
                        savedSetup
                    } else if (model.profile == nil || showingNewConnection) && !model.isDemo {
                        firstRun
                    } else {
                        profileContent
                    }
                    if page != "Help", let error = model.selectionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.text("Choose another folder…")) { model.chooseProfile() }.help(L10n.text("Pick a different saved profile folder")).disabled(model.busy)
                        if let detail = model.selectionErrorDetail {
                            MurmurDisclosure(title: L10n.text("Technical details")) { Text(detail).textSelection(.enabled) }
                        }
                    }
                    if model.checkingSelection { ProgressView(L10n.text("Checking this folder before opening it…")) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            AIMFooterBridge(keys: window.keysLine, status: model.isDemo ? "preview" : (["Overview", "People"].contains(page) ? L10n.text("Server overview · 60s refresh") : (model.profile == nil ? "choose a connection" : "local profile · 15s refresh")))
                .frame(width: 708, height: 30).padding(.horizontal, 16)
        }.font(AIMTheme.body).foregroundStyle(AIMTheme.ink).background(AIMTheme.canvas)
            .tint(AIMTheme.signal).buttonStyle(AIMQuietButtonStyle())
            .background(AIMKeyboardBridge(onSettings: { navigation.openSettings() }, onTab: { navigation.select($0) })
                .frame(width: 0, height: 0).accessibilityHidden(true))
            .onExitCommand {
                if model.showCreateProfileSheet { if !model.creatingProfile { model.showCreateProfileSheet = false } }
                else if model.showPairingSheet { if !model.busy { model.showPairingSheet = false } }
                else if navigation.escape() { AIMWindowState.shared.close(.escape) }
            }
            .sheet(isPresented: $model.showCreateProfileSheet, onDismiss: { model.ownProfileSheetDismissed() }) { CreateProfileSheet(model: model) }
            .sheet(isPresented: $model.showPairingSheet, onDismiss: { model.clearPairing() }) { PairingSheet(model: model) }
            .onChange(of: model.profile) { _ in showingNewConnection = false; entry = "welcome" }
    }

    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Connect your AI assistants")).font(AIMTheme.title)
            Text(L10n.text("Murmur lets an assistant in Claude Code or Codex send work to another assistant and get a reply."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Set up the connection here. Keep working with your assistant in its usual application."))
                .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
            if model.preparingRuntime {
                ProgressView(L10n.text("Checking the Murmur engine…"))
            } else if let error = model.runtimeError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button(L10n.text("Try again")) { model.prepareRuntime() }.help(L10n.text("Check the Murmur engine again"))
            } else {
                if model.creatingProfile {
                    ProgressView(L10n.text("Creating your profile…"))
                } else if model.needsExistingProfileChoice {
                    Text(model.requiresRecoveryChoice ? L10n.text("Choose how to continue") : L10n.text("Saved connections on this Mac")).font(AIMTheme.heading)
                    profileExplanation
                    Text(model.requiresRecoveryChoice ? L10n.text("The saved record was reset. The earlier setup outcome is still unknown. Choose an existing profile or create a separate one.") : L10n.text("Choose an existing profile to continue. These folders may contain profiles from an earlier setup attempt."))
                        .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
                    ForEach(model.savedProfiles, id: \.dataDirectory) { profile in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.dataDirectory).font(AIMTheme.meta).textSelection(.enabled)
                            Button(L10n.text("Check and open this connection")) { model.chooseSavedProfile(profile) }.help(L10n.text("Verify this saved profile, then open it")).disabled(model.busy)
                        }
                    }
                    if model.requiresRecoveryChoice {
                        Button(L10n.text("Choose profile folder…")) { model.chooseProfile() }.help(L10n.text("Pick the folder that holds Murmur's saved settings and keys")).disabled(model.busy)
                        if model.archivedSetupRecord != nil {
                            Button(L10n.text("Show saved record copy")) { model.showArchivedSetupRecord() }.help(L10n.text("Show the copy of the reset setup record in Finder")).disabled(model.busy)
                        }
                    }
                    Button(L10n.text("Create a separate profile…")) { model.allowNewSeparateProfile() }.help(L10n.text("Start a new profile next to the existing ones")).disabled(model.busy)
                } else {
                    if entry == "restore" {
                        Button(L10n.text("Back")) { entry = "welcome" }.help(L10n.text("Back to the first step")).buttonStyle(.link)
                        Text(L10n.text("Open an existing connection")).font(AIMTheme.heading)
                        profileExplanation
                        Button(L10n.text("Find saved settings…")) { model.chooseProfile() }.help(L10n.text("Pick the folder of a connection saved earlier"))
                            .buttonStyle(AIMQuietButtonStyle()).disabled(model.busy)
                    } else if entry == "no-invitation" {
                        Button(L10n.text("Back")) { entry = "welcome" }.help(L10n.text("Back to the first step")).buttonStyle(.link)
                        Text(L10n.text("Ask your colleague for an Invitation line. Return your Reply, then check the connection."))
                        Text(L10n.text("Starting the network yourself? You need an existing connection server and its details. This app does not create a server."))
                            .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                        Button(L10n.text("I already have my own server…")) { model.beginOwnProfile() }.help(L10n.text("Create a profile for a server you already run")).disabled(model.busy)
                    } else {
                        Button(L10n.text("I have an invitation…")) { model.useInvitation() }
                            .buttonStyle(AIMQuietButtonStyle()).controlSize(.large)
                            .disabled(model.busy || !model.canUseInvitation).keyboardShortcut(.defaultAction)
                            .help(model.invitationBlockReason ?? L10n.text("Paste the Invitation line sent by your colleague."))
                        if let reason = model.invitationBlockReason {
                            Text(reason).font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L10n.text("Paste the Invitation line sent by your colleague."))
                            .font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                        Button(L10n.text("Invite a colleague")) { model.beginInviting() }
                            .disabled(model.busy || !model.canUseInvitation)
                            .help(model.invitationBlockReason ?? L10n.text("Invite a colleague"))
                        Divider()
                        navigationRow("I do not have an invitation yet", detail: "How to get one or connect to your own server") { entry = "no-invitation" }
                        navigationRow("I have used Murmur before", detail: "Open settings already saved on this Mac") { entry = "restore" }
                    }
                }
                if let error = model.creationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }.padding(.vertical, 8)
    }

    private var profileExplanation: some View {
        Text(L10n.text("A profile is Murmur's saved settings and private keys. A project folder or Documents is not a profile. New connections create these settings automatically; choose a folder only to restore an existing connection."))
            .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
    }

    private func navigationRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(title)).font(AIMTheme.heading)
                    Text(L10n.text(detail)).font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy).help(L10n.text(detail))
    }

    private var savedSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.pendingTitle).font(AIMTheme.title)
            if let pending = model.pendingCreation {
                Text(pending.plan.agentID).font(AIMTheme.heading)
                Text(pending.plan.profile.dataDirectory).font(AIMTheme.meta).textSelection(.enabled)
                if model.pendingCanRetryCreation {
                    Text(L10n.text("No profile or reply files were found. You can try the setup again."))
                        .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("Try setup again")) { model.discardEmptySetup() }.help(L10n.text("Discard the empty attempt and start the setup again")).disabled(model.busy)
                } else {
                    Text(L10n.text("Your files were kept. Check this same profile to continue; no new identity will be created."))
                        .foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
                    Button(model.creatingProfile ? L10n.text("Checking…") : L10n.text("Check saved profile and continue")) {
                        model.resumeSavedSetup()
                    }.buttonStyle(AIMQuietButtonStyle()).disabled(model.busy || model.runtimeError != nil).help(L10n.text("Continue with the files already saved; no new identity is created"))
                }
            }
            if let error = model.savedSetupError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = model.creationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Button(L10n.text("Show saved files")) { model.showSavedSetupFiles() }.help(L10n.text("Show the setup files in Finder")).disabled(model.busy)
            if model.canResetSavedSetup {
                Button(L10n.text("Reset saved setup record…")) { model.resetSavedSetupRecord() }.help(L10n.text("Reset the record after a confirmation; a copy is kept")).buttonStyle(.link)
            }
        }.padding(.vertical, 24)
    }

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.status == nil && !model.isDemo {
                Text(ConnectionGuidance.profileLabel(agentID: model.agentID, hasStatus: false, checking: model.checkingStatus))
                    .font(AIMTheme.title)
                if model.checkingStatus {
                    ProgressView()
                } else {
                    Text(L10n.text("Murmur could not verify the selected settings. Open a saved connection, or start a new one from an invitation."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("Start a new connection")) { showingNewConnection = true; entry = "welcome" }.help(L10n.text("Begin a new connection from an invitation"))
                        .buttonStyle(AIMQuietButtonStyle()).disabled(model.busy)
                    Button(L10n.text("Open an existing connection")) { model.chooseProfile() }.help(L10n.text("Pick a connection saved on this Mac")).disabled(model.busy)
                }
            } else {
                if let service = model.status?.service { ServiceHeading(service: service) }
                Label(model.verdict.reason, systemImage: model.verdict.indicator.symbol)
                    .font(AIMTheme.heading).fixedSize(horizontal: false, vertical: true)
                if let agent = model.agentID { Text(L10n.text("Your assistant: %@", agent)) }
            }
            if model.status != nil && !model.isDemo {
                HStack {
                    Button(L10n.text("Invite a colleague")) { model.beginInviting() }.help(L10n.text("Create an Invitation line for a colleague"))
                    Button(L10n.text("Paste colleague's Reply")) { model.beginPairing(.reply) }.help(L10n.text("Paste the Reply line your colleague returned"))
                }.disabled(!model.canPair)
            }
            if model.hasSetupSteps { setupSteps }
            if let peers = model.status?.peers.list, !peers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Connections")).font(AIMTheme.heading)
                    ForEach(peers, id: \.agentId) { peer in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.agentId).font(.subheadline).textSelection(.enabled)
                            Text(peer.exchangeDescription).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                        }
                    }
                    Text(L10n.text("Exchange verification does not test automatic agent wake."))
                        .font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                }.fixedSize(horizontal: false, vertical: true)
            }
            MurmurOutboxView(model: model)
            if model.status != nil && !model.isDemo { MurmurClientSetupView(model: model) }
            if let mismatch = model.status?.modeMismatch { Text(mismatch) }
            operationFeedback
            if let count = model.status?.inbox.unread { Text(L10n.text("Unread: %@", String(count))) }
            if let count = model.status?.wake.delivery.pendingUndelivered {
                Text(L10n.text("Waiting for agent delivery: %@", String(count)))
            }
            Button(model.checkingStatus ? L10n.text("Refreshing…") : L10n.text("Refresh status")) { model.refreshStatus() }.help(L10n.text("Ask the local service for its status now"))
                .disabled(model.busy || model.isDemo)
            if model.isDemo {
                Picker(L10n.text("Preview states"), selection: $model.demoState) {
                    ForEach(Indicator.allCases, id: \.self) { Text($0.title).tag($0) }
                }.help(L10n.text("Preview the states with synthetic data"))
            }
            if model.updateAvailable {
                Button(L10n.text("Murmur update available")) { model.openUpdateRelease() }.help(L10n.text("Open the upstream release page; this edition is rebuilt by hand")).disabled(model.isDemo)
            }
            MurmurDisclosure(title: L10n.text("Connection check"), explanation: L10n.text("Understand a problem and find the next step")) { diagnostics }
            if model.status != nil {
                Text(L10n.text("A running service does not prove that your AI assistant can answer. Send a test message from your AI application and wait for a reply."))
                    .font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Settings")).font(AIMTheme.title)
            Menu(L10n.text("Preferences")) { preferences }.help(L10n.text("Invitation, language, launch at login and update checks"))
            operationFeedback
            MurmurDisclosure(title: L10n.text("Background operation"), explanation: L10n.text("What keeps running when you close the window")) { service }
            Divider()
            MurmurDisclosure(title: L10n.text("Connection check"), explanation: L10n.text("Understand a problem and find the next step")) { diagnostics }
            Divider()
            MurmurDisclosure(title: L10n.text("Murmur updates"), explanation: L10n.text("Installed version and the last check")) { updateDetails }
            Divider()
            MurmurDisclosure(title: L10n.text("Saved connection"), explanation: L10n.text("Open settings already saved on this Mac")) {
                profileExplanation
                if let profile = model.profile {
                    Text(profile.dataDirectory).font(AIMTheme.meta).textSelection(.enabled)
                    if let service = profile.serviceName { Text(L10n.text("Service: %@", service)).font(AIMTheme.meta) }
                }
                Button(L10n.text("Open an existing connection")) { model.chooseProfile() }.help(L10n.text("Pick a connection saved on this Mac"))
                    .disabled(model.busy || model.isDemo || model.runtimeError != nil || model.hasPendingSetup)
            }
            Divider()
            shellSettings
        }
    }


    /// Rules 31, 38, 50, 53: every switch of the shell with its default, the same rows as the siblings.
    private var shellSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Window pin")).font(AIMTheme.heading)
            Text(L10n.text("Pinned: the window stays open on a click elsewhere. Unpinned, the default: a click in another app closes it. The same switch is the circle in the header."))
                .font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
            Button(window.pinned ? L10n.text("Unpin window") : L10n.text("Keep window open")) { window.setPinned(!window.pinned) }
                .help(L10n.text("Survives a restart; stored as org.aimindset.murmur.pinned"))
            Divider()
            Text(L10n.text("Theme")).font(AIMTheme.heading)
            Text(L10n.text("White by default. Black turns the window and its sheets dark; the menu bar mark follows macOS and the character keeps its white plate. The same switch sits in the footer."))
                .font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
            Button(window.theme == .dark ? L10n.text("White theme") : L10n.text("Black theme")) { window.setTheme(window.theme == .dark ? .light : .dark) }
                .help(L10n.text("Stored as org.aimindset.murmur.theme and applied at once"))
            Divider()
            Text(L10n.text("Global key")).font(AIMTheme.heading)
            Text(L10n.text("One combination opens and closes this window from any app. Press the field, then the keys: esc keeps the old one, delete clears it. A combination another AIM app or macOS holds is refused by name."))
                .font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
            HStack {
                AIMHotkeyBridge().frame(width: 160, height: 28)
                ForEach([FamilyHotkey(keyCode: 32, modifiers: [.option, .command], character: "u"),
                         FamilyHotkey(keyCode: 32, modifiers: [.control, .option], character: "u"),
                         FamilyHotkey(keyCode: 32, modifiers: [.option, .shift], character: "u")], id: \.storage) { pick in
                    Button(pick.display) {
                        if let refusal = pick.conflict(against: FamilyHotkeys.holders(excluding: FamilyHotkeys.murmur)) {
                            window.hotkeyLine = pick.display + " refused: " + refusal
                        } else {
                            AIMWindowState.hotkeyStore.store(pick); window.hotkeyLine = "stored " + pick.display; window.hotkeyChanged(pick)
                        }
                    }.help(L10n.text("Quick pick: use this combination if nobody holds it"))
                }
            }
            Text(window.hotkeyLine.isEmpty ? (window.hotkeyAvailable ? L10n.text("Default ⌥⌘U, held until AIM 4 as ⌃⌥⌘M") : L10n.text("The combination is held by another app"))
                 : window.hotkeyLine).font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
            Text(L10n.text("Family keys") + " · " + FamilyHotkeys.printedRows.joined(separator: " · "))
                .font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Next steps")).font(AIMTheme.heading)
            if model.setupReplyFile != nil {
                Text(L10n.text("Send your Reply line to the colleague who invited you."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Show and copy Reply")) { model.showSavedReply() }.help(L10n.text("Show the Reply line and copy it to the clipboard")).disabled(model.busy)
            }
            if model.status?.service.isRunning == true {
                Text(L10n.text("The Service is running. Check the connection after exchanging the Reply."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Check connection")) { model.refreshDoctor(); model.refreshStatus() }.help(L10n.text("Run the connection check and refresh the status"))
                    .disabled(model.busy || !model.canControl)
            } else {
                Text(L10n.text("Start Murmur to keep delivery running when this window is closed."))
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.operating ? L10n.text("Working…") : L10n.text("Start Murmur on this Mac")) { model.startNewProfile() }.help(L10n.text("Start the background service so delivery continues with the window closed"))
                    .buttonStyle(AIMQuietButtonStyle()).disabled(!model.canStartNewProfile)
            }
            if model.status?.service.isRunning == true {
                Button(L10n.text("Hide setup steps")) { model.hideSetupSteps() }.help(L10n.text("Hide this checklist"))
                    .buttonStyle(.link).font(AIMTheme.meta).disabled(model.busy)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var service: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let service = model.status?.service { ServiceHeading(service: service) }
            else { Text(L10n.text("Service status unknown")).font(AIMTheme.heading) }
            Text(L10n.text("When the background service is running, you can close this window and messages will still be delivered. Stopping the service stops delivery. Your AI assistant needs its own active session to answer."))
                .fixedSize(horizontal: false, vertical: true)
            if let enabled = model.status?.wake.config.enabled { Text(L10n.text("Configured: %@", model.wakeState(enabled))) }
            if let enabled = model.status?.wake.effective.enabled { Text(L10n.text("Effective now: %@", model.wakeState(enabled))) }
            if model.status?.wake.effective.needsRestart == true { Text(L10n.text("Restart the service to apply this setting")) }
            if let reason = model.controlBlockReason { Text(reason).font(AIMTheme.meta).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted)) }
            if model.status?.wake.config.enabled != nil {
                Button(model.operating ? L10n.text("Working…") : model.wakeAction.title) { model.perform(model.wakeAction) }.help(L10n.text("Turn automatic agent wake on or off for this profile"))
                    .disabled(!model.canControl)
            }
            HStack {
                Button(L10n.text("Start")) { model.perform(.start) }.help(L10n.text("Start the background service"))
                    .disabled(!model.canControl || model.status?.service.isRunning == true)
                Button(L10n.text("Stop")) { model.perform(.stop) }.help(L10n.text("Stop the background service; delivery stops"))
                    .disabled(!model.canControl || model.status?.service.state == .stopped || model.status?.service.state == .runningUnmanaged)
            }
            Button(L10n.text("Open configured log folder")) { model.openLogs() }.help(L10n.text("Open the service log folder in Finder")).disabled(!model.canControl)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var operationFeedback: some View {
        if let error = model.operationError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        if let message = model.operationMessage {
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let doctor = model.doctor {
                let summary = ConnectionGuidance.diagnosticSummary(doctor)
                Text(summary.title).font(AIMTheme.heading)
                Text(summary.message).fixedSize(horizontal: false, vertical: true)
                if doctor.stages.contains(where: { $0.state == "fail" }) {
                    Text(L10n.text("Later checks wait until the first problem is resolved."))
                        .font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                }
            } else {
                Text(model.checkingDoctor ? L10n.text("Checking the connection…") : L10n.text("The connection has not been checked yet."))
            }
            MurmurDisclosure(title: L10n.text("Technical details")) {
                if let doctor = model.doctor {
                    ForEach(doctor.rows()) { row in Label("\(row.title): \(row.detail)", systemImage: row.symbol).textSelection(.enabled) }
                    Text(L10n.text("Checked: %@", doctor.generatedAt)).font(AIMTheme.meta)
                } else if let error = model.doctorError { Text(error).textSelection(.enabled) }
                if let error = model.profileError { Text(error).textSelection(.enabled) }
                if let status = model.status {
                    ForEach(status.diagnosticNotes.filter { $0 != status.modeMismatch }, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
            HStack {
                Button(model.checkingDoctor ? L10n.text("Checking…") : L10n.text("Check now")) {
                    model.refreshDoctor(); model.refreshStatus()
                }.disabled(model.busy || model.isDemo || model.profile == nil).help(L10n.text("Run every connection check again"))
                Button(L10n.text("Copy diagnostics")) { model.copyDiagnostics() }.help(L10n.text("Copy the connection check results to the clipboard"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let updates = model.updates {
                Text(updates.title())
                Text(L10n.text("Product version: %@", updates.currentVersion ?? L10n.text("unknown.version")))
                Text(updates.reasonText)
                if let checkedAt = updates.checkedAt, let date = timestamp(checkedAt) {
                    Text(L10n.text("Last check: %@", date.formatted(date: .abbreviated, time: .shortened)))
                }
                Text(L10n.text("Checks can reuse a saved result. The date above is the time of that result, not a new network check."))
                    .font(AIMTheme.body).foregroundStyle(Color(nsColor: AIMAppShellStyle.muted))
                MurmurDisclosure(title: L10n.text("Technical details")) {
                    Text(L10n.text("Last attempt: %@", updates.checkedAt ?? L10n.text("not-measured.time")))
                    Text(updates.ageText())
                    Text(L10n.text("Last successful check: %@", updates.lastSuccessAt ?? L10n.text("not-measured.time")))
                    if let next = updates.nextCheckAt { Text(L10n.text("Next check no earlier than: %@", next)) }
                }
                if updates.stale { Text(L10n.text("The previous successful result is stale")) }
            } else { Text(L10n.text("Updates: result unknown")) }
            if model.checkingUpdates { Text(L10n.text("Checking for updates…")) }
            if let error = model.updateError { Text(error) }
            Button(L10n.text("Check updates")) { model.refreshUpdates() }.help(L10n.text("Ask GitHub for the latest upstream release")).disabled(!model.canChangeUpdates)
            if model.updateAvailable { Button(L10n.text("Open release page")) { model.openUpdateRelease() }.disabled(model.isDemo).help(L10n.text("Open the upstream release page in the browser")) }
        }.font(AIMTheme.meta).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var preferences: some View {
        Button(L10n.text("I have an invitation…")) { model.useInvitation() }
            .disabled(!model.canUseInvitation)
            .help(model.invitationBlockReason ?? L10n.text("Paste the Invitation line sent by your colleague."))
        Divider()
        Menu(L10n.text("Language")) {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Button { model.selectLanguage(language) } label: {
                    if model.language == language { Label(language.name, systemImage: "checkmark") }
                    else { Text(language.name) }
                }.disabled(model.busy || model.checkingUpdates)
            }
        }.help(L10n.text("Interface language; message text keeps its own language"))
        Toggle(L10n.text("Launch at login"), isOn: Binding(
            get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
        )).disabled(model.isDemo).help(L10n.text("Open Murmur AIM in the menu bar when you log in"))
        Menu(L10n.text("Murmur updates")) {
            Text(L10n.text("Checks every 6 hours; cache shared by this user"))
            Text(L10n.text("GitHub receives your IP address and sees that you use Murmur"))
            if model.updatesForcedOff { Text(L10n.text("Checks are blocked by MURMUR_UPDATE_CHECK=0")) }
            Button(L10n.text("Enable update checks")) { model.refreshUpdates(enabled: true) }
                .disabled(!model.canChangeUpdates || model.updatesForcedOff)
            Button(L10n.text("Disable update checks")) { model.refreshUpdates(enabled: false) }
                .disabled(!model.canChangeUpdates)
        }.help(L10n.text("Turn the 6-hour update check on or off"))
    }
}
