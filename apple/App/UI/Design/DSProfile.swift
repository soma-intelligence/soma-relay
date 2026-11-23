import SwiftUI

// Pieces shared by the contact screens (relay-screens 07 to 11): profile header, quick actions,
// safety words, glass segment and round glass buttons.

/// Round 44 pt Liquid Glass button of the floating top bar (close, back, edit, torch).
struct DSRoundGlassButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.label)
                .frame(width: DS.roundButton, height: DS.roundButton)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

/// Profile header of the contact sheet and the group info: 96 pt avatar, name 28 bold, one status
/// line (seal or lock glyph, 15 medium secondary).
struct DSProfileHeader<AvatarView: View>: View {
    let name: String
    var statusIcon: String?
    var statusIconTint: Color = DS.accent
    let status: String
    @ViewBuilder var avatar: AvatarView

    var body: some View {
        VStack(spacing: 0) {
            avatar.padding(.bottom, 12)
            Text(name)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(DS.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 5) {
                if let statusIcon {
                    Image(systemName: statusIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(statusIconTint)
                }
                Text(status)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(DS.label2)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Quick action tile under a profile header: 64 pt, 20 pt corners, `cell` fill, icon over label.
/// `accent` paints the icon lime (Écrire, Appeler, Vidéo, Ajouter, Rechercher).
struct DSQuickActionLabel: View {
    let systemName: String
    let title: String
    var accent = true

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 19))
                .foregroundStyle(accent ? DS.accent : DS.label)
                .frame(height: 22)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(DS.cell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A quick action as a plain button.
struct DSQuickAction: View {
    let systemName: String
    let title: String
    var accent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DSQuickActionLabel(systemName: systemName, title: title, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The four safety words, numbered, in a 2 x 2 grid of 50 pt tiles.
struct DSWordGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.label3)
                        .frame(width: 10)
                    Text(word)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DS.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(DS.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mots de sécurité : " + words.joined(separator: ", "))
    }
}

/// Lime "Identiques" badge (the words were compared and match).
struct DSMatchBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            Text("Identiques")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.accent)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(DS.accentSoft, in: Capsule())
    }
}

/// Glass segmented control of the card screen ("Ma carte" / "Scanner"): 236 x 40, the selected
/// half on a light fill.
struct DSGlassSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button {
                    Haptics.select()
                    withAnimation(.snappy(duration: 0.25)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? DS.label : DS.label2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if on {
                                Capsule().fill(Color.white.opacity(0.15)).matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .frame(width: 236, height: 40)
        .glassEffect(.regular, in: Capsule())
    }
}
