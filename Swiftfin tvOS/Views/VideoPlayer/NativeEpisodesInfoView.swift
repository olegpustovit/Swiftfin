//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

/// The "Episodes" tab of the system info panel shown by `NativePlayerViewController`.
struct NativeEpisodesInfoView: View {

    let mediaSession: MediaSession

    @FocusState
    private var focusedID: ItemEntry.ID?

    private var queue: any MediaPlayerQueue? {
        mediaSession.queue
    }

    @ContentBuilder
    var body: some View {
        if let queue {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(queue.items) { entry in
                            EpisodeButton(
                                entry: entry,
                                isCurrent: entry.id == queue.currentEntryID
                            ) {
                                guard entry.id != queue.currentEntryID else { return }

                                queue.select(entry)
                            }
                            .focused($focusedID, equals: entry.id)
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .onAppear {
                    if let current = queue.currentEntryID {
                        proxy.scrollTo(current, anchor: .center)
                        focusedID = current
                    }
                }
            }
            .focusSection()
        }
    }

    private struct EpisodeButton: View {

        let entry: ItemEntry
        let isCurrent: Bool
        let action: () -> Void

        private var item: BaseItemDto {
            entry.snapshot
        }

        private var imageSource: ImageSource? {
            let options = ImageSourceOptions(maxWidth: 420)

            return item.imageSource(.primary, itemID: item.id, environment: options)
                ?? item.imageSource(.thumb, itemID: item.id, environment: options)
        }

        @ContentBuilder
        var body: some View {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    Color.secondary.opacity(0.3)

                    ImageView(imageSource)
                        .aspectRatio(contentMode: .fill)

                    if isCurrent {
                        Label(L10n.nowPlaying, systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(12)
                    }
                }
                .frame(width: 400, height: 225)
                .clipped()
            }
            .buttonStyle(.card)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.episodeLocator ?? item.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(item.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .frame(width: 400, alignment: .leading)
                .offset(y: 245)
            }
            .padding(.bottom, 80)
        }
    }
}
