import UIKit
import SwiftUI
import Observation

/// EPG as a hard split: non-focusable channel column (left), focusable program grid (right),
/// time header (top), each clipped to its region. Grid is the scroll source of truth; column-y and
/// header-x sync to it in `scrollViewDidScroll` (cheap UIKit, no SwiftUI re-render). No overlap, so
/// programs can't scroll behind channels and focus can't land under the column.
@MainActor
final class EPGCollectionViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegate, EPGCollectionLayoutDelegate {

    private struct Row {
        let channel: JellyfinChannel
        let programs: [JellyfinProgram]
    }

    private let model: EPGGuideViewModel
    var tintColor: UIColor
    private let onSelect: (JellyfinChannel, JellyfinProgram) -> Void
    private let logoURLProvider: (JellyfinChannel) -> URL?

    private let metrics: EPGMetrics
    private let columnWidth: CGFloat
    private let rowHeight: CGFloat
    private let headerHeight: CGFloat

    private let gridLayout = EPGCollectionLayout()
    private var gridView: UICollectionView!
    private var columnView: UICollectionView!
    private let timeHeaderScroll = UIScrollView()
    private let timeHeaderContent = EPGTimeHeaderContentView()
    private let cornerView = UIView()
    private var rows: [Row] = []
    /// Advances the now line + current-program highlight as wall-clock passes, without a reload.
    private var nowLineTimer: Timer?
    /// One-shot: scroll the grid so "now" is near the left edge on first layout.
    private var didInitialScroll = false

    init(model: EPGGuideViewModel, tintColor: UIColor,
         logoURLProvider: @escaping (JellyfinChannel) -> URL?,
         onSelect: @escaping (JellyfinChannel, JellyfinProgram) -> Void) {
        self.model = model
        self.tintColor = tintColor
        self.logoURLProvider = logoURLProvider
        self.onSelect = onSelect
        self.metrics = model.metrics
        self.columnWidth = model.metrics.channelColumnWidth
        self.rowHeight = model.metrics.rowHeight
        self.headerHeight = model.metrics.headerHeight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        gridLayout.delegate = self
        gridLayout.rowHeight = rowHeight
        gridLayout.totalWidth = model.totalWidth
        gridLayout.nowX = max(0, model.xOffset(for: Date()))
        gridLayout.gridlineXs = model.timeTicks.map { model.xOffset(for: $0) }
        gridLayout.register(EPGNowLineView.self, forDecorationViewOfKind: EPGCollectionLayout.nowLineKind)
        gridLayout.register(EPGGridLineView.self, forDecorationViewOfKind: EPGCollectionLayout.gridLineKind)
        gridView = UICollectionView(frame: .zero, collectionViewLayout: gridLayout)
        gridView.backgroundColor = .clear
        gridView.clipsToBounds = true
        gridView.dataSource = self
        gridView.delegate = self
        gridView.remembersLastFocusedIndexPath = true
        gridView.contentInsetAdjustmentBehavior = .never
        gridView.register(EPGProgramCollectionCell.self,
                          forCellWithReuseIdentifier: EPGProgramCollectionCell.reuseID)
        view.addSubview(gridView)

        // Channel column: passive, scroll synced to the grid.
        let columnLayout = UICollectionViewFlowLayout()
        columnLayout.scrollDirection = .vertical
        columnLayout.minimumLineSpacing = 0
        columnLayout.minimumInteritemSpacing = 0
        columnLayout.itemSize = CGSize(width: columnWidth, height: rowHeight)
        columnView = UICollectionView(frame: .zero, collectionViewLayout: columnLayout)
        columnView.backgroundColor = epgPinnedBackground
        columnView.clipsToBounds = true
        columnView.isScrollEnabled = false
        columnView.contentInsetAdjustmentBehavior = .never
        columnView.dataSource = self
        columnView.register(EPGChannelCell.self, forCellWithReuseIdentifier: EPGChannelCell.reuseID)
        view.addSubview(columnView)

        // Time header: passive, scroll synced to the grid.
        timeHeaderScroll.backgroundColor = epgPinnedBackground
        timeHeaderScroll.clipsToBounds = true
        timeHeaderScroll.isScrollEnabled = false
        timeHeaderScroll.isUserInteractionEnabled = false
        timeHeaderScroll.contentInsetAdjustmentBehavior = .never
        timeHeaderScroll.addSubview(timeHeaderContent)
        view.addSubview(timeHeaderScroll)

        cornerView.backgroundColor = epgPinnedBackground
        view.addSubview(cornerView)

        rebuildRows()
        gridView.reloadData()
        columnView.reloadData()
        timeHeaderContent.configure(ticks: timeTicks())
        startObserving()
        observeFavorites()
        observeTimerState()
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

    // MARK: - Now line + current-program highlight

    /// Tick once a minute (one minute is the smallest visible move): recompute now-line x, nudge the
    /// layout, refresh visible cells so the live-program highlight tracks.
    private func startNowLineTimer() {
        nowLineTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // .common so it keeps firing while the user scrolls the grid.
        RunLoop.main.add(timer, forMode: .common)
        nowLineTimer = timer
    }

    private func refreshNow() {
        gridLayout.nowX = max(0, model.xOffset(for: Date()))
        let ctx = UICollectionViewLayoutInvalidationContext()
        ctx.invalidateDecorationElements(
            ofKind: EPGCollectionLayout.nowLineKind, at: [IndexPath(item: 0, section: 0)])
        gridLayout.invalidateLayout(with: ctx)
        // Refresh visible cells so the "on now" border follows the clock across program boundaries.
        for indexPath in gridView.indexPathsForVisibleItems {
            guard let cell = gridView.cellForItem(at: indexPath) as? EPGProgramCollectionCell else { continue }
            // Bounds-guard (as refreshTimerDots/refreshFavoriteStars): visible paths can outlive a model mutation.
            guard indexPath.section < rows.count else { continue }
            let row = rows[indexPath.section]
            guard indexPath.item < row.programs.count else { continue }
            cell.setOnNow(isProgramOnNow(row.programs[indexPath.item]))
        }
    }

    private func isProgramOnNow(_ program: JellyfinProgram) -> Bool {
        guard let start = program.startDate, let end = program.endDate else { return false }
        let now = Date()
        return start <= now && now < end
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Inset the whole grid by the PER-SIDE safe area so the channel column + programs clear the
        // Dynamic Island / rounded corners in landscape. Read the window's insets: the hosting SwiftUI
        // view ignoresSafeArea horizontally, so the VC's own safeAreaInsets are zeroed. tvOS: no inset.
        #if os(iOS)
        let safe = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let leftInset = safe.left
        let rightInset = safe.right
        #else
        let leftInset: CGFloat = 0
        let rightInset: CGFloat = 0
        #endif
        let w = view.bounds.width - leftInset - rightInset, h = view.bounds.height
        cornerView.frame = CGRect(x: leftInset, y: 0, width: columnWidth, height: headerHeight)
        timeHeaderScroll.frame = CGRect(x: leftInset + columnWidth, y: 0, width: w - columnWidth, height: headerHeight)
        timeHeaderScroll.contentSize = CGSize(width: model.totalWidth, height: headerHeight)
        timeHeaderContent.frame = CGRect(x: 0, y: 0, width: model.totalWidth, height: headerHeight)
        columnView.frame = CGRect(x: leftInset, y: headerHeight, width: columnWidth, height: h - headerHeight)
        gridView.frame = CGRect(x: leftInset + columnWidth, y: headerHeight, width: w - columnWidth, height: h - headerHeight)

        // One-shot: open with "now" near the left edge, with a little context to its left (the
        // just-ended part of the current program), clamped to the scrollable range.
        if !didInitialScroll, gridView.bounds.width > 0, model.totalWidth > 0 {
            didInitialScroll = true
            let leading = gridView.bounds.width * 0.08
            let maxOffset = max(0, model.totalWidth - gridView.bounds.width)
            let target = min(max(0, gridLayout.nowX - leading), maxOffset)
            gridView.contentOffset.x = target
            timeHeaderScroll.contentOffset.x = target
        }
    }

    // MARK: - Scroll sync (grid drives column + header)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === gridView else { return }
        columnView.contentOffset.y = gridView.contentOffset.y
        timeHeaderScroll.contentOffset.x = gridView.contentOffset.x
    }

    // MARK: - Focus column anchoring (vertical moves keep the time column)

    /// Timeline position the user is navigating at; set on horizontal moves, kept across vertical
    /// ones. Without it the engine picks the next row's cell nearest the CURRENT cell's center, so a
    /// wide cell (3h program, or full-width 24h "no program info" placeholder) teleports focus hours
    /// right and drags scroll along.
    private var focusAnchorX: CGFloat?
    /// One-shot redirect served via `indexPathForPreferredFocusedView` after `shouldUpdateFocusIn` vetoes a vertical move.
    private var pendingFocusRedirect: IndexPath?
    /// Last vetoed (prev, next). Same proposal again = redirect never took (anchor-column cell not
    /// focusable/materialized, typical at the placeholder/real-program seam after deep scrolling);
    /// re-vetoing strands focus, so accept the engine's unanchored pick instead.
    private var lastVetoedMove: (prev: IndexPath, next: IndexPath)?

    func collectionView(_ collectionView: UICollectionView,
                        shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        guard collectionView === gridView,
              let next = context.nextFocusedIndexPath
        else { return true }
        if let redirect = pendingFocusRedirect {
            // Our own redirect: let it through (didUpdateFocus clears the marker). Anything ELSE
            // pending is a move that raced ahead of the async setNeedsFocusUpdate during fast scroll;
            // re-veto it against the anchor rather than waving it through unanchored (which let focus
            // teleport onto a far-right wide cell).
            if next == redirect { return true }
        }
        guard let prev = context.previouslyFocusedIndexPath,
              next.section != prev.section,
              context.focusHeading.contains(.up) || context.focusHeading.contains(.down),
              let anchorX = focusAnchorX
        else { return true }
        let desired = itemIndex(nearestToX: anchorX, inSection: next.section)
        guard desired != next.item else {
            // Engine's pick already in the anchor column; drop the obsolete redirect so the async
            // re-run doesn't yank focus back to an older row.
            pendingFocusRedirect = nil
            return true
        }
        if let last = lastVetoedMove, last.prev == prev, last.next == next {
            // Same proposal after a veto: redirect didn't take, accept the engine's pick.
            lastVetoedMove = nil
            pendingFocusRedirect = nil
            return true
        }
        lastVetoedMove = (prev, next)
        // Veto and re-run; indexPathForPreferredFocusedView serves the column-anchored target.
        pendingFocusRedirect = IndexPath(item: desired, section: next.section)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRedirect != nil else { return }
            self.gridView.setNeedsFocusUpdate()
            self.gridView.updateFocusIfNeeded()
        }
        return false
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        collectionView === gridView ? pendingFocusRedirect : nil
    }

    func collectionView(_ collectionView: UICollectionView,
                        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard collectionView === gridView else { return }
        let wasRedirect = pendingFocusRedirect != nil
        pendingFocusRedirect = nil
        // Focus moved, so redirect is healthy; clear lastVetoedMove so the escape hatch only fires
        // on a genuinely repeated (failed) proposal.
        lastVetoedMove = nil
        guard let indexPath = context.nextFocusedIndexPath else { return }
        let vertical = context.focusHeading.contains(.up) || context.focusHeading.contains(.down)
        // Keep the anchor across vertical moves (incl. redirects, whose heading isn't directional);
        // re-anchor on horizontal/first focus using the cell's VISIBLE-span midpoint so a wide cell
        // anchors where the user is looking, not at its possibly far-offscreen center.
        guard focusAnchorX == nil || (!vertical && !wasRedirect) else { return }
        let (x, w) = epgProgramXWidth(section: indexPath.section, item: indexPath.item)
        let visMin = max(x, gridView.contentOffset.x)
        let visMax = min(x + w, gridView.contentOffset.x + gridView.bounds.width)
        focusAnchorX = visMax > visMin ? (visMin + visMax) / 2 : x + w / 2
    }

    /// Item in `section` whose horizontal span contains `x`, or the one
    /// nearest to it (rows can have gaps between programs).
    private func itemIndex(nearestToX x: CGFloat, inSection section: Int) -> Int {
        let row = rows[section]
        guard !row.programs.isEmpty else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 0..<row.programs.count {
            let (cx, cw) = epgProgramXWidth(section: section, item: i)
            if x >= cx && x < cx + cw { return i }
            let distance = x < cx ? cx - x : x - (cx + cw)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    // MARK: - Model observation

    private func startObserving() {
        withObservationTracking {
            _ = model.channels
            _ = model.programsByChannel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyModelChange()
                self.startObserving()
            }
        }
    }

    /// Track favorites separately: a toggle doesn't change rows, so skip row-diffing and just
    /// refresh the visible channel-column stars in place.
    private func observeFavorites() {
        withObservationTracking {
            _ = model.favoriteChannelIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshFavoriteStars()
                self.observeFavorites()
            }
        }
    }

    private func refreshFavoriteStars() {
        for indexPath in columnView.indexPathsForVisibleItems {
            guard indexPath.item < rows.count,
                  let cell = columnView.cellForItem(at: indexPath) as? EPGChannelCell else { continue }
            cell.setFavorite(model.isFavorite(rows[indexPath.item].channel.id))
        }
    }

    /// Track timer-state separately: a record toggle doesn't change rows, only each cell's red dot.
    private func observeTimerState() {
        withObservationTracking {
            _ = model.timerStateVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshTimerDots()
                self.observeTimerState()
            }
        }
    }

    private func refreshTimerDots() {
        for indexPath in gridView.indexPathsForVisibleItems {
            guard indexPath.section < rows.count,
                  let cell = gridView.cellForItem(at: indexPath) as? EPGProgramCollectionCell else { continue }
            let row = rows[indexPath.section]
            guard !row.programs.isEmpty, indexPath.item < row.programs.count else { continue }
            cell.setTimer(model.hasTimer(programID: row.programs[indexPath.item].id))
        }
    }

    private func applyModelChange() {
        let old = rows
        rebuildRows()
        let new = rows

        guard !old.isEmpty, isPrefix(old, of: new) else {
            gridView.reloadData()
            columnView.reloadData()
            return
        }

        var changed = IndexSet()
        for s in 0..<old.count where signature(old[s]) != signature(new[s]) {
            changed.insert(s)
        }
        let appended = new.count > old.count ? IndexSet(integersIn: old.count..<new.count) : IndexSet()
        guard !changed.isEmpty || !appended.isEmpty else { return }

        UIView.performWithoutAnimation {
            gridView.performBatchUpdates {
                if !changed.isEmpty { gridView.reloadSections(changed) }
                if !appended.isEmpty { gridView.insertSections(appended) }
            }
            if !appended.isEmpty {
                let items = appended.map { IndexPath(item: $0, section: 0) }
                columnView.insertItems(at: items)
            }
        }
    }

    private func rebuildRows() {
        rows = model.channels.map { channel in
            Row(channel: channel, programs: model.programsByChannel[channel.id] ?? [])
        }
    }

    private func isPrefix(_ old: [Row], of new: [Row]) -> Bool {
        guard new.count >= old.count else { return false }
        for i in 0..<old.count where old[i].channel.id != new[i].channel.id { return false }
        return true
    }

    private func signature(_ row: Row) -> String {
        "\(row.programs.count):\(row.programs.first?.id ?? "-"):\(row.programs.last?.id ?? "-")"
    }

    // MARK: - Program layout delegate

    func epgChannelCount() -> Int { rows.count }

    func epgProgramCount(section: Int) -> Int {
        rows[section].programs.isEmpty ? 1 : rows[section].programs.count
    }

    func epgProgramXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat) {
        let row = rows[section]
        if row.programs.isEmpty { return (0, gridLayout.totalWidth) }
        let program = row.programs[item]
        guard let start = program.startDate, let end = program.endDate else {
            return (0, gridLayout.totalWidth)
        }
        return (max(0, model.xOffset(for: start)), model.width(start: start, end: end))
    }

    // MARK: - Data source (grid + column share this VC)

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === gridView ? rows.count : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        collectionView === gridView ? epgProgramCount(section: section) : rows.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if collectionView === columnView {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: EPGChannelCell.reuseID, for: indexPath) as! EPGChannelCell
            let channel = rows[indexPath.item].channel
            cell.configure(name: channel.name, number: channel.channelNumber,
                           logoURL: logoURLProvider(channel), isFavorite: model.isFavorite(channel.id),
                           metrics: metrics)
            return cell
        }
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EPGProgramCollectionCell.reuseID, for: indexPath) as! EPGProgramCollectionCell
        let row = rows[indexPath.section]
        if row.programs.isEmpty {
            cell.configure(title: NSLocalizedString("livetv.noProgramInfo", comment: ""),
                           subtitle: nil, tint: tintColor, isOnNow: false, hasTimer: false)
        } else {
            let program = row.programs[indexPath.item]
            cell.configure(title: program.name, subtitle: timeRange(program),
                           tint: tintColor, isOnNow: isProgramOnNow(program),
                           hasTimer: model.hasTimer(programID: program.id))
        }
        return cell
    }

    // MARK: - Grid delegate (selection + lazy load)

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === gridView else { return }
        let row = rows[indexPath.section]
        let program = row.programs.isEmpty
            ? synthesizedProgram(for: row.channel)
            : row.programs[indexPath.item]
        onSelect(row.channel, program)
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard collectionView === gridView else { return }
        let section = indexPath.section
        let ids = (section..<min(section + 6, rows.count)).map { rows[$0].channel.id }
        Task { await model.ensurePrograms(for: ids) }
        if section >= rows.count - 3 {
            Task { await model.loadMoreChannels() }
        }
    }

    // MARK: - Helpers

    // One shared formatter; DateFormatter allocation/config is costly and this ran per program cell.
    // Main-thread only (cell config + tick layout), so no thread-safety concern.
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func timeRange(_ program: JellyfinProgram) -> String? {
        guard let start = program.startDate, let end = program.endDate else { return nil }
        let f = Self.shortTimeFormatter
        return "\(f.string(from: start)) - \(f.string(from: end))"
    }

    private func timeTicks() -> [(x: CGFloat, text: String)] {
        let f = Self.shortTimeFormatter
        return model.timeTicks.map { (model.xOffset(for: $0), f.string(from: $0)) }
    }

    private func synthesizedProgram(for channel: JellyfinChannel) -> JellyfinProgram {
        JellyfinProgram(
            id: "live-\(channel.id)", channelId: channel.id, channelName: channel.name,
            name: channel.name, overview: nil, startDate: Date().addingTimeInterval(-1),
            endDate: Date().addingTimeInterval(3600), genres: nil, imageTags: nil,
            isLive: true, isNews: nil, isMovie: nil, isSeries: nil,
            isKids: nil, isSports: nil, seriesName: nil, parentIndexNumber: nil,
            indexNumber: nil, episodeTitle: nil, timerId: nil, seriesTimerId: nil)
    }
}

// MARK: - SwiftUI bridge

struct EPGCollectionContainer: UIViewControllerRepresentable {
    let model: EPGGuideViewModel
    let tint: Color
    var isActive: Bool = true
    let logoURLProvider: (JellyfinChannel) -> URL?
    let onSelect: (JellyfinChannel, JellyfinProgram) -> Void

    func makeUIViewController(context: Context) -> EPGCollectionViewController {
        EPGCollectionViewController(
            model: model, tintColor: UIColor(tint),
            logoURLProvider: logoURLProvider, onSelect: onSelect)
    }

    func updateUIViewController(_ controller: EPGCollectionViewController, context: Context) {
        controller.tintColor = UIColor(tint)
        // isUserInteractionEnabled (not allowsHitTesting/opacity) removes a UIKit subtree from the
        // tvOS focus engine; without it the hidden guide stays focusable behind the recordings view.
        controller.view.isUserInteractionEnabled = isActive
    }
}
