--[[
  KillClock - vanilla 1.12.1 (Lua 5.0)
  Estimates time remaining on a boss fight from:
    1) live boss HP trend (linear regression over the last N seconds)
    2) your own recorded kill times for that boss (saved per character/account)
  Blends both, shows time to execute (20%) and time to kill, tracks your
  Death Wish cooldown and warns you when the fight enters its last X seconds.
]]

local defaults = {
  threshold = 30,          -- alert when estimated kill time <= this (seconds)
  window    = 20,          -- seconds of HP history used for the live trend
  spell     = "Death Wish",
  spellcd   = 180,         -- Death Wish cooldown (3 min)
  mode      = "blend",     -- blend | live | history
  locked    = false,
  sound     = true,
  keep      = 5,           -- how many recent kills the history average uses
  bigwigs   = "last",      -- use BigWigs Boss Records when we have no kills: last | best | mid | off
  hidden    = false,       -- window toggled off (minimap left-click)
  fightonly = false,       -- only show the window during boss fights
  minimap   = true,        -- show the minimap button
  mmangle   = 200,         -- minimap button position (degrees around the minimap)
  bigsize   = 22,          -- font size of the "Kill in" countdown
  titlesize = 13,          -- font size of the boss name line
  infosize  = 11,          -- font size of the execute / Death Wish lines
  outline   = true,        -- outlined text (easier to read over spell effects)
  bgalpha   = 0.75,        -- window background opacity
  scale     = 1.0,         -- overall window scale
  testdur   = 90,          -- length of the simulated test fight (seconds)
  shortfight = 45,         -- fights this short (or shorter) in the data: trust raid DPS almost at once
  longfight  = 240,        -- fights this long (or longer): lean on past kills for the first minute
}

local db
local SAMPLE_INTERVAL = 0.5

-- fight state
local active    = false
local boss      = nil
local startTime = 0
local lastSeen  = 0
local samples   = {}
local alerted   = false
local killed    = false
local curHP     = 100
local manualTarget = nil

-- test mode (simulated fight)
local testing  = false
local TEST_BOSS = "Test Dummy"

-- spell cache
local spellIndex = nil
local spellScanned = false

------------------------------------------------------------
-- helpers
------------------------------------------------------------
local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff8800KillClock:|r " .. msg)
end

local function Fmt(s)
  if not s then return "--:--" end
  if s < 0 then s = 0 end
  s = math.floor(s + 0.5)
  local m = math.floor(s / 60)
  return string.format("%d:%02d", m, s - m * 60)
end

local function ParseTime(x)
  if not x then return nil end
  local _, _, m, s = string.find(x, "^(%d+):(%d+)$")
  if m then return tonumber(m) * 60 + tonumber(s) end
  return tonumber(x)
end

local function IsBoss(unit)
  if not UnitExists(unit) or UnitIsDead(unit) or UnitIsFriend("player", unit) then
    return false
  end
  if manualTarget and UnitName(unit) == manualTarget then return true end
  return UnitClassification(unit) == "worldboss"
end

-- returns a unit id currently pointing at the boss (by name if locked on one)
local function FindBossUnit(name)
  local function ok(u)
    if not UnitExists(u) then return false end
    if name then return UnitName(u) == name end
    return IsBoss(u)
  end
  if ok("target") then return "target" end
  local n = GetNumRaidMembers()
  if n > 0 then
    for i = 1, n do
      local u = "raid" .. i .. "target"
      if ok(u) then return u end
    end
  else
    for i = 1, GetNumPartyMembers() do
      local u = "party" .. i .. "target"
      if ok(u) then return u end
    end
  end
  return nil
end

local function GetKills(name)
  if not db.kills[name] then db.kills[name] = {} end
  return db.kills[name]
end

local function HistAvg(name)
  local list = db.kills[name]
  if not list then return nil end
  local n = table.getn(list)
  if n == 0 then return nil end
  local first = n - db.keep + 1
  if first < 1 then first = 1 end
  local sum, c = 0, 0
  for i = first, n do sum = sum + list[i]; c = c + 1 end
  return sum / c
end

local function HistBest(name)
  local list = db.kills[name]
  if not list or table.getn(list) == 0 then return nil end
  local best = list[1]
  for i = 2, table.getn(list) do
    if list[i] < best then best = list[i] end
  end
  return best
end

------------------------------------------------------------
-- BigWigs "Boss Records": { [1] = kills, [2] = best time, [3] = last time }
------------------------------------------------------------
local function BigWigsRecords()
  local ns = BigWigsDB and BigWigsDB.namespaces and BigWigsDB.namespaces["Boss Records"]
  if not ns or not ns.profiles then return nil end
  return ns.profiles
end

local function BigWigsRecord(name)
  local profiles = BigWigsRecords()
  if not profiles then return nil end
  local rec = profiles["Default"] and profiles["Default"][name]
  if not rec then
    for _, p in pairs(profiles) do
      if type(p) == "table" and p[name] then rec = p[name]; break end
    end
  end
  if type(rec) ~= "table" or not rec[2] then return nil end
  return rec[1], rec[2], rec[3] or rec[2]
end

local function BigWigsTime(name, how)
  how = how or db.bigwigs
  if how == "off" then return nil end
  local _, best, last = BigWigsRecord(name)
  if not best then return nil end
  if how == "best" then return best end
  if how == "mid" then return (best + last) / 2 end
  return last
end

-- expected total fight length + where it came from
local function ExpectedDuration(name)
  if testing then return db.testdur, "test" end
  local own = HistAvg(name)
  if own then return own, "own" end
  local bw = BigWigsTime(name)
  if bw then return bw, "BW" end
  return nil
end

------------------------------------------------------------
-- Death Wish cooldown
------------------------------------------------------------
local function FindSpell(name)
  local i = 1
  local found = nil
  while true do
    local n = GetSpellName(i, BOOKTYPE_SPELL)
    if not n then break end
    if n == name then found = i end -- keep last (= highest rank)
    i = i + 1
  end
  return found
end

-- nil = spell not known, 0 = ready, >0 = seconds left on cooldown
local function SpellCD()
  if not spellScanned then
    spellIndex = FindSpell(db.spell)
    spellScanned = true
  end
  if not spellIndex then return nil end
  local start, dur = GetSpellCooldown(spellIndex, BOOKTYPE_SPELL)
  if start and start > 0 and dur and dur > 1.5 then
    local left = start + dur - GetTime()
    if left > 0 then return left end
  end
  return 0
end

------------------------------------------------------------
-- live estimate: least squares fit of HP% vs time
------------------------------------------------------------
local function LiveEstimate(t)
  while samples[1] and samples[1].t < t - db.window do
    table.remove(samples, 1)
  end
  local n = table.getn(samples)
  if n < 6 then return nil end
  if samples[n].t - samples[1].t < 5 then return nil end

  local st, sh = 0, 0
  for i = 1, n do st = st + samples[i].t; sh = sh + samples[i].h end
  local mt, mh = st / n, sh / n
  local num, den = 0, 0
  for i = 1, n do
    local dt = samples[i].t - mt
    num = num + dt * (samples[i].h - mh)
    den = den + dt * dt
  end
  if den == 0 then return nil end
  local slope = num / den              -- HP% per second (negative)
  if slope > -0.01 then return nil end -- boss not going down (phase, immune, etc.)
  local hpNow = mh + slope * (t - mt)
  if hpNow < 0 then hpNow = 0 end
  return -hpNow / slope, slope, hpNow
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local f = CreateFrame("Frame", "KillClockFrame", UIParent)
f:SetWidth(210)
f:SetHeight(92)
f:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
f:SetBackdrop({
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
f:SetBackdropColor(0, 0, 0, 0.75)
f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function()
  if not db.locked then this:StartMoving() end
end)
f:SetScript("OnDragStop", function()
  this:StopMovingOrSizing()
  local point, _, relPoint, x, y = this:GetPoint()
  db.pos = { point, relPoint, x, y }
end)
f:Hide()

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -7)
title:SetJustifyH("LEFT")

local big = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
big:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
big:SetJustifyH("LEFT")

local info1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
info1:SetPoint("TOPLEFT", big, "BOTTOMLEFT", 0, -4)
info1:SetJustifyH("LEFT")

local info2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
info2:SetPoint("TOPLEFT", info1, "BOTTOMLEFT", 0, -2)
info2:SetJustifyH("LEFT")

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function ApplyFonts()
  local flags = db.outline and "OUTLINE" or ""
  title:SetFont(FONT, db.titlesize, flags)
  big:SetFont(FONT, db.bigsize, db.outline and "THICKOUTLINE" or "")
  info1:SetFont(FONT, db.infosize, flags)
  info2:SetFont(FONT, db.infosize, flags)
  f:SetBackdropColor(0, 0, 0, db.bgalpha)
  f:SetBackdropBorderColor(0.6, 0.6, 0.6, db.bgalpha > 0.05 and 1 or 0)
  f:SetScale(db.scale)
end

-- grow / shrink the window to fit its text
local function AutoSize()
  if not db then return end
  local w = title:GetStringWidth()
  if big:GetStringWidth() > w then w = big:GetStringWidth() end
  if info1:GetStringWidth() > w then w = info1:GetStringWidth() end
  if info2:GetStringWidth() > w then w = info2:GetStringWidth() end
  if w < 120 then w = 120 end
  f:SetWidth(w + 18)
  local h = 8 + db.titlesize + 4 + db.bigsize + 4 + db.infosize + 2 + 10
  if (info2:GetText() or "") ~= "" then h = h + db.infosize + 2 end
  f:SetHeight(h)
end

-- two-line info text: info:SetText("line1\nline2")
local info = {}
function info:SetText(s)
  local _, _, a, b = string.find(s or "", "^(.-)\n(.*)$")
  if not a then a = s or ""; b = "" end
  info1:SetText(a)
  info2:SetText(b)
  AutoSize()
end

-- idle text shown when the window is visible outside a boss fight
local function ShowIdle()
  if db.locked then
    title:SetText("KillClock")
  else
    title:SetText("KillClock |cff888888(drag me)|r")
  end
  big:SetText("|cff888888Waiting for boss|r")
  local cd = SpellCD()
  if cd == nil then
    info:SetText("")
  elseif cd == 0 then
    info:SetText(db.spell .. ": |cff00ff00ready|r")
  else
    info:SetText(db.spell .. ": CD " .. Fmt(cd))
  end
end

-- hidden   -> never shown
-- fightonly-> only during boss fights
-- else     -> always shown (idle text outside fights)
local function RefreshVisibility()
  if testing then
    f:Show()
  elseif db.hidden then
    f:Hide()
  elseif active then
    f:Show()
  elseif db.fightonly then
    f:Hide()
  else
    ShowIdle()
    f:Show()
  end
end

------------------------------------------------------------
-- fight lifecycle
------------------------------------------------------------
local function StartFight(name, now)
  active    = true
  boss      = name
  startTime = now
  lastSeen  = now
  samples   = {}
  alerted   = false
  killed    = false
  curHP     = 100
  RefreshVisibility()
end

local function StopFight()
  active = false
  boss = nil
  samples = {}
  RefreshVisibility()
end

local function Kill()
  if not active or killed then return end
  killed = true
  local dur = GetTime() - startTime
  local list = GetKills(boss)
  table.insert(list, dur)
  while table.getn(list) > 20 do table.remove(list, 1) end
  Print(boss .. " killed in " .. Fmt(dur) .. "  (avg of last " .. db.keep .. ": " .. Fmt(HistAvg(boss)) .. ")")
  StopFight()
end

local function Alert(text)
  UIErrorsFrame:AddMessage(text, 1, 0.2, 0.2, 1, 4)
  if db.sound then PlaySound("RaidWarning") end
end

-- How much the blended estimate trusts live raid DPS (0..1) at fight time t,
-- given the boss's expected fight length from the data.
--   short fight in the data -> starts at 50% DPS and reaches 100% after ~15s
--   long fight in the data  -> starts at 0% DPS and reaches 100% after 60s
local function LiveWeight(t, expected)
  local short, long = db.shortfight, db.longfight
  if long <= short then long = short + 1 end
  local s = (long - expected) / (long - short) -- 1 = short fight, 0 = long fight
  if s < 0 then s = 0 elseif s > 1 then s = 1 end
  local ramp = 60 - 45 * s
  local base = 0.5 * s
  local r = t / ramp
  if r > 1 then r = 1 end
  return base + (1 - base) * r
end

local function UpdateDisplay(now)
  local t = now - startTime
  local live, slope, hpNow = LiveEstimate(t)
  local avg, src = ExpectedDuration(boss)
  local histRem = nil
  if avg and avg - t > 0 then histRem = avg - t end

  local dpsShare = nil
  local est
  if db.mode == "live" then
    est = live
  elseif db.mode == "history" then
    est = histRem or live
  else -- blend: the shorter the fight is in the data, the sooner we trust raid DPS
    if live and histRem then
      local w = LiveWeight(t, avg)
      dpsShare = w
      est = w * live + (1 - w) * histRem
    else
      est = live or histRem
      if live then dpsShare = 1 elseif histRem then dpsShare = 0 end
    end
  end

  title:SetText(boss .. "  |cffffffff" .. math.floor(curHP + 0.5) .. "%|r")

  if est then
    local c = "|cff00ff00"
    if est <= db.threshold then c = "|cffff2020"
    elseif est <= db.threshold + 30 then c = "|cffffd000" end
    big:SetText(c .. "Kill in " .. Fmt(est) .. "|r")
  else
    big:SetText("|cff888888Kill in --:--|r")
  end

  local exec
  if slope and hpNow then
    if hpNow <= 20 then exec = "|cffff2020EXECUTE|r"
    else exec = "Execute in " .. Fmt((hpNow - 20) / -slope) end
  else
    exec = "Execute in --:--"
  end
  local line1 = exec .. "  |  " .. Fmt(t)
  if avg then
    local tag = src
    if dpsShare and db.mode == "blend" then
      tag = tag .. ", DPS " .. math.floor(dpsShare * 100 + 0.5) .. "%"
    end
    line1 = line1 .. " / " .. Fmt(avg) .. " (" .. tag .. ")"
  end

  local line2 = ""
  local cd = SpellCD()
  if cd and est then
    local sp = db.spell
    if cd == 0 then
      if est > db.spellcd + db.threshold then
        line2 = "|cff00ff00" .. sp .. ": use NOW, back in time for the end|r"
      elseif est > db.threshold then
        line2 = sp .. ": ready - hold " .. Fmt(est - db.threshold)
      else
        line2 = "|cffff2020" .. sp .. ": USE NOW|r"
      end
    else
      if cd > est then
        line2 = "|cff888888" .. sp .. ": CD " .. Fmt(cd) .. " (not back before kill)|r"
      else
        line2 = sp .. ": CD " .. Fmt(cd)
      end
    end
  elseif cd and cd > 0 then
    line2 = db.spell .. ": CD " .. Fmt(cd)
  end
  info:SetText(line1 .. "\n" .. line2)

  if est and not alerted and t > 10 and est <= db.threshold then
    alerted = true
    local cdNow = SpellCD()
    if cdNow == nil or cdNow == 0 then
      Alert(">> LAST " .. db.threshold .. "s - " .. string.upper(db.spell) .. " NOW <<")
    else
      Alert(">> LAST " .. db.threshold .. "s <<")
    end
  end
end

------------------------------------------------------------
-- test mode: a fake boss that dies in db.testdur seconds
------------------------------------------------------------
-- simulated HP: steady damage with some noise, like a real raid
local function TestHP(t)
  local hp = 100 * (1 - t / db.testdur)
  hp = hp + math.sin(t * 1.7) * 0.6 + math.sin(t * 0.43) * 0.9
  if hp > 100 then hp = 100 end
  return hp
end

local function StopTest(quiet)
  if not testing then return end
  testing = false
  StopFight()
  if not quiet then Print("test fight stopped.") end
end

local function StartTest()
  if active and not testing then
    Print("can't start a test during a real boss fight.")
    return
  end
  testing = true
  -- start 15s "into" the fake fight with HP history already filled in,
  -- so every line of the window shows right away (no target needed)
  local now = GetTime()
  StartFight(TEST_BOSS, now - 15)
  local t = 0
  while t <= 15 do
    table.insert(samples, { t = t, h = TestHP(t) })
    t = t + SAMPLE_INTERVAL
  end
  curHP = TestHP(15)
  UpdateDisplay(now)
  Print("test fight started: " .. TEST_BOSS .. " dies in " .. Fmt(db.testdur) ..
        ". Drag the window, right-click the minimap button for settings. /kc test again to stop.")
end

local function ToggleTest()
  if testing then StopTest() else StartTest() end
end

local function Tick()
  local now = GetTime()
  if testing then
    local t = now - startTime
    if t >= db.testdur then
      Print(TEST_BOSS .. " killed in " .. Fmt(t) .. " (test - not saved).")
      StopTest(true)
      return
    end
    curHP = TestHP(t)
    table.insert(samples, { t = t, h = curHP })
    UpdateDisplay(now)
    return
  end
  if not active and f:IsVisible() then ShowIdle() end
  if not active then
    if UnitAffectingCombat("player") then
      local u = FindBossUnit(nil)
      if u then StartFight(UnitName(u), now) end
    end
    return
  end

  local u = FindBossUnit(boss)
  if u then
    lastSeen = now
    local max = UnitHealthMax(u)
    if max and max > 0 then
      local hp = UnitHealth(u) / max * 100
      -- dead, or turned friendly (Majordomo surrenders instead of dying)
      if UnitIsDead(u) or hp <= 0 or UnitIsFriend("player", u) then Kill(); return end
      curHP = hp
      table.insert(samples, { t = now - startTime, h = hp })
    end
  else
    -- nobody is targeting the boss: wipe (we're alive and out of combat) or lost for too long
    if (not UnitAffectingCombat("player") and not UnitIsDeadOrGhost("player")) or now - lastSeen > 60 then
      StopFight()
      return
    end
  end
  -- also stop on wipe while the boss is still targeted
  if not UnitAffectingCombat("player") and not UnitIsDeadOrGhost("player") and now - startTime > 5 then
    local raidInCombat = false
    for i = 1, GetNumRaidMembers() do
      if UnitAffectingCombat("raid" .. i) then raidInCombat = true; break end
    end
    if not raidInCombat then StopFight(); return end
  end
  UpdateDisplay(now)
end

------------------------------------------------------------
-- window toggles
------------------------------------------------------------
local function ToggleWindow()
  db.hidden = not db.hidden
  RefreshVisibility()
  Print("window " .. (db.hidden and "hidden" or "shown") .. ".")
end

local function ToggleLock()
  db.locked = not db.locked
  RefreshVisibility()
  Print("window " .. (db.locked and "locked" or "unlocked - drag it where you want") .. ".")
end

local function ToggleFightOnly()
  db.fightonly = not db.fightonly
  RefreshVisibility()
  Print(db.fightonly and "window only shows during boss fights." or "window always shown.")
end

------------------------------------------------------------
-- minimap button
------------------------------------------------------------
local mm = CreateFrame("Button", "KillClockMinimapButton", Minimap)
mm:SetWidth(31)
mm:SetHeight(31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:SetToplevel(true)
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")

local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetTexture("Interface\\Icons\\Spell_Shadow_DeathPact") -- Death Wish icon
mmIcon:SetWidth(20)
mmIcon:SetHeight(20)
mmIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
mmIcon:SetPoint("TOPLEFT", mm, "TOPLEFT", 6, -5)

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetWidth(53)
mmBorder:SetHeight(53)
mmBorder:SetPoint("TOPLEFT", mm, "TOPLEFT", 0, 0)

local function MinimapPosition()
  local a = math.rad(db.mmangle)
  mm:ClearAllPoints()
  mm:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 54 - 80 * math.cos(a), 80 * math.sin(a) - 55)
end

local function MinimapIconState()
  if db.hidden then
    mmIcon:SetVertexColor(0.45, 0.45, 0.45) -- greyed out when window is hidden
  else
    mmIcon:SetVertexColor(1, 1, 1)
  end
end

local function MinimapDragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local s = Minimap:GetEffectiveScale()
  px, py = px / s, py / s
  db.mmangle = math.deg(math.atan2(py - my, mx - px))
  MinimapPosition()
end

mm:SetScript("OnDragStart", function()
  this:LockHighlight()
  this:SetScript("OnUpdate", MinimapDragUpdate)
end)
mm:SetScript("OnDragStop", function()
  this:SetScript("OnUpdate", nil)
  this:UnlockHighlight()
end)

local ToggleConfig -- defined with the settings window below

mm:SetScript("OnClick", function()
  if arg1 == "RightButton" then
    ToggleConfig()
  elseif IsShiftKeyDown() then
    ToggleTest()
  else
    ToggleWindow()
  end
  MinimapIconState()
  if GameTooltip:IsOwned(this) then this:GetScript("OnEnter")() end
end)

mm:SetScript("OnEnter", function()
  GameTooltip:SetOwner(this, "ANCHOR_LEFT")
  GameTooltip:SetText("KillClock")
  GameTooltip:AddLine("Left-click: " .. (db.hidden and "show" or "hide") .. " window", 1, 1, 1)
  GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
  GameTooltip:AddLine("Shift-click: " .. (testing and "stop" or "start") .. " test fight", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
mm:Hide()

local function MinimapRefresh()
  if db.minimap then
    MinimapPosition()
    MinimapIconState()
    mm:Show()
  else
    mm:Hide()
  end
end

------------------------------------------------------------
-- settings window (/kc config, or right-click the minimap button)
------------------------------------------------------------
local cfg = CreateFrame("Frame", "KillClockConfig", UIParent)
cfg:SetWidth(560)
cfg:SetHeight(560)
cfg:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
cfg:SetFrameStrata("DIALOG")
cfg:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
cfg:SetMovable(true)
cfg:EnableMouse(true)
cfg:RegisterForDrag("LeftButton")
cfg:SetScript("OnDragStart", function() this:StartMoving() end)
cfg:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
cfg:Hide()
table.insert(UISpecialFrames, "KillClockConfig") -- Escape closes it

local cfgTitle = cfg:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
cfgTitle:SetPoint("TOP", cfg, "TOP", 0, -18)
cfgTitle:SetText("KillClock settings")

local cfgClose = CreateFrame("Button", "KillClockConfigClose", cfg, "UIPanelCloseButton")
cfgClose:SetPoint("TOPRIGHT", cfg, "TOPRIGHT", -6, -6)

local LEFT, RIGHT = 28, 300
local widgets = {}

local function Header(text, x, y)
  local h = cfg:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  h:SetPoint("TOPLEFT", cfg, "TOPLEFT", x, y)
  h:SetText(text)
end

local function fmtInt(v) return tostring(math.floor(v + 0.5)) end
local function fmtSec(v) return math.floor(v + 0.5) .. "s" end
local function fmtPct(v) return math.floor(v * 100 + 0.5) .. "%" end
local function fmtMul(v) return string.format("%.2fx", v) end
local function fmtTime(v) return Fmt(v) end

local sliderCount = 0
local function Slider(label, key, minv, maxv, step, fmt, x, y, onchange)
  sliderCount = sliderCount + 1
  local name = "KillClockCfgSlider" .. sliderCount
  local s = CreateFrame("Slider", name, cfg, "OptionsSliderTemplate")
  s:SetWidth(230)
  s:SetHeight(16)
  s:SetPoint("TOPLEFT", cfg, "TOPLEFT", x, y)
  s:SetMinMaxValues(minv, maxv)
  s:SetValueStep(step)
  getglobal(name .. "Low"):SetText(fmt(minv))
  getglobal(name .. "High"):SetText(fmt(maxv))
  s:SetScript("OnValueChanged", function()
    local v = math.floor(this:GetValue() / step + 0.5) * step
    getglobal(this:GetName() .. "Text"):SetText(label .. ": |cffffffff" .. fmt(v) .. "|r")
    if not db or db[key] == v then return end
    db[key] = v
    if onchange then onchange() end
  end)
  s.Refresh = function()
    s:SetValue(db[key])
    getglobal(name .. "Text"):SetText(label .. ": |cffffffff" .. fmt(db[key]) .. "|r")
  end
  table.insert(widgets, s)
  return s
end

local checkCount = 0
local function Check(label, key, x, y, onchange)
  checkCount = checkCount + 1
  local name = "KillClockCfgCheck" .. checkCount
  local c = CreateFrame("CheckButton", name, cfg, "UICheckButtonTemplate")
  c:SetWidth(24)
  c:SetHeight(24)
  c:SetPoint("TOPLEFT", cfg, "TOPLEFT", x - 4, y)
  getglobal(name .. "Text"):SetText(label)
  c:SetScript("OnClick", function()
    db[key] = this:GetChecked() and true or false
    if onchange then onchange() end
  end)
  c.Refresh = function() c:SetChecked(db[key] and 1 or nil) end
  table.insert(widgets, c)
  return c
end

local buttonCount = 0
local function Button(text, width, onclick)
  buttonCount = buttonCount + 1
  local b = CreateFrame("Button", "KillClockCfgButton" .. buttonCount, cfg, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(22)
  b:SetText(text)
  b:SetScript("OnClick", onclick)
  return b
end

-- a button that cycles through a list of values
local function Cycle(label, key, values, x, y, onchange)
  local b = Button("", 230, nil)
  b:SetPoint("TOPLEFT", cfg, "TOPLEFT", x, y)
  b.Refresh = function() b:SetText(label .. ": " .. db[key]) end
  b:SetScript("OnClick", function()
    local n = table.getn(values)
    local idx = 1
    for i = 1, n do if values[i] == db[key] then idx = i end end
    db[key] = values[math.mod(idx, n) + 1]
    b.Refresh()
    if onchange then onchange() end
  end)
  table.insert(widgets, b)
  return b
end

local function DisplayChanged()
  ApplyFonts()
  if active then AutoSize() else RefreshVisibility() end
end

local function VisibilityChanged()
  RefreshVisibility()
  MinimapRefresh()
end

-- left column: display
Header("Display", LEFT, -48)
Slider("Kill timer font size", "bigsize",   10, 48,  1,    fmtInt, LEFT, -80,  DisplayChanged)
Slider("Boss name font size",  "titlesize",  8, 24,  1,    fmtInt, LEFT, -122, DisplayChanged)
Slider("Info lines font size", "infosize",   8, 20,  1,    fmtInt, LEFT, -164, DisplayChanged)
Slider("Window scale",         "scale",    0.5,  2,  0.05, fmtMul, LEFT, -206, DisplayChanged)
Slider("Background opacity",   "bgalpha",    0,  1,  0.05, fmtPct, LEFT, -248, DisplayChanged)
Check("Outlined text",                    "outline",   LEFT, -280, DisplayChanged)
Check("Lock window position",             "locked",    LEFT, -304, VisibilityChanged)
Check("Hide window",                      "hidden",    LEFT, -328, VisibilityChanged)
Check("Only show during boss fights",     "fightonly", LEFT, -352, VisibilityChanged)
Check("Show minimap button",              "minimap",   LEFT, -376, VisibilityChanged)

-- right column: timing
Header("Timing", RIGHT, -48)
Slider("Alert at last",          "threshold",  5,   90,  5, fmtSec,  RIGHT, -80)
Slider("Live trend window",      "window",     8,   60,  1, fmtSec,  RIGHT, -122)
Slider("Past kills averaged",    "keep",       1,   10,  1, fmtInt,  RIGHT, -164)
Slider("Test fight length",      "testdur",   30,  600, 10, fmtTime, RIGHT, -206)
Slider("Cooldown length",        "spellcd",   30, 1800, 30, fmtTime, RIGHT, -248)
Slider("Short fight (trust DPS)", "shortfight", 15,  180,  5, fmtTime, RIGHT, -290)
Slider("Long fight (trust kills)", "longfight", 60,  600, 10, fmtTime, RIGHT, -332)

local spellLabel = cfg:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
spellLabel:SetPoint("TOPLEFT", cfg, "TOPLEFT", RIGHT, -366)
spellLabel:SetText("Tracked cooldown (press Enter):")

local spellBox = CreateFrame("EditBox", "KillClockCfgSpell", cfg, "InputBoxTemplate")
spellBox:SetWidth(222)
spellBox:SetHeight(20)
spellBox:SetPoint("TOPLEFT", cfg, "TOPLEFT", RIGHT + 6, -380)
spellBox:SetAutoFocus(false)
spellBox:SetScript("OnEnterPressed", function()
  local v = this:GetText()
  if v and v ~= "" then
    db.spell = v
    spellScanned = false
    if SpellCD() == nil then
      Print("'" .. v .. "' not found in your spellbook (check the spelling).")
    else
      Print("tracking cooldown of: " .. v)
    end
  end
  this:ClearFocus()
end)
spellBox:SetScript("OnEscapePressed", function()
  this:SetText(db.spell)
  this:ClearFocus()
end)
spellBox.Refresh = function() spellBox:SetText(db.spell) end
table.insert(widgets, spellBox)

Cycle("Estimate", "mode", { "blend", "live", "history" }, RIGHT, -408)
Cycle("BigWigs times", "bigwigs", { "last", "best", "mid", "off" }, RIGHT, -434)
Check("Play sound on alert", "sound", RIGHT, -462)

-- bottom buttons
local testBtn = Button("Start test fight", 150, function() ToggleTest() end)
testBtn:SetPoint("BOTTOMLEFT", cfg, "BOTTOMLEFT", 24, 22)

local importBtn = Button("Import BigWigs", 130, function() SlashCmdList["KILLCLOCK"]("import") end)
importBtn:SetPoint("LEFT", testBtn, "RIGHT", 8, 0)

local histBtn = Button("Show history", 120, function() SlashCmdList["KILLCLOCK"]("history") end)
histBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)

local closeBtn = Button("Close", 90, function() cfg:Hide() end)
closeBtn:SetPoint("BOTTOMRIGHT", cfg, "BOTTOMRIGHT", -24, 22)

local function RefreshConfig()
  for i = 1, table.getn(widgets) do widgets[i].Refresh() end
end

cfg:SetScript("OnShow", RefreshConfig)

-- keep the test button and checkboxes in sync with minimap / slash changes
local cfgAcc = 0
cfg:SetScript("OnUpdate", function()
  cfgAcc = cfgAcc + arg1
  if cfgAcc < 0.25 then return end
  cfgAcc = 0
  testBtn:SetText(testing and "Stop test fight" or "Start test fight")
end)

ToggleConfig = function()
  if cfg:IsVisible() then
    cfg:Hide()
  else
    cfg:Show()
  end
end

------------------------------------------------------------
-- events
------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("LEARNED_SPELL_IN_TAB")

ev:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and arg1 == "KillClock" then
    if not KillClockDB then KillClockDB = {} end
    for k, v in pairs(defaults) do
      if KillClockDB[k] == nil then KillClockDB[k] = v end
    end
    if not KillClockDB.kills then KillClockDB.kills = {} end
    db = KillClockDB
    if db.pos then
      f:ClearAllPoints()
      f:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    end
    ApplyFonts()
    RefreshVisibility()
    MinimapRefresh()
  elseif event == "CHAT_MSG_COMBAT_HOSTILE_DEATH" then
    if active and arg1 then
      local _, _, name = string.find(arg1, "^(.+) dies%.$")
      if name and name == boss then Kill() end
    end
  elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
    spellScanned = false
  end
end)

local acc = 0
ev:SetScript("OnUpdate", function()
  if not db then return end
  acc = acc + arg1
  if acc < SAMPLE_INTERVAL then return end
  acc = 0
  Tick()
end)

------------------------------------------------------------
-- slash commands
------------------------------------------------------------
SLASH_KILLCLOCK1 = "/killclock"
SLASH_KILLCLOCK2 = "/kc"
SlashCmdList["KILLCLOCK"] = function(msg)
  local _, _, cmd, rest = string.find(msg or "", "^(%S*)%s*(.-)$")
  cmd = string.lower(cmd or "")

  if cmd == "" or cmd == "config" or cmd == "options" then
    ToggleConfig()
  elseif cmd == "test" then
    ToggleTest()
  elseif cmd == "lock" then
    if not db.locked then ToggleLock() end
  elseif cmd == "unlock" then
    if db.locked then ToggleLock() end
  elseif cmd == "show" then
    if db.hidden then ToggleWindow() end
    MinimapIconState()
  elseif cmd == "hide" then
    if not db.hidden then ToggleWindow() end
    MinimapIconState()
  elseif cmd == "toggle" then
    ToggleWindow()
    MinimapIconState()
  elseif cmd == "fight" then
    ToggleFightOnly()
  elseif cmd == "minimap" then
    db.minimap = not db.minimap
    MinimapRefresh()
    Print("minimap button " .. (db.minimap and "shown" or "hidden") .. ".")
  elseif cmd == "threshold" then
    local n = tonumber(rest)
    if n then db.threshold = n; Print("alert at last " .. n .. "s.") else Print("usage: /kc threshold 30") end
  elseif cmd == "window" then
    local n = tonumber(rest)
    if n and n >= 8 then db.window = n; Print("live trend window: " .. n .. "s.") else Print("usage: /kc window 20 (min 8)") end
  elseif cmd == "mode" then
    if rest == "blend" or rest == "live" or rest == "history" then
      db.mode = rest; Print("mode: " .. rest)
    else
      Print("usage: /kc mode blend | live | history")
    end
  elseif cmd == "spell" then
    if rest ~= "" then db.spell = rest; spellScanned = false; Print("tracking cooldown of: " .. rest) end
  elseif cmd == "sound" then
    db.sound = not db.sound; Print("sound " .. (db.sound and "on" or "off"))
  elseif cmd == "track" then
    if UnitExists("target") then
      manualTarget = UnitName("target")
      Print("will treat '" .. manualTarget .. "' as a boss (for bosses not flagged as worldboss).")
      if UnitAffectingCombat("player") and not active then StartFight(manualTarget, GetTime()) end
    else
      manualTarget = nil
      Print("manual tracking cleared.")
    end
  elseif cmd == "set" then
    -- /kc set 3:45 [Boss Name]   (no name = current target)
    local _, _, tm, name = string.find(rest, "^(%S+)%s*(.-)$")
    local secs = ParseTime(tm)
    if name == "" then name = UnitExists("target") and UnitName("target") or nil end
    if secs and name then
      table.insert(GetKills(name), secs)
      Print("added kill time " .. Fmt(secs) .. " for " .. name .. ".")
    else
      Print("usage: /kc set 3:45 Ragnaros   (or target the boss and /kc set 3:45)")
    end
  elseif cmd == "bigwigs" or cmd == "bw" then
    if rest == "last" or rest == "best" or rest == "mid" or rest == "off" then
      db.bigwigs = rest; Print("BigWigs records: " .. rest)
    elseif BigWigsRecords() then
      local profiles = BigWigsRecords()
      local recs = profiles["Default"] or {}
      local c = 0
      for name, rec in pairs(recs) do
        if type(rec) == "table" and rec[2] then
          c = c + 1
          Print(name .. ": " .. (rec[1] or "?") .. " kills, best " .. Fmt(rec[2]) .. ", last " .. Fmt(rec[3] or rec[2]))
        end
      end
      Print(c .. " BigWigs records found, using: " .. db.bigwigs .. "  (/kc bw last|best|mid|off)")
    else
      Print("BigWigs records not found - is BigWigs enabled in the AddOns list?")
    end
  elseif cmd == "import" then
    local profiles = BigWigsRecords()
    if not profiles then Print("BigWigs records not found.") return end
    local recs = profiles["Default"] or {}
    local c = 0
    for name, rec in pairs(recs) do
      if type(rec) == "table" and rec[2] and table.getn(GetKills(name)) == 0 then
        table.insert(GetKills(name), BigWigsTime(name, db.bigwigs ~= "off" and db.bigwigs or "last"))
        c = c + 1
      end
    end
    Print("imported " .. c .. " boss times from BigWigs (bosses you already had kills for were skipped).")
  elseif cmd == "history" then
    local any = false
    for name, list in pairs(db.kills) do
      if table.getn(list) > 0 then
        any = true
        Print(name .. ": " .. table.getn(list) .. " kills, avg " .. Fmt(HistAvg(name)) .. ", best " .. Fmt(HistBest(name)))
      end
    end
    if not any then Print("no kills recorded yet (BigWigs times are still used - see /kc bw).") end
  elseif cmd == "reset" then
    if rest == "all" then
      db.kills = {}; Print("all kill history cleared.")
    elseif rest ~= "" then
      db.kills[rest] = nil; Print("history cleared for " .. rest .. ".")
    else
      Print("usage: /kc reset Boss Name | all")
    end
  else
    Print("commands:")
    Print("/kc - open the settings window")
    Print("/kc test - start / stop a simulated test fight")
    Print("/kc show | hide | toggle - show / hide the window")
    Print("/kc lock | unlock - lock / move the window")
    Print("/kc fight - only show the window during boss fights")
    Print("/kc minimap - show / hide the minimap button")
    Print("/kc threshold 30 - alert when the fight has ~30s left")
    Print("/kc mode blend|live|history - how the estimate is made")
    Print("/kc window 20 - seconds of HP data for the live trend")
    Print("/kc spell Death Wish - which cooldown to track")
    Print("/kc set 3:45 [Boss] - add a kill time by hand (e.g. from BigWigs)")
    Print("/kc bw [last|best|mid|off] - show / choose BigWigs kill times")
    Print("/kc import - copy BigWigs times into KillClock's own history")
    Print("/kc history | reset <Boss>|all | track | sound")
  end
end
