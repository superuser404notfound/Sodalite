import SwiftUI

@MainActor
@Observable
final class SeerrRequestEditModel {
    var serverID: Int?
    var profileID: Int?
    var rootFolder: String?
    var selectedSeasons: Set<Int> = []
    var servers: [SeerrServiceServer] = []
    var profiles: [SeerrQualityProfile] = []
    var rootFolders: [SeerrRootFolder] = []
    var isLoading: Bool = true
    var loadError: String?
    var isSaving: Bool = false
    /// A server change is waiting for its profiles and folders.
    private(set) var isLoadingDetails = false

    private let request: SeerrRequest
    private let configService: SeerrServiceConfigServiceProtocol

    /// What the pickers showed for the request's own server before any edit. A field still on that value
    /// goes back exactly as the request had it, nil included: Seerr assigns what it is sent, so echoing the
    /// value that merely stood in for "default" would pin it (and turn off anime routing for good).
    private var seededServerID: Int?
    private var seededProfileID: Int?
    private var seededRootFolder: String?
    private var didSeed = false
    /// Bumped by every load, so an answer that arrives after a newer request was made is dropped.
    private var detailsToken = 0

    /// Save is only safe once the pickers hold the request's own values: before that the body would
    /// carry empty fields, and Seerr assigns every field it is sent, so they would be cleared (CAT-203).
    var isReady: Bool { didSeed && loadError == nil && !isLoading && !isLoadingDetails }

    /// The body to send, or nil while ``isReady`` is false.
    var updateBody: SeerrRequestUpdateBody? { isReady ? buildUpdateBody() : nil }

    init(request: SeerrRequest, configService: SeerrServiceConfigServiceProtocol) {
        self.request = request
        self.configService = configService
        if let seasons = request.seasons {
            self.selectedSeasons = Set(seasons.map(\.seasonNumber))
        }
    }

    func bootstrap() async {
        isLoading = true
        loadError = nil
        detailsToken += 1
        let token = detailsToken
        defer { isLoading = false }
        do {
            if request.type == .movie {
                servers = try await configService.radarrServers()
            } else {
                servers = try await configService.sonarrServers()
            }
            if serverID == nil {
                serverID = Self.initialServerID(for: request, in: servers)
            }
            if let activeID = serverID {
                try await loadDetails(forServerID: activeID, token: token)
            }
            guard token == detailsToken else { return }
            if !didSeed {
                didSeed = true
                seededServerID = serverID
                seededProfileID = profileID
                seededRootFolder = rootFolder
            }
        } catch {
            loadError = ErrorText.user(for: error)
        }
    }

    /// The instance the request actually routes to: its own `serverId`, else the one Seerr falls back to,
    /// the default of the request's OWN quality tier (a 4K request goes to the 4K default).
    static func initialServerID(for request: SeerrRequest, in servers: [SeerrServiceServer]) -> Int? {
        if let own = request.serverId, servers.contains(where: { $0.id == own }) { return own }
        let is4k = request.is4k ?? false
        return servers.first(where: { $0.isDefault == true && ($0.is4k ?? false) == is4k })?.id
            ?? servers.first(where: { ($0.is4k ?? false) == is4k })?.id
            ?? servers.first?.id
    }

    /// Cycling the picker fast starts several of these; only the newest one may fill the lists (CAT-208).
    func selectServer(_ id: Int) async {
        serverID = id
        profileID = nil
        rootFolder = nil
        detailsToken += 1
        let token = detailsToken
        isLoadingDetails = true
        defer { if token == detailsToken { isLoadingDetails = false } }
        do {
            try await loadDetails(forServerID: id, token: token)
            if token == detailsToken { loadError = nil }
        } catch {
            if token == detailsToken { loadError = ErrorText.user(for: error) }
        }
    }

    private func loadDetails(forServerID id: Int, token: Int) async throws {
        let details: SeerrServiceDetails = request.type == .movie
            ? try await configService.radarrDetails(serverID: id)
            : try await configService.sonarrDetails(serverID: id)
        guard token == detailsToken else { return }
        profiles = details.profiles
        rootFolders = details.rootFolders
        let onOwnServer = id == (seededServerID ?? Self.initialServerID(for: request, in: servers))
        let profileIDs = Set(details.profiles.map(\.id))
        let folderPaths = Set(details.rootFolders.map(\.path))
        if profileID == nil {
            profileID = [onOwnServer ? request.profileId : nil, details.server.activeProfileId]
                .compactMap { $0 }
                .first(where: profileIDs.contains)
                ?? details.profiles.first?.id
        }
        if rootFolder == nil {
            rootFolder = [onOwnServer ? request.rootFolder : nil, details.server.activeDirectory]
                .compactMap { $0 }
                .first(where: folderPaths.contains)
                ?? details.rootFolders.first?.path
        }
    }

    /// The request's complete state with the edits applied (see `SeerrRequestUpdateBody`). Language profile
    /// and tags are not edited here and their ids belong to one instance, so they stay on the request's own
    /// server and fall back to that server's defaults on another.
    func buildUpdateBody() -> SeerrRequestUpdateBody {
        let sameServer = serverID == seededServerID
        return SeerrRequestUpdateBody(
            mediaType: request.type,
            serverId: sameServer ? request.serverId : serverID,
            profileId: sameServer && profileID == seededProfileID ? request.profileId : profileID,
            rootFolder: sameServer && rootFolder == seededRootFolder ? request.rootFolder : rootFolder,
            languageProfileId: request.type == .tv && sameServer ? request.languageProfileId : nil,
            tags: sameServer ? request.tags : nil,
            seasons: request.type == .tv ? selectedSeasons.sorted() : nil,
            userId: nil
        )
    }
}

struct SeerrRequestEditSheet: View {
    let request: SeerrRequest
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var model: SeerrRequestEditModel?

    var body: some View {
        Group {
            if let model = model {
                sheetBody(model: model)
            } else {
                // Fills what the sheet gives it rather than declaring a size of its own: 600x400 is
                // the tvOS sheet's shape, and on a phone it is a box wider and taller than the sheet.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // .task on the outer Group, not the ProgressView branch: assigning self.model unmounts ProgressView, which would cancel a task attached to it mid-bootstrap. The Group stays mounted across the swap.
        .task {
            guard model == nil else { return }
            let m = SeerrRequestEditModel(
                request: request,
                configService: dependencies.seerrServiceConfigService
            )
            self.model = m
            await m.bootstrap()
        }
    }

    @ViewBuilder
    private func sheetBody(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("catalog.allRequests.edit.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(viewModel.title(for: request) ?? "#\(request.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.loadError {
                errorView(message: error, retry: { Task { await model.bootstrap() } })
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                pickerSection(model: model)
            }

            Spacer()

            footer(model: model)
        }
        .padding(48)
        .frame(maxWidth: 800)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func pickerSection(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serverPicker(model: model)
            profilePicker(model: model)
            rootFolderPicker(model: model)
            if request.type == .tv {
                seasonsPicker(model: model)
            }
        }
    }

    private func profilePicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.profile",
            options: model.profiles,
            selected: model.profiles.first(where: { $0.id == model.profileID }),
            label: { $0.name },
            onSelect: { profile in model.profileID = profile.id }
        )
    }

    private func rootFolderPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.rootFolder",
            options: model.rootFolders,
            selected: model.rootFolders.first(where: { $0.path == model.rootFolder }),
            label: { $0.path },
            onSelect: { folder in model.rootFolder = folder.path }
        )
    }

    @ViewBuilder
    private func seasonsPicker(model: SeerrRequestEditModel) -> some View {
        if let seasons = request.seasons, !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("catalog.allRequests.edit.seasons")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                ForEach(seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber })) { season in
                    SeerrSeasonRow(
                        title: SeerrSeasonRow.seasonTitle(season.seasonNumber),
                        status: nil,
                        isOn: model.selectedSeasons.contains(season.seasonNumber),
                        toggle: {
                            if model.selectedSeasons.contains(season.seasonNumber) {
                                model.selectedSeasons.remove(season.seasonNumber)
                            } else {
                                model.selectedSeasons.insert(season.seasonNumber)
                            }
                        }
                    )
                }
            }
        }
    }

    private func serverPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: request.type == .movie
                ? "catalog.allRequests.edit.server.radarr"
                : "catalog.allRequests.edit.server.sonarr",
            options: model.servers,
            selected: model.servers.first(where: { $0.id == model.serverID }),
            label: { $0.name },
            onSelect: { server in
                Task { await model.selectServer(server.id) }
            }
        )
    }

    private func footer(model: SeerrRequestEditModel) -> some View {
        HStack(spacing: 24) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: { dismiss() }
            )
            .disabled(model.isSaving)

            GlassActionButton(
                title: "catalog.allRequests.edit.save",
                systemImage: "checkmark",
                isProminent: true,
                isLoading: model.isSaving,
                action: { Task { await save(model: model) } }
            )
            .disabled(model.isSaving || !model.isReady || isSeasonSelectionInvalid(model: model))
        }
    }

    /// TV requests need >=1 season: Seerr refuses a series edit without seasons (500, "Missing seasons"). Movies are always valid (selectedSeasons empty by design).
    private func isSeasonSelectionInvalid(model: SeerrRequestEditModel) -> Bool {
        guard request.type == .tv else { return false }
        guard request.seasons?.isEmpty == false else { return false }
        return model.selectedSeasons.isEmpty
    }

    private func errorView(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("catalog.allRequests.edit.serverLoadError")
                .font(.body)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            GlassActionButton(
                title: "home.retry",
                systemImage: "arrow.clockwise",
                action: retry
            )
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func save(model: SeerrRequestEditModel) async {
        model.isSaving = true
        defer { model.isSaving = false }
        guard let body = model.updateBody else { return }
        let updated = await viewModel.updateRequest(request, body: body)
        if updated != nil {
            dismiss()
        }
    }
}

// MARK: - EditPickerRow

/// Generic single-select Edit-sheet picker row; ValuePickerRow conventions: left/right cycles, .tint stroke, tinted focused fill.
private struct EditPickerRow<Option: Identifiable & Equatable>: View {
    let title: LocalizedStringKey
    let options: [Option]
    let selected: Option?
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    /// The phone is too narrow for the tvOS side-by-side label + stepper: the stepper's minWidth
    /// starves the label, which then wraps to one glyph per line. Compact stacks label over stepper.
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        rowContent
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(focused
                          ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18))
                          : AnyShapeStyle(Color.Theme.restFill))
            )
            .focusStroke(cornerRadius: 16, isFocused: focused)
            .focusableSurface(!options.isEmpty)
            .focused($focused)
            #if os(tvOS)
            .onMoveCommand { direction in
                switch direction {
                case .left:  advance(by: -1)
                case .right: advance(by: 1)
                default: break
                }
            }
            #endif
            .animation(.easeInOut(duration: 0.15), value: focused)
    }

    @ViewBuilder
    private var rowContent: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 12) {
                titleLabel
                stepper
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 20) {
                titleLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                stepper
            }
        }
    }

    private var titleLabel: some View {
        Text(title)
            .font(.body)
            .fontWeight(.medium)
    }

    private var stepper: some View {
        HStack(spacing: 12) {
            chevron("chevron.left", enabled: canMoveBackward, step: -1)
            Text(selected.map(label) ?? String(localized: "catalog.allRequests.edit.loading", defaultValue: "Loading..."))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(minWidth: isCompact ? 0 : 180, maxWidth: isCompact ? .infinity : nil, alignment: .center)
                .lineLimit(1)
                .truncationMode(.tail)
            chevron("chevron.right", enabled: canMoveForward, step: 1)
        }
        .frame(maxWidth: isCompact ? .infinity : nil)
    }

    @ViewBuilder
    private func chevron(_ system: String, enabled: Bool, step: Int) -> some View {
        Image(systemName: system)
            .font(.caption)
            .foregroundStyle(focused ? Color.white : Color.secondary)
            .opacity(enabled ? 1 : 0.25)
            #if os(iOS)
            .padding(8)
            .contentShape(Rectangle())
            .onTapGesture { advance(by: step) }
            #endif
    }

    private var currentIndex: Int? { options.firstIndex(where: { $0 == selected }) }
    private var canMoveBackward: Bool { (currentIndex ?? 0) > 0 }
    private var canMoveForward: Bool { (currentIndex ?? -1) < options.count - 1 }

    private func advance(by step: Int) {
        guard let idx = currentIndex else { return }
        let new = max(0, min(options.count - 1, idx + step))
        if new != idx { onSelect(options[new]) }
    }
}
