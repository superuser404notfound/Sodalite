import Foundation
import Observation
import StoreKit

/// Purchase result flattened from StoreKit 2's `Product.PurchaseResult` so the UI avoids `VerificationResult` / `@unknown default`.
enum PurchaseOutcome: Sendable {
    case success
    case userCancelled
    /// Awaiting parental approval / SCA; no entitlement yet, a later `Transaction.updates` may grant one.
    case pending
}

enum StoreKitServiceError: LocalizedError {
    /// Unverified JWS (forged transaction or stale App Store key); never trust the entitlement.
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            String(
                localized: "error.store.verificationFailed",
                defaultValue: "The App Store could not verify this purchase."
            )
        }
    }
}

@MainActor
protocol StoreKitServiceProtocol: AnyObject {
    var isSupporter: Bool { get }
    var tipProducts: [Product] { get }
    var supporterPackProduct: Product? { get }
    var hasLoadedProducts: Bool { get }
    var lastLoadError: String? { get }

    func loadProducts() async
    func purchase(_ product: Product) async throws -> PurchaseOutcome
    func restorePurchases() async throws
    func refreshSupporterStatus() async
}

/// Owns the StoreKit 2 session: loads products, purchases, verifies, exposes observable `isSupporter`. Caches `isSupporter` in UserDefaults for first-frame correctness; the authoritative `Transaction.currentEntitlements` refresh runs async on launch and overwrites the cache.
@MainActor
@Observable
final class StoreKitService: StoreKitServiceProtocol {

    // MARK: - Observable State

    private(set) var isSupporter: Bool
    private(set) var tipProducts: [Product] = []
    private(set) var supporterPackProduct: Product?
    /// True once a `Product.products(for:)` call finished (success or fail); lets the UI tell "loading" from "loaded with nothing".
    private(set) var hasLoadedProducts: Bool = false
    /// Last load-failure message, surfaced so the user isn't stuck on a spinner when StoreKit errors or products aren't approved.
    private(set) var lastLoadError: String?

    // MARK: - Private

    private let store: UserDefaults

    private enum Keys {
        static let cachedIsSupporter = "store.cachedIsSupporter"
    }

    // MARK: - Init

    init(store: UserDefaults = .standard) {
        self.store = store
        self.isSupporter = store.bool(forKey: Keys.cachedIsSupporter)
        // Listener lives for the process lifetime (no cancel/deinit bookkeeping); captures self weakly.
        Self.startTransactionListener { [weak self] transaction in
            await self?.handle(transaction: transaction)
        }
    }

    // MARK: - Product Loading

    func loadProducts() async {
        do {
            let products = try await Product.products(for: StoreProducts.allProductIDs)

            var tips: [Product] = []
            var pack: Product?
            for product in products {
                if StoreProducts.isTipJar(product.id) {
                    tips.append(product)
                } else if StoreProducts.isSupporterPack(product.id) {
                    pack = product
                }
            }
            tips.sort { $0.price < $1.price }

            self.tipProducts = tips
            self.supporterPackProduct = pack
            self.lastLoadError = nil
        } catch {
            #if DEBUG
            print("[StoreKit] loadProducts failed: \(error)")
            #endif
            self.lastLoadError = ErrorText.user(for: error)
        }
        // Always flip so the UI exits loading even on failure / empty list (common pre-IAP-review).
        self.hasLoadedProducts = true
    }

    // MARK: - Purchasing

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try Self.verify(verification)
            await handle(transaction: transaction)
            await transaction.finish()
            return .success
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .pending
        }
    }

    func restorePurchases() async throws {
        // Required by App Review (happy path needs no sync; currentEntitlements already has Apple-ID-restored non-consumables); also covers offline-during-last-change. Restores the Supporter Pack only: tips are consumables and never come back.
        try await AppStore.sync()
        await refreshSupporterStatus()
    }

    // MARK: - Entitlement Refresh

    func refreshSupporterStatus() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if StoreProducts.isSupporterPack(transaction.productID),
               transaction.revocationDate == nil {
                active = true
            }
        }
        setSupporter(active)
    }

    // MARK: - Internal Helpers

    private func handle(transaction: Transaction) async {
        if StoreProducts.isSupporterPack(transaction.productID) {
            setSupporter(transaction.revocationDate == nil)
        }
        // Tips are consumables: nothing to unlock, caller just finishes them.
    }

    private func setSupporter(_ value: Bool) {
        isSupporter = value
        store.set(value, forKey: Keys.cachedIsSupporter)
    }

    private static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified: throw StoreKitServiceError.verificationFailed
        }
    }

    /// Listener for transactions outside the main purchase flow (Ask-To-Buy completions, cross-device purchases). Apple requires IAP apps to attach this early so nothing is missed.
    private static func startTransactionListener(
        handler: @escaping @Sendable (Transaction) async -> Void
    ) {
        Task {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await handler(transaction)
                await transaction.finish()
            }
        }
    }
}
