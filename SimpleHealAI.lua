--[[
    SimpleHealAI - Auto-Target, Auto-Rank Healing Addon
    Vanilla WoW 1.12
    
    Supports: Shaman, Priest, Paladin, Druid
    
    Usage:
        /heal        - Smart heal (lowest HP target, best efficiency)
        /sheal       - (alias) Same as /heal
        /heal config - Open settings (Modes: Efficient/Smart, LOS Toggle)
        /heal help   - Show commands
]]

SimpleHealAI = {}
SimpleHealAI.Ready = false
SimpleHealAI.Spells = { Wave = {}, Lesser = {} }
SimpleHealAI.ExtendedAPI = nil -- nil = unchecked, true/false after check
SimpleHealAI.LastAnnounce = nil  -- For spam reduction
SimpleHealAI.LastManaNotify = 0  -- Time of last /oom emote

--[[ ================================================================
    SUPERWOW / EXTENDED API DETECTION
================================================================ ]]

function SimpleHealAI:HasExtendedAPI()
    if SimpleHealAI.ExtendedAPI ~= nil then return SimpleHealAI.ExtendedAPI end
    
    local hasIt = (SUPERWOW_VERSION ~= nil) or 
                  (type(UnitXP) == "function") or 
                  (type(UnitPosition) == "function") or
                  (type(SpellInfo) == "function")
    
    SimpleHealAI.ExtendedAPI = hasIt
    if hasIt then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Extended API (SuperWoW/UnitXP) detected.")
    end
    return hasIt
end

function SimpleHealAI:GetUnitDistance(unit)
    if not SimpleHealAI:HasExtendedAPI() then return nil end
    
    -- Try UnitXP first (most accurate, factors in combat reach)
    if type(UnitXP) == "function" then
        local ok, dist = pcall(function() return UnitXP(unit, "range") end)
        if ok and dist and type(dist) == "number" and dist < 500 then
            return dist
        end
    end
    
    -- Fallback to UnitPosition (manual 3D distance)
    if type(UnitPosition) == "function" then
        local x1, y1, z1 = UnitPosition("player")
        local x2, y2, z2 = UnitPosition(unit)
        if x1 and x2 then
            local dx, dy, dz = x1-x2, y1-y2, z1-z2
            return math.sqrt(dx*dx + dy*dy + dz*dz)
        end
    end
    return nil
end

function SimpleHealAI:IsInLineOfSight(unit)
    if not SimpleHealAI:HasExtendedAPI() then return nil end
    if type(UnitXP) ~= "function" then return nil end
    
    local ok, los = pcall(function() return UnitXP(unit, "los") end)
    if ok and los ~= nil then return los end
    return nil
end

--[[ ================================================================
    INITIALIZATION & SETTINGS
================================================================ ]]

function SimpleHealAI:OnLoad()
    SimpleHealAI_Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    SimpleHealAI_Frame:RegisterEvent("SPELLS_CHANGED")
    SimpleHealAI_Frame:RegisterEvent("VARIABLES_LOADED")
    SimpleHealAI_Frame:RegisterEvent("UNIT_MANA")
    SimpleHealAI_Frame:RegisterEvent("UNIT_MAXMANA")
    
    SlashCmdList["SIMPLEHEALAI"] = SimpleHealAI.SlashHandler
    SLASH_SIMPLEHEALAI1 = "/heal"
    SLASH_SIMPLEHEALAI2 = "/sheal"
    SLASH_SIMPLEHEALAI3 = "/healai"
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Loaded. /heal config for options.")
end

function SimpleHealAI:OnEvent(event)
    if event == "VARIABLES_LOADED" then
        SimpleHealAI:LoadSettings()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED" then
        SimpleHealAI:ScanSpells()
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
        SimpleHealAI:ScanSpells()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r Spell scanning complete.")
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
    SimpleHealAI.Spells = { Wave = {}, Lesser = {} }
    
    local _, class = UnitClass("player")
    local validClasses = {SHAMAN=1, PRIEST=1, PALADIN=1, DRUID=1}
    if not validClasses[class] then return end
    
    local hasSpellInfo = type(SpellInfo) == "function"
    local i = 1
    while true do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        
        local spellType = SimpleHealAI:GetSpellType(spellName, class)
        if spellType then
            local mana, minH, maxH, range
            
            if hasSpellInfo then
                local _, _, _, _, maxR = SpellInfo(i)
                range = (maxR and maxR > 0) and maxR or 40
                mana, minH, maxH = SimpleHealAI:ParseSpellTooltip(i)
            else
                mana, minH, maxH = SimpleHealAI:ParseSpellTooltip(i)
                range = 40
            end

            local rankNum = SimpleHealAI:ExtractRank(spellRank)
            
            if mana and minH and maxH then
                local avgHeal = (minH + maxH) / 2
                table.insert(SimpleHealAI.Spells[spellType], {
                    id = i, name = spellName, rank = rankNum, mana = mana,
                    avg = avgHeal, min = minH, max = maxH, 
                    hpm = avgHeal / mana, range = range
                })
            end
        end
        i = i + 1
    end
    
    table.sort(SimpleHealAI.Spells.Wave, function(a,b) return a.rank < b.rank end)
    table.sort(SimpleHealAI.Spells.Lesser, function(a,b) return a.rank < b.rank end)
    
    local total = table.getn(SimpleHealAI.Spells.Wave) + table.getn(SimpleHealAI.Spells.Lesser)
    SimpleHealAI.Ready = (total > 0)
end

function SimpleHealAI:GetSpellType(name, class)
    local n = string.lower(name)
    if class == "SHAMAN" then
        if string.find(n, "lesser healing wave") then return "Lesser" end
        if string.find(n, "chain heal") then return "Lesser" end 
        if string.find(n, "healing wave") then return "Wave" end
    elseif class == "PRIEST" then
        if string.find(n, "flash heal") then return "Lesser" end
        if string.find(n, "greater heal") or n == "heal" or string.find(n, "lesser heal") then return "Wave" end
    elseif class == "PALADIN" then
        if string.find(n, "flash of light") then return "Lesser" end
        if string.find(n, "holy light") then return "Wave" end
        if string.find(n, "holy shock") then return "Lesser" end
    elseif class == "DRUID" then
        if string.find(n, "regrowth") then return "Lesser" end
        if string.find(n, "healing touch") then return "Wave" end
    end
    return nil
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
                local _, _, min = string.find(text, "(%d+) to")
                local _, _, max = string.find(text, "to (%d+)")
                if min and max then
                    minHeal = tonumber(min)
                    maxHeal = tonumber(max)
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
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No spells found. Use /heal scan")
        return
    end
    
    local target = SimpleHealAI:FindBestTarget()
    if not target then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHealAI]|r No one needs healing.")
        return
    end
    
    local deficit = target.max - target.current
    local spellList = SimpleHealAI.Spells.Wave
    if table.getn(spellList) == 0 then spellList = SimpleHealAI.Spells.Lesser end
    
    if table.getn(spellList) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r No healing spells available!")
        return
    end
    
    local spell = SimpleHealAI:PickBestRank(spellList, deficit)
    if not spell then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHealAI]|r Not enough mana!")
        return
    end
    
    SimpleHealAI:Cast(spell, target.unit)
    SimpleHealAI:Announce(target.name, spell.name, spell.rank)
end

function SimpleHealAI:CheckManaNotify()
    if not SimpleHealAI_Saved or not SimpleHealAI_Saved.EnableLowManaNotify then return end
    
    local _, class = UnitClass("player")
    local mana, maxMana

    if class == "DRUID" then
        local _, casterMana = UnitMana("player")
        local _, casterMaxMana = UnitManaMax("player")
        mana = casterMana
        maxMana = casterMaxMana
    else
        mana = UnitMana("player")
        maxMana = UnitManaMax("player")
    end

    if not maxMana or maxMana == 0 then return end
    
    local manaPercent = (mana / maxMana) * 100
    local now = GetTime()
    
    if manaPercent <= SimpleHealAI_Saved.LowManaThreshold then
        -- 10s frequency limit to prevent spam
        if now - SimpleHealAI.LastManaNotify >= 10 then
            DoEmote("OOM")
            SimpleHealAI.LastManaNotify = now
        end
    end
end

function SimpleHealAI:Cast(spell, unit)
    if (SUPERWOW_VERSION or type(CastSpellByName) == "function") and unit then
        CastSpellByName(spell.name .. (spell.rank and "(Rank " .. spell.rank .. ")" or ""), unit)
    else
        local hadTarget = UnitExists("target")
        local savedTarget = hadTarget and SimpleHealAI:GetTargetInfo() or nil
        TargetUnit(unit)
        CastSpell(spell.id, BOOKTYPE_SPELL)
        if hadTarget and savedTarget then
            SimpleHealAI:RestoreTarget(savedTarget)
        elseif not hadTarget then
            ClearTarget()
        end
    end
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
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return end
    if UnitIsPlayer(unit) and not UnitIsConnected(unit) then return end
    if not UnitIsFriend("player", unit) then return end

    for _, c in ipairs(list) do
        if UnitIsUnit(c.unit, unit) then return end
    end
    
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if max == 0 then return end
    
    table.insert(list, {
        unit = unit,
        name = UnitName(unit),
        current = cur,
        max = max,
        ratio = cur / max
    })
end

function SimpleHealAI:CanReach(unit)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return false end
    if UnitIsUnit(unit, "player") then return true end
    
    -- 1. Try Extended API distance
    local dist = SimpleHealAI:GetUnitDistance(unit)
    
    -- 2. LOS Check
    if SimpleHealAI_Saved and SimpleHealAI_Saved.UseLOS then
        if SimpleHealAI:IsInLineOfSight(unit) == false then return false end
    end
    
    -- 3. Range Verification
    local testSpell = nil
    if SimpleHealAI.Spells.Wave[1] then testSpell = SimpleHealAI.Spells.Wave[1]
    elseif SimpleHealAI.Spells.Lesser[1] then testSpell = SimpleHealAI.Spells.Lesser[1] end
    
    if dist then
        local maxR = (testSpell and testSpell.range) and testSpell.range or 40
        if dist > maxR then return false end
    end
    
    if testSpell and IsSpellInRange then
        if IsSpellInRange(testSpell.id, BOOKTYPE_SPELL, unit) == 0 then
            return false
        end
    elseif not dist then
        if not CheckInteractDistance(unit, 4) then
            return false
        end
    end

    return true
end

function SimpleHealAI:PickBestRank(spellList, deficit)
    local power, mana = UnitMana("player")
    local _, class = UnitClass("player")
    local playerMana = (class == "DRUID" and mana) and mana or power
    local mode = SimpleHealAI_Saved and SimpleHealAI_Saved.HealMode or 1
    
    local affordable = {}
    for _, spell in ipairs(spellList) do
        if spell.mana <= playerMana then table.insert(affordable, spell) end
    end
    if table.getn(affordable) == 0 then return nil end
    
    table.sort(affordable, function(a,b) return a.rank < b.rank end)
    
    if mode == 1 then -- Efficient
        local bestSpell, bestEfficiency = nil, -1
        for _, spell in ipairs(affordable) do
            local eff = math.min(spell.avg, deficit) / spell.mana
            if eff >= bestEfficiency then
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
    TARGET UTILITIES
================================================================ ]]

function SimpleHealAI:GetTargetInfo()
    if not UnitExists("target") then return nil end
    local info = { name = UnitName("target"), unit = nil }
    if UnitIsUnit("target", "player") then
        info.unit = "player"
    elseif UnitInParty("target") then
        for i = 1, GetNumPartyMembers() do
            if UnitIsUnit("target", "party" .. i) then info.unit = "party" .. i break end
        end
    elseif UnitInRaid("target") then
        for i = 1, GetNumRaidMembers() do
            if UnitIsUnit("target", "raid" .. i) then info.unit = "raid" .. i break end
        end
    end
    return info
end

function SimpleHealAI:RestoreTarget(info)
    if not info then return end
    if info.unit and UnitExists(info.unit) then
        TargetUnit(info.unit)
    elseif info.name then
        TargetByName(info.name)
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
