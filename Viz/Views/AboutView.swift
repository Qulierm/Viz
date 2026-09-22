import SwiftUI
import AlinFoundation

struct AboutView: View {

    var body: some View {

        VStack(spacing: 0) {

            // No icon or app-name block: the About window keeps only the version, the
            // repository link and the attribution, centred in the window.
            Spacer()

            VStack(spacing: 0) {
                Text("Version \(Bundle.main.version) (Build \(Bundle.main.buildVersion))")
                    .padding(.vertical, 4)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/alienator88/Viz")!)
                } label: {
                    Label("GitHub", systemImage: "paperplane")
                        .padding(5)
                }
                .vizGlassButton(prominent: true, tint: VizTheme.link)
            }
            .padding()
            .vizGlassSurface(cornerRadius: VizTheme.cornerLarge, tint: VizTheme.cardTint)


            Spacer()

            HStack(spacing: 0){
                Spacer()
                Text("Made with ❤️ by ")
                Text("Alin Lupascu")
                    .bold()
                Spacer()
            }
            .padding()

        }
//        .ignoresSafeArea(edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vizGlassSurface(cornerRadius: 0, tint: VizTheme.surfaceTint)

    }
}
