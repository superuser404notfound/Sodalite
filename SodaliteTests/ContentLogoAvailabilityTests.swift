import Testing
@testable import Sodalite

/// The three states the detail header's title slot has to tell apart (Sodalite#125). A plain Bool
/// collapsed "the snapshot says there is no logo" into "the snapshot has not said yet", and the
/// second one paints a text title that the mark replaces a moment later.
struct ContentLogoAvailabilityTests {

    private func tags(logo: String?) -> ImageTags {
        ImageTags(primary: "p", backdrop: nil, thumb: nil, logo: logo, banner: nil)
    }

    // MARK: - Derivation

    /// The defect: the episode -> series stub carries no ImageTags at all, and the tagless logo
    /// request is already in flight.
    @Test func snapshotWithoutTagsIsUnknownUntilDetailSettles() {
        #expect(ContentLogoAvailability.from(imageTags: nil, hasFullDetail: false) == .unknown)
    }

    /// The other end of the same case: a server that omits the key has answered once the detail
    /// fetch is done, so the slot must stop waiting without needing a 404 to tell it.
    @Test func snapshotWithoutTagsIsAbsentOnceDetailSettles() {
        #expect(ContentLogoAvailability.from(imageTags: nil, hasFullDetail: true) == .absent)
    }

    /// A populated ImageTags is authoritative on its own. Home and Library rows carry one, so those
    /// opens keep painting their title on frame one and never blank.
    @Test func populatedTagsAreAuthoritativeBeforeDetailSettles() {
        #expect(ContentLogoAvailability.from(imageTags: tags(logo: nil), hasFullDetail: false) == .absent)
        #expect(ContentLogoAvailability.from(imageTags: tags(logo: "abc"), hasFullDetail: false) == .present)
    }

    @Test func aLogoTagIsPresentEitherWay() {
        #expect(ContentLogoAvailability.from(imageTags: tags(logo: "abc"), hasFullDetail: true) == .present)
    }

    /// Ties the enum to the type that produces the defect: DetailRouterView builds the episode ->
    /// series destination from this stub.
    @Test func theSeriesStubReadsAsUnknown() {
        let stub = JellyfinItem(seriesStub: "series-1", name: "Andor")
        #expect(ContentLogoAvailability.from(imageTags: stub.imageTags, hasFullDetail: false) == .unknown)
    }

    // MARK: - Slot

    /// Both states with a request in flight hold the slot; only the authoritative no paints text.
    @Test func onlyAbsentPaintsTheTextTitle() {
        #expect(ContentLogoAvailability.present.reservesSlot)
        #expect(ContentLogoAvailability.unknown.reservesSlot)
        #expect(!ContentLogoAvailability.absent.reservesSlot)
    }
}
