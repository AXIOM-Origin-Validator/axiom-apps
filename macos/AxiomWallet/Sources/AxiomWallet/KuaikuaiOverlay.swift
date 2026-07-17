// 乖乖 (椰子口味) — decorative inert easter egg.
//
// GENERATED FILE. Do not hand-edit the kuaikuaiArt raw string below;
// it is regenerated from the single source of truth at
// `denomination/assets/kuaikuai.txt` by `scripts/sync_kuaikuai_swift.sh`.
// CI runs that script with `--check` and fails on byte drift.
//
// The art lives once in the workspace and is carried into every
// produced artifact by `axiom-denomination` (see README "Easter egg").
// For the Mac apps the art is compiled into the .app binary via this
// Swift raw string; if you don't see it after a rebuild, the sync
// script never ran or the .swift edit was undone.
//
// Wire it up by attaching `.kuaikuaiTapTarget()` to the version /
// build-info Text in About / Settings. Tap 7× within 2 s to
// trigger the overlay. Dismiss is click-anywhere on the overlay.
// NEVER add a button labeled "open" / "打開". NEVER change the
// flavor away from 椰子. See README "Easter egg".

import SwiftUI

private let kuaikuaiArt: String = #"""
                               `-+syhddmmmddhyo+:`
                            .+hmmdddddddddddddddmmds/`      ``...`
                         `/hmddddddddddddddddddddddddmy++osyhyyyhhs.
                       `ommddddddddddddddddddddddddddddmmdys+++syhhh:
           .`         /mmddddddddddddddddddddddddddddddddmmhyyyyyyyyh/
       `:sdNy`      .ymddddddddddddddddddddddddddddddddddddmdhhhyyyyyh-
   `.+hmmmddmo     -mmddddddddddddddddddddddddddddddddddddddmmhhhhhhhh+
  odmmdddddddms` `+mmddddddddddddddddddddddddddddddddddddddddmmddhhhhh+
  ymdmmmmmmmmdmmdmmdddddddddddddmmddddddddddddddddddddddddddddmd:ydhhd:
  :Nmmmmmmmmmmmmmmddy+::+ydddms/:::/+osydmdddddddddddddddddddddN-`:+o:
   ymmmmmmmmmmmmmmdo.`.``/hmm/+hdd/``````-+ydmdddddddddddddddddmy
   .mmmmmmmmmmmmmmh:`-o+`:hm/`-o:.```````os/./ymddddddddddddddddN`
    /Nmmmmmmmmmmmmh:..::-od/``dMs````````/hNm:`-ymddddddddddddddN-
     sNmmmmmmmmmmmd+-:/-.`..`.hh:`...``:hh..:```:NdmmmmmmmdmddddN/
  `::/dmmmmmmmmmmmmdo:```./d/````-..:`-mdd.````.dmdmmmmmmmmmmmdmmy
./::-..+dmmmmmmmmmmh/````-dNms-```..``.+/`````-dmds/:-:ohmmmmmmmmN.
-/.``--`/dmmmdysydmy.````omNd+.-::-...-:os:..`-hs-``.``./hmmmmmmmmd.       .os`
/:---.`.`-/sy:```omy-````hddo` `s.``/NNNNo...`````-+o/``/dmmmmmmmmmms:..:+ymmN:
:/.``.``````-``./dNh/````syyyhshd-``:mNmy.````````.```./hmmmmmmmmmmmmmmmmmmmmmd
 .::-```...````+dNNNs-```//::/+ooosyhdds.``````-----:+ydmmmmmmmmmmmmmmmmmmmmmmN:
   `:/````..``-shhdmms-``./::/:::::::+/``````.+dmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmd
     ./:-```.-oyyhyhhhy+.`.:/::::///:.````..:ymNNmmo:/ymmmmmmmmmmmmmmmmmmmmmmmmN
       `:y:./yyyyyyyyhh///:..--:--.````..-/ymNNNNNy.``-hNNNNNmmmmmmmmmmmmmmNmh+-
       `ymdyhyyyyyyhhy/---o+///:::::://oyhmNNNNNNNo```:osyho/---:ymmNNNNmho:`
       `+hhhhhyyyyhhs-----y--o/------:+hhhhhhhddds.````````..-..-+dNds+-`
         `.:+oossyyyy:---:ssoy:------+hyyyyhhyyys-``....```..--..//`
                    syysyysssho:-----ohyyyyhyhhyy/`````..``````-o.
                   `hssssssoyhhyo+++syyhhhhyyhyyh+:::-..-:::::::.
                   :hysssyo/yhhssyysssssyhyhhhyhdmmy....`
                   shyyyyyyhhhhyyyyyyyyyyhh/-+syhdo`
                  `hhhhhhhhhhhhhhhhhhhhhhhhy`
                   -:yhyyyysyhhyyyyyyyyyyyyh-
                     -hysssssyydsyyssssssssyh.
                      /hsysyyyyd-.+yyyssyyssyh-
          -/+oo++/-`   +hhyhhhso`  .ohyyyyyyhho:`   `-:/++++/:.
       -+ooooooooooso+/ssss.yy:      `//+ds/oysss+ossoooooooo+os/.
    `:o+:/oooooooooooooooossyh:          oyyssooooooooooooooo+/:os+`
   -ssoooooooooooooooooosssssy+          .hyssssssooooooooooooooooss-
   /syysssssssssssssssyyyyyyyh-           shyyyysyyysssssssssssssssyy
     `-/+ossyyyysso+/:-./++//.             .---` `.-:/+oossssoo++/:-`
"""#

/// Tap-counter modifier. Attach with `.kuaikuaiTapTarget()` to any
/// `Text` (or other view) and the user gets the egg after 7 taps
/// within 2 s. Caller is responsible for binding the resulting
/// `@State` to a `.sheet` / fullScreenCover.
struct KuaikuaiTapTarget: ViewModifier {
    @Binding var showOverlay: Bool
    @State private var taps: Int = 0
    @State private var lastTap: Date = Date(timeIntervalSince1970: 0)

    func body(content: Content) -> some View {
        // Two-part fix for SwiftUI gesture composition on macOS:
        //
        //  (1) `.contentShape(Rectangle())` makes the entire frame
        //      hit-testable. Without it, an `HStack { Text; Spacer;
        //      Text }` host (the AxiomWallet "App version" row) only
        //      registers taps on the Text bounding boxes — the
        //      Spacer area in the middle is transparent to hits.
        //
        //  (2) `simultaneousGesture(TapGesture()...)` instead of
        //      `onTapGesture` so the counter survives subviews that
        //      already claim tap events — most notably
        //      `Text(...).textSelection(.enabled)`, which on macOS
        //      focuses for selection on click and swallows outer
        //      onTapGesture calls. The AxiomWallet version row uses
        //      textSelection so users can copy the version string;
        //      that broke the 7-tap trigger before this commit.
        //
        // UNCLE SAM and AxiomKiddo hosts are plain Texts without
        // textSelection, so they were unaffected by (2) — but (1)
        // still helps if anyone later wraps their tap host in an
        // HStack with a Spacer.
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                let now = Date()
                if now.timeIntervalSince(lastTap) > 2.0 { taps = 0 }
                lastTap = now
                taps += 1
                if taps >= 7 {
                    taps = 0
                    showOverlay = true
                }
            })
    }
}

extension View {
    /// Convenience: `.kuaikuaiTapTarget(presenting: $showKuaikuai)`.
    /// Pure view-layer. Nothing persists.
    func kuaikuaiTapTarget(presenting binding: Binding<Bool>) -> some View {
        modifier(KuaikuaiTapTarget(showOverlay: binding))
    }
}

/// Full-screen overlay. Dismiss is `.onTapGesture` on the whole
/// view — click anywhere. No buttons. Nothing labeled "open" / "打開".
struct KuaikuaiOverlay: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                ScrollView([.horizontal, .vertical]) {
                    Text(kuaikuaiArt)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 0.5))
                        .lineSpacing(0)
                        .padding(16)
                }
                VStack(spacing: 6) {
                    Text("乖乖 (椰子口味) · this app is well-behaved")
                    Text("本機乖乖聽話 — 請勿打開，請勿食用")
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(red: 0.63, green: 1.0, blue: 0.63))
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
    }
}
