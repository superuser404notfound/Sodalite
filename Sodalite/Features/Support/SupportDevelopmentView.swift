import StoreKit
import SwiftUI

/// Optional tip / Supporter Pack; every functional feature stays free.
struct SupportDevelopmentView: View {

    @Environment(\.dependencies) private var dependencies

    @State private var purchasing: String?
    @State private var isRestoring = false
    @State private var statusMessage: StatusMessage?

    private var service: StoreKitServiceProtocol { dependencies.storeKitService }

    var body: some View {
        ScrollView {
            VStack(spacing: 48) {
                Text(String(
                    localized: "settings.support.title",
                    defaultValue: "Support Development"
                ))
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)

                header
                tipJarSection
                supporterPackSection
            }
            .screenContentInset()
        }
        // Inline largeTitle only; floating nav-title otherwise sits behind scroll content. Matches PlaybackSettingsView.
        .hidesNavigationBarChrome()
        .task {
            if !service.hasLoadedProducts {
                await service.loadProducts()
            }
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                statusBanner(statusMessage)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: statusMessage)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 48))
                .foregroundStyle(.pink)

            Text(String(
                localized: "support.header.title",
                defaultValue: "Thanks for considering"
            ))
            .font(.title2)
            .fontWeight(.semibold)

            Text(String(
                localized: "support.header.copy",
                defaultValue: "Sodalite is a one-person passion project. Every functional feature in the app is and stays free. Tips and the paid cosmetic Supporter Pack are optional. They help cover the Apple Developer fee and show that the work is appreciated."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
    }

    private var tipJarSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "support.tipJar.title",
                    defaultValue: "Tip Jar"
                ))
                .font(.title3)
                .fontWeight(.semibold)
                Text(String(
                    localized: "support.tipJar.subtitle",
                    defaultValue: "One-time tips, no strings attached. Buy as many as you like."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            productsSection(for: .tips)
        }
    }

    private var supporterPackSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "support.pack.title",
                    defaultValue: "Supporter Pack"
                ))
                .font(.title3)
                .fontWeight(.semibold)
                Text(String(
                    localized: "support.pack.subtitle",
                    defaultValue: "One-time unlock. Curated accent palettes, premium animated backgrounds, and a special splash icon."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            productsSection(for: .pack)
            restoreSection
        }
    }

    private enum ProductSection { case tips, pack }

    @ViewBuilder
    private func productsSection(for kind: ProductSection) -> some View {
        if !service.hasLoadedProducts {
            loadingCard
        } else if let message = service.lastLoadError {
            unavailableCard(reason: .loadError(message))
        } else {
            switch kind {
            case .tips:
                if service.tipProducts.isEmpty {
                    unavailableCard(reason: .empty)
                } else {
                    VStack(spacing: 4) {
                        ForEach(service.tipProducts, id: \.id) { product in
                            TipJarRow(
                                product: product,
                                isPurchasing: purchasing == product.id,
                                isAnyPurchasing: purchasing != nil
                            ) {
                                await purchase(product)
                            }
                        }
                    }
                }
            case .pack:
                if service.supporterPackProduct == nil && !service.isSupporter {
                    unavailableCard(reason: .empty)
                } else {
                    SupporterPackRow(
                        product: service.supporterPackProduct,
                        isUnlocked: service.isSupporter,
                        isPurchasing: purchasing == service.supporterPackProduct?.id,
                        isAnyPurchasing: purchasing != nil
                    ) {
                        if let product = service.supporterPackProduct {
                            await purchase(product)
                        }
                    }
                }
            }
        }
    }

    /// Lives inside the Supporter Pack section: the pack is the only restorable product, tips are consumables (App Review 3.1.1).
    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            restoreButton
            Text(String(
                localized: "support.restore.footnote",
                defaultValue: "Tips are one-time purchases and cannot be restored."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            Label(
                String(localized: "support.restore.button", defaultValue: "Restore Supporter Pack"),
                systemImage: "arrow.clockwise"
            )
            .font(.body)
            .fontWeight(.medium)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        // Tile style keeps label readable across every accent tint, matches tip / supporter cards above.
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(isRestoring)
        .opacity(isRestoring ? 0.5 : 1)
    }

    // MARK: - Helpers

    private var loadingCard: some View {
        HStack(spacing: 20) {
            ProgressView()
            Text(String(
                localized: "support.loading",
                defaultValue: "Loading products…"
            ))
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.05))
        )
    }

    private enum UnavailableReason {
        case empty
        case loadError(String)
    }

    private func unavailableCard(reason: UnavailableReason) -> some View {
        let title: String
        let detail: String
        switch reason {
        case .empty:
            title = String(
                localized: "support.unavailable.title",
                defaultValue: "Products not available"
            )
            // On tvOS, empty product list is almost always a missing sandbox tester.
            detail = String(
                localized: "support.unavailable.subtitle",
                defaultValue: "Sign in with a Sandbox Tester account or wait for Apple to approve the in-app purchases. Tap to retry."
            )
        case .loadError(let message):
            title = String(
                localized: "support.unavailable.errorTitle",
                defaultValue: "Couldn't reach the App Store"
            )
            detail = message
        }

        return Button {
            Task { await service.loadProducts() }
        } label: {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }

    private func statusBanner(_ message: StatusMessage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: message.kind.icon)
                .foregroundStyle(message.kind.tint)
            Text(message.text)
                .font(.body)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(.thinMaterial)
        )
    }

    // MARK: - Actions

    private func purchase(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }

        do {
            let outcome = try await service.purchase(product)
            switch outcome {
            case .success:
                let text: String = StoreProducts.isSupporterPack(product.id)
                    ? String(
                        localized: "support.pack.thanks",
                        defaultValue: "Welcome aboard! Supporter Pack unlocked."
                    )
                    : String(
                        localized: "support.tipJar.thanks",
                        defaultValue: "Thank you!"
                    )
                show(.success, text: text)
            case .userCancelled:
                break
            case .pending:
                show(.info, text: String(
                    localized: "support.pending",
                    defaultValue: "Waiting for approval. The purchase will complete once approved."
                ))
            }
        } catch {
            show(.error, text: String(
                localized: "support.error",
                defaultValue: "Purchase failed. Please try again."
            ))
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await service.restorePurchases()
            if service.isSupporter {
                show(.success, text: String(
                    localized: "support.restore.success",
                    defaultValue: "Supporter Pack restored."
                ))
            } else {
                show(.info, text: String(
                    localized: "support.restore.none",
                    defaultValue: "No Supporter Pack purchase found for this Apple Account."
                ))
            }
        } catch {
            show(.error, text: String(
                localized: "support.restore.error",
                defaultValue: "Restore failed. Please try again."
            ))
        }
    }

    private func show(_ kind: StatusMessage.Kind, text: String) {
        statusMessage = StatusMessage(kind: kind, text: text)
        Task {
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                if statusMessage?.text == text { statusMessage = nil }
            }
        }
    }
}

// MARK: - Status Message

private struct StatusMessage: Equatable {
    enum Kind {
        case success, info, error

        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .info: "clock.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .green
            case .info: .yellow
            case .error: .red
            }
        }
    }

    let kind: Kind
    let text: String
}

// MARK: - Tip Jar Row

private struct TipJarRow: View {
    let product: Product
    let isPurchasing: Bool
    let isAnyPurchasing: Bool
    let action: () async -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 28) {
                Image(systemName: icon(for: product.id))
                    .font(.title2)
                    .frame(width: 56)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isPurchasing {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.body)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(isAnyPurchasing)
    }

    private func icon(for id: String) -> String {
        switch id {
        case StoreProducts.tipCoffee: "cup.and.saucer.fill"
        case StoreProducts.tipBeer: "mug.fill"
        case StoreProducts.tipPizza: "fork.knife"
        default: "gift.fill"
        }
    }
}

// MARK: - Supporter Pack Row

private struct SupporterPackRow: View {
    let product: Product?
    let isUnlocked: Bool
    let isPurchasing: Bool
    let isAnyPurchasing: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 28) {
                Image(systemName: isUnlocked ? "star.circle.fill" : "star.circle")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                    .frame(width: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product?.displayName ?? String(
                        localized: "support.pack.title",
                        defaultValue: "Supporter Pack"
                    ))
                    .font(.body)
                    .fontWeight(.medium)

                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                trailing
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .disabled(isUnlocked || product == nil || isAnyPurchasing)
    }

    @ViewBuilder
    private var trailing: some View {
        if isUnlocked {
            Label(
                String(localized: "support.pack.unlocked", defaultValue: "Unlocked"),
                systemImage: "checkmark"
            )
            .labelStyle(.titleAndIcon)
            .font(.body)
            .fontWeight(.semibold)
            .foregroundStyle(Color.Theme.success)
        } else if isPurchasing {
            ProgressView()
        } else if let product {
            Text(product.displayPrice)
                .font(.body)
                .fontWeight(.semibold)
                .monospacedDigit()
        } else {
            // verbatim: a bare dash is the same in every locale, and without it Xcode
            // extracts it into the catalog as an empty key on every build.
            Text(verbatim: "–")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusSubtitle: String {
        if isUnlocked {
            return String(
                localized: "support.pack.unlockedSubtitle",
                defaultValue: "Thank you for your support!"
            )
        }
        return product?.description ?? ""
    }
}
