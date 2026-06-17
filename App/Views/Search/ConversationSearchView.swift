import SwiftUI
import SwiftData

/// Detail-column search panel (col 3) for the `.search` sidebar section.
///
/// Empty state: the search bar sits centered. On the first non-empty query it
/// animates up to the top and a boxed list of matched conversations renders
/// below it, with the query highlighted in titles and snippets. Selecting a
/// result routes back to the Chats section and opens that chat.
///
/// Search runs a naive per-keystroke scan (`ConversationSearch`) over the
/// `@Query`-loaded chats — title + message body. A dedicated body index is
/// out of scope here.
///
/// Layout note: the view tree is kept structurally STABLE across the
/// empty→searching transition — the centering is driven by an animated top
/// inset, not by inserting/removing `Spacer`s. Toggling the tree shape under
/// animation was observed to blow up the macOS hosting view and leave the
/// window's accessibility tree disabled (the #511 family of hosting bugs).
struct ConversationSearchView: View {
  @EnvironmentObject private var windowState: WindowState
  @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
  @State private var query: String = ""

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool { !trimmedQuery.isEmpty }

  private var results: [ConversationSearchResult] {
    ConversationSearch.results(in: chats, query: query)
  }

  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 16) {
        // Animated centering: a clear strut whose height interpolates between
        // ~a third of the column (centered empty state) and 0 (bar at top).
        Color.clear
          .frame(height: isSearching ? 0 : max(0, geo.size.height * 0.30))
        searchField
        content
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(24)
      .animation(.easeInOut(duration: 0.25), value: isSearching)
    }
  }

  /// Stable slot below the field: prompt → empty-results → results list. Only
  /// the leaf content swaps; the surrounding tree is unchanged.
  @ViewBuilder
  private var content: some View {
    if !isSearching {
      Text("Search your conversations")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if results.isEmpty {
      Text("No conversations match “\(trimmedQuery)”.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("search.noResults")
    } else {
      ScrollView {
        VStack(spacing: 10) {
          ForEach(results) { result in
            resultCard(result)
          }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier("search.results")
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search conversations", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .accessibilityIdentifier("search.field")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.25))
        )
    )
    .frame(maxWidth: 520)
  }

  private func resultCard(_ result: ConversationSearchResult) -> some View {
    Button {
      windowState.selectedSection = .chats
      windowState.selectedItemID = result.id
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(highlighted(result.title))
          .font(.headline)
          .lineLimit(1)
        if let snippet = result.snippet {
          Text(highlighted(snippet))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(Color.secondary.opacity(0.2))
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Highlight each case-insensitive occurrence of the current query inside
  /// `text` with a soft accent wash — the "finding-style" emphasis.
  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    let needle = trimmedQuery
    guard !needle.isEmpty else { return attributed }

    var searchStart = text.startIndex
    while let match = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex) {
      if let lower = AttributedString.Index(match.lowerBound, within: attributed),
         let upper = AttributedString.Index(match.upperBound, within: attributed) {
        attributed[lower..<upper].backgroundColor = Color.accentColor.opacity(0.30)
        attributed[lower..<upper].foregroundColor = .primary
      }
      if match.upperBound == text.endIndex { break }
      searchStart = match.upperBound
    }
    return attributed
  }
}
