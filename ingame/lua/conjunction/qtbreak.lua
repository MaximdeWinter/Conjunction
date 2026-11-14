-- Where Qt 6.11 may break a line (qunicodetools.cpp getLineBreaks, UAX #14 as Qt has it - with its own synthetic
-- classes, Unicode 17), and which characters it takes for white space (QChar::isSpace). On code points.
--   local QB = require("conjunction.qtbreak")
--   local brk, must, white = QB.attributes(cps)   cps: code points; brk[i], must[i]: a break before cps[i] (i = 1 ..
--                                                 #cps + 1, the last the end); white[i]: cps[i] is white space
-- Qt's data per character: data/qt_unicode.lua (read from Qt6Core by ingame/tools/qt_unicode).
-- Checked against Qt: ingame/ref/qtbreak_check.py.
local QB = {}

-- QUnicodeTables::LineBreakClass
local C = {}
for i, n in ipairs({"OP", "CL", "CP", "QU", "QU_Pi", "QU_Pf", "QU_19", "GL", "NS", "EX", "SY", "IS", "PR", "PO", "NU",
                    "AL", "HL", "ID", "IN", "HY", "WS_HY", "HH", "BA", "WS_BA", "HYBA", "BB", "B2", "ZW", "CM", "WJ",
                    "H2", "H3", "JL", "JV", "JT", "RI", "CB", "EB", "EM", "AK", "AP", "AS", "VI", "VF", "ZWJ", "SA",
                    "SG", "SP", "CR", "LF", "BK"}) do C[n] = i - 1 end
QB.C = C
-- QChar::Category (the ones asked about), EastAsianWidth, GraphemeBreakClass
local Mn, Mc, Cn, Pi, Pf = 0, 1, 13, 23, 24
local Zs, Zl, Zp = 6, 7, 8
local EAW_F, EAW_H, EAW_W = 1, 2, 5
local GB_EXT_PICT = 14

-- --- the data: ranges of {start, lbc, eaw, category, grapheme} ---
local starts, vals = {}, {}
do
  local raw = require("conjunction.data.qt_unicode")
  for i = 1, #raw, 5 do
    starts[#starts + 1] = raw[i]
    vals[#vals + 1] = {raw[i + 1], raw[i + 2], raw[i + 3], raw[i + 4]}
  end
end
local cache = {}
local function props(c)
  local p = cache[c]
  if p then return p end
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if starts[mid] <= c then lo = mid else hi = mid - 1 end
  end
  p = vals[lo]
  if c < 0x3000 then cache[c] = p end
  return p
end
QB.props = props
local function lbc(c) return props(c)[1] end

-- the pair table (breakTable): PB, DB, IB, CI, CP, HH, IN, DN
local PB, DB, IB, CI, CPB, HH, IN, DN = 0, 1, 2, 3, 4, 5, 6, 7
local T = {
  "PPPPPPPPPPPPPPPPPPPPPPPPPPPPCPPPPPPPPPPPPPPP", -- OP
  "DPPIIPIIPPPPDDDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- CL
  "DPPIIPIIPPPPDDIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- CP
  "IPPIIPIIIPPPIIIIIDIIIIIIIIIPcPIIIIIIIIIIIIII", -- QU
  "PPPPPPPPPPPPPPPPPPPPPPPPPPPPCPPPPPPPPPPPPPPP", -- +Pi
  "IPPIIPIIIPPPIIIIIIIIIIIIIIIPcPIIIIIIIIIIIIII", -- +Pf
  "IPPIIPIIIPPPIIIIIIIIIIIIIIIPcPIIIIIIIIIIIIII", -- +19
  "IPPIIPIIIPPPIIIIIIIIIIIIIIIPcPIIIIIIIIIIIIII", -- GL
  "DPPDIPIIIPPPDDDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- NS
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- EX
  "DPPIIPIIIPPPDDDDIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- SY
  "DPPIIPIIIPPPNDIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- IS
  "DPPIIPIIIPPPDDIIIIIIIIIIIDDPcPIIIIIDDIIDDDDD", -- PR
  "DPPIIPIIIPPPDDIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- PO
  "nPPIIPIIIPPPIIIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- NU
  "nPPIIPIIIPPPIIIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- AL
  "nPPIIPIIIPPPIIIIIDIIccIccDDPcPDDDDDDDDDDDDDD", -- HL
  "DPPDIPIIIPPPDIDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- ID
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- IN
  "hPPIIPIhIPPPhhIhhhIIIIIIIhhPcPhhhhhhDDDhhhhh", -- HY
  "hPPIIPIhIPPPhhIIIhIIIIIIIhhPcPhhhhhhDDDhhhhh", -- +WS (HY)
  "hPPIIPIhIPPPhhIhhhIIIIIIIhhPcPhhhhhhDDDhhhhh", -- HH
  "hPPIIPIhIPPPhhhhhhIIIIIIIhhPcPhhhhhhDDDhhhhh", -- BA
  "hPPIIPIhIPPPhhhIIhIIIIIIIhhPcPhhhhhhDDDhhhhh", -- +WS (BA)
  "PPPPPPPPPPPPPPPPDPPPPPPPPPPPPPPPPPPPPPPPPPPP", -- HYBA
  "IPPIIPIIIPPPIIIIIIIIIIIIIIIPcPIIIIIIDIIIIIII", -- BB
  "DPPIIPIIIPPPDDDDDDIIIIIIIDPPcPDDDDDDDDDDDDDD", -- B2
  "DDDDDDDDDDDDDDDDDDDDDDDDDDDPDDDDDDDDDDDDDDDD", -- ZW
  "IPPIIPIIIPPPDDIIIDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- CM
  "IPPIIPIIIPPPIIIIIIIIIIIIIIIPcPIIIIIIIIIIIIII", -- WJ
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDIIDDDDDDDDD", -- H2
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDDIDDDDDDDDD", -- H3
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPIIIIDDDDDDDDDD", -- JL
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDIIDDDDDDDDD", -- JV
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDDIDDDDDDDDD", -- JT
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPcPDDDDDIDDDDDDDD", -- RI
  "DPPIIPIIDPPPDDDDDDDDDDDDDDDPcPDDDDDDDDDDDDDD", -- CB
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDDDDDDIDDDDD", -- EB
  "DPPIIPIIIPPPDIDDDDIIIIIIIDDPcPDDDDDDDDDDDDDD", -- EM
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPDPDDDDDDDDDDDDII", -- AK
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPDPDDDDDDDDDIDIDD", -- AP
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPDPDDDDDDDDDDDDII", -- AS
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPDPDDDDDDDDDDDDDD", -- VI
  "DPPIIPIIIPPPDDDDDDIIIIIIIDDPDPDDDDDDDDDDDDDD", -- VF
}
local CODE = {P = PB, D = DB, I = IB, c = CI, C = CPB, h = HH, n = IN, N = DN}
local TABLE = {}
for r, row in ipairs(T) do
  local t = {}
  for k = 1, #row do t[k - 1] = CODE[row:sub(k, k)] end
  TABLE[r - 1] = t
end
QB.TABLE = TABLE

-- --- LB25: number sequences (NS) ---
local NSX, PRPO, NOP, NHY, NNU, NSY, NIS, CLCP = 0, 1, 2, 3, 4, 5, 6, 7
local None, Start, Continue, Break, NeedOPNU, CNeedNU, CNeedISNU = 0, 1, 2, 3, 4, 5, 6
local ACT = {
  [NSX] = {None, NeedOPNU, Start, None, Start, None, None, None},
  [PRPO] = {None, NeedOPNU, Continue, Break, Start, None, None, None},
  [NOP] = {None, Start, Start, Break, Continue, None, Continue, None},
  [NHY] = {None, None, None, Start, Continue, None, None, None},
  [NNU] = {Break, Break, Break, Break, Continue, Continue, Continue, Continue},
  [NSY] = {Break, Break, Break, Break, Continue, Continue, Continue, Continue},
  [NIS] = {Break, Break, Break, Break, Continue, Continue, Continue, Continue},
  [CLCP] = {Break, Continue, Break, Break, Break, Break, Break, Break},
}
local function act(a, b) return ACT[a][b + 1] end
local function ns_class(c)
  if c == C.PR or c == C.PO then return PRPO end
  if c == C.OP then return NOP end
  if c == C.HY then return NHY end
  if c == C.NU then return NNU end
  if c == C.SY then return NSY end
  if c == C.IS then return NIS end
  if c == C.CL or c == C.CP then return CLCP end
  return NSX
end

-- --- LB28a: Brahmic sequences (BRS) ---
local DOTTED = 0x25CC
local B_None, B_Start, B_2VF, B_2VI, B_3VIAK, B_4, B_4VF, B_Restart = 0, 1, 2, 3, 4, 5, 6, 7
local function brs_update(state, cls, c)
  if cls == C.CM then return state end
  if state == B_Start then
    if cls == C.VF then return B_2VF end
    if cls == C.VI then return B_2VI end
    if c == DOTTED or cls == C.AK or cls == C.AS then return B_4 end
  elseif state == B_2VI then
    if c == DOTTED or cls == C.AK then return B_3VIAK end
  elseif state == B_4 then
    if cls == C.VF then return B_4VF end
    return B_Restart
  elseif state == B_None then
    if c == DOTTED or cls == C.AK or cls == C.AS then return B_Start end
  end
  return B_None
end

local function east_asian(eaw) return eaw == EAW_W or eaw == EAW_F or eaw == EAW_H end
local LB15A = {[C.BK] = true, [C.CR] = true, [C.LF] = true, [C.OP] = true, [C.QU] = true, [C.QU_Pi] = true,
               [C.QU_Pf] = true, [C.GL] = true, [C.SP] = true, [C.ZW] = true}
local LB15B = {[C.SP] = true, [C.GL] = true, [C.WJ] = true, [C.CL] = true, [C.QU] = true, [C.QU_Pi] = true,
               [C.QU_Pf] = true, [C.CP] = true, [C.EX] = true, [C.IS] = true, [C.SY] = true, [C.BK] = true,
               [C.CR] = true, [C.LF] = true, [C.ZW] = true}
local PROPS_A = props(0x41)

-- QChar::isSpace
local function is_space(c, p)
  if c == 0x20 or (c >= 0x09 and c <= 0x0d) then return true end
  if c <= 127 then return false end
  if c == 0x85 or c == 0xa0 then return true end
  local cat = (p or props(c))[3]
  return cat == Zs or cat == Zl or cat == Zp
end
QB.is_space = is_space

-- getLineBreaks with QTextEngine's options (the Hangul tailoring on), index i the code point (Qt's pos)
function QB.attributes(s)
  local n = #s
  local brk, must, white = {}, {}, {}
  for i = 1, n + 1 do brk[i], must[i] = false, false end
  local nestart = 0
  local nelast, neactlast = NSX, None
  local brs_state, brs_start = B_None, 0
  local lcls = C.LF
  local cls = lcls
  local last = props(0x0a)
  local i = 0                                   -- (0-based, as Qt's i and pos)
  while i < n do
    local pos = i
    local c = s[i + 1]
    local prop = props(c)
    white[i + 1] = is_space(c, prop)
    local ncls = prop[1]
    local tcls
    -- (HangulLineBreakTailoring)
    if (ncls >= C.H2 and ncls <= C.JT) or (c >= 0x3130 and c <= 0x318F and ncls == C.ID) then
      ncls = C.AL
    elseif ncls == C.SA then
      if prop[3] == Mn or prop[3] == Mc then ncls = C.CM end
    end
    if ncls == C.SA then
      if prop[3] == Mn or prop[3] == Mc then ncls = C.CM end
    end
    if ncls == C.QU then
      if prop[3] == Pi then
        if LB15A[lcls] then ncls = C.QU_Pi end
      elseif prop[3] == Pf then
        local nn = i + 1 >= n and C.LF or lbc(s[i + 2])
        if LB15B[nn] then ncls = C.QU_Pf end
      end
    end
    if (lcls >= C.SP or lcls == C.ZW or lcls == C.GL or lcls == C.CB) and (ncls == C.HY or ncls == C.HH) then
      ncls = ncls == C.HH and C.WS_BA or C.WS_HY
    end
    local goto_next, goto_nocls = false, false
    if cls == C.AP and c == DOTTED and lcls ~= C.SP then
      goto_next = true
    end
    if not goto_next then
      while true do
        local old = brs_state
        brs_state = brs_update(brs_state, ncls, c)
        if brs_state == old then break end
        if brs_state == B_Start then
          brs_start = i
        elseif brs_state == B_2VI then
          for j = brs_start + 1, i - 1 do brk[j + 1] = false end
          brs_start = i
          goto_next = true
        elseif brs_state == B_Restart then
          brs_state = B_Start
          brs_start = pos - 1
          goto continue_brs
        elseif brs_state == B_2VF or brs_state == B_4VF or brs_state == B_3VIAK then
          for j = brs_start + 1, i - 1 do brk[j + 1] = false end
          if brs_state == B_3VIAK then brs_state, brs_start = B_Start, i else brs_state = B_None end
          goto_next = true
        end
        break
        ::continue_brs::
      end
    end
    if not goto_next and ncls == C.IS and lcls == C.SP and i + 1 < n and lbc(s[i + 2]) == C.NU then
      brk[pos + 1] = true                      -- LB15c
      goto_next = true
    end
    if not goto_next and lcls == C.HL and (ncls == C.HY or ncls == C.HH) then
      ncls = C.HYBA                            -- LB21a
      goto_next = true
    end
    if not goto_next then
      -- LB25
      local necur = ns_class(ncls)
      local neact = act(nelast, necur)
      if neactlast == CNeedNU and necur ~= NNU then
        neact = None
      elseif neactlast == NeedOPNU then
        if necur == NOP then neact = CNeedISNU elseif necur == NNU then neact = Continue else neact = None end
      elseif neactlast == CNeedISNU then
        if necur == NIS then neact = CNeedNU elseif necur == NNU then neact = Continue else neact = None end
      end
      if neact == Break then
        for j = nestart + 1, pos - 1 do brk[j + 1] = false end
        nelast = NSX
      elseif neact == None then
        nelast = NSX
      elseif neact == NeedOPNU or neact == Start then
        if neactlast == Start or neactlast == Continue then
          for j = nestart + 1, pos - 1 do brk[j + 1] = false end
        end
        nestart = i
        nelast = necur
      else
        nelast = necur
      end
      neactlast = neact
      -- LB19a
      if ncls == C.QU and lcls ~= C.SP and lcls ~= C.ZW then
        local next_non_ea = true
        if i + 1 < n then
          local np = props(s[i + 2])
          next_non_ea = np[1] ~= C.CM and np[1] <= C.SP and not east_asian(np[2])
        end
        if not east_asian(last[2]) or next_non_ea then ncls = C.QU_19 end
      end
      if lcls >= C.CR then
        -- LB4, LB5
        if lcls > C.CR or ncls ~= C.LF then brk[pos + 1], must[pos + 1] = true, true end
        goto_next = true
      elseif ncls >= C.SP then
        if ncls > C.SP then goto_next = true else goto_nocls = true end
      elseif ((ncls == C.QU or ncls == C.QU_19) and prop[3] ~= Pi) or (cls == C.QU and last[3] ~= Pf) then
        -- LB19
        if lcls ~= C.SP and lcls ~= C.ZW and ncls ~= C.CM then goto_next = true end
      end
      if not goto_next and not goto_nocls then
        if (ncls == C.CM or ncls == C.ZWJ) and lcls ~= C.ZW and lcls < C.SP then
          goto_nocls = true                    -- LB9
        elseif lcls == C.ZWJ then
          goto_next = true                     -- LB8a
        elseif ncls == C.RI and lcls == C.RI then
          ncls = C.SP                          -- LB30a
          goto_next = true
        elseif ncls == C.EM and last[3] == Cn and last[4] == GB_EXT_PICT and lcls ~= C.SP then
          goto_next = true                     -- LB30b
        end
      end
      if not goto_next and not goto_nocls then
        if cls >= C.SA then cls = C.AL end
        tcls = cls
        -- (LB10, remapToAL: by reference - the class and the properties stay remapped for what follows)
        if tcls == C.CM or tcls == C.ZWJ then tcls = C.AL last = PROPS_A end
        if ncls == C.CM or ncls == C.ZWJ then ncls = C.AL prop = PROPS_A end
        local a = TABLE[tcls][ncls < C.ZWJ and ncls or C.AL]
        if a == DB then
          brk[pos + 1] = true
        elseif a == IB then
          if lcls == C.SP then brk[pos + 1] = true end
        elseif a == CI then
          if lcls ~= C.SP then goto_nocls = true else brk[pos + 1] = true end
        elseif a == CPB then
          if lcls ~= C.SP then goto_nocls = true end
        elseif a == HH then
          if lcls ~= C.HL then brk[pos + 1] = true end
        elseif a == IN then
          local w = prop[2]
          if w == EAW_F or w == EAW_W or w == EAW_H or lcls == C.SP then brk[pos + 1] = true end
        elseif a == DN then
          if neactlast == None or neactlast > Break then brk[pos + 1] = true end
        end
      end
    end
    -- next:
    if not goto_nocls then
      if ncls ~= C.CM and ncls ~= C.ZWJ then
        cls = ncls
        last = prop
      end
    end
    -- next_no_cls_update:
    lcls = ncls
    i = i + 1
  end
  if act(nelast, NSX) == Break then
    for j = nestart + 1, n - 1 do brk[j + 1] = false end
  end
  brk[1], must[1] = false, false
  brk[n + 1], must[n + 1] = true, true
  return brk, must, white
end

return QB
