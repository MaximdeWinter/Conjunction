-- Qt's box layout (QBoxLayout / qGeomCalc in qlayoutengine.cpp) in Lua, so a row of controls gets the positions Qt
-- gives it.
--
--   local placed = L.row(items, x, y, w, h, {margins = {l, t, r, b}, spacing = 2})
--   -- placed[i] = {x, y, w, h} for items[i]
-- An item: {hint = w, min = , max = , stretch = , expanding = , empty = , cross = h, cross_max = h, align = "top"}
--   hint       Qt's sizeHint along the row
--   min, max   minimum and maximum along the row (default: hint and unlimited, as a QPushButton: Minimum policy)
--   stretch    the stretch factor (addStretch(1): {spacer = true, stretch = 1, expanding = true})
--   expanding  the size policy grows first (Expanding)
--   empty      takes no room and no spacing (a hidden widget, a spacer)
--   cross, cross_max  the size across the row (a fixed height): placed in the middle, the odd pixel above
--
-- Measured: equal shares for items without a stretch factor (Qt does not add the extra to each hint), those whose
-- hint is larger keep their hint (mode button: icon 18, "Select" 31, key 18 from hints 14, 31, 6 in 67 px).
local L = {}
local BIG = 16777215          -- QLAYOUTSIZE_MAX

local function to_fixed(i) return i * 256 end
local function fround(i)      -- Qt's fRound for Fixed64 (non-negative here)
  if i % 256 < 128 then return i // 256 end
  return 1 + i // 256
end

-- QLayoutStruct::smartSizeHint: an item with a stretch factor asks for its minimum only
local function smart_hint(it) return (it.stretch or 0) > 0 and it.min or it.hint end

-- qGeomCalc: sizes and positions along one axis. chain[i] = {hint, min, max, stretch, expanding, empty, spacing}
-- (spacing: after this item, before the next non-empty one; the last non-empty item's is not counted)
local function geom_calc(chain, pos, space)
  local c_hint, c_min, sum_stretch, sum_spacing, expanding_count = 0, 0, 0, 0, 0
  local all_empty_nonstretch = true
  local pending, spacer_count = nil, 0
  for _, d in ipairs(chain) do
    d.done = false
    c_hint = c_hint + smart_hint(d)
    c_min = c_min + d.min
    sum_stretch = sum_stretch + (d.stretch or 0)
    if not d.empty then
      if pending then
        sum_spacing = sum_spacing + pending
        spacer_count = spacer_count + 1
      end
      pending = d.spacing or 0
    end
    if d.expanding then expanding_count = expanding_count + 1 end
    all_empty_nonstretch = all_empty_nonstretch and d.empty and not d.expanding and (d.stretch or 0) <= 0
  end
  local extraspace = 0
  if space < c_min + sum_spacing then
    -- less than the minimum: the biggest give first (every item cut down to one size, the remainder spread)
    local count = #chain
    local mins = {}
    for i, d in ipairs(chain) do mins[i] = d.min end
    table.sort(mins)
    local space_left = space - sum_spacing
    local sum, idx, used, current = 0, 1, 0, 0
    while idx <= count and used < space_left do
      current = mins[idx]
      used = sum + current * (count - idx + 1)
      sum = sum + current
      idx = idx + 1
    end
    idx = idx - 1
    local deficit = used - space_left
    local items = count - idx + 1
    local per = deficit >= 0 and deficit // items or -((-deficit) // items)   -- (C's / and %: toward zero)
    local remainder = deficit - per * items
    local maxval = current - per
    local rest = 0
    for _, d in ipairs(chain) do
      local maxv = maxval
      rest = rest + remainder
      if rest >= items then
        maxv = maxv - 1
        rest = rest - items
      end
      d.size = math.min(d.min, maxv)
      d.done = true
    end
  elseif space < c_hint + sum_spacing then
    local n = #chain
    local space_left = space - sum_spacing
    local overdraft = c_hint - space_left
    for _, d in ipairs(chain) do
      if not d.done and d.min >= smart_hint(d) then
        d.size = smart_hint(d); d.done = true; space_left = space_left - smart_hint(d); n = n - 1
      end
    end
    local finished = n == 0
    while not finished do
      finished = true
      local fp_over = to_fixed(overdraft)
      local fp_w = 0
      for _, d in ipairs(chain) do
        if not d.done then
          fp_w = fp_w + fp_over // n
          local w = fround(fp_w)
          d.size = smart_hint(d) - w
          fp_w = fp_w - to_fixed(w)
          if d.size < d.min then
            d.done = true
            d.size = d.min
            finished = false
            overdraft = overdraft - (smart_hint(d) - d.min)
            n = n - 1
            break
          end
        end
      end
    end
  else
    local n = #chain
    local space_left = space - sum_spacing
    for _, d in ipairs(chain) do
      if not d.done and (d.max <= smart_hint(d) or (not all_empty_nonstretch and d.empty and not d.expanding and (d.stretch or 0) == 0)) then
        d.size = smart_hint(d)
        d.done = true
        space_left = space_left - smart_hint(d)
        sum_stretch = sum_stretch - (d.stretch or 0)
        if d.expanding then expanding_count = expanding_count - 1 end
        n = n - 1
      end
    end
    extraspace = space_left
    local surplus, deficit
    repeat
      surplus, deficit = 0, 0
      local fp_space = to_fixed(space_left)
      local fp_w = 0
      for _, d in ipairs(chain) do
        if not d.done then
          extraspace = 0
          if sum_stretch > 0 then fp_w = fp_w + (fp_space * (d.stretch or 0)) // sum_stretch
          elseif expanding_count > 0 then fp_w = fp_w + (fp_space * (d.expanding and 1 or 0)) // expanding_count
          else fp_w = fp_w + fp_space // n end
          local w = fround(fp_w)
          d.size = w
          fp_w = fp_w - to_fixed(w)
          if w < smart_hint(d) then deficit = deficit + smart_hint(d) - w
          elseif w > d.max then surplus = surplus + w - d.max end
        end
      end
      if deficit > 0 and surplus <= deficit then
        for _, d in ipairs(chain) do
          if not d.done and d.size < smart_hint(d) then
            d.size = smart_hint(d); d.done = true; space_left = space_left - smart_hint(d)
            sum_stretch = sum_stretch - (d.stretch or 0)
            if d.expanding then expanding_count = expanding_count - 1 end
            n = n - 1
          end
        end
      end
      if surplus > 0 and surplus >= deficit then
        for _, d in ipairs(chain) do
          if not d.done and d.size > d.max then
            d.size = d.max; d.done = true; space_left = space_left - d.max
            sum_stretch = sum_stretch - (d.stretch or 0)
            if d.expanding then expanding_count = expanding_count - 1 end
            n = n - 1
          end
        end
      end
    until not (n > 0 and surplus ~= deficit)
    if n == 0 then extraspace = space_left end
  end
  local extra = extraspace // (spacer_count + 2)
  local p = pos + extra
  for _, d in ipairs(chain) do
    d.pos = p
    p = p + d.size
    if not d.empty then p = p + (d.spacing or 0) + extra end
  end
end

local function prepare(items, spacing)
  local chain = {}
  local prev = nil
  for i, it in ipairs(items) do
    local d = {hint = it.hint or 0, min = it.min or it.hint or 0, max = it.max or BIG, stretch = it.stretch or 0,
               expanding = it.expanding or (it.stretch or 0) > 0, empty = it.empty or false, spacing = 0}
    if it.spacer and it.fixed then d.min, d.max = d.hint, d.hint end
    if not d.empty then
      if prev then prev.spacing = spacing end
      prev = d
    end
    chain[i] = d
  end
  return chain
end

-- items along a row; returns {x, y, w, h} for each
function L.row(items, x, y, w, h, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local chain = prepare(items, opts.spacing or 0)
  geom_calc(chain, x + m[1], w - m[1] - m[3])
  local out = {}
  local cy, ch = y + m[2], h - m[2] - m[4]
  for i, it in ipairs(items) do
    local d = chain[i]
    local ih = math.min(ch, it.cross_max or BIG)
    local iy = cy
    if it.align == "top" then iy = cy elseif ih < ch then iy = cy + (ch - ih) // 2 end
    -- (QWidgetItem::setGeometry: no bigger than its maximum, at the left of its slot)
    out[i] = {x = d.pos, y = iy, w = math.max(it.least or 0, math.min(d.size, it.max or BIG)),
              h = math.max(it.cross_least or 0, ih)}
  end
  return out
end

-- the same down a column (an item's hfw(width): its height for the column's width, within cross_min / cross_max;
-- across, an item narrower than the column stands at its left: align = "center" for one centred)
function L.column(items, x, y, w, h, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local cx, cw = x + m[1], w - m[1] - m[3]
  local chain = prepare(items, opts.spacing or 0)
  for i, it in ipairs(items) do
    if it.hfw and not it.empty then
      local hh = it.hfw(math.max(it.cross_min or 0, math.min(cw, it.cross_max or BIG)))
      chain[i].hint, chain[i].min = hh, hh
    end
  end
  geom_calc(chain, y + m[2], h - m[2] - m[4])
  local out = {}
  for i, it in ipairs(items) do
    local d = chain[i]
    local iw = math.min(cw, it.cross_max or BIG)
    local ix = cx
    if iw < cw and it.align == "center" then ix = cx + (cw - iw) // 2 end
    -- (no higher than its maximum, in the middle of its slot: a height for its width can make the slot higher)
    local ih = math.min(d.size, it.max or BIG)
    out[i] = {x = ix, y = d.pos + (d.size - ih) // 2, w = math.max(it.cross_least or 0, iw),
              h = math.max(it.least or 0, ih)}
  end
  return out
end

-- --- a widget as a layout sees it (QWidgetItem: qSmartMinSize, qSmartMaxSize, its size policy) ---
-- policy: "fixed", "minimum", "maximum", "preferred", "expanding", "minimum_expanding", "ignored"
local GROW = {minimum = true, preferred = true, expanding = true, minimum_expanding = true, ignored = true}
local SHRINK = {maximum = true, preferred = true, expanding = true, ignored = true}
local EXPAND = {expanding = true, minimum_expanding = true}
L.BIG = BIG
-- one direction of QWidgetItem: sizeHint, qSmartMinSize, qSmartMaxSize, the expanding flag; least: the explicit
-- minimum QWidget::setGeometry keeps to (a fixed size)
local function axis(hint, min_hint, policy, fixed, max)
  policy = policy or "preferred"
  min_hint = min_hint or 0
  local emin, emax = fixed or 0, fixed or max or BIG
  local h0 = math.max(hint, min_hint)                  -- (sizeHint expanded to minimumSizeHint)
  local qhint = math.max(math.min(h0, emax), emin)
  if policy == "ignored" then qhint = 0 end
  local mn = 0
  if policy ~= "ignored" then mn = SHRINK[policy] and min_hint or h0 end
  mn = math.min(mn, emax)
  if emin > 0 then mn = emin end
  mn = math.max(mn, 0)
  local mx = emax
  if mx == BIG and not GROW[policy] then mx = math.max(h0, emin) end
  return {hint = qhint, min = mn, max = mx, expanding = EXPAND[policy] or false, least = emin > 0 and emin or nil}
end
-- -> {w = {hint, min, max, expanding}, h = {...}}; o: min_w, min_h (minimumSizeHint), fixed_w, fixed_h, max_w, max_h
function L.widget(hint_w, hint_h, hpol, vpol, o)
  o = o or {}
  return {w = axis(hint_w, o.min_w, hpol, o.fixed_w, o.max_w), h = axis(hint_h, o.min_h, vpol, o.fixed_h, o.max_h)}
end

-- --- QGridLayout (qgridlayout.cpp: setupLayoutData, distributeMultiBox, setupSpacings, recalcHFW, distribute) ---
-- cells[i] = {row, col, rows = 1, cols = 1, w = {hint, min, max, expanding, stretch}, h = {...}, hfw = fn(w),
--             empty = hidden}
-- opts: margins {l, t, r, b}, hspacing, vspacing (fixed spacings, as setHorizontalSpacing / setVerticalSpacing),
--       row_stretch {[r] = n}, col_stretch {[c] = n} (0-based rows and columns, as Qt's)
local function lstruct(stretch)
  return {stretch = stretch or 0, hint = 0, min = 0, max = (stretch or 0) > 0 and BIG or 0, expanding = false,
          empty = true, spacing = 0}
end
local function add_data(d, a, fixed_stretch)
  if not fixed_stretch then d.stretch = math.max(d.stretch, a.stretch or 0) end
  d.hint = math.max(a.hint, d.hint)
  d.min = math.max(a.min, d.min)
  -- qMaxExpCalc (the box is never empty here: hidden ones are left out)
  if d.expanding then
    if a.expanding then d.max = math.max(d.max, a.max) end
  else
    if a.expanding or d.empty then d.max = a.max else d.max = math.min(d.max, a.max) end
  end
  d.expanding = d.expanding or a.expanding
  d.empty = false
end
local function init_empty_multi(chain, s, e)
  for i = s, e do
    local d = chain[i]
    if d.empty and d.max == 0 then d.max = BIG end
    d.empty = false
  end
end
local function sub_calc(chain, s, e, space)
  local part = {}
  for i = s, e do part[#part + 1] = chain[i] end
  geom_calc(part, 0, space)
end
local function distribute_multi(chain, s, e, min_size, hint, stretches, stretch)
  local w, wh, mx = 0, 0, 0
  for i = s, e do
    local d = chain[i]
    w, wh, mx = w + d.min, wh + d.hint, mx + d.max
    if (stretches[i - 1] or 0) == 0 then d.stretch = math.max(d.stretch, stretch or 0) end
    if i ~= e then w, wh, mx = w + d.spacing, wh + d.spacing, mx + d.spacing end
  end
  if mx < min_size then
    sub_calc(chain, s, e, min_size)
    local pos = 0
    for i = s, e do
      local d = chain[i]
      local next_pos = (i == e) and min_size or chain[i + 1].pos
      local real = next_pos - pos
      if i ~= e then real = real - d.spacing end
      if d.min < real then d.min = real end
      if d.max < d.min then d.max = d.min end
      pos = next_pos
    end
  elseif w < min_size then
    sub_calc(chain, s, e, min_size)
    for i = s, e do
      local d = chain[i]
      if d.min < d.size then d.min = d.size end
    end
  end
  if wh < hint then
    sub_calc(chain, s, e, hint)
    for i = s, e do
      local d = chain[i]
      if d.hint < d.size then d.hint = d.size end
    end
  end
end
-- spacing between neighbours that are not the same cell (fixed spacing; a row or column with nothing is skipped)
local function setup_spacings(chain, grid, n_along, n_across, spacing, along_is_col)
  for c = 1, n_across do
    local prev_box, prev = nil, nil
    for r = 1, n_along do
      if not chain[r].empty then
        local box
        if along_is_col then box = grid[c] and grid[c][r] else box = grid[r] and grid[r][c] end
        if prev and (box == nil or prev_box ~= box) then
          if spacing > chain[prev].spacing then chain[prev].spacing = spacing end
        end
        prev_box, prev = box, r
      end
    end
  end
end
local function grid_setup(cells, opts)
  local rr, cc = 0, 0
  for _, c in ipairs(cells) do
    if not c.empty then
      rr = math.max(rr, c.row + (c.rows or 1))
      cc = math.max(cc, c.col + (c.cols or 1))
    end
  end
  local rs, cs = opts.row_stretch or {}, opts.col_stretch or {}
  for r in pairs(rs) do rr = math.max(rr, r + 1) end       -- (a stretch makes its row or column exist)
  for c in pairs(cs) do cc = math.max(cc, c + 1) end
  local rows, cols = {}, {}
  for i = 1, rr do rows[i] = lstruct(rs[i - 1]) end
  for i = 1, cc do cols[i] = lstruct(cs[i - 1]) end
  local grid, has_multi, has_hfw = {}, false, false
  for _, c in ipairs(cells) do
    if not c.empty then
      local r1, c1 = c.row + 1, c.col + 1
      local r2, c2 = r1 + (c.rows or 1) - 1, c1 + (c.cols or 1) - 1
      if c.hfw then has_hfw = true end
      if r1 == r2 then add_data(rows[r1], c.h, (rs[r1 - 1] or 0) > 0) else init_empty_multi(rows, r1, r2); has_multi = true end
      if c1 == c2 then add_data(cols[c1], c.w, (cs[c1 - 1] or 0) > 0) else init_empty_multi(cols, c1, c2); has_multi = true end
      for r = r1, r2 do
        grid[r] = grid[r] or {}
        for k = c1, c2 do grid[r][k] = c end
      end
    end
  end
  -- the columns' spacing looked for along every row, the rows' along every column
  setup_spacings(cols, grid, cc, rr, opts.hspacing or 0, true)
  setup_spacings(rows, grid, rr, cc, opts.vspacing or 0, false)
  if has_multi then
    for _, c in ipairs(cells) do
      if not c.empty then
        local r1, c1 = c.row + 1, c.col + 1
        local r2, c2 = r1 + (c.rows or 1) - 1, c1 + (c.cols or 1) - 1
        if r1 ~= r2 then distribute_multi(rows, r1, r2, c.h.min, c.h.hint, rs, c.h.stretch) end
        if c1 ~= c2 then distribute_multi(cols, c1, c2, c.w.min, c.w.hint, cs, c.w.stretch) end
      end
    end
  end
  for _, d in ipairs(rows) do d.expanding = d.expanding or d.stretch > 0 end
  for _, d in ipairs(cols) do d.expanding = d.expanding or d.stretch > 0 end
  return rows, cols, rr, cc, has_hfw
end
-- the rows again with each cell's height for the width its columns got (recalcHFW / setupHfwLayoutData)
local function hfw_rows(cells, rows, cols, rs)
  local rd = {}
  for i, d in ipairs(rows) do
    rd[i] = {stretch = d.stretch, hint = 0, min = 0, max = d.max, expanding = d.expanding, empty = d.empty,
             spacing = d.spacing}
  end
  for pass = 0, 1 do
    for _, c in ipairs(cells) do
      if not c.empty then
        local r1, c1 = c.row + 1, c.col + 1
        local r2, c2 = r1 + (c.rows or 1) - 1, c1 + (c.cols or 1) - 1
        local w = cols[c2].pos + cols[c2].size - cols[c1].pos
        if r1 == r2 then
          if pass == 0 then
            local d = rd[r1]
            if c.hfw then
              local hh = c.hfw(w)
              d.hint, d.min = math.max(hh, d.hint), math.max(hh, d.min)
            else
              d.hint, d.min = math.max(c.h.hint, d.hint), math.max(c.h.min, d.min)
            end
          end
        elseif pass == 0 then
          init_empty_multi(rd, r1, r2)
        else
          local hint, mn = c.h.hint, c.h.min
          if c.hfw then
            local hh = c.hfw(w)
            hint, mn = math.max(hint, hh), math.max(mn, hh)
          end
          distribute_multi(rd, r1, r2, mn, hint, rs, c.h.stretch)
        end
      end
    end
  end
  for _, d in ipairs(rd) do d.expanding = d.expanding or d.stretch > 0 end
  return rd
end
local function sum_of(chain, key)
  local s = 0
  for _, d in ipairs(chain) do s = s + d[key] + d.spacing end
  return math.min(BIG, s)
end
-- the grid's size: hint w, hint h, minimum w, minimum h (with its margins)
function L.grid_size(cells, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local rows, cols = grid_setup(cells, opts)
  return sum_of(cols, "hint") + m[1] + m[3], sum_of(rows, "hint") + m[2] + m[4],
         sum_of(cols, "min") + m[1] + m[3], sum_of(rows, "min") + m[2] + m[4]
end
-- the grid's height for a width (nil: nothing in it has a height for its width); also its minimum height for it
function L.grid_hfw(cells, width, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local rows, cols, _, _, has_hfw = grid_setup(cells, opts)
  if not has_hfw then return nil end
  geom_calc(cols, 0, width - m[1] - m[3])
  local rd = hfw_rows(cells, rows, cols, opts.row_stretch or {})
  return sum_of(rd, "hint") + m[2] + m[4], sum_of(rd, "min") + m[2] + m[4]
end
-- each cell's widget: its cell's rectangle, no bigger than its maximum, at the left and in the middle of the height
-- (QWidgetItem::setGeometry without an alignment: QStyle::visualAlignment makes that AlignLeft)
function L.grid(cells, x, y, w, h, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local rows, cols, _, _, has_hfw = grid_setup(cells, opts)
  local gx, gy, gw, gh = x + m[1], y + m[2], w - m[1] - m[3], h - m[2] - m[4]
  geom_calc(cols, gx, gw)
  local rd = rows
  if has_hfw then rd = hfw_rows(cells, rows, cols, opts.row_stretch or {}) end
  geom_calc(rd, gy, gh)
  local out = {}
  for i, c in ipairs(cells) do
    if not c.empty then
      local r1, c1 = c.row + 1, c.col + 1
      local r2, c2 = r1 + (c.rows or 1) - 1, c1 + (c.cols or 1) - 1
      local cx, cy = cols[c1].pos, rd[r1].pos
      local cw, ch = cols[c2].pos + cols[c2].size - cx, rd[r2].pos + rd[r2].size - cy
      local sw, sh = math.min(cw, c.w.max), math.min(ch, c.h.max)
      local dy = (ch - sh) // 2
      if ch - sh < 0 then dy = -((sh - ch) // 2) end          -- (C's division)
      out[i] = {x = cx, y = cy + dy, w = math.max(c.w.least or 0, sw), h = math.max(c.h.least or 0, sh),
                cell = {x = cx, y = cy, w = cw, h = ch}}
    end
  end
  return out
end

-- a layout's own size hint along the row: margins, hints, spacing between the non-empty ones
function L.row_hint(items, opts)
  opts = opts or {}
  local m = opts.margins or {0, 0, 0, 0}
  local total, count = m[1] + m[3], 0
  for _, it in ipairs(items) do
    total = total + (it.hint or 0)
    if not it.empty then count = count + 1 end
  end
  return total + math.max(0, count - 1) * (opts.spacing or 0)
end

return L
