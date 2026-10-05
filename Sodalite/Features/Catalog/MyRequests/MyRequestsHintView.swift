import SwiftUI

/// What changed on the user's own requests since they last looked.
struct MyRequestsHintView: View {
    let events: [MyRequestEvent]
    let onWatch: (String) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("catalog.notify.mine.panel.title")
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(events) { event in
                        row(event)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            Button(action: onDone) {
                Text("catalog.notify.mine.panel.done")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(48)
        .frame(maxWidth: 900)
    }

    private func row(_ event: MyRequestEvent) -> some View {
        HStack(spacing: 24) {
            AsyncImage(url: SeerrImageURL.poster(path: event.posterPath, size: .w342)) { image in
                image.resizable().aspectRatio(2 / 3, contentMode: .fill)
            } placeholder: {
                Color.Theme.restFill
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.Theme.hairline))

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title ?? "")
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.statusText)
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(event.kind == .available ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            if event.kind == .available, let itemID = event.jellyfinItemID {
                Button {
                    onWatch(itemID)
                } label: {
                    Text("catalog.notify.mine.panel.watch")
                        .fixedSize()
                }
            }
        }
    }
}
