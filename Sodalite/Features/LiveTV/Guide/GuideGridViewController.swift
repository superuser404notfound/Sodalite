import UIKit
import SwiftUI
import Observation

/// The guide canvas: a focusable ruler on top, a focusable channel column on the left, and the
/// program grid. The grid is the scroll source of truth; the column's y and the ruler's x follow it
/// in `scrollViewDidScroll`, which is cheap UIKit and triggers no SwiftUI re-render. The three views
/// are siblings with no overlap, so programs cannot scroll under the column and focus cannot land
/// beneath it.
@MainActor
final class GuideGridViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegate, GuideGridLayoutDelegate {

    struct Row {
        let channel: JellyfinChannel
        let programs: [JellyfinProgram]
        /// Content-space geometry per program, computed once per rebuild with overlaps resolved.
        /// The layout asks for this per cell, so deriving it from dates on every call would be the
        /// same walk repeated for every visible column.
        let spans: [(x: CGFloat, width: CGFloat)]
    }

    let model: GuideViewModel
    var tint: Color { didSet { reloadVisibleCells(); reloadVisibleColumnCells() } }
    /// Removes the whole subtree from the focus engine while another segment is showing.
    var isActive: Bool = true {
        didSet { view.isUserInteractionEnabled = isActive }
    }

    let dependencies: DependencyContainer
    let theme: ResolvedAppearanceTheme
    let onSelect: (JellyfinChannel, JellyfinProgram) -> Void
    let onPlayChannel: (JellyfinChannel, JellyfinProgram?) -> Void
    let onToggleFavorite: (JellyfinChannel) -> Void
    /// Fires when the grid takes focus, so the tab can hand the chrome back to the focus engine the
    /// moment it is no longer in the way rather than after a fixed wait.
    var onGridFocused: (() -> Void)?

    let gridLayout = GuideGridLayout()
    private(set) var gridView: UICollectionView!
    private(set) var columnView: UICollectionView!
    private(set) var rulerView: UICollectionView!
    private let cornerView = UIView()

    /// Reports no safe area to its cells. The guide deliberately extends past the bottom safe area,
    /// and a cell that overlaps it otherwise has its hosted SwiftUI content squeezed by exactly the
    /// overlapping amount, which is what made the bottom row render at half height with its rounded
    /// bottom fully drawn instead of being cut. `UITableView` has `insetsContentViewsToSafeArea` for
    /// this; `UICollectionView` does not, so the inset is removed at the source.
    final class SafeAreaFreeCollectionView: UICollectionView {
        override var safeAreaInsets: UIEdgeInsets { .zero }
    }

    private(set) var rows: [Row] = []
    /// Cached from the axis once. Not private: the focus extension reads it on every ruler move, and
    /// `axis.slots` rebuilds a 96-element array on each call.
    private(set) var slots: [Date] = []

    /// Guards the three-way scroll sync from feeding itself.
    var isSyncingScroll = false
    /// One-shot focus redirect, served by the focus extension.
    var pendingFocusRedirect: IndexPath?
    /// Last vetoed (previous, next) pair. The same proposal arriving twice means the redirect did
    /// not take, and re-vetoing it strands focus with no way out in ANY direction. Accept the
    /// engine's pick instead. The old guide had this hatch; the rebuild dropped it on the theory
    /// that a time anchor always materializes its target, and Vincent's Apple TV disagreed.
    var lastVetoedMove: (previous: IndexPath, next: IndexPath)?

    private var nowLineTimer: Timer?
    /// Set when the window wanted to move while the guide held focus. Reloading out from under a
    /// focused cell is worth avoiding, so the move waits for the next focus change instead.
    private var axisRefreshPending = false
    private var didInitialScroll = false
    private var lastScrollRequestVersion = 0
    var lastFocusRequest = 0
    /// Set when the player closes, cleared by the first focus that arrives in the guide. The restore
    /// picks its item geometrically and asks nobody, so the landing has to be corrected afterwards.
    /// A deadline, not a plain flag: if focus never arrives, an unrelated move minutes later must not
    /// be treated as the restore.
    var restoreCorrectionDeadline: Date?

    let metrics: GuideMetrics

    init(model: GuideViewModel,
         tint: Color,
         dependencies: DependencyContainer,
         theme: ResolvedAppearanceTheme,
         onSelect: @escaping (JellyfinChannel, JellyfinProgram) -> Void,
         onPlayChannel: @escaping (JellyfinChannel, JellyfinProgram?) -> Void,
         onToggleFavorite: @escaping (JellyfinChannel) -> Void) {
        self.model = model
        self.tint = tint
        self.dependencies = dependencies
        self.theme = theme
        self.onSelect = onSelect
        self.onPlayChannel = onPlayChannel
        self.onToggleFavorite = onToggleFavorite
        self.metrics = model.metrics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        // Nothing is cached from the axis yet, so a controller built hours into the session simply
        // starts from the current window instead of inheriting the one the model was born with.
        model.refreshAxis()
        slots = model.axis.slots
        lastScrollRequestVersion = model.scrollRequestVersion

        gridLayout.delegate = self
        gridLayout.rowHeight = metrics.rowHeight
        gridLayout.totalWidth = model.axis.totalWidth
        gridLayout.nowX = max(0, model.axis.x(for: Date()))
        gridLayout.gridlineXs = slots.map { model.axis.x(for: $0) }
        gridLayout.register(GuideNowLineView.self,
                            forDecorationViewOfKind: GuideGridLayout.nowLineKind)
        gridLayout.register(GuideGridLineView.self,
                            forDecorationViewOfKind: GuideGridLayout.gridLineKind)

        gridView = SafeAreaFreeCollectionView(frame: .zero, collectionViewLayout: gridLayout)
        gridView.backgroundColor = .clear
        gridView.clipsToBounds = true
        gridView.dataSource = self
        gridView.delegate = self
        // Not what brings focus back from the player (see LiveTVTabView.chromeFocusSuppressed and
        // correctRestoreLanding), but it keeps the row when focus merely steps out to the ruler.
        gridView.remembersLastFocusedIndexPath = true
        gridView.contentInsetAdjustmentBehavior = .never
        gridView.register(GuideProgramCell.self, forCellWithReuseIdentifier: GuideProgramCell.reuseID)
        view.addSubview(gridView)

        // Channel column. Scrolling stays ENABLED, unlike the old passive column: the focus engine
        // only offers items it can scroll into view, so a disabled column would trap focus on the
        // rows that happen to be visible. The y offset is synced both ways instead.
        let columnLayout = UICollectionViewFlowLayout()
        columnLayout.scrollDirection = .vertical
        columnLayout.minimumLineSpacing = 0
        columnLayout.minimumInteritemSpacing = 0
        columnLayout.itemSize = CGSize(width: metrics.channelColumnWidth, height: metrics.rowHeight)
        columnView = SafeAreaFreeCollectionView(frame: .zero, collectionViewLayout: columnLayout)
        columnView.backgroundColor = .clear
        columnView.clipsToBounds = true
        columnView.showsVerticalScrollIndicator = false
        columnView.contentInsetAdjustmentBehavior = .never
        columnView.dataSource = self
        columnView.delegate = self
        columnView.register(GuideChannelCell.self, forCellWithReuseIdentifier: GuideChannelCell.reuseID)
        view.addSubview(columnView)

        // Ruler: focusable half-hour chips. Left and right on it are plain focus movement, which is
        // what makes the time jump work at all: swipes on the Siri Remote produce no pressesBegan,
        // so a design that intercepts a direction key while focus stays put is not implementable.
        let rulerLayout = UICollectionViewFlowLayout()
        rulerLayout.scrollDirection = .horizontal
        rulerLayout.minimumLineSpacing = 0
        rulerLayout.minimumInteritemSpacing = 0
        rulerLayout.itemSize = CGSize(width: metrics.slotWidth, height: metrics.rulerHeight)
        rulerView = SafeAreaFreeCollectionView(frame: .zero, collectionViewLayout: rulerLayout)
        rulerView.backgroundColor = .clear
        rulerView.clipsToBounds = true
        rulerView.showsHorizontalScrollIndicator = false
        // Passive axis: it follows the grid and never drives it. See GuideRulerCellContent.
        rulerView.isUserInteractionEnabled = false
        rulerView.contentInsetAdjustmentBehavior = .never
        rulerView.dataSource = self
        rulerView.delegate = self
        rulerView.register(GuideRulerCell.self, forCellWithReuseIdentifier: GuideRulerCell.reuseID)
        view.addSubview(rulerView)

        cornerView.backgroundColor = .clear
        view.addSubview(cornerView)


        rebuildRows()
        gridView.reloadData()
        columnView.reloadData()
        rulerView.reloadData()

        observeRows()
        observeFavorites()
        observeTimerState()
        observeScrollRequests()
        installGestures()

        // The now-line timer does not fire while the app is suspended, and the guide is a screen
        // people leave running. Without this the window stays on the old half hour for up to a
        // minute after the app comes back, which is the symptom itself.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// The one route that does not wait for focus to move: coming back from suspension the screen
    /// is being re-established and focus with it, so there is no settled focus to disturb.
    @objc private func appDidBecomeActive() {
        refreshAxisIfNeeded(deferWhileFocused: false)
        refreshNow()
    }

    /// The grid, not the ruler or the column. Paired with indexPathForPreferredFocusedView, which
    /// answers from the anchor, this puts focus back on the channel the user was watching.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        gridView.map { [$0] } ?? super.preferredFocusEnvironments
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshNow()
        startNowLineTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        nowLineTimer?.invalidate()
        nowLineTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Inset by the per-side safe area so the column and the programs clear the Dynamic Island
        // and the rounded corners in landscape. The window's insets, not the controller's: the
        // hosting SwiftUI view ignores the safe area horizontally, which zeroes ours.
        #if os(iOS)
        let safe = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let leftInset = safe.left
        let rightInset = safe.right
        #else
        let leftInset: CGFloat = 0
        let rightInset: CGFloat = 0
        #endif
        let width = view.bounds.width - leftInset - rightInset
        let height = view.bounds.height
        let column = metrics.channelColumnWidth
        let ruler = metrics.rulerHeight

        // Full height on purpose. Snapping to whole rows removed the cut row but left an empty
        // strip, and the cut row carries the "there is more below" signal; the alpha ramp is what
        // makes it read cleanly.
        cornerView.frame = CGRect(x: leftInset, y: 0, width: column, height: ruler)
        rulerView.frame = CGRect(x: leftInset + column, y: 0, width: width - column, height: ruler)
        columnView.frame = CGRect(x: leftInset, y: ruler, width: column, height: height - ruler)
        gridView.frame = CGRect(x: leftInset + column, y: ruler,
                                width: width - column, height: height - ruler)
        applyEdgeFade()

        if !didInitialScroll, gridView.bounds.width > 0, model.axis.totalWidth > 0 {
            didInitialScroll = true
            // The anchor, not Date(): a jump requested before this controller existed (a category
            // snap while the list was still empty) is already sitting in anchorTime, and the
            // observer only fires on a CHANGE, so it would otherwise be dropped.
            scrollGrid(to: model.anchorTime, animated: false)
        }
    }

    /// Fade the row the bottom edge cuts through, instead of leaving it chopped in half.
    ///
    /// Per-cell alpha, not a gradient mask on the view: the guide ignores the bottom safe area, so
    /// where a mask's ramp actually lands on screen is not something this controller can know, and
    /// the first attempt was invisible. A cell's own frame against the scroller's visible rect is
    /// geometry that is knowable here. It is also cheaper: no offscreen compositing pass.
    private func applyEdgeFade() {
        fade(cellsOf: gridView)
        fade(cellsOf: columnView)
    }

    private func fade(cellsOf collectionView: UICollectionView) {
        let visibleBottom = collectionView.bounds.maxY
        for cell in collectionView.visibleCells {
            cell.alpha = Self.edgeAlpha(for: cell.frame, visibleBottom: visibleBottom)
        }
    }

    /// Full opacity until the row is actually being cut, then straight down with the visible
    /// fraction. The first attempt boosted this by 1.6, which left a half-cut row at 0.88 alpha:
    /// arithmetically a fade, visually nothing.
    static func edgeAlpha(for frame: CGRect, visibleBottom: CGFloat) -> CGFloat {
        guard frame.height > 0, frame.maxY > visibleBottom else { return 1 }
        let visible = (visibleBottom - frame.minY) / frame.height
        return min(1, max(0, visible))
    }

    // MARK: - Scroll sync

    /// Three scroll views, one sync point. The ruler and the grid share a content width (the axis
    /// spans a whole number of slots, so `slots.count * slotWidth == axis.totalWidth`), which is why
    /// their x offsets can be copied straight across rather than converted.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        if scrollView === gridView {
            columnView.contentOffset.y = gridView.contentOffset.y
            rulerView.contentOffset.x = gridView.contentOffset.x
        } else if scrollView === columnView {
            gridView.contentOffset.y = columnView.contentOffset.y
        }
        applyEdgeFade()
    }

    /// Scroll the grid (and with it the ruler) so `date` sits `leadingFraction` into the viewport.
    func scrollGrid(to date: Date, animated: Bool, leadingFraction: CGFloat = 0.08) {
        guard gridView.bounds.width > 0 else { return }
        let leading = gridView.bounds.width * leadingFraction
        let maxOffset = max(0, model.axis.totalWidth - gridView.bounds.width)
        let target = min(max(0, model.axis.x(for: date) - leading), maxOffset)
        // Only the grid animates. The ruler follows it through scrollViewDidScroll; animating
        // both meant two curves racing to the same target and writing over each other.
        rulerView.setContentOffset(CGPoint(x: target, y: 0), animated: false)
        gridView.setContentOffset(CGPoint(x: target, y: gridView.contentOffset.y), animated: animated)
    }

    // MARK: - Now line

    /// One minute is the smallest visible move, so tick at that rate: recompute the now line's x,
    /// nudge the layout, and refresh visible cells so the airing outline tracks across boundaries.
    private func startNowLineTimer() {
        nowLineTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // .common so it keeps firing while the grid is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        nowLineTimer = timer
    }

    private func refreshNow() {
        refreshAxisIfNeeded()
        gridLayout.nowX = max(0, model.axis.x(for: Date()))
        let context = UICollectionViewLayoutInvalidationContext()
        context.invalidateDecorationElements(
            ofKind: GuideGridLayout.nowLineKind, at: [IndexPath(item: 0, section: 0)])
        gridLayout.invalidateLayout(with: context)
        reloadVisibleCells()
    }

    // MARK: - Moving window

    /// Sodalite#138: the axis is a snapshot of "now", and this controller caches geometry derived
    /// from it (`slots`, the content width, the gridlines). Re-derive both, together, so the left
    /// edge cannot part company with the now line.
    private func refreshAxisIfNeeded(deferWhileFocused: Bool = true) {
        guard !(deferWhileFocused && guideHoldsFocus) else {
            axisRefreshPending = true
            return
        }
        axisRefreshPending = false
        let previous = model.axis
        guard model.refreshAxis() else { return }
        applyAxisChange(from: previous)
    }

    private func applyAxisChange(from previous: GuideAxis) {
        // The wall clock under the viewport's left edge, taken before the axis moves. Keeping it is
        // what makes the move invisible: the window slides, the programs do not.
        let leading = previous.date(atX: gridView.contentOffset.x)
        slots = model.axis.slots
        gridLayout.totalWidth = model.axis.totalWidth
        gridLayout.gridlineXs = slots.map { model.axis.x(for: $0) }
        gridLayout.nowX = max(0, model.axis.x(for: Date()))
        rebuildRows()
        gridLayout.invalidateLayout()
        UIView.performWithoutAnimation {
            gridView.reloadData()
            rulerView.reloadData()
            gridView.layoutIfNeeded()
        }
        let offset = Self.preservedOffset(date: leading, axis: model.axis,
                                          viewportWidth: gridView.bounds.width)
        rulerView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        gridView.setContentOffset(CGPoint(x: offset, y: gridView.contentOffset.y), animated: false)
        // Once per half hour at most, and it is what a retest can point at: Settings > Diagnostic
        // Log says whether the window ever moved, without a Mac in the room.
        LogTap.shared.note("[guide] window moved to \(model.axis.start.ISO8601Format()), "
                           + "was \(previous.start.ISO8601Format())")
    }

    /// Content offset that puts `date` back under the viewport's left edge, clamped to the new axis.
    static func preservedOffset(date: Date, axis: GuideAxis, viewportWidth: CGFloat) -> CGFloat {
        let maxOffset = max(0, axis.totalWidth - viewportWidth)
        return min(max(0, axis.x(for: date)), maxOffset)
    }

    /// True while the focused item is inside the guide. `UIFocusSystem` rather than a flag kept in
    /// `didUpdateFocus`: focus also leaves through routes this controller never hears about.
    private var guideHoldsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
        else { return false }
        return focused.isDescendant(of: view)
    }

    /// Focus moved somewhere in this subtree, or out of it. Either way it is worth asking again
    /// whether the deferred move can happen now.
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard axisRefreshPending else { return }
        // Applied whether focus left the guide or only moved inside it. Waiting for it to leave
        // would keep the stale window for as long as someone is navigating the grid, which is the
        // report's own scenario; a move is also the moment the screen is changing anyway, and the
        // anchor puts focus back on the same channel at the same time. Next turn of the loop: the
        // focus system still reports the old item during the update.
        Task { @MainActor [weak self] in self?.refreshAxisIfNeeded(deferWhileFocused: false) }
    }

    // MARK: - Model observation

    private func observeRows() {
        withObservationTracking {
            _ = model.channels
            _ = model.programsByChannel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyRowChange()
                self.observeRows()
            }
        }
    }

    /// Favorites separately: a toggle changes no rows, only the column's star.
    private func observeFavorites() {
        withObservationTracking {
            _ = model.timers.favoriteChannelIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reloadVisibleColumnCells()
                self.observeFavorites()
            }
        }
    }

    /// Timer state separately: a record toggle changes no rows, only a cell's dot.
    private func observeTimerState() {
        withObservationTracking {
            _ = model.timers.timerStateVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reloadVisibleCells()
                self.observeTimerState()
            }
        }
    }

    /// Jumps requested by the controls or a category snap, which the grid did not initiate.
    private func observeScrollRequests() {
        withObservationTracking {
            _ = model.scrollRequestVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.model.scrollRequestVersion != self.lastScrollRequestVersion {
                    self.lastScrollRequestVersion = self.model.scrollRequestVersion
                    self.scrollGrid(to: self.model.anchorTime, animated: true)
                }
                self.observeScrollRequests()
            }
        }
    }

    private func applyRowChange() {
        let old = rows
        rebuildRows()
        guard !old.isEmpty, isPrefix(old, of: rows) else {
            gridView.reloadData()
            columnView.reloadData()
            return
        }
        var changed = IndexSet()
        for section in 0..<old.count where signature(old[section]) != signature(rows[section]) {
            changed.insert(section)
        }
        let appended = rows.count > old.count ? IndexSet(integersIn: old.count..<rows.count) : IndexSet()
        guard !changed.isEmpty || !appended.isEmpty else { return }
        UIView.performWithoutAnimation {
            gridView.performBatchUpdates {
                if !changed.isEmpty { gridView.reloadSections(changed) }
                if !appended.isEmpty { gridView.insertSections(appended) }
            }
            if !appended.isEmpty {
                columnView.insertItems(at: appended.map { IndexPath(item: $0, section: 0) })
            }
        }
    }

    private func rebuildRows() {
        rows = model.channels.map { channel in
            let programs = model.programs(for: channel.id)
            return Row(channel: channel, programs: programs,
                       spans: GuideRowMath.spans(programs.map(\.guideTimeRange), axis: model.axis))
        }
    }

    private func isPrefix(_ old: [Row], of new: [Row]) -> Bool {
        guard new.count >= old.count else { return false }
        for index in 0..<old.count where old[index].channel.id != new[index].channel.id { return false }
        return true
    }

    private func signature(_ row: Row) -> String {
        "\(row.programs.count):\(row.programs.first?.id ?? "-"):\(row.programs.last?.id ?? "-")"
    }

    private func reloadVisibleCells() {
        for indexPath in gridView.indexPathsForVisibleItems {
            guard let cell = gridView.cellForItem(at: indexPath) as? GuideProgramCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func reloadVisibleColumnCells() {
        for indexPath in columnView.indexPathsForVisibleItems {
            guard let cell = columnView.cellForItem(at: indexPath) as? GuideChannelCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    // MARK: - Layout delegate

    func guideRowCount() -> Int { rows.count }

    func guideItemCount(section: Int) -> Int {
        guard section < rows.count else { return 0 }
        return rows[section].programs.isEmpty ? placeholderCount : rows[section].programs.count
    }

    /// A channel with no EPG data used to be ONE cell spanning the whole axis. With nothing to its
    /// left or right, focus had nowhere to go and left/right did nothing at all: the row read as a
    /// frozen app. It is also the cell the old guide blamed for teleporting focus hours away on a
    /// vertical move. Hourly segments fix both.
    private static let placeholderMinutes = 60

    private var placeholderCount: Int {
        let minutes = model.axis.end.timeIntervalSince(model.axis.start) / 60
        return max(1, Int(ceil(minutes / Double(Self.placeholderMinutes))))
    }

    func guideItemXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat) {
        programXWidth(section: section, item: item)
    }

    /// Content-space geometry of a cell. A channel with no EPG data gets one full-width placeholder.
    func programXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat) {
        guard section < rows.count else { return (0, gridLayout.totalWidth) }
        let row = rows[section]
        if row.programs.isEmpty {
            let slot = CGFloat(Self.placeholderMinutes) * model.axis.pointsPerMinute
            let x = CGFloat(item) * slot
            return (x, min(slot, max(0, gridLayout.totalWidth - x)))
        }
        guard item < row.spans.count else { return (0, gridLayout.totalWidth) }
        return row.spans[item]
    }

    // MARK: - Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === gridView ? rows.count : 1
    }

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        if collectionView === gridView { return guideItemCount(section: section) }
        if collectionView === rulerView { return slots.count }
        return rows.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === rulerView {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GuideRulerCell.reuseID, for: indexPath) as! GuideRulerCell
            configure(cell, at: indexPath)
            return cell
        }
        if collectionView === columnView {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GuideChannelCell.reuseID, for: indexPath) as! GuideChannelCell
            configure(cell, at: indexPath)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GuideProgramCell.reuseID, for: indexPath) as! GuideProgramCell
        configure(cell, at: indexPath)
        return cell
    }

    /// Item to focus in `section` for the current anchor time. Placeholder rows have no programs,
    /// so their index comes from the axis instead of the program list.
    func anchoredItemIndex(section: Int) -> Int? {
        guard section < rows.count else { return nil }
        let row = rows[section]
        if row.programs.isEmpty {
            let minutes = model.anchorTime.timeIntervalSince(model.axis.start) / 60
            let index = Int(minutes / Double(Self.placeholderMinutes))
            return min(max(0, index), placeholderCount - 1)
        }
        return model.programIndex(coveringOrNearest: model.anchorTime, in: row.channel.id)
    }

    private func configure(_ cell: GuideProgramCell, at indexPath: IndexPath) {
        guard indexPath.section < rows.count else { return }
        let row = rows[indexPath.section]
        if row.programs.isEmpty {
            cell.configure(title: NSLocalizedString("livetv.noProgramInfo", comment: ""),
                           isAiring: false, hasTimer: false, tint: tint,
                           dependencies: dependencies, theme: theme)
            return
        }
        guard indexPath.item < row.programs.count else { return }
        let program = row.programs[indexPath.item]
        cell.configure(title: program.name,
                       isAiring: program.isAiring(at: Date()),
                       hasTimer: model.timers.hasTimer(programID: program.id),
                       tint: tint, dependencies: dependencies, theme: theme)
    }

    private func configure(_ cell: GuideChannelCell, at indexPath: IndexPath) {
        guard indexPath.item < rows.count else { return }
        let channel = rows[indexPath.item].channel
        let logoURL = dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, imageType: .primary,
            tag: channel.primaryImageTag, maxHeight: Int(metrics.channelLogoSize * 2))
        cell.configure(name: channel.name, number: channel.channelNumber, logoURL: logoURL,
                       isFavorite: model.timers.isFavorite(channel.id), tint: tint,
                       metrics: metrics, dependencies: dependencies, theme: theme)
    }

    private func configure(_ cell: GuideRulerCell, at indexPath: IndexPath) {
        guard indexPath.item < slots.count else { return }
        let slot = slots[indexPath.item]
        // A 48h axis crosses midnight, and two unlabelled "00:00" chips are indistinguishable.
        let isFirstOfDay = indexPath.item == 0
            || !Calendar.current.isDate(slot, inSameDayAs: slots[indexPath.item - 1])
        cell.configure(label: Self.timeFormatter.string(from: slot),
                       dayLabel: isFirstOfDay ? Self.weekdayFormatter.string(from: slot) : nil,
                       dependencies: dependencies, theme: theme)
    }

    // MARK: - Formatting

    // One shared formatter: DateFormatter setup is costly and this runs per ruler chip.
    // Main-thread only, so there is no thread-safety concern.
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    /// Placeholder program for a channel with no EPG data. The id does not exist server-side, so
    /// `isSynthesized` keeps the record affordances hidden.
    func synthesizedProgram(for channel: JellyfinChannel) -> JellyfinProgram {
        JellyfinProgram(
            id: "live-\(channel.id)", channelId: channel.id, channelName: channel.name,
            name: channel.name, overview: nil, startDate: Date().addingTimeInterval(-1),
            endDate: Date().addingTimeInterval(3600), genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil,
            isKids: nil, isSports: nil, seriesName: nil, parentIndexNumber: nil,
            indexNumber: nil, episodeTitle: nil, timerId: nil, seriesTimerId: nil)
    }

    #if os(tvOS)
    /// Play/Pause plays the focused row's channel, the mapping the button already implies elsewhere
    /// in the app. In the class body, not the focus extension: overriding an inherited method from
    /// an extension is fragile ground in Swift and there is no reason to stand on it.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .playPause }),
              let channelID = model.anchorChannelID,
              let row = rows.first(where: { $0.channel.id == channelID })
        else {
            super.pressesBegan(presses, with: event)
            return
        }
        onPlayChannel(row.channel, row.programs.first { $0.isAiring(at: Date()) })
    }
    #endif
}

// MARK: - SwiftUI bridge

struct GuideGridContainer: UIViewControllerRepresentable {
    let model: GuideViewModel
    let tint: Color
    var isActive: Bool = true
    /// Bumped when the live player closes, so the grid can take focus back from the segment picker.
    var focusRequest: Int = 0
    let onSelect: (JellyfinChannel, JellyfinProgram) -> Void
    let onPlayChannel: (JellyfinChannel, JellyfinProgram?) -> Void
    let onToggleFavorite: (JellyfinChannel) -> Void
    var onGridFocused: () -> Void = {}

    @Environment(\.dependencies) private var dependencies
    @Environment(\.appearanceTheme) private var appearanceTheme

    func makeUIViewController(context: Context) -> GuideGridViewController {
        GuideGridViewController(
            model: model, tint: tint, dependencies: dependencies, theme: appearanceTheme,
            onSelect: onSelect, onPlayChannel: onPlayChannel, onToggleFavorite: onToggleFavorite)
    }

    func updateUIViewController(_ controller: GuideGridViewController, context: Context) {
        controller.onGridFocused = onGridFocused
        if controller.tint != tint { controller.tint = tint }
        // isUserInteractionEnabled, not opacity or allowsHitTesting: only this removes a UIKit
        // subtree from the tvOS focus engine, and without it the hidden guide stays focusable
        // behind the other segments.
        if controller.isActive != isActive { controller.isActive = isActive }
        if controller.lastFocusRequest != focusRequest {
            controller.lastFocusRequest = focusRequest
            // Not on the first pass: 0 is the initial value, and taking focus at launch would pull it
            // off whatever the tab itself wants focused.
            // Arms the one-shot landing correction. Nothing is asked of the focus engine here:
            // requesting focus into the grid was measured to be refused every single time.
            if focusRequest > 0 {
                controller.restoreCorrectionDeadline = Date().addingTimeInterval(3)
            }
        }
    }
}
