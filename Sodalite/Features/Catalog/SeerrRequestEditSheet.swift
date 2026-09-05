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

    private let request: SeerrRequest
    private let configService: SeerrServiceConfigServiceProtocol

    init(request: SeerrRequest, configService: SeerrServiceConfigServiceProtocol) {
        self.request = request
        self.configService = configService
        self.serverID = request.media?.serviceId
        if let seasons = request.seasons {
            self.selectedSeasons = Set(seasons.map(\.seasonNumber))
        }
    }

    func bootstrap() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            if request.type == .movie {
                servers = try await configService.radarrServers()
            } else {
                servers = try await configService.sonarrServers()
            }
            if let activeID = serverID ?? servers.first(where: { $0.isDefault == true })?.id ?? servers.first?.id {
                serverID = activeID
                try await loadDetails(forServerID: activeID)
            }
        } catch {
            loadError = ErrorText.user(for: error)
        }
    }

    func selectServer(_ id: Int) async {
        serverID = id
        profileID = nil
        rootFolder = nil
        do {
            try await loadDetails(forServerID: id)
        } catch {
            loadError = ErrorText.user(for: error)
        }
    }

    private func loadDetails(forServerID id: Int) async throws {
        let details: SeerrServiceDetails = request.type == .movie
            ? try await configService.radarrDetails(serverID: id)
            : try await configService.sonarrDetails(serverID: id)
        profiles = details.profiles
        rootFolders = details.rootFolders
        if profileID == nil { profileID = details.profiles.first?.id }
        if rootFolder == nil { rootFolder = details.rootFolders.first?.path }
    }

    /// Partial body of only changed fields; avoids sending no-op values back to Jellyseerr (defensive against server-side validation rejecting a no-op edit).
    func buildUpdateBody() -> SeerrRequestUpdateBody {
        let originalSeasons = Set((request.seasons ?? []).map(\.seasonNumber))
        let newSeasons: [Int]? = (request.type == .tv && selectedSeasons != originalSeasons)
            ? Array(selectedSeasons).sorted()
            : nil
        return SeerrRequestUpdateBody(
            serverId: serverID != request.media?.serviceId ? serverID : nil,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: nil,
            seasons: newSeasons,
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
                    SeasonCheckboxRow(
                        seasonNumber: season.seasonNumber,
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
            .disabled(model.isSaving || model.serverID == nil || isSeasonSelectionInvalid(model: model))
        }
    }

    /// TV requests need >=1 season: Jellyseerr's update endpoint accepts `seasons: []` and destructively clears the request to zero seasons. Movies are always valid (selectedSeasons empty by design).
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
        let body = model.buildUpdateBody()
        let updated = await viewModel.updateRequest(request, body: body)
        if updated != nil {
            dismiss()
        }
    }
}

// MARK: - SeasonCheckboxRow

/// Focusable per-season checkbox row; sodalite-ui-focus-and-tint rules: `.focusable(true)` not Button, `.tint` stroke, tinted focused fill.
private struct SeasonCheckboxRow: View {
    let seasonNumber: Int
    let isOn: Bool
    let toggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(String(
                format: String(localized: "catalog.allRequests.edit.season.format", defaultValue: "Season %d"),
                seasonNumber
            ))
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(focused
                      ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18))
                      : AnyShapeStyle(Color.Theme.restFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) { toggle() }
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
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
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(focused ? 1 : 0)
            )
            .focusable(!options.isEmpty)
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
