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
    CleanseSpells = {},
    LastManaNotify = 0,
    LastAnnounce = "",
}

-- Tables for dispelling logic (inspired by Rinse)
SimpleHeal.DispelSpells = {
    PALADIN = { 
        ["Magic"] = {"Cleanse"}, 
        ["Poison"] = {"Cleanse", "Purify"}, 
        ["Disease"] = {"Cleanse", "Purify"} 
    },
    DRUID   = { 
        ["Curse"] = {"Remove Curse"}, 
        ["Poison"] = {"Abolish Poison", "Cure Poison"} 
    },
    PRIEST  = { 
        ["Magic"] = {"Dispel Magic"}, 
        ["Disease"] = {"Abolish Disease", "Cure Disease"} 
    },
    SHAMAN  = { 
        ["Poison"] = {"Cure Poison"}, 
        ["Disease"] = {"Cure Disease"} 
    },
}

SimpleHeal.PendingHeals = {} -- { [guid] = timestamp }

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
        if SimpleHeal:CheckDependencies() then
            SimpleHeal:ScanSpells()
        else
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
    if SimpleHeal_Saved.EnableCleanse == nil then SimpleHeal_Saved.EnableCleanse = true end
    
    SimpleHeal.Ready = false
    SimpleHeal.Spells = {}
    SimpleHeal.CleanseSpells = {}
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
    SPELL SCANNING
================================================================ ]]

function SimpleHeal:ScanSpells()
    SimpleHeal.Spells = {}
    SimpleHeal.CleanseSpells = {}
    
    local _, class = UnitClass("player")
    local validClasses = {SHAMAN=1, PRIEST=1, PALADIN=1, DRUID=1}
    if not validClasses[class] then 
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r Player class " .. (class or "unknown") .. " not supported.")
        return 
    end
    
    local i = 1
    while true do
        local name, rank, _, _, maxR = SpellInfo(i)
        if not name then break end
        
        if SimpleHeal:IsHealingSpell(name, class) then
            local mana, minVal, maxVal = SimpleHeal:ParseSpellTooltip(i)
            if mana and minVal and maxVal then
                table.insert(SimpleHeal.Spells, {
                    id = i,
                    name = name,
                    rank = SimpleHeal:ExtractRank(rank),
                    mana = mana,
                    avg = (minVal + maxVal) / 2,
                    range = maxR or 40
                })
            end
        end

        local dispels = SimpleHeal.DispelSpells[class]
        if dispels then
            for dtype, dlist in pairs(dispels) do
                for _, dname in ipairs(dlist) do
                    if string.lower(name) == string.lower(dname) then
                        -- Store the first match Found (priority based on list order)
                        if not SimpleHeal.CleanseSpells[dtype] then
                            SimpleHeal.CleanseSpells[dtype] = name
                        end
                    end
                end
            end
        end
        
        i = i + 1
        if i > 512 then break end
    end
    
    table.sort(SimpleHeal.Spells, function(a,b) 
        if a.name ~= b.name then return a.name < b.name end
        return a.rank < b.rank 
    end)
    
    local total = table.getn(SimpleHeal.Spells)
    local hasCleanse = false
    for _ in pairs(SimpleHeal.CleanseSpells) do hasCleanse = true break end
    
    SimpleHeal.Ready = (total > 0 or hasCleanse)
    
    if SimpleHeal.Ready then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Scanned " .. total .. " healing spells.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No healing spells found in your spellbook!")
    end
end

function SimpleHeal:IsHealingSpell(name, class)
    local n = string.lower(name)
    if class == "SHAMAN" then
        return string.find(n, "healing wave") or string.find(n, "chain heal")
    elseif class == "PRIEST" then
        return string.find(n, "flash heal") or string.find(n, "greater heal") or n == "heal" or string.find(n, "lesser heal") or string.find(n, "prayer of healing") or string.find(n, "renew") or string.find(n, "power word: shield")
    elseif class == "PALADIN" then
        return string.find(n, "flash of light") or string.find(n, "holy light") or string.find(n, "holy shock")
    elseif class == "DRUID" then
        return string.find(n, "regrowth") or string.find(n, "healing touch") or string.find(n, "rejuvenation")
    end
    return false
end

function SimpleHeal:UnitHasBuff(unit, buffName)
    local i = 1
    local bname = string.lower(buffName)
    local tooltip = getglobal("SimpleHeal_Tooltip")
    while true do
        local name = UnitBuff(unit, i)
        if not name then break end
        
        tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        tooltip:ClearLines()
        tooltip:SetUnitBuff(unit, i)
        local text = getglobal("SimpleHeal_TooltipTextLeft1"):GetText()
        
        if text and string.find(string.lower(text), bname) then 
            tooltip:Hide()
            return true 
        end
        i = i + 1
    end
    tooltip:Hide()
    return false
end

function SimpleHeal:UnitHasDebuff(unit, debuffName)
    local i = 1
    local dname = string.lower(debuffName)
    local tooltip = getglobal("SimpleHeal_Tooltip")
    while true do
        local name = UnitDebuff(unit, i)
        if not name then break end
        
        tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        tooltip:ClearLines()
        tooltip:SetUnitDebuff(unit, i)
        local text = getglobal("SimpleHeal_TooltipTextLeft1"):GetText()
        
        if text and string.find(string.lower(text), dname) then 
            tooltip:Hide()
            return true 
        end
        i = i + 1
    end
    tooltip:Hide()
    return false
end

function SimpleHeal:GetDispellableDebuff(unit)
    if not SimpleHeal_Saved.EnableCleanse then return nil end
    local i = 1
    while true do
        local name, rank, texture, count, dtype = UnitDebuff(unit, i)
        if not name then break end
        if dtype and SimpleHeal.CleanseSpells[dtype] then
            return SimpleHeal.CleanseSpells[dtype]
        end
        i = i + 1
    end
    return nil
end

function SimpleHeal:ExtractRank(rankStr)
    if not rankStr then return 1 end
    local _, _, num = string.find(rankStr, "(%d+)")
    return tonumber(num) or 1
end

function SimpleHeal:ParseSpellTooltip(spellID)
    local tooltip = getglobal("SimpleHeal_Tooltip")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:ClearLines()
    tooltip:SetSpell(spellID, BOOKTYPE_SPELL)
    
    local mana, minHeal, maxHeal
    local line2 = getglobal("SimpleHeal_TooltipTextLeft2")
    if line2 then
        local text = line2:GetText()
        if text then
            local _, _, m = string.find(text, "(%d+) Mana")
            mana = tonumber(m)
        end
    end
    
    for j = 3, 8 do
        local line = getglobal("SimpleHeal_TooltipTextLeft" .. j)
        if line then
            local text = line:GetText()
            if text then
                local _, _, min = string.find(text, "(%d+) to")
                local _, _, max = string.find(text, "to (%d+)")
                if min and max then
                    minHeal = tonumber(min)
                    maxHeal = tonumber(max)
                    break
                end
                
                local _, _, hot = string.find(text, "Heals (%d+) over")
                if hot then
                    minHeal = tonumber(hot)
                    maxHeal = tonumber(hot)
                    break
                end

                local _, _, absorb = string.find(text, "absorbing (%d+) damage")
                if absorb then
                    minHeal = tonumber(absorb)
                    maxHeal = tonumber(absorb)
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
    
    if SimpleHeal_Saved.EnableCleanse and target.ratio > 0.70 then
        local cleanseSpell = SimpleHeal:GetDispellableDebuff(target.unit)
        if cleanseSpell then
            CastSpellByName(cleanseSpell, target.unit)
            SimpleHeal:Announce(target.name, cleanseSpell)
            return
        end
    end

    local deficit = target.max - target.current
    local spellList = SimpleHeal.Spells
    
    if table.getn(spellList) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No healing spells available!")
        return
    end
    
    local spell = SimpleHeal:PickBestRank(spellList, deficit, target.unit, isEmergency)
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
    if spell.rank then
        spellString = spellString .. "(Rank " .. spell.rank .. ")"
    end
    CastSpellByName(spellString, unit)
end

function SimpleHeal:FindBestTarget()
    local candidates = {}
    local threshold = (SimpleHeal_Saved and SimpleHeal_Saved.Threshold or 95) / 100
    
    SimpleHeal:AddCandidate(candidates, "player")
    local numParty = GetNumPartyMembers()
    if numParty > 0 then
        for i = 1, numParty do SimpleHeal:AddCandidate(candidates, "party" .. i) end
    end
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do SimpleHeal:AddCandidate(candidates, "raid" .. i) end
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
    local maxManaVal = UnitManaMax("player")
    local playerMana = (class == "DRUID" and casterMana) and casterMana or currentMana
    local playerMaxMana = maxManaVal or 1
    
    local mode = SimpleHeal_Saved and SimpleHeal_Saved.HealMode or 1
    if (playerMana / playerMaxMana) < 0.15 then
        mode = 1 -- Force Efficient
    end

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
    getglobal("SimpleHeal_ModeCleanseCheck"):SetChecked(s.EnableCleanse)
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
function SimpleHeal:ToggleCleanse() SimpleHeal_Saved.EnableCleanse = not SimpleHeal_Saved.EnableCleanse SimpleHeal:RefreshConfig() end
