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
