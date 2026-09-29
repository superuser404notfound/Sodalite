import SwiftUI

/// Where a channel press is headed (Sodalite#173). Number and name only; the programme line comes from
/// the channel list's current programme when the server sent one and it is still on air.
struct LiveZapBannerView: View {
    let banner: LiveZapBanner

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: banner.direction >= 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 22, weight: .bold))
            if let channel = banner.channel {
                if let number = channel.channelNumber {
                    Text(number)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 26, weight: .semibold))
                    if let current = channel.currentProgram, current.isAiring(at: Date()) {
                        Text(current.name)
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.Theme.scrim, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.Theme.panelEdge))
    }
}
