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
    LastNoHealMessage = 0,
    LastManaMessage = 0,
    LastNoSpellsMessage = 0,
    DebugMode = false, -- Debug toggle
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
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not SimpleHeal:CheckDependencies() then
            SimpleHeal.Ready = false
        end
    elseif event == "SPELLS_CHANGED" then
        -- Don't auto-scan on spell changes - user must manually scan
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
    SimpleHeal.LastNoHealMessage = 0
    SimpleHeal.LastManaMessage = 0
    SimpleHeal.LastNoSpellsMessage = 0
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
        DEFAULT_CHAT_FRAME:AddMessage("  /heal debug - Toggle debug mode")
    elseif msg == "scan" then
        SimpleHeal:ScanSpells()
    elseif msg == "debug" then
        SimpleHeal.DebugMode = not SimpleHeal.DebugMode
        local status = SimpleHeal.DebugMode and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Debug mode: " .. status)
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
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r Scanning spellbook for " .. class .. "...")

    local totalSpells = 0
    local numTabs = GetNumSpellTabs()
    
    -- Use enhanced tab-based scanning with SuperWoW
    for tabIndex = 1, numTabs do
        local _, _, offset, numSlots = GetSpellTabInfo(tabIndex)
        if offset and numSlots then
            for i = offset + 1, offset + numSlots do
                if SimpleHeal:ProcessSpellSlot(i, classSpells) then
                    totalSpells = totalSpells + 1
                end
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
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No healing spells found! Check your spellbook.")
    end
end

function SimpleHeal:ProcessSpellSlot(slotIndex, classSpells)
    local name, rank, spellID = GetSpellName(slotIndex, BOOKTYPE_SPELL)
    if not name then return false end
    
    local lowName = string.lower(name)
    local isMatch = false
    
    -- Use partial match for safety with lookup
    for key, _ in pairs(classSpells) do
        if string.find(lowName, key, 1, true) then
            isMatch = true
            break
        end
    end

    if isMatch then
        local maxRange = 40 -- Default range
        local mana, minVal, maxVal
        
        -- Use SuperWoW SpellInfo for range and other data
        if SpellInfo and spellID and spellID > 0 then
            local sName, sRank, texture, minR, maxR = SpellInfo(spellID)
            if type(maxR) == "number" and maxR > 0 then
                maxRange = maxR
            end
        end
        
        -- Parse tooltip for exact mana and healing values
        mana, minVal, maxVal = SimpleHeal:ParseSpellTooltip(slotIndex)
        
        if mana and minVal and maxVal then
            table.insert(SimpleHeal.Spells, {
                id = slotIndex,
                spellID = spellID or slotIndex,
                name = name,
                rank = SimpleHeal:ExtractRank(rank),
                mana = mana,
                avg = (minVal + maxVal) / 2,
                range = maxRange
            })
            return true
        else
            -- Use enhanced estimation if tooltip parsing fails
            local estimatedMana = SimpleHeal:EstimateManaCost(name, SimpleHeal:ExtractRank(rank))
            local estimatedHeal = SimpleHeal:EstimateHealingAmount(name, SimpleHeal:ExtractRank(rank))
            
            if estimatedMana and estimatedHeal then
                table.insert(SimpleHeal.Spells, {
                    id = slotIndex,
                    spellID = spellID or slotIndex,
                    name = name,
                    rank = SimpleHeal:ExtractRank(rank),
                    mana = estimatedMana,
                    avg = estimatedHeal,
                    range = maxRange,
                    estimated = true
                })
                return true
            end
        end
    end
    return false
end

function SimpleHeal:UnitHasBuff(unit, buffName)
    local bname = string.lower(buffName)
    local i = 1
    while true do
        local tex, _, _, auraID = UnitBuff(unit, i)
        if not tex then break end
        
        -- Method 1: Try SuperWoW's enhanced UnitBuff with auraID
        if auraID then
            local name = SpellInfo(auraID)
            if name and string.lower(name) == bname then 
                if SimpleHeal.DebugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF]|r Found " .. buffName .. " via SpellInfo(" .. auraID .. ")")
                end
                return true 
            end
        end
        
        -- Method 2: Try GetPlayerBuffID if available (SuperWoW)
        if GetPlayerBuffID then
            local buffID = GetPlayerBuffID(i)
            if buffID then
                local name = SpellInfo(buffID)
                if name and string.lower(name) == bname then 
                    if SimpleHeal.DebugMode then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF]|r Found " .. buffName .. " via GetPlayerBuffID(" .. buffID .. ")")
                    end
                    return true 
                end
            end
        end
        
        -- Method 3: Fallback to texture name matching
        if tex then
            local textureName = string.lower(tex)
            if string.find(textureName, bname, 1, true) then
                if SimpleHeal.DebugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF]|r Found " .. buffName .. " via texture: " .. tex)
                end
                return true
            end
        end
        
        i = i + 1
    end
    
    if SimpleHeal.DebugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[BUFF]|r " .. buffName .. " NOT found on " .. unit)
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

function SimpleHeal:ParseSpellTooltip(spellID)
    local tooltip = getglobal("SimpleHeal_Tooltip")
    if not tooltip then return nil, nil, nil end
    
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    tooltip:ClearLines()
    
    local success = pcall(tooltip.SetSpell, tooltip, spellID, BOOKTYPE_SPELL)
    if not success then
        tooltip:Hide()
        return nil, nil, nil
    end
    
    local mana, minHeal, maxHeal
    
    -- Parse mana cost from line 2
    local line = getglobal("SimpleHeal_TooltipTextLeft2")
    if line then
        local text = line:GetText()
        if text then
            -- Debug: Show what we're trying to parse
            if SimpleHeal.DebugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TOOLTIP]|r Mana line: " .. text)
            end
            -- Try multiple mana patterns
            local _, _, m = string.find(text, "(%d+) Mana")
            if not m then
                _, _, m = string.find(text, "(%d+)%% of base mana")
            end
            if not m then
                _, _, m = string.find(text, "(%d+) to (%d+) Mana")
            end
            mana = tonumber(m)
            if SimpleHeal.DebugMode then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[TOOLTIP]|r Parsed mana: " .. tostring(mana))
            end
        end
    end
    
    -- Parse healing values from lines 3-10
    for j = 3, 10 do
        line = getglobal("SimpleHeal_TooltipTextLeft" .. j)
        if line then
            local text = line:GetText()
            if text then
                -- Try multiple healing patterns
                local _, _, min, max = string.find(text, "Heals for (%d+) to (%d+)")
                if not min then
                    _, _, min, max = string.find(text, "Heals (%d+) to (%d+)")
                end
                if not min then
                    _, _, min = string.find(text, "Heals for (%d+)")
                    max = min
                end
                if not min then
                    _, _, min = string.find(text, "Heals (%d+)")
                    max = min
                end
                if not min then
                    _, _, min, max = string.find(text, "absorbing (%d+) to (%d+) damage")
                end
                if not min then
                    _, _, min = string.find(text, "absorbing (%d+) damage")
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

function SimpleHeal:EstimateManaCost(spellName, rank)
    -- Basic mana cost estimation based on spell type and rank
    local lowName = string.lower(spellName)
    
    if string.find(lowName, "flash heal") then
        return 35 + (rank * 25)
    elseif string.find(lowName, "greater heal") then
        return 170 + (rank * 110)
    elseif string.find(lowName, "heal") then
        return 30 + (rank * 20)
    elseif string.find(lowName, "lesser heal") then
        return 25 + (rank * 15)
    elseif string.find(lowName, "prayer of healing") then
        return 400 + (rank * 200)
    elseif string.find(lowName, "renew") then
        return 15 + (rank * 10)
    elseif string.find(lowName, "power word: shield") then
        return 50 + (rank * 30)
    elseif string.find(lowName, "flash of light") then
        return 35 + (rank * 20)
    elseif string.find(lowName, "holy light") then
        return 35 + (rank * 25)
    elseif string.find(lowName, "holy shock") then
        return 60 + (rank * 40)
    elseif string.find(lowName, "healing touch") then
        return 55 + (rank * 35)
    elseif string.find(lowName, "regrowth") then
        return 80 + (rank * 50)
    elseif string.find(lowName, "rejuvenation") then
        return 25 + (rank * 15)
    elseif string.find(lowName, "healing wave") then
        return 25 + (rank * 20)
    elseif string.find(lowName, "lesser healing wave") then
        return 45 + (rank * 25)
    elseif string.find(lowName, "chain heal") then
        return 120 + (rank * 80)
    else
        return 100 -- Default estimate
    end
end

function SimpleHeal:EstimateHealingAmount(spellName, rank)
    -- Basic healing amount estimation based on spell type and rank
    local lowName = string.lower(spellName)
    
    if string.find(lowName, "flash heal") then
        return 200 + (rank * 150)
    elseif string.find(lowName, "greater heal") then
        return 500 + (rank * 400)
    elseif string.find(lowName, "heal") then
        return 100 + (rank * 80)
    elseif string.find(lowName, "lesser heal") then
        return 50 + (rank * 30)
    elseif string.find(lowName, "prayer of healing") then
        return 300 + (rank * 200)
    elseif string.find(lowName, "renew") then
        return 50 + (rank * 40)
    elseif string.find(lowName, "power word: shield") then
        return 100 + (rank * 80)
    elseif string.find(lowName, "flash of light") then
        return 150 + (rank * 100)
    elseif string.find(lowName, "holy light") then
        return 200 + (rank * 150)
    elseif string.find(lowName, "holy shock") then
        return 250 + (rank * 180)
    elseif string.find(lowName, "healing touch") then
        return 300 + (rank * 200)
    elseif string.find(lowName, "regrowth") then
        return 250 + (rank * 180)
    elseif string.find(lowName, "rejuvenation") then
        return 80 + (rank * 60)
    elseif string.find(lowName, "healing wave") then
        return 120 + (rank * 90)
    elseif string.find(lowName, "lesser healing wave") then
        return 180 + (rank * 120)
    elseif string.find(lowName, "chain heal") then
        return 350 + (rank * 250)
    else
        return 200 -- Default estimate
    end
end

function SimpleHeal:ExtractRank(rankStr)
    if not rankStr then return 1 end
    local _, _, num = string.find(tostring(rankStr), "(%d+)")
    return tonumber(num) or 1
end

--[[ ================================================================
    HEALING LOGIC
================================================================ ]]

function SimpleHeal:DoHeal(isEmergency)
    if not SimpleHeal.Ready then
        if not SimpleHeal:CheckDependencies() then return end
        local now = GetTime()
        if now - SimpleHeal.LastNoSpellsMessage > 30 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r No spells found. Use /heal scan")
            SimpleHeal.LastNoSpellsMessage = now
        end
        return
    end
    
    local target = SimpleHeal:FindBestTarget()
    if not target then
        local now = GetTime()
        if now - SimpleHeal.LastNoHealMessage > 10 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SimpleHeal]|r No one needs healing.")
            SimpleHeal.LastNoHealMessage = now
        end
        return
    end
    
    local deficit = target.max - target.current
    local spell = SimpleHeal:PickBestRank(SimpleHeal.Spells, deficit, target.unit, isEmergency)
    
    if not spell then
        local now = GetTime()
        if now - SimpleHeal.LastManaMessage > 10 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SimpleHeal]|r Not enough mana!")
            SimpleHeal.LastManaMessage = now
        end
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
    
    -- Use UnitXP LOS check if enabled
    if SimpleHeal_Saved and SimpleHeal_Saved.UseLOS then
        local los = UnitXP("inSight", "player", unit)
        if not los then return false end
    end
    
    local firstSpell = SimpleHeal.Spells and SimpleHeal.Spells[1]
    if not firstSpell then return false end

    -- Method 1: Use Nampower's enhanced range checking
    if IsSpellInRange then
        local inRange = IsSpellInRange(firstSpell.spellID, unit)
        if inRange == 1 then return true end
        if inRange == 0 then return false end
    end

    -- Method 2: Use UnitXP distance for precise measurement
    local dist = UnitXP("distanceBetween", "player", unit)
    if not dist then return false end

    local maxR = firstSpell.range or 40
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
        
        -- Use basic mana checking instead of Nampower APIs
        if spell.mana > playerMana then
            skip = true
        end
        
        -- Debug: Show spell usability info
        if SimpleHeal.DebugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[DEBUG]|r " .. spell.name .. " - Mana: " .. spell.mana .. "/" .. playerMana .. " - Skip: " .. tostring(skip))
        end

        if not skip then
            if isHot and unit then
                -- More specific HoT checking - only skip if the target already has THIS SPECIFIC HoT
                if SimpleHeal:UnitHasBuff(unit, spell.name) then
                    if SimpleHeal.DebugMode then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[HOT]|r Skipping " .. spell.name .. " - target already has this HoT")
                    end
                    skip = true
                end
            elseif isShield then
                if unit and (SimpleHeal:UnitHasBuff(unit, "Power Word: Shield") or SimpleHeal:UnitHasDebuff(unit, "Weakened Soul")) then
                    skip = true
                else
                    -- Use basic cooldown checking
                    local start, duration = GetSpellCooldown(spell.id, BOOKTYPE_SPELL)
                    if start and start > 0 and duration > 1.5 then skip = true end
                end
            end
        end
        if not skip then table.insert(affordable, spell) end
    end
    if table.getn(affordable) == 0 then 
        if SimpleHeal.DebugMode then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DEBUG]|r No affordable spells found!")
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DEBUG]|r Player mana: " .. playerMana .. "/" .. playerMaxMana)
            for _, spell in ipairs(spellList) do
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DEBUG]|r " .. spell.name .. " - Mana: " .. spell.mana .. ", Estimated: " .. tostring(spell.estimated or false))
            end
        end
        return nil 
    end
    
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
