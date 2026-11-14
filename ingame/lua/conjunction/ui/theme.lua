-- One look for every window of Conjunction: the values of conjunction/theme.py (keep the two the same).
local T = {}

local function c(hex) return tonumber(hex:sub(2), 16) * 256 + 255 end   -- "#rrggbb" -> 0xRRGGBBff
T.rgb = c

-- colours
T.BG = c("#18181a")              -- windows, the panel
T.SURFACE = c("#1d1d20")         -- lists, trees, tables, rows
T.FIELD = c("#2a2a2d")           -- text fields, choices, check boxes
T.BUTTON = c("#303033")
T.HEADER = c("#252528")          -- tabs, table headers
T.LINE = c("#444444")            -- frames, the lines of the nav
T.EDGE = c("#55555a")            -- the edge of what can be clicked or typed into
T.EDGE_HOVER = c("#8a8a8f")
T.CHOSEN = c("#4b4b50")          -- the one mark for chosen / selected
T.CHOSEN_EDGE = c("#c8c8c8")
T.HOVER = c("#29292d")
T.TEXT = c("#cccccc")
T.BRIGHT = c("#eeeeee")
T.DIM = c("#8c8c90")
T.RED = c("#e57a7a")
T.GOLD = c("#d9a441")            -- the graph's selection, the logo and the way back from a sub page
T.BUTTON_TEXT = c("#dddddd")
T.DISABLED_TEXT = c("#6a6a6e")
T.WHITE = c("#ffffff")
T.HEAD_TEXT = c("#bbbbbb")       -- tab and table header text
T.SCROLL = c("#3a3a3e")

-- sizes (px)
T.FONT = 13                      -- labels, buttons, fields
T.FONT_LIST = 12                 -- entries of lists, trees, tables
T.FONT_SMALL = 11                -- dim lines, table headers
T.FONT_HEAD = 14                 -- a page's heading
T.BOX = 14                       -- a check box
T.LABEL_W = 190                  -- the label column of a settings page
T.FIELD_W = 560                  -- a field there at most

return T
