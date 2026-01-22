--[[
    SimpleHealAI - Auto-Target, Auto-Rank Healing Addon
    Vanilla WoW 1.12
    
    PRO CORE: Requires SuperWoW and UnitXP (SP3)
    
    Usage:
        /heal        - Smart heal (lowest HP target, best efficiency)
        /sheal       - (alias) Same as /heal
        /heal config - Open settings (Modes: Efficient/Smart, LOS Toggle)
        /heal help   - Show commands
]]

SimpleHealAI = {}
SimpleHealAI.Ready = false
SimpleHealAI.Spells = {}
SimpleHealAI.LastAnnounce = nil
SimpleHealAI.LastManaNotify = 0

--[[ ================================================================
    DEPENDENCY CHECK
================================================================ ]]

function SimpleHealAI:CheckDependencies()
    local hasSuperWoW = (type(CastSpellByName) == "function")
    local hasUnitXP = (type(UnitXP) == "function") and pcall(UnitXP, "nop", "nop")
    local hasSpellInfo = (type(SpellInfo) == "function")
    
    if hasSuperWoW and hasUnitXP and hasSpellInfo then
        return true
    end
    
    local missing = {}
    if not hasSuperWoW then table.insert(missing, "SuperWoW") end
    if not hasUnitXP then table.insert(missing, "UnitXP (SP3)") end
    if not hasSpellInfo then table.insert(missing, "SpellInfo API") end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI] ERROR: Missing mandatory dependencies: " .. table.concat(missing, ", ") .. "|r")
    return false
end

function SimpleHealAI:GetUnitDistance(unit)
    return UnitXP("distanceBetween", "player", unit)
end

function SimpleHealAI:IsInLineOfSight(unit)
    local ok, los = pcall(UnitXP, "inSight", "player", unit)
    return ok and los
end

--[[ ================================================================
    INITIALIZATION & SETTINGS
================================================================ ]]

function SimpleHealAI:OnLoad()
    SimpleHealAI_Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    SimpleHealAI_Frame:RegisterEvent("VARIABLES_LOADED")
    SimpleHealAI_Frame:RegisterEvent("UNIT_MANA")
    SimpleHealAI_Frame:RegisterEvent("UNIT_MAXMANA")
    
    SlashCmdList["SIMPLEHEALAI"] = SimpleHealAI.SlashHandler
    SLASH_SIMPLEHEALAI1 = "/heal"
    SLASH_SIMPLEHEALAI2 = "/sheal"
    SLASH_SIMPLEHEALAI3 = "/healai"
    
    if SimpleHealAI:CheckDependencies() then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Loaded. Direct Casting & XP3 Range active.")
    end
end

function SimpleHealAI:OnEvent(event)
    if event == "VARIABLES_LOADED" then
        SimpleHealAI:LoadSettings()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if SimpleHealAI:CheckDependencies() then
            SimpleHealAI:ScanSpells()
        else
            SimpleHealAI.Ready = false
        end
    elseif event == "UNIT_MANA" or event == "UNIT_MAXMANA" then
        if arg1 == "player" then SimpleHealAI:CheckManaNotify() end
    end
end

function SimpleHealAI:LoadSettings()
    if not SimpleHealAI_Saved then SimpleHealAI_Saved = {} end
    if SimpleHealAI_Saved.MsgMode == nil then SimpleHealAI_Saved.MsgMode = 2 end
    if SimpleHealAI_Saved.Threshold == nil then SimpleHealAI_Saved.Threshold = 90 end
    if SimpleHealAI_Saved.HealMode == nil then SimpleHealAI_Saved.HealMode = 1 end
    if SimpleHealAI_Saved.UseLOS == nil then SimpleHealAI_Saved.UseLOS = true end
    if SimpleHealAI_Saved.LowManaThreshold == nil then SimpleHealAI_Saved.LowManaThreshold = 30 end
    if SimpleHealAI_Saved.EnableLowManaNotify == nil then SimpleHealAI_Saved.EnableLowManaNotify = true end
end

function SimpleHealAI:Announce(targetName, spellName, rank)
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.MsgMode or 2
    if mode == 0 then return end
    
    local announceKey = targetName .. "_" .. (rank or "0")
    if mode == 2 and announceKey == SimpleHealAI.LastAnnounce then return end
    
    SimpleHealAI.LastAnnounce = announceKey
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r " .. targetName .. " <- " .. spellName .. (rank and " R" .. rank or ""))
end

function SimpleHealAI.SlashHandler(msg)
    msg = string.lower(msg or "")
    if msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal - Auto-heal")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal config - Settings")
        DEFAULT_CHAT_FRAME:AddMessage("  /heal scan - Manual spell scan")
    elseif msg == "scan" then
        if SimpleHealAI:CheckDependencies() then
            SimpleHealAI:ScanSpells()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Spell scanning complete.")
        end
    elseif msg == "config" or msg == "options" then
        SimpleHealAI:ToggleConfig()
    else
        SimpleHealAI:DoHeal()
    end
end

--[[ ================================================================
    SPELL SCANNING
================================================================ ]]

function SimpleHealAI:ScanSpells()
    SimpleHealAI.Spells = {}
    
    local _, class = UnitClass("player")
    local validClasses = {SHAMAN=1, PRIEST=1, PALADIN=1, DRUID=1}
    if not validClasses[class] then return end
    
    local i = 1
    while true do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        if SimpleHealAI:IsHealingSpell(spellName, class) then
            local _, _, _, _, maxR = SpellInfo(i)
            local range = (maxR and type(maxR) == "number" and maxR > 0) and maxR or 40
            local mana, minH, maxH = SimpleHealAI:ParseSpellTooltip(i)

            local rankNum = SimpleHealAI:ExtractRank(spellRank)
            
            if mana and minH and maxH then
                local avgHeal = (minH + maxH) / 2
                table.insert(SimpleHealAI.Spells, {
                    id = i, name = spellName, rank = rankNum, mana = mana,
                    avg = avgHeal, min = minH, max = maxH, 
                    hpm = avgHeal / mana, range = range
                })
            end
        end
        i = i + 1
    end
    
    table.sort(SimpleHealAI.Spells, function(a,b) 
        if a.name ~= b.name then return a.name < b.name end
        return a.rank < b.rank 
    end)
    
    local total = table.getn(SimpleHealAI.Spells)
    SimpleHealAI.Ready = (total > 0)
    
    if SimpleHealAI.Ready then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Scanned " .. total .. " spells.")
    end
end

function SimpleHealAI:IsHealingSpell(name, class)
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

function SimpleHealAI:UnitHasBuff(unit, buffName)
    local i = 1
    while true do
        if not UnitBuff(unit, i) then break end
        SimpleHealAI_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        SimpleHealAI_Tooltip:ClearLines()
        SimpleHealAI_Tooltip:SetUnitBuff(unit, i)
        local text = SimpleHealAI_TooltipTextLeft1:GetText()
        
        if text and string.find(string.lower(text), string.lower(buffName)) then 
            SimpleHealAI_Tooltip:Hide()
            return true 
        end
        i = i + 1
    end
    SimpleHealAI_Tooltip:Hide()
    return false
end

function SimpleHealAI:UnitHasDebuff(unit, debuffName)
    local i = 1
    while true do
        if not UnitDebuff(unit, i) then break end
        SimpleHealAI_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
        SimpleHealAI_Tooltip:ClearLines()
        SimpleHealAI_Tooltip:SetUnitDebuff(unit, i)
        local text = SimpleHealAI_TooltipTextLeft1:GetText()
        
        if text and string.find(string.lower(text), string.lower(debuffName)) then 
            SimpleHealAI_Tooltip:Hide()
            return true 
        end
        i = i + 1
    end
    SimpleHealAI_Tooltip:Hide()
    return false
end

function SimpleHealAI:ExtractRank(rankStr)
    if not rankStr then return 1 end
    local _, _, num = string.find(rankStr, "(%d+)")
    return tonumber(num) or 1
end

function SimpleHealAI:ParseSpellTooltip(spellID)
    SimpleHealAI_Tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    SimpleHealAI_Tooltip:ClearLines()
    SimpleHealAI_Tooltip:SetSpell(spellID, BOOKTYPE_SPELL)
    
    local mana, minHeal, maxHeal
    local line2 = SimpleHealAI_TooltipTextLeft2
    if line2 then
        local text = line2:GetText()
        if text then
            local _, _, m = string.find(text, "(%d+) Mana")
            mana = tonumber(m)
        end
    end
    
    for j = 3, 8 do
        local line = getglobal("SimpleHealAI_TooltipTextLeft" .. j)
        if line then
            local text = line:GetText()
            if text then
                -- Standard Heal: "Heals X to Y"
                local _, _, min = string.find(text, "(%d+) to")
                local _, _, max = string.find(text, "to (%d+)")
                if min and max then
                    minHeal = tonumber(min)
                    maxHeal = tonumber(max)
                    break
                end
                
                -- HoT: "Heals X over Y sec"
                local _, _, hot = string.find(text, "Heals (%d+) over")
                if hot then
                    minHeal = tonumber(hot)
                    maxHeal = tonumber(hot)
                    break
                end

                -- Shield: "absorbing X damage"
                local _, _, absorb = string.find(text, "absorbing (%d+) damage")
                if absorb then
                    minHeal = tonumber(absorb)
                    maxHeal = tonumber(absorb)
                    break
                end
            end
        end
    end
    
    SimpleHealAI_Tooltip:Hide()
    return mana, minHeal, maxHeal
end

--[[ ================================================================
    HEALING LOGIC
================================================================ ]]

function SimpleHealAI:DoHeal()
    if not SimpleHealAI.Ready then
        if not SimpleHealAI:CheckDependencies() then return end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No spells found. Use /heal scan")
        return
    end
    
    local target = SimpleHealAI:FindBestTarget()
    if not target then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r No one needs healing.")
        return
    end
    
    local deficit = target.max - target.current
    local spellList = SimpleHealAI.Spells
    
    if table.getn(spellList) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No healing spells available!")
        return
    end
    
    local spell = SimpleHealAI:PickBestRank(spellList, deficit, target.unit)
    if not spell then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r Not enough mana!")
        return
    end
    
    SimpleHealAI:Cast(spell, target.unit)
    SimpleHealAI:Announce(target.name, spell.name, spell.rank)
end

function SimpleHealAI:Cast(spell, unit)
    local spellString = spell.name
    if spell.rank then
        spellString = spellString .. "(Rank " .. spell.rank .. ")"
    end
    CastSpellByName(spellString, unit)
end

function SimpleHealAI:FindBestTarget()
    local candidates = {}
    local threshold = (SimpleHealAI_Saved and SimpleHealAI_Saved.Threshold or 90) / 100
    
    SimpleHealAI:AddCandidate(candidates, "player")
    local numParty = GetNumPartyMembers()
    if numParty > 0 then
        for i = 1, numParty do SimpleHealAI:AddCandidate(candidates, "party" .. i) end
    end
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do SimpleHealAI:AddCandidate(candidates, "raid" .. i) end
    end
    
    -- Always check target for non-group healing
    SimpleHealAI:AddCandidate(candidates, "target")
    
    local best = nil
    for _, c in ipairs(candidates) do
        if c.ratio < threshold and SimpleHealAI:CanReach(c.unit) then
            if not best or c.ratio < best.ratio then
                best = c
            end
        end
    end
    return best
end

function SimpleHealAI:AddCandidate(list, unit)
    local exists, guid = UnitExists(unit)
    if not exists or UnitIsDeadOrGhost(unit) then return end
    if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
    if not UnitIsFriend("player", unit) then return end

    -- SuperWoW returns GUID as second value; dedupe by GUID if available
    if guid then
        for _, c in ipairs(list) do
            if c.guid == guid then return end
        end
    end
    
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if max == 0 then return end
    
    table.insert(list, {
        unit = unit,
        guid = guid or unit,  -- fallback to unit ID if no GUID
        name = UnitName(unit),
        current = cur,
        max = max,
        ratio = cur / max
    })
end

function SimpleHealAI:CanReach(unit)
    local exists = UnitExists(unit)
    if not exists or UnitIsDeadOrGhost(unit) then return false end
    if UnitIsUnit(unit, "player") then return true end
    
    if SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS then
        if not SimpleHealAI:IsInLineOfSight(unit) then return false end
    end
    
    local dist = SimpleHealAI:GetUnitDistance(unit)
    if not dist then return false end

    local testSpell = SimpleHealAI.Spells[1]
    
    local maxR = (testSpell and testSpell.range) and testSpell.range or 40
    return dist <= maxR
end

function SimpleHealAI:PickBestRank(spellList, deficit, unit)
    local currentMana, casterMana = UnitMana("player")
    local _, class = UnitClass("player")
    local playerMana = (class == "DRUID" and casterMana) and casterMana or currentMana
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    
    local affordable = {}
    for _, spell in ipairs(spellList) do
        local name = string.lower(spell.name)
        local isHot = string.find(name, "renew") or string.find(name, "rejuvenation")
        local isShield = string.find(name, "power word: shield")
        
        local skip = false
        if spell.mana > playerMana then
            skip = true
        elseif isHot and unit and SimpleHealAI:UnitHasBuff(unit, spell.name) then
            skip = true
        elseif isShield then
            -- Check for active shield or Weakened Soul debuff
            if unit and (SimpleHealAI:UnitHasBuff(unit, "Power Word: Shield") or SimpleHealAI:UnitHasDebuff(unit, "Weakened Soul")) then
                skip = true
            else
                -- Check spell cooldown
                local start, duration = GetSpellCooldown(spell.id, BOOKTYPE_SPELL)
                if start > 0 and duration > 1.5 then
                    skip = true
                end
            end
        end
        
        if not skip then 
            table.insert(affordable, spell) 
        end
    end
    if table.getn(affordable) == 0 then return nil end
    
    table.sort(affordable, function(a,b) return a.rank < b.rank end)
    
    if mode == 1 then -- Efficient
        local bestSpell, bestEfficiency = nil, -1
        for _, spell in ipairs(affordable) do
            local eff = math.min(spell.avg, deficit) / spell.mana
            -- If efficiencies are equal, pick the one that heals more (closer to deficit)
            if eff > bestEfficiency or (math.abs(eff - bestEfficiency) < 0.001 and spell.avg > (bestSpell and bestSpell.avg or 0)) then
                bestEfficiency = eff
                bestSpell = spell
            end
        end
        return bestSpell
    else -- Smart (smallest rank covering deficit)
        for _, spell in ipairs(affordable) do
            if spell.avg >= deficit then return spell end
        end
        return affordable[table.getn(affordable)]
    end
end

--[[ ================================================================
    MANA NOTIFY
================================================================ ]]

function SimpleHealAI:CheckManaNotify()
    if not SimpleHealAI_Saved or not SimpleHealAI_Saved.EnableLowManaNotify then return end
    
    local _, class = UnitClass("player")
    local mana, maxMana

    if class == "DRUID" then
        -- SuperWoW: UnitMana returns (formPower, casterMana) for druids
        local _, casterMana = UnitMana("player")
        local maxManaVal = UnitManaMax("player")
        -- For druids in form, casterMana is the real mana pool
        mana = casterMana or UnitMana("player")
        maxMana = maxManaVal
    else
        mana = UnitMana("player")
        maxMana = UnitManaMax("player")
    end

    if not maxMana or maxMana == 0 then return end
    
    local manaPercent = (mana / maxMana) * 100
    local now = GetTime()
    
    if manaPercent <= SimpleHealAI_Saved.LowManaThreshold then
        if now - SimpleHealAI.LastManaNotify >= 10 then
            DoEmote("OOM")
            SimpleHealAI.LastManaNotify = now
        end
    end
end

--[[ ================================================================
    UI / TAB LOGIC
================================================================ ]]

function SimpleHealAI:ShowTooltip(text)
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

function SimpleHealAI:ToggleConfig()
    if SimpleHealAI_ConfigFrame:IsVisible() then 
        SimpleHealAI_ConfigFrame:Hide() 
    else 
        SimpleHealAI_ConfigFrame:Show() 
    end
end

function SimpleHealAI:RefreshConfig()
    if not SimpleHealAI_Saved then SimpleHealAI:LoadSettings() end
    local msgMode = SimpleHealAI_Saved.MsgMode
    local healMode = SimpleHealAI_Saved.HealMode
    local thresh = SimpleHealAI_Saved.Threshold
    local useLOS = SimpleHealAI_Saved.UseLOS
    
    SimpleHealAI_ModeEff:SetText(healMode == 1 and "|cff00ff00Eff|r" or "Eff")
    SimpleHealAI_ModeSmart:SetText(healMode == 2 and "|cff00ff00Smart|r" or "Smart")
    SimpleHealAI_ModeLOSCheck:SetChecked(useLOS)
    
    SimpleHealAI_MsgOff:SetText(msgMode == 0 and "|cff00ff00Off|r" or "Off")
    SimpleHealAI_MsgAll:SetText(msgMode == 1 and "|cff00ff00All|r" or "All")
    SimpleHealAI_MsgNew:SetText(msgMode == 2 and "|cff00ff00New|r" or "New")
    
    SimpleHealAI_ThreshSlider:SetValue(thresh)
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(thresh .. "%")
    
    SimpleHealAI_LowManaCheck:SetChecked(SimpleHealAI_Saved.EnableLowManaNotify)
    SimpleHealAI_LowManaSlider:SetValue(SimpleHealAI_Saved.LowManaThreshold)
    getglobal("SimpleHealAI_LowManaSliderText"):SetText(SimpleHealAI_Saved.LowManaThreshold .. "%")
end

function SimpleHealAI:SetHealMode(mode)
    SimpleHealAI_Saved.HealMode = mode
    SimpleHealAI:RefreshConfig()
end

function SimpleHealAI:ToggleLOS()
    SimpleHealAI_Saved.UseLOS = not SimpleHealAI_Saved.UseLOS
    SimpleHealAI:RefreshConfig()
end

function SimpleHealAI:SetMsgMode(mode)
    SimpleHealAI_Saved.MsgMode = mode
    SimpleHealAI:RefreshConfig()
end

function SimpleHealAI:OnThresholdChange(val)
    if not SimpleHealAI_Saved then return end
    val = math.floor(val)
    SimpleHealAI_Saved.Threshold = val
    getglobal("SimpleHealAI_ThreshSliderText"):SetText(val .. "%")
end

function SimpleHealAI:ToggleLowManaNotify()
    SimpleHealAI_Saved.EnableLowManaNotify = not SimpleHealAI_Saved.EnableLowManaNotify
    SimpleHealAI:RefreshConfig()
end

function SimpleHealAI:OnLowManaThresholdChange(val)
    if not SimpleHealAI_Saved then return end
    val = math.floor(val)
    SimpleHealAI_Saved.LowManaThreshold = val
    getglobal("SimpleHealAI_LowManaSliderText"):SetText(val .. "%")
end