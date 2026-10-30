import SwiftUI
import AppKit

typealias ViewState<Value> = SwiftUI.State<Value>

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct PanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 25))
        } else {
            content.background(GlassBackdrop()).clipShape(RoundedRectangle(cornerRadius: 25))
        }
    }
}

/// The whole application is here: a session button, the lid switch and a cutoff.
struct MokaPanel: View {
    @ObservedObject var model: AppModel
    var quit: () -> Void
    var panelHeight: CGFloat = 470
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Moka").font(.system(size: 20, weight: .semibold)).tracking(-0.6)
                Spacer()
                Button(action: quit) {
                    Image(systemName: "power").font(.system(size: 14)).frame(width: 28, height: 28)
                }.buttonStyle(QuietButton()).foregroundStyle(.secondary)
                    .help("Quitter Moka").accessibilityLabel("Quitter Moka")
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 5) {
                        RobotAvatar(awake: model.awake, size: 68, isVisible: model.panelVisible)
                        Text(model.awake ? "Votre Mac reste éveillé" : "Moka est arrêté")
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.7)
                        Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            // Reserve two lines in every state so the session
                            // button never moves underneath the user's pointer.
                            .frame(height: 34, alignment: .top)
                    }.frame(maxWidth: .infinity).padding(.bottom, 17)
                    sessionButton.padding(.bottom, 14)
                    if model.lid.isSupported { lidSwitch }
                    divider.padding(.top, 3).padding(.bottom, 15)
                    batteryCutoff
                    if let notice = model.notice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    }
                    if let error = model.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 14)
            }
            HStack {
                Image(systemName: model.power.onBattery ? "battery.100percent" : "powerplug")
                    .font(.system(size: 10))
                Text(model.powerLabel).font(.system(size: 10))
                Spacer()
            }.foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
                .overlay(alignment: .top) { divider }
        }.frame(width: 360, height: panelHeight)
            .modifier(PanelGlass()).foregroundStyle(.primary).tint(.primary)
    }
    private var divider: some View { Rectangle().fill(Color.primary.opacity(0.065)).frame(height: 0.5) }
    private var explanation: String {
        if model.awake {
            return model.lid.active
                ? "Vos tâches continuent, même écran éteint et capot fermé."
                : "L’écran peut s’éteindre. Votre Mac continue de travailler."
        }
        if model.lid.unmanagedSleepDisabled {
            return "Un réglage système bloque encore la veille, même sans Moka."
        }
        return "Votre Mac se met en veille comme d’habitude."
    }
    private var sessionButton: some View {
        Button { model.toggle() } label: {
            HStack(spacing: 12) {
                Text(model.enabled ? "Arrêter la session" : "Garder le Mac éveillé")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: model.enabled ? nil : .infinity)
                if model.enabled {
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 11)).opacity(0.65)
                        Text(model.sessionClock).font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit().transaction { $0.animation = nil }
                    }.padding(.vertical, 5).padding(.horizontal, 8)
                        .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.12), in: Capsule())
                }
            }.padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 42)
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .background(colorScheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(QuietButton()).keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel(model.enabled ? "Arrêter la session" : "Garder le Mac éveillé")
            .accessibilityValue(model.enabled ? "Temps écoulé : \(model.sessionClock)" : "")
            .help(model.enabled ? "Temps écoulé : \(model.sessionClock). Cliquer pour arrêter." : "Empêcher la veille du Mac tout en laissant l’écran s’éteindre.")
    }
    private var lidSwitch: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                OptionGlyph(symbol: .lid)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aussi capot fermé").font(.system(size: 12))
                    Text(model.lid.active ? "Actif · sur une table, jamais dans un sac."
                        : model.awake ? "Pour continuer en refermant le Mac."
                        : "Disponible pendant une session.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.lid.pending || model.lid.stopping { ProgressView().controlSize(.mini).frame(width: 38) }
                else {
                    Toggle("Aussi capot fermé", isOn: Binding(get: { model.lid.active }, set: { value in
                        if value { model.lid.start(reserve: model.reserve) } else { model.lid.stop() }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.regular).tint(.green).disabled(!model.awake)
                }
            }.frame(minHeight: 52)
            .help("Installation autorisée une fois, puis activation sans mot de passe. Maximum 4 heures. Le Mac doit rester ventilé ; ne l’utilisez pas dans un sac fermé.")
            if let message = lidMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(model.lid.message == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            }
        }
    }
    private var lidMessage: String? {
        if model.lid.pending { return "Préparation du service Moka… Une autorisation est nécessaire à la première utilisation." }
        if model.lid.stopping { return "Restauration du réglage de veille…" }
        if model.lid.active { return nil }
        return model.lid.message
    }
    private var batteryCutoff: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                OptionGlyph(symbol: .battery)
                Text("Seuil de batterie").font(.system(size: 12))
                Spacer()
                Text("\(model.reserve) %").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            Slider(value: Binding(get: { Double(model.reserve) }, set: { model.reserve = Int($0) }), in: 5...50, step: 5)
                .accessibilityLabel("Seuil d’arrêt sur batterie").accessibilityValue("\(model.reserve) pour cent")
            Text("Moka s’arrête à \(model.reserve) % ou moins. Sur secteur, la session continue.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
