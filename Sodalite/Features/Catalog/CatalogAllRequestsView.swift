import SwiftUI

struct CatalogAllRequestsView: View {
    @Environment(\.appState) private var appState
    @Bindable var viewModel: CatalogViewModel
    @State private var requestPendingDecline: SeerrRequest?
    @State private var requestPendingDelete: SeerrRequest?
    @State private var requestBeingEdited: SeerrRequest?
    @State private var toastMessage: String?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat { metrics.rowLeading(shellPaysLeading: shellPaysLeading) }

    var body: some View {
        VStack(spacing: 0) {
            filterChips
                .padding(.leading, leadingInset)
                .padding(.trailing, metrics.rowInset)
                .padding(.top, 24)
                .padding(.bottom, 12)

            content
        }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.Theme.scrimHeavy, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .alert(
            "catalog.allRequests.confirm.decline.title",
            isPresented: declineAlertBinding,
            presenting: requestPendingDecline
        ) { request in
            Button("common.cancel", role: .cancel) {}
            Button("catalog.allRequests.action.decline", role: .destructive) {
                Task { await viewModel.declineRequest(request) }
            }
        } message: { request in
            Text(String(
                format: String(
                    localized: "catalog.allRequests.confirm.decline.message",
                    defaultValue: "%@ will be declined. Can still be deleted later."
                ),
                viewModel.title(for: request) ?? "#\(request.id)"
            ))
        }
        .alert(
            "catalog.allRequests.confirm.delete.title",
            isPresented: deleteAlertBinding,
            presenting: requestPendingDelete
        ) { request in
            Button("common.cancel", role: .cancel) {}
            Button("catalog.allRequests.action.delete", role: .destructive) {
                Task { await viewModel.deleteRequest(request) }
            }
        } message: { request in
            Text(String(
                format: String(
                    localized: "catalog.allRequests.confirm.delete.message",
                    defaultValue: "%@ will be removed from Jellyseerr. The file stays untouched if already downloaded."
                ),
                viewModel.title(for: request) ?? "#\(request.id)"
            ))
        }
        .menuPresentation(item: $requestBeingEdited, panel: .plain) { request in
            SeerrRequestEditSheet(request: request, viewModel: viewModel)
        }
        .onChange(of: viewModel.lastAdminRequestOutcome) { _, outcome in
            guard let outcome else { return }
            toastMessage = toastText(for: outcome)
            viewModel.lastAdminRequestOutcome = nil
            Task {
                try? await Task.sleep(for: .seconds(3))
                if toastMessage == toastText(for: outcome) { toastMessage = nil }
            }
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        #if os(iOS)
        Picker("", selection: Binding(
            get: { viewModel.allRequestsFilter },
            set: { newValue in Task { await viewModel.setAllRequestsFilter(newValue) } }
        )) {
            ForEach(SeerrRequestFilter.allCases) { filter in
                Text(filterTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        #else
        HStack(spacing: 12) {
            ForEach(SeerrRequestFilter.allCases) { filter in
                FilterChip(
                    title: filterTitle(filter),
                    count: viewModel.allRequestsCounts[filter],
                    isSelected: viewModel.allRequestsFilter == filter,
                    action: { Task { await viewModel.setAllRequestsFilter(filter) } }
                )
            }
            Spacer()
        }
        #endif
    }

    private func filterTitle(_ filter: SeerrRequestFilter) -> LocalizedStringKey {
        switch filter {
        case .pending:  "catalog.allRequests.filter.pending"
        case .approved: "catalog.allRequests.filter.approved"
        case .declined: "catalog.allRequests.filter.declined"
        case .all:      "catalog.allRequests.filter.all"
        }
    }

    // MARK: - List body

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingAllRequests && viewModel.allRequests.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.allRequests.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(viewModel.allRequests.enumerated()), id: \.element.id) { index, request in
                        SeerrRequestAdminRow(
                            request: request,
                            title: viewModel.title(for: request),
                            year: viewModel.year(for: request),
                            posterURL: viewModel.posterURL(for: request),
                            onApprove: { Task { await viewModel.approveRequest(request) } },
                            onEdit:    { requestBeingEdited = request },
                            onDecline: { requestPendingDecline = request },
                            onDelete:  { requestPendingDelete = request }
                        )
                        .onAppear {
                            if index >= viewModel.allRequests.count - 5 {
                                Task { await viewModel.loadMoreAllRequests() }
                            }
                        }
                    }

                    if viewModel.isLoadingMoreAllRequests {
                        ProgressView().padding(.vertical, 20)
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, 50)
                .padding(.bottom, 40)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(emptyKey)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyKey: LocalizedStringKey {
        switch viewModel.allRequestsFilter {
        case .pending:  "catalog.allRequests.empty.pending"
        case .approved: "catalog.allRequests.empty.approved"
        case .declined: "catalog.allRequests.empty.declined"
        case .all:      "catalog.allRequests.empty.all"
        }
    }

    // MARK: - Toast text + alert bindings

    private func toastText(for outcome: CatalogViewModel.AdminRequestOutcome) -> String {
        switch outcome {
        case .approved:
            return String(localized: "catalog.allRequests.toast.approved", defaultValue: "Request approved")
        case .declined:
            return String(localized: "catalog.allRequests.toast.declined", defaultValue: "Request declined")
        case .deleted:
            return String(localized: "catalog.allRequests.toast.deleted", defaultValue: "Request deleted")
        case .updated:
            return String(localized: "catalog.allRequests.toast.updated", defaultValue: "Request updated")
        case .permissionDenied:
            return String(localized: "catalog.allRequests.toast.permissionDenied", defaultValue: "Server denied the action")
        case .failed(let message):
            return message
        }
    }

    private var declineAlertBinding: Binding<Bool> {
        Binding(
            get: { requestPendingDecline != nil },
            set: { if !$0 { requestPendingDecline = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { requestPendingDelete != nil },
            set: { if !$0 { requestPendingDelete = nil } }
        )
    }
}
