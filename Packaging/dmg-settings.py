# dmgbuild settings for Karui for Mac's disk image. Scripts/make-dmg.sh passes
# app (the Karui.app to copy in) and background (the drawn window art) with -D.
# Positions are icon centres in points from the window's top left, and must match
# Packaging/dmg-background.swift.

import os

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = []
icon_locations = {
    os.path.basename(app): (170, 165),
    "Applications": (470, 165),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
# Finder counts the 32 pt title bar in the height; the art below it is 640 × 400.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
