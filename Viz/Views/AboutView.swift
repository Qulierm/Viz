import SwiftUI
import AlinFoundation

struct AboutView: View {

    var body: some View {

        VStack(spacing: 0) {

            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .padding()

            Text(Bundle.main.name)
                .font(.title)
                .bold()
                .foregroundStyle(
                    LinearGradient(
                        colors: [VizTheme.accent, VizTheme.accentBright],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            VStack(spacing: 0) {
                Text("Version \(Bundle.main.version) (Build \(Bundle.main.buildVersion))")
                    .padding(.vertical, 4)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/alienator88/Viz")!)
                } label: {
                    Label("GitHub", systemImage: "paperplane")
                        .padding(5)
                }
                .vizGlassButton(prominent: true)
            }
            .padding()
            .vizGlassSurface(cornerRadius: VizTheme.cornerLarge)


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

    }
}
