"""Generate mcl-distributor's three C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: mcl-distributor and who it deals with
  c4-containers.svg  Level 2: the service on its box
  c4-components.svg  Level 3: inside the service

Colours are plain classes with a prefers-color-scheme: dark block, no CSS
custom properties (rsvg-convert renders those black), so the SVGs render the
same on GitHub, in IDE previews and through rsvg-convert. After a change,
render each (rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and
look at it; keep architecture/README.md in step. The drawing code is
mcl-jobs' (architecture/c4_diagrams.py there).
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component"), ("b-later", "Planned, not built")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-distributor system context", 1000, 560)
    d.box("b-per", 40, 30, 270, 96, "Org operator", "[Person]",
          ["Runs the distributor for the org;", "removes a member by adding its node id"], person=True)
    d.box("b-ext", 690, 30, 270, 96, "Group members", "[macula_group_keyring]",
          ["Pull the group's epochs at join", "and in every rotation's ahead window"])
    d.box("b-sys", 365, 190, 270, 120, "mcl-distributor", "[mcl_om mesh service]",
          ["Answers <org>/group_keys_v1 over", "sealed calls; epoch keys in memory", "only; not in the data path"])
    d.box("b-mac", 40, 190, 270, 120, "macula-realm", "[Macula infrastructure]",
          ["Admits the service; its member", "endorsements are what membership", "is read from"])
    d.box("b-ext", 690, 190, 270, 120, "Publishers, subscribers", "[Other mesh nodes]",
          ["Seal and open the group's events", "under the epochs; the distributor", "never sees that traffic"])
    d.box("b-mac", 365, 400, 270, 110, "Macula mesh", "[Macula infrastructure]",
          ["Stations carry the sealed pulls", "and the DHT records membership", "is read from"])
    d.edge("M175 126V160H420V190"); d.text("t-rel", 300, 152, "removes members", anchor="middle")
    d.edge("M825 126V160H580V190"); d.text("t-rel", 720, 152, "sealed pulls, org UCAN", anchor="middle")
    d.edge("M365 250H310"); d.text("t-rel", 337, 240, "boot", anchor="middle"); d.text("t-rel", 337, 272, "claim", anchor="middle")
    d.edge("M500 310V400"); d.text("t-rel", 508, 360, "advertises, reads membership")
    d.edge("M825 310V455H635"); d.text("t-rel", 833, 380, "publish, subscribe sealed")
    d.legend(530, boundary=False)
    d.write()


def containers():
    d = Diagram("c4-containers.svg", "mcl-distributor containers", 1000, 520)
    d.bound(24, 40, 620, 420, "A fleet box [docker, reconciled from the fleet repository]")
    d.box("b-sys", 44, 76, 580, 120, "mcl-distributor service", "[mcl_om mesh service, OCI image, OTP 28 release]",
          ["Boots as an mcl_om service: identity key, realm admission, a mesh pool, /health.",
           "Advertises group_keys_v1 sealed-only once the org key id is known.",
           "No Erlang distribution listener, cookie or epmd; writes no crash dump."])
    d.box("b-cmp", 44, 220, 280, 112, "Identity key", "[Named volume]",
          ["/etc/mcl/secrets: the node's key, the", "provider id members pin it by"])
    d.box("b-cmp", 344, 220, 280, 112, "Removed set", "[Named volume]",
          ["/var/lib/mcl-distributor/removed_members:", "one node id per line, read at every", "pull, kept across restarts"])
    d.box("b-cmp", 44, 352, 580, 84, "/health", "[Unix socket /run/mcl/health.sock]",
          ["The container healthcheck; internal to the box, not on the mesh."])
    d.box("b-mac", 690, 76, 286, 96, "Macula mesh", "[Macula infrastructure]",
          ["Entry: pinned stations (QUIC)"])
    d.box("b-mac", 690, 190, 286, 88, "macula-realm", "[Macula infrastructure]",
          ["Admission; trust anchor"])
    d.box("b-ext", 690, 300, 286, 96, "ghcr.io", "[External system]",
          ["The signed image, pinned by digest", "in the fleet repository"])
    d.edge("M624 124H690"); d.text("t-rel", 657, 116, "joins", anchor="middle")
    d.edge("M624 170H660V234H690"); d.text("t-rel", 668, 206, "claim", anchor="middle", rotate=-90)
    d.edge("M690 348H644V186H624"); d.text("t-rel", 652, 300, "pulled from", anchor="middle", rotate=-90)
    d.edge("M184 196V220"); d.text("t-rel", 192, 212, "reads")
    d.edge("M484 196V220"); d.text("t-rel", 492, 212, "reads at every pull")
    d.legend(490)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-distributor components", 1000, 580)
    d.bound(16, 40, 968, 480, "mcl-distributor service [Container]")
    d.box("b-cmp", 32, 70, 456, 112, "mcl_distributor_service", "[mcl_om_service module]",
          ["group_keys_v1 is its own procedure, and the only one;",
           "mcl_om adds open info and get_limits to every service;",
           "capabilities/0 is the list."], code=True)
    d.box("b-cmp", 512, 70, 456, 112, "mcl_distributor_pull", "[macula_response handler]",
          ["Forwards each pull to the registered", "distributor; no_distributor while it restarts"], code=True)
    d.box("b-sys", 32, 200, 456, 130, "mcl_distributor", "[worker start, deploy config]",
          ["Starts macula_group_keys for the org, registered", "by name: the pool by name, the removed set,",
           "the realm pins, ids checked as 64 hex at boot"], code=True)
    d.box("b-sys", 512, 200, 456, 130, "macula_group_keys", "[macula SDK gen_server]",
          ["Admits by removed set, then realm membership;", "epochs in a private ets table, not in the state;",
           "format_status redacts every key it shows"], code=True)
    d.box("b-cmp", 32, 370, 456, 110, "mcl_distributor_removed_members", "[module]",
          ["Reads removed_members at every pull;", "unreadable or malformed refuses everyone"], code=True)
    d.box("b-cmp", 512, 370, 456, 110, "mcl_distributor_sup", "[supervisor]",
          ["One permanent worker; a restart loses", "only in-memory epochs"], code=True)
    d.edge("M740 182V200"); d.text("t-rel", 748, 194, "calls by name")
    d.edge("M488 265H512"); d.text("t-rel", 500, 256, "starts", anchor="middle")
    d.edge("M260 330V370"); d.text("t-rel", 268, 354, "removed/2")
    d.edge("M740 480V500H860V330"); d.text("t-rel", 868, 420, "supervises")
    d.legend(550)
    d.write()


if __name__ == "__main__":
    for make in (context, containers, components):
        make()
