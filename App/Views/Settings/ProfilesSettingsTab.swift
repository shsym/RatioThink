import SwiftUI
import AppKit

/// *Settings → Profiles* — list of `<PIE_HOME>/profiles/*.toml` with a
/// per-profile editor. The detail pane lets users edit the default model,
/// system prompt, and user-facing sampling defaults without exposing the
/// empty Advanced/inferlet-args inspection surface.
struct ProfilesSettingsTab: View {
  @EnvironmentObject private var profileStore: ProfileStore
  @State private var entries: [ProfileLoadResult] = []
  @State private var directoryError: String?
  @State private var selectionURL: URL?

  var body: some View {
    HSplitView {
      list
        .frame(minWidth: 220, maxWidth: 280)
      detail
        .frame(minWidth: 320, maxWidth: .infinity)
    }
    .task { await refresh() }
  }

  // MARK: - List

  private var list: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SettingsSectionHeader(title: "Profiles")
        Spacer()
        Button {
          revealProfilesDirInFinder()
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Reveal profiles directory in Finder")
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      if let directoryError {
        Text(directoryError)
          .foregroundStyle(.red)
          .padding(12)
      }

      // #702: a broken customization of a built-in was reverted to the app
      // default on launch (the broken file saved as `.bak`). Non-fatal, so it
      // renders as an informational notice rather than the red error block.
      ForEach(profileStore.lastBuiltinRevertNotices, id: \.profileID) { notice in
        Label(
          "\(notice.profileName) couldn’t be read — reverted to the app default; your file was saved as \(notice.bakFilename).",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .fixedSize(horizontal: false, vertical: true)
      }

      if entries.isEmpty && directoryError == nil {
        VStack {
          Spacer()
          Text("No profiles yet.")
            .foregroundStyle(.secondary)
          Spacer()
        }
      } else {
        List(selection: $selectionURL) {
          ForEach(entries, id: \.url) { entry in
            ProfileListRow(entry: entry)
              .tag(Optional(entry.url))
          }
        }
        .listStyle(.sidebar)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Detail

  private var detail: some View {
    Group {
      if let url = selectionURL,
         let entry = entries.first(where: { $0.url == url }) {
        ProfileEditor(entry: entry, onModelChanged: { Task { await refresh() } })
      } else {
        VStack(spacing: 6) {
          Spacer()
          Image(systemName: "person.crop.rectangle")
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
          Text("Select a profile")
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - Side effects

  @MainActor
  private func refresh() async {
    do {
      let dir = try PieDirs.profiles()
      // Use the shared `ProfileStore.effectiveScan` rather than
      // re-implementing the TOML enumeration here (review v2 F9). #702:
      // `effectiveScan` overlays the immutable in-code base layer on the
      // user files, so the four built-ins always render here even when no
      // file exists on disk for them.
      let (loaded, scanErr) = ProfileStore.effectiveScan(directory: dir)
      entries = loaded
      directoryError = scanErr.map(String.init(describing:))
      if selectionURL == nil { selectionURL = entries.first?.url }
    } catch {
      directoryError = String(describing: error)
      entries = []
    }
  }

  /// Routes the resolve failure through `directoryError` so it
  /// surfaces in the existing red-text block instead of silently
  /// no-op'ing (review v2 F7).
  private func revealProfilesDirInFinder() {
    do {
      let dir = try PieDirs.profiles()
      NSWorkspace.shared.activateFileViewerSelecting([dir])
    } catch {
      directoryError = "Reveal profiles directory failed: \(error)"
    }
  }
}

// MARK: - List row

private struct ProfileListRow: View {
  let entry: ProfileLoadResult

  var body: some View {
    HStack(spacing: 6) {
      if !entry.isValid {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(entry.error?.description ?? "")
      } else if !entry.warnings.isEmpty {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help(entry.warnings.map(\.description).joined(separator: "\n"))
      }
      VStack(alignment: .leading) {
        Text(displayName)
          .lineLimit(1)
        if let p = entry.profile {
          Text(p.id)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var displayName: String {
    entry.profile?.name ?? entry.url.deletingPathExtension().lastPathComponent
  }
}
