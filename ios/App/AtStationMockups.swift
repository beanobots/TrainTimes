import SwiftUI

// Throwaway mockups: "At Station" for 15 s after a train's countdown reaches 0:00, in each place
// it could go. Delete once the real version is built.

private let marks = TimeMarks(marksLiveTimes: true, marksScheduledTimes: false, withoutColor: false)

/// A mock's title over a before/after pair.
private struct MockSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Today" or "With At Station" over a mock.
private func tag(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
}

// MARK: 1 · Go walk, Lock Screen

/// The walk banner's footer at the station: the train's countdown, or At Station.
private struct WalkBannerMock: View {
    let atStation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "stairs")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.walkBlue, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Here").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Down the stairs at the NE corner of 4 Av & 9 St")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    Text("Manhattan-bound").font(.caption).foregroundStyle(Color.boardGray)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.boardGray.opacity(0.4))
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    LineBullet(route: "R", size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            StatusMark(isLive: true, marks: marks, size: 12)
                            Text(atStation ? "At Station" : "0:00")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Color.liveGreen)
                        Text("Board near the front")
                            .font(.caption.weight(.medium)).foregroundStyle(Color.boardGray)
                    }
                }
                Spacer(minLength: 0)
                mockButtons(boarding: true)
            }
        }
        .padding(16)
        .background(Color.boardBlack, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// The compact Dynamic Island while walking: the turn, then the train's countdown or At Station.
private struct CompactIslandMock: View {
    let atStation: Bool

    var body: some View {
        HStack {
            Image(systemName: "stairs").font(.caption.weight(.bold)).foregroundStyle(Color.walkBlue)
            Text("Here").font(.caption.weight(.semibold))
            Spacer()
            LineBullet(route: "R", size: 16)
            Text(atStation ? "At Stn" : "Due").font(.caption.weight(.semibold)).foregroundStyle(Color.liveGreen)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: 250, height: 37)
        .background(.black, in: Capsule())
    }
}

// MARK: 2 · Plain Lock Screen countdown

/// The countdown started from a train's detail, not from Go.
private struct CountdownBannerMock: View {
    let atStation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LineBullet(route: "R", size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("4 Av-9 St").font(.headline).foregroundStyle(.white)
                    Text("Manhattan").font(.caption).foregroundStyle(Color.boardGray)
                }
                Spacer()
                mockButtons(boarding: false)
            }
            HStack(spacing: 6) {
                StatusMark(isLive: true, marks: marks, size: 18)
                Text(atStation ? "At Station" : "0:00")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.liveGreen)
            Text("8:22 AM · then 8 minutes, 15 minutes")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.boardGray)
            HStack {
                Spacer()
                Text("Updated 8:21 AM").font(.caption).foregroundStyle(Color.boardGray)
            }
        }
        .padding(16)
        .background(Color.boardBlack, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: 3 · Widgets

/// Medium Next train: the big countdown, its line and time, the next ones' minutes.
private struct NextTrainWidgetMock: View {
    let atStation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("4 Av-9 St").font(.subheadline.bold())
                Text("Manhattan").font(.caption).foregroundStyle(Color.boardGray)
                Spacer()
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(atStation ? "At Station" : "0:00")
                        .font(.system(size: atStation ? 36 : 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    StatusMark(isLive: true, marks: marks, size: 16)
                }
                .foregroundStyle(Color.liveText)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        LineBullet(route: "R", size: 18)
                        Text("8:22").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    Text("then 8 min, 15 min").font(.caption.weight(.semibold)).foregroundStyle(Color.boardGray)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
        }
        .foregroundStyle(Color.boardText)
        .padding(14)
        .frame(width: 338, height: 158)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// ↻ and the lit walk button; "I'm on the train" first on a walk at the station.
private func mockButtons(boarding: Bool) -> some View {
    HStack(spacing: 6) {
        if boarding {
            Image(systemName: "tram.fill").font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36).background(Color.white.opacity(0.15), in: Circle())
        }
        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold))
            .frame(width: 36, height: 36).background(Color.white.opacity(0.15), in: Circle())
        Image(systemName: "figure.walk").font(.system(size: 15, weight: .bold))
            .frame(width: 36, height: 36).background(Color.walkBlue, in: Circle())
    }
    .foregroundStyle(.white)
}

private struct AtStationMockups: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                MockSection(title: "1 · Go walk countdown",
                            note: "Walking to the train, at the station or at a change: Lock Screen, Dynamic Island and the walking screen") {
                    tag("Today")
                    WalkBannerMock(atStation: false)
                    tag("With At Station, 0–15 s after")
                    WalkBannerMock(atStation: true)
                    HStack(spacing: 12) {
                        CompactIslandMock(atStation: false)
                        CompactIslandMock(atStation: true)
                    }
                    .scaleEffect(0.8, anchor: .leading)
                }
                MockSection(title: "2 · Plain Lock Screen countdown",
                            note: "Started from a train's detail, not from Go") {
                    tag("Today")
                    CountdownBannerMock(atStation: false)
                    tag("With At Station, 0–15 s after")
                    CountdownBannerMock(atStation: true)
                }
                MockSection(title: "3 · Widgets",
                            note: "Next train, Transfers and Favorite Stop's big countdown; bus boards unchanged. Not with a walking time, which counts to leaving") {
                    tag("Today")
                    NextTrainWidgetMock(atStation: false)
                    tag("With At Station, 0–15 s after")
                    NextTrainWidgetMock(atStation: true)
                }
            }
            .padding()
        }
    }
}

#Preview("At Station mockups") {
    AtStationMockups()
}
