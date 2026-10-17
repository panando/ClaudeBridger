import SwiftUI
import ClaudeBridgerCore

/// Shared spacing, radii and colours.
///
/// A settings app is mostly chrome, and the fastest way for it to look unfinished is for every
/// view to invent its own numbers. These are the only ones.
public enum Tokens {
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 18
    public static let spacingXL: CGFloat = 28

    public static let radiusS: CGFloat = 6
    public static let radiusM: CGFloat = 9
    public static let radiusL: CGFloat = 13

    public static let sidebarWidth: CGFloat = 230
    public static let detailMinWidth: CGFloat = 520
    public static let windowMinWidth: CGFloat = 860
    public static let windowMinHeight: CGFloat = 600

    public static let fieldWidth: CGFloat = 260
    public static let labelWidth: CGFloat = 116

    public static let noticeAutoDismissSeconds: Double = 6
}

/// A titled group of form rows, used for every section so they cannot drift apart.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusL, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusL, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

/// One label / control pair, with the label column a fixed width so rows line up.
struct FormRow<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spacingM) {
            HStack(spacing: Tokens.spacingXS) {
                Text(label)
                if let help {
                    InfoPopover(text: help)
                }
            }
            .frame(width: Tokens.labelWidth, alignment: .leading)
            .foregroundStyle(.primary)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// The small ⓘ that explains a field. Text only; no affordance that suggests an action.
struct InfoPopover: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
    }
}

/// Lets a host view start disclosure sections open.
///
/// Only the initial value is affected, so clicking still behaves exactly as before. It exists so
/// SwiftUI previews and the offscreen screenshot renderer can show what a section holds without
/// anyone clicking it.
private struct DisclosureInitiallyExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Public so the screenshot renderer can open every section at once.
    public var disclosureInitiallyExpanded: Bool {
        get { self[DisclosureInitiallyExpandedKey.self] }
        set { self[DisclosureInitiallyExpandedKey.self] = newValue }
    }
}

/// A section that starts collapsed and can be opened.
///
/// Used for the option groups most people never touch: thirteen behaviour flags and five limits
/// would otherwise push the two fields that matter — endpoint and credential — off the first
/// screen. Collapsed by default because the common case is to not open them.
struct DisclosureSection<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Shown next to the title so a collapsed section still says whether it holds anything;
    /// without it, collapsed reads as empty.
    var badge: String?
    @Environment(\.disclosureInitiallyExpanded) private var environmentExpanded
    @State private var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        badge: String? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingM) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Tokens.spacingS) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.headline)
                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, Tokens.spacingS)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let subtitle, isExpanded {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded {
                content()
            }
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusL, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusL, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
        .onAppear {
            if environmentExpanded { isExpanded = true }
        }
    }
}

/// The chip shown beside an option whose key is not in the official documentation.
struct ProvenanceBadge: View {
    let provenance: OptionProvenance

    var body: some View {
        if !provenance.isOfficial {
            Text(provenance.shortLabel)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Tokens.spacingXS + 2)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
                .help(provenance.explanation)
        }
    }
}

/// One behaviour flag, with its provenance and any caveat.
struct FlagToggleRow: View {
    let flag: EnvironmentFlag
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingS) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.spacingXS) {
                    Text(flag.displayName)
                    ProvenanceBadge(provenance: flag.provenance)
                }
                Text(flag.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat = flag.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A notice bar. Reads as one line in the common case and grows only when there is more to say.
struct NoticeBar: View {
    let notice: AppModel.Notice
    let onDismiss: () -> Void

    private var tint: Color {
        switch notice.kind {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingS) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                Text(notice.title)
                    .fontWeight(.medium)
                ForEach(notice.details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Tokens.spacingS)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(Tokens.spacingM)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusM, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusM, style: .continuous)
                .strokeBorder(tint.opacity(0.35))
        )
    }
}
