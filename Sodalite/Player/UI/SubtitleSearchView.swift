import SwiftUI

/// Feature #4 overlay: search + pick a subtitle to download. DISPLAY-ONLY:
/// renders highlight from `subtitleSearchFocus`; PlayerHostController routes
/// all remote input (host has user interaction disabled like every overlay).
struct SubtitleSearchView: View {
    @Bindable var viewModel: PlayerViewModel
    var tint: Color

    #if os(macOS)
    /// A player window is iPad-sized at most, so the Mac takes the compact layout.
    private var isCompact: Bool { true }
    #else
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// iPhone (compact) shrinks the panel + fonts and adds a touch close button; tvOS/iPad full size.
    private var isCompact: Bool { hSizeClass == .compact }
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: isCompact ? 14 : 28) {
                HStack {
                    Text("player.subtitle.search.title")
                        .font(isCompact ? .headline : .title2.weight(.semibold))
                    Spacer()
                    #if os(iOS) || os(macOS)
                    Button { viewModel.dismissSubtitleSearch() } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                languageSwitcher
                content
            }
            .padding(isCompact ? 18 : 48)
            #if os(iOS) || os(macOS)
            .frame(maxWidth: 760, maxHeight: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            #else
            .frame(width: 1000, height: 760)
            #endif
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 18 : 28))
        }
    }

    private var languageSwitcher: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.subtitleSearchLanguageOptions.enumerated()), id: \.offset) { idx, choice in
                        let isFocused = viewModel.subtitleSearchFocus == .language(idx)
                        let isSelected = choice.code == viewModel.subtitleSearchLanguage
                        Text(choice.short)
                            .fontWeight(isSelected ? .bold : .regular)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isFocused ? tint : Color.Theme.restFillStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(isSelected && !isFocused ? tint : .clear, lineWidth: 2)
                            )
                            .foregroundStyle(isFocused ? .black : .primary)
                            .id(idx)
                            #if os(iOS) || os(macOS)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.subtitleSearchFocus = .language(idx)
                                viewModel.subtitleSearchConfirm()
                            }
                            #if os(macOS)
                            .onHover { if $0 { viewModel.subtitleSearchFocus = .language(idx) } }
                            #endif
                            #endif
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.subtitleSearchFocus) { _, newValue in
                if case .language(let i) = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.subtitleSearchState {
        case .idle, .loading:
            centered { ProgressView() }
        case .empty:
            centered {
                VStack(spacing: 8) {
                    Text("player.subtitle.search.noResults").foregroundStyle(.secondary)
                    Text("player.subtitle.search.noResultsHint")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            }
        case .error(let message):
            centered { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        case .downloadTimedOut(_, _, let message):
            centered {
                VStack(spacing: 24) {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    let isFocused = viewModel.subtitleSearchFocus == .retry
                    Text("player.subtitle.search.tryAgain")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isFocused ? tint : Color.Theme.restFillStrong)
                        )
                        .foregroundStyle(isFocused ? .black : .primary)
                        #if os(iOS) || os(macOS)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.subtitleSearchFocus = .retry
                            viewModel.subtitleSearchConfirm()
                        }
                        #endif
                }
                .padding(.horizontal, 24)
            }
        case .downloading:
            centered {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("player.subtitle.search.downloading").foregroundStyle(.secondary)
                }
            }
        case .results(let results):
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(results.enumerated()), id: \.offset) { idx, info in
                            resultRow(info, focused: viewModel.subtitleSearchFocus == .result(idx))
                                .id(idx)
                                #if os(iOS) || os(macOS)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.subtitleSearchFocus = .result(idx)
                                    viewModel.subtitleSearchConfirm()
                                }
                                #if os(macOS)
                                .onHover { if $0 { viewModel.subtitleSearchFocus = .result(idx) } }
                                #endif
                                #endif
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: viewModel.subtitleSearchFocus) { _, newValue in
                    if case .result(let i) = newValue {
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ info: RemoteSubtitleInfo, focused: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if info.isHashMatch == true {
                        Label(
                            String(localized: "player.subtitle.search.exactMatch",
                                   defaultValue: "Exact match"),
                            systemImage: "checkmark.seal.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(focused ? .black : Color.Theme.success)
                    }
                    Text(info.name ?? info.providerName ?? "Subtitle")
                        .lineLimit(1)
                        .foregroundStyle(focused ? .black : .primary)
                }
                HStack(spacing: 12) {
                    if let provider = info.providerName { Text(provider) }
                    if let lang = info.threeLetterISOLanguageName { Text(lang.uppercased()) }
                    if let fmt = info.format { Text(fmt.uppercased()) }
                }
                .font(.caption)
                .foregroundStyle(focused ? .black.opacity(0.7) : .secondary)
            }
            Spacer()
            if let count = info.downloadCount {
                Label("\(count)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(focused ? .black.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(focused ? tint : Color.Theme.restFill)
        )
    }
}
