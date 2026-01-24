--[[
    SimpleHeal - Auto-Target, Auto-Rank Healing Addon
    Vanilla WoW 1.12
    
    PRO CORE: Requires SuperWoW and UnitXP (SP3)
    
    Usage:
        /heal           - Smart heal (lowest HP target, best efficiency)
        /heal emergency - Emergency heal (highest HPS rank)
        /heal config    - Open configuration menu
        /heal scan      - Rescan spellbook for updated ranks
]]

SimpleHeal = {
    Ready = false,
    Spells = {},
    PendingHeals = {}, -- { [guid] = timestamp }
    LastManaNotify = 0,
    LastAnnounce = "",
}

function SimpleHeal:CheckDependencies()
    local missing = {}
    if not SUPERWOW_VERSION then table.insert(missing, "SuperWoW") end
    if type(UnitXP) ~= "function" then table.insert(missing, "UnitXP") end
    if type(SpellInfo) ~= "function" then table.insert(missing, "SpellInfo API") end
    
    if table.getn(missing) > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal] ERROR: Missing mandatory dependencies: " .. table.concat(missing, ", ") .. "|r")
        return false
    end
    return true
end

function SimpleHeal:OnLoad()
    this:RegisterEvent("ADDON_LOADED")
    this:RegisterEvent("PLAYER_ENTERING_WORLD")
    this:RegisterEvent("PLAYER_ALIVE")
    this:RegisterEvent("UNIT_MANA")
    this:RegisterEvent("UNIT_MAXMANA")
    this:RegisterEvent("SPELLS_CHANGED")
    
    SimpleHeal.Ready = false
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00SimpleHeal Loaded. Type /heal help for commands.|r")
end

function SimpleHeal:OnEvent(event)
    if event == "ADDON_LOADED" and arg1 == "SimpleHeal" then
        SimpleHeal:LoadSettings()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" then
        if not SimpleHeal:CheckDependencies() then
            SimpleHeal.Ready = false
        end
    elseif event == "UNIT_MANA" or event == "UNIT_MAXMANA" then
        if arg1 == "player" then SimpleHeal:CheckManaNotify() end
    end
end

function SimpleHeal:LoadSettings()
    if not SimpleHeal_Saved then SimpleHeal_Saved = {} end
    if SimpleHeal_Saved.MsgMode == nil then SimpleHeal_Saved.MsgMode = 2 end
    if SimpleHeal_Saved.HealMode == nil then SimpleHeal_Saved.HealMode = 1 end
    if SimpleHeal_Saved.Threshold == nil then SimpleHeal_Saved.Threshold = 95 end
    if SimpleHeal_Saved.EnableLowManaNotify == nil then SimpleHeal_Saved.EnableLowManaNotify = true end
    if SimpleHeal_Saved.LowManaThreshold == nil then SimpleHeal_Saved.LowManaThreshold = 20 end
    if SimpleHeal_Saved.UseLOS == nil then SimpleHeal_Saved.UseLOS = true end
    
    SimpleHeal.Spells = SimpleHeal_Saved.Spells or {}
    SimpleHeal.Ready = (table.getn(SimpleHeal.Spells) > 0)
    SimpleHeal.PendingHeals = {}
    SimpleHeal.LastManaNotify = 0
    SimpleHeal.LastAnnounce = ""
end

function SimpleHeal:Announce(targetName, spellName, rank)
    local mode = SimpleHeal_Saved.MsgMode
    if mode == 0 then return end
    
    local announceKey = targetName .. spellName .. (rank or "")
    if mode == 2 and SimpleHeal.LastAnnounce == announceKey then return end
    
    SimpleHeal.LastAnnounce = announceKey
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r " .. targetName .. " <- " .. spellName .. (rank and " R" .. rank or ""))
end

SLASH_SIMPLEHEAL1 = "/heal"
SlashCmdList["SIMPLEHEAL"] = function(msg) SimpleHeal.SlashHandler(msg) end

function SimpleHeal.SlashHandler(msg)
    msg = string.lower(msg or "")
    if msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal - Auto-heal")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal emergency - Emergency heal (HPS focus)")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal config - Options")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal scan - Manual spell scan")
    elseif msg == "scan" then
        SimpleHeal:ScanSpells()
    elseif msg == "config" then
        SimpleHeal:ToggleConfig()
    elseif msg == "emergency" then
        SimpleHeal:DoHeal(true)
    else
        SimpleHeal:DoHeal()
    end
end

--[[ ================================================================
    SPELL SCANNING (SUPERWOW BUILT-IN)
================================================================ ]]

local HealingSpells = {
    ["SHAMAN"] = { ["healing wave"] = true, ["chain heal"] = true, ["lesser healing wave"] = true },
    ["PRIEST"] = { ["flash heal"] = true, ["greater heal"] = true, ["heal"] = true, ["lesser heal"] = true, ["prayer of healing"] = true, ["renew"] = true, ["power word: shield"] = true },
    ["PALADIN"] = { ["flash of light"] = true, ["holy light"] = true, ["holy shock"] = true },
    ["DRUID"] = { ["regrowth"] = true, ["healing touch"] = true, ["rejuvenation"] = true },
}

function SimpleHeal:ScanSpells()
    SimpleHeal.Spells = {}
    
    local _, class = UnitClass("player")
    local classSpells = HealingSpells[class]
    if not classSpells then 
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r Error: Unsupported class " .. (class or "nil"))
        return 
    end
    
    -- Debug: Start scanning
    -- DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Scanning spellbook for " .. class .. "...")

    local totalSpells = 0
    local numTabs = GetNumSpellTabs()
    local _, _, offset, numSlots = GetSpellTabInfo(numTabs)
    local lastIndex = (offset or 0) + (numSlots or 0)
    if lastIndex == 0 then lastIndex = 300 end -- Fallback

    for i = 1, lastIndex do
        local name, rank, spellID = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        
        local lowName = string.lower(name)
        local isMatch = false
        
        -- Use partial match for safety with lookup
        for key, _ in pairs(classSpells) do
            if string.find(lowName, key) then
                isMatch = true
                break
            end
        end

        if isMatch then
            -- SuperWoW SpellInfo returns: name, rank, texture, minRange, maxRange
            local _, _, _, _, maxR = SpellInfo(spellID or 0)
            local mana, minVal, maxVal = SimpleHeal:ParseSpellTooltip(i)
            
            if mana and minVal and maxVal then
                table.insert(SimpleHeal.Spells, {
                    id = i,
                    spellID = spellID,
                    name = name,
                    rank = SimpleHeal:ExtractRank(rank),
                    mana = mana,
                    avg = (minVal + maxVal) / 2,
                    range = (type(maxR) == "number" and maxR > 0) and maxR or 40
                })
                totalSpells = totalSpells + 1
                -- DEFAULT_CHAT_FRAME:AddMessage("|cffddffdd[SimpleHeal]|r Found: " .. name .. " (Rank " .. SimpleHeal:ExtractRank(rank) .. ")")
            end
        end
    end
    
    table.sort(SimpleHeal.Spells, function(a,b) 
        if a.name ~= b.name then return a.name < b.name end
        return a.rank < b.rank 
    end)
    
    SimpleHeal_Saved.Spells = SimpleHeal.Spells
    SimpleHeal.Ready = (totalSpells > 0)
    
    if SimpleHeal.Ready then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Scanned " .. totalSpells .. " healing spells.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No healing spells found! Make sure you are a healer and have spells in your book.")
    end
end

function SimpleHeal:UnitHasBuff(unit, buffName)
    local bname = string.lower(buffName)
    local i = 1
    while true do
        local tex, _, _, auraID = UnitBuff(unit, i)
        if not tex then break end
        
        if auraID then
            local name = SpellInfo(auraID)
            if name and string.lower(name) == bname then return true end
        end
        i = i + 1
    end
    return false
end

function SimpleHeal:UnitHasDebuff(unit, debuffName)
    local dname = string.lower(debuffName)
    local i = 1
    while true do
        local tex, _, _, auraID = UnitDebuff(unit, i)
        if not tex then break end
        
        if auraID then
            local name = SpellInfo(auraID)
            if name and string.lower(name) == dname then return true end
        end
        i = i + 1
    end
    return false
end

function SimpleHeal:ExtractRank(rankStr)
    if not rankStr then return 1 end
    local _, _, num = string.find(tostring(rankStr), "(%d+)")
    return tonumber(num) or 1
end

function SimpleHeal:ParseSpellTooltip(spellID)
    local tooltip = getglobal("SimpleHeal_Tooltip")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:ClearLines()
    tooltip:SetSpell(spellID, BOOKTYPE_SPELL)
    
    local mana, minHeal, maxHeal
    local line = getglobal("SimpleHeal_TooltipTextLeft2")
    if line then
        local text = line:GetText()
        if text and string.find(text, "Mana") then
            local _, _, m = string.find(text, "(%d+) Mana")
            mana = tonumber(m)
        end
    end
    
    for j = 3, 10 do
        line = getglobal("SimpleHeal_TooltipTextLeft" .. j)
        if line then
            local text = line:GetText()
            if text then
                local _, _, min = string.find(text, "Heals.+ (%d+) to")
                local _, _, max = string.find(text, "to (%d+)")
                if not (min and max) then
                    _, _, min = string.find(text, "Heals (%d+)")
                    max = min
                end
                
                if not min then
                    _, _, min = string.find(text, "absorbing (%d+)")
                    max = min
                end

                if min then
                    minHeal, maxHeal = tonumber(min), tonumber(max)
                    break
                end
            end
        end
    end
    tooltip:Hide()
    return mana, minHeal, maxHeal
end

--[[ ================================================================
    HEALING LOGIC
================================================================ ]]

function SimpleHeal:DoHeal(isEmergency)
    if not SimpleHeal.Ready then
        if not SimpleHeal:CheckDependencies() then return end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No spells found. Use /heal scan")
        return
    end
    
    local target = SimpleHeal:FindBestTarget()
    if not target then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r No one needs healing.")
        return
    end
    
    local deficit = target.max - target.current
    local spell = SimpleHeal:PickBestRank(SimpleHeal.Spells, deficit, target.unit, isEmergency)
    
    if not spell then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r Not enough mana!")
        return
    end
    
    SimpleHeal:Cast(spell, target.unit)
    SimpleHeal:Announce(target.name, spell.name, spell.rank)
end

function SimpleHeal:Cast(spell, unit)
    local _, guid = UnitExists(unit)
    SimpleHeal.PendingHeals[guid or unit] = GetTime()
    local spellString = spell.name
    if spell.rank then spellString = spellString .. "(Rank " .. spell.rank .. ")" end
    CastSpellByName(spellString, unit)
end

function SimpleHeal:FindBestTarget()
    local candidates = {}
    local threshold = (SimpleHeal_Saved and SimpleHeal_Saved.Threshold or 95) / 100
    
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do SimpleHeal:AddCandidate(candidates, "raid" .. i) end
    else
        SimpleHeal:AddCandidate(candidates, "player")
        for i = 1, GetNumPartyMembers() do 
            SimpleHeal:AddCandidate(candidates, "party" .. i) 
        end
    end
    
    SimpleHeal:AddCandidate(candidates, "target")
    
    local best = nil
    for _, c in ipairs(candidates) do
        if c.ratio < threshold and SimpleHeal:CanReach(c.unit) then
            if not best or c.ratio < best.ratio then
                best = c
            end
        end
    end
    return best
end

function SimpleHeal:AddCandidate(list, unit)
    local exists, guid = UnitExists(unit)
    if not exists or UnitIsDeadOrGhost(unit) then return end
    if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
    if not UnitIsFriend("player", unit) then return end

    if guid then
        local lastTime = SimpleHeal.PendingHeals[guid]
        if lastTime and (GetTime() - lastTime < 1.5) then return end
        for _, c in ipairs(list) do
            if c.guid == guid then return end
        end
    end
    
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if max == 0 then return end
    
    table.insert(list, {
        unit = unit,
        guid = guid or unit,
        name = UnitName(unit),
        current = cur,
        max = max,
        ratio = cur / max
    })
end

function SimpleHeal:CanReach(unit)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return false end
    if UnitIsUnit(unit, "player") then return true end
    
    if SimpleHeal_Saved and SimpleHeal_Saved.UseLOS then
        local ok, los = pcall(UnitXP, "inSight", "player", unit)
        if not ok or not los then return false end
    end
    
    local dist = UnitXP("distanceBetween", "player", unit)
    if not dist then return false end

    local testSpell = SimpleHeal.Spells and SimpleHeal.Spells[1]
    local maxR = (testSpell and testSpell.range) and testSpell.range or 40
    return dist <= maxR
end

function SimpleHeal:PickBestRank(spellList, deficit, unit, isEmergency)
    local currentMana, casterMana = UnitMana("player")
    local _, class = UnitClass("player")
    local playerMana = (class == "DRUID" and casterMana) and casterMana or currentMana
    local playerMaxMana = UnitManaMax("player") or 1
    
    local mode = SimpleHeal_Saved and SimpleHeal_Saved.HealMode or 1
    if (playerMana / playerMaxMana) < 0.15 then mode = 1 end

    local affordable = {}
    for _, spell in ipairs(spellList) do
        local name = string.lower(spell.name)
        local isHot = string.find(name, "renew") or string.find(name, "rejuvenation")
        local isShield = string.find(name, "power word: shield")
        
        local skip = false
        if spell.mana > playerMana then
            skip = true
        elseif isHot and unit and SimpleHeal:UnitHasBuff(unit, spell.name) then
            skip = true
        elseif isShield then
            if unit and (SimpleHeal:UnitHasBuff(unit, "Power Word: Shield") or SimpleHeal:UnitHasDebuff(unit, "Weakened Soul")) then
                skip = true
            else
                local start, duration = GetSpellCooldown(spell.id, BOOKTYPE_SPELL)
                if start > 0 and duration > 1.5 then skip = true end
            end
        end
        if not skip then table.insert(affordable, spell) end
    end
    if table.getn(affordable) == 0 then return nil end
    
    table.sort(affordable, function(a,b) return a.rank < b.rank end)
    if isEmergency then return affordable[table.getn(affordable)] end

    if mode == 1 then -- Efficient
        local bestSpell, bestEfficiency = nil, -1
        for _, spell in ipairs(affordable) do
            local eff = math.min(spell.avg, deficit) / spell.mana
            if eff > bestEfficiency or (math.abs(eff - bestEfficiency) < 0.001 and spell.avg > (bestSpell and bestSpell.avg or 0)) then
                bestEfficiency = eff
                bestSpell = spell
            end
        end
        return bestSpell
    else -- Smart
        for _, spell in ipairs(affordable) do
            if spell.avg >= deficit then return spell end
        end
        return affordable[table.getn(affordable)]
    end
end

function SimpleHeal:CheckManaNotify()
    if not SimpleHeal_Saved or not SimpleHeal_Saved.EnableLowManaNotify then return end
    local _, class = UnitClass("player")
    local current, caster = UnitMana("player")
    local mana = (class == "DRUID" and caster) and caster or current
    local maxMana = UnitManaMax("player")
    
    if not maxMana or maxMana == 0 then return end
    local manaPercent = (mana / maxMana) * 100
    local now = GetTime()
    if manaPercent <= SimpleHeal_Saved.LowManaThreshold then
        if now - SimpleHeal.LastManaNotify >= 10 then
            DoEmote("OOM")
            SimpleHeal.LastManaNotify = now
        end
    end
end

function SimpleHeal:ShowTooltip(text)
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

function SimpleHeal:ToggleConfig()
    local frame = getglobal("SimpleHeal_ConfigFrame")
    if frame:IsVisible() then frame:Hide() else frame:Show() end
end

function SimpleHeal:RefreshConfig()
    if not SimpleHeal_Saved then SimpleHeal:LoadSettings() end
    local s = SimpleHeal_Saved
    getglobal("SimpleHeal_ModeEff"):SetText(s.HealMode == 1 and "|cff00ff00Eff|r" or "Eff")
    getglobal("SimpleHeal_ModeSmart"):SetText(s.HealMode == 2 and "|cff00ff00Smart|r" or "Smart")
    getglobal("SimpleHeal_ModeLOSCheck"):SetChecked(s.UseLOS)
    getglobal("SimpleHeal_MsgOff"):SetText(s.MsgMode == 0 and "|cff00ff00Off|r" or "Off")
    getglobal("SimpleHeal_MsgAll"):SetText(s.MsgMode == 1 and "|cff00ff00All|r" or "All")
    getglobal("SimpleHeal_MsgNew"):SetText(s.MsgMode == 2 and "|cff00ff00New|r" or "New")
    getglobal("SimpleHeal_ThreshSlider"):SetValue(s.Threshold)
    getglobal("SimpleHeal_ThreshSliderText"):SetText(s.Threshold .. "%")
    getglobal("SimpleHeal_LowManaCheck"):SetChecked(s.EnableLowManaNotify)
    getglobal("SimpleHeal_LowManaSlider"):SetValue(s.LowManaThreshold)
    getglobal("SimpleHeal_LowManaSliderText"):SetText(s.LowManaThreshold .. "%")
end

function SimpleHeal:SetHealMode(m) SimpleHeal_Saved.HealMode = m SimpleHeal:RefreshConfig() end
function SimpleHeal:ToggleLOS() SimpleHeal_Saved.UseLOS = not SimpleHeal_Saved.UseLOS SimpleHeal:RefreshConfig() end
function SimpleHeal:SetMsgMode(m) SimpleHeal_Saved.MsgMode = m SimpleHeal:RefreshConfig() end
function SimpleHeal:OnThresholdChange(v) SimpleHeal_Saved.Threshold = math.floor(v) getglobal("SimpleHeal_ThreshSliderText"):SetText(SimpleHeal_Saved.Threshold .. "%") end
function SimpleHeal:ToggleLowManaNotify() SimpleHeal_Saved.EnableLowManaNotify = not SimpleHeal_Saved.EnableLowManaNotify SimpleHeal:RefreshConfig() end
function SimpleHeal:OnLowManaThresholdChange(v) SimpleHeal_Saved.LowManaThreshold = math.floor(v) getglobal("SimpleHeal_LowManaSliderText"):SetText(SimpleHeal_Saved.LowManaThreshold .. "%") end
