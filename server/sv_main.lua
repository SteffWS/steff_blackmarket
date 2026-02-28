--[[
    steff_blackmarket - Server Logic (enhanced and patched)

    This version of the server script includes a fix for the previously
    reported issue where paying via bank could be abused if a player was not
    carrying a phone. The default payment type has been switched to 'cash'
    (configured in Config.DefaultPaymentType). If you choose to re‑enable
    bank payments, the server now checks that the player has a phone item
    (see Config.RequirePhoneForBank and Config.PhoneItemNames) before
    withdrawing funds from the bank.
]]

-- Resource Name Guard
if GetCurrentResourceName() ~= 'steff_blackmarket' then
    print('^1[steff_blackmarket] Incorrect resource name. Stopping server.')
    StopResource(GetCurrentResourceName())
    return
end

local QBCore = exports['qb-core']:GetCoreObject()
local cfg    = Config
local lastOrder  = {}
local activeDrops = {}

-- Load locale from file if configured
do
    if cfg.LocalesFolder and cfg.Locale then
        local path = ('%s/%s.lua'):format(cfg.LocalesFolder, cfg.Locale)
        local contents = LoadResourceFile(GetCurrentResourceName(), path)
        if contents then
            local func, err = load(contents, '@' .. path)
            if func then
                local ok, localeTbl = pcall(func)
                if ok and type(localeTbl) == 'table' then
                    cfg.Locales = cfg.Locales or {}
                    cfg.Locales[cfg.Locale] = localeTbl
                else
                    print(('Locale file %s did not return a table'):format(path))
                end
            else
                print(('Failed to load locale file %s: %s'):format(path, err))
            end
        end
    end
end

---Fetch a translated string from the Config.Locales table.
---@param key string The localisation key
---@param ... any Arguments used to format the string
---@return string
local function L(key, ...)
    local locale = cfg.Locale or 'en'
    local locales = cfg.Locales or {}
    local langTbl = locales[locale] or {}
    local str = langTbl[key] or key
    if select('#', ...) > 0 then
        return string.format(str, ...)
    end
    return str
end

---Give an item to a player. Respects the configured inventory backend.
---@param src number Player server ID
---@param item string Item name
---@param amount number? Number of items (default 1)
---@return boolean, string|nil ok Whether the item was given successfully and an optional error message
local function addItemToPlayer(src, item, amount)
    amount = amount or 1
    if cfg.Interface and cfg.Interface.inventory == 'qb' then
        local ply = QBCore.Functions.GetPlayer(src)
        if not ply then
            return false, 'Player not found'
        end
        ply.Functions.AddItem(item, amount)
        return true
    else
        return exports.ox_inventory:AddItem(src, item, amount)
    end
end

---Remove an item from a player. Used primarily for black money removal when
---configured to use item-based currency. Respects configured inventory.
---@param src number Player server ID
---@param item string Item name
---@param amount number? Number of items to remove (default 1)
---@return boolean ok Whether the item was removed successfully
local function removeItemFromPlayer(src, item, amount)
    amount = amount or 1
    if cfg.Interface and cfg.Interface.inventory == 'qb' then
        local ply = QBCore.Functions.GetPlayer(src)
        if not ply then
            return false
        end
        return ply.Functions.RemoveItem(item, amount)
    else
        return exports.ox_inventory:RemoveItem(src, item, amount)
    end
end

---Remove money from a player. Always uses QBCore's money functions because
---cash and bank balances are stored on the Player object regardless of
---inventory backend. Returns whether the removal succeeded.
---@param Player table QBCore player object
---@param mtype string 'cash' or 'bank'
---@param amount number Amount to remove
---@return boolean
local function removeMoneyFromPlayer(Player, mtype, amount)
    if not Player then return false end
    return Player.Functions.RemoveMoney(mtype, amount)
end

---Send a log message to a configured Discord webhook.
---@param title string
---@param description string
local function logWebhook(title, description)
    local url = cfg.WebhookURL
    if not url or url == '' then return end
    local payload = json.encode({
        username = 'BlackMarket Logs',
        embeds = {
            {
                title = title,
                description = description,
                color = 7506394
            }
        }
    })
    PerformHttpRequest(url, function() end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

---Give an item to the player via ox_inventory and notify them. Supports any item
---defined in the shared items list.
---@param src number Player server ID
---@param item string Item name
local function giveItem(src, item)
    local ok, err = addItemToPlayer(src, item, 1)
    if not ok then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('delivery_failed'),
            description = err or L('unknown_error'),
            duration = cfg.NotifyDuration or 5000
        })
        return
    end
    local label = (QBCore.Shared.Items[item] and QBCore.Shared.Items[item].label) or item
    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        title = L('delivery_complete'),
        description = L('you_received', label),
        duration = cfg.NotifyDuration or 5000
    })
end

---Event handler: deliver a purchased item to the player when they unlock their
---drop. Validates that the item belongs to the player's active drop before
---granting it. Without this validation, clients could spoof event calls
---to obtain arbitrary items.
RegisterNetEvent('blackmarket:giveWeaponsBulk', function()
    local src = source
    local drop = activeDrops[src]
    if not drop or not drop.items or type(drop.items) ~= 'table' then return end

    -- Count all items
    local itemCounts = {}
    for _, item in ipairs(drop.items) do
        itemCounts[item] = (itemCounts[item] or 0) + 1
    end

    -- Give each item in one call
    for item, count in pairs(itemCounts) do
        local ok, err = addItemToPlayer(src, item, count)
        if ok then
            local label = (QBCore.Shared.Items[item] and QBCore.Shared.Items[item].label) or item
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'success',
                title = L('delivery_complete'),
                description = L('you_received', label .. ' x' .. count),
                duration = cfg.NotifyDuration or 5000
            })
        else
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                title = L('delivery_failed'),
                description = err or 'Unknown error',
                duration = cfg.NotifyDuration or 5000
            })
        end
    end

    -- Mark drop as consumed
    activeDrops[src] = nil

    local Player = QBCore.Functions.GetPlayer(src)
    if Player then
        local charinfo = Player.PlayerData.charinfo or {}
        local playerName = (charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')
        local username = GetPlayerName(src)
        logWebhook('Drop Collected', ('Player %s (%s) [ID %d] collected %d items'):format(playerName, username, src, #drop.items))
    end

end)

-- Helper function: check if the player possesses a phone when paying by bank.
-- Returns true if a phone is found, false otherwise.
local function playerHasPhone(Player)
    if not cfg.RequirePhoneForBank then
        return true
    end
    -- Ensure the list of phone items is present and is a table
    if not cfg.PhoneItemNames or type(cfg.PhoneItemNames) ~= 'table' then
        return false
    end
    for _, phoneName in ipairs(cfg.PhoneItemNames) do
        -- QBCore inventory items are stored on Player.Functions.GetItemByName
        local item = Player.Functions.GetItemByName(phoneName)
        if item and item.amount and item.amount > 0 then
            return true
        end
    end
    return false
end

---Handle purchase of an individual item (weapon, ammo or component). Players
---pay with the default payment method and receive a GPS chip when ready.
---The server never trusts price data from the client; instead, it looks up
---the correct price from Config.MenuSections. If the item is not defined
---in the config, the purchase is rejected.
RegisterNetEvent('blackmarket:orderWeapon', function(item, price)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- Enforce order cooldown per player
    local now = os.time()
    if lastOrder[src] and (now - lastOrder[src]) < (cfg.OrderCooldownSec or 0) then
        local wait = (cfg.OrderCooldownSec or 0) - (now - lastOrder[src])
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('cooldown'),
            description = L('try_again_in', wait),
            duration = cfg.NotifyDuration or 5000
        })
        return
    end
    lastOrder[src] = now

    -- Look up the real price from the configuration. Never trust client input.
    local realPrice = 0
    local found = false
    for _, section in pairs(cfg.MenuSections or {}) do
        if section.items and section.items[item] then
            realPrice = section.items[item]
            found = true
            break
        end
    end
    if not found or realPrice <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('payment_failed'),
            description = L('invalid_item'),
            duration = cfg.NotifyDuration or 5000
        })
        return
    end

    -- Process payment using the verified price
    local payType = cfg.DefaultPaymentType
    local paid = false
    if payType == 'cash' then
        paid = removeMoneyFromPlayer(Player, payType, realPrice)
    elseif payType == 'bank' then
        -- Ensure the player has a phone if bank payments are enabled
        if not playerHasPhone(Player) then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                title = L('payment_failed'),
                description = L('no_phone_bank_payment'),
                duration = cfg.NotifyDuration or 5000
            })
            return
        end
        paid = removeMoneyFromPlayer(Player, payType, realPrice)
    elseif payType == 'black_money' then
        paid = removeItemFromPlayer(src, 'black_money', realPrice)
    end
    if not paid then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('payment_failed'),
            description = L('you_need', realPrice),
            duration = cfg.NotifyDuration or 5000
        })
        return
    end

    -- Select a random drop zone and generate a lock code
    local dropCoords = cfg.DropZones[math.random(#cfg.DropZones)]
    local lockCode  = tostring(math.random(1000, 9999))
    activeDrops[src] = {
        coords   = dropCoords,
        item     = item,
        lockCode = lockCode,
        ready    = false,
        revealed = false
    }

    -- Inform the player of their lock code and drop expiry
    TriggerClientEvent('blackmarket:showLockCode', src, lockCode, cfg.DropExpiryMin or 1)

    -- Log the order to the webhook
    local charinfo = Player.PlayerData.charinfo or {}
    local playerName = (charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')
    local username = GetPlayerName(src)

    logWebhook('Order Placed', ('Player %s [%s | ID %d] ordered %s for $%d'):format(playerName, username, src, item, realPrice))

    -- Schedule the drop spawn after the configured delay
    SetTimeout(cfg.DropTimeMs or 0, function()
        local drop = activeDrops[src]
        if not drop then return end
        drop.ready = true
        drop.revealed = true
        TriggerClientEvent('blackmarket:sendGPS', src, dropCoords, item, lockCode, cfg.TrackerRadius or 50.0)
    end)
end)

---Handle checkout of multiple items at once. Calculates the total cost of all
---items, processes payment in a single transaction, creates a single drop
---containing all purchased items and grants one GPS chip to the player. Only
---items defined in the configuration are processed; unknown items are ignored.
RegisterNetEvent('blackmarket:orderCart', function(items)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(items) ~= 'table' or #items == 0 then
        TriggerClientEvent('blackmarket:cartCheckoutResult', src, false)
        return
    end
    -- Enforce order cooldown per player
    local now = os.time()
    if lastOrder[src] and (now - lastOrder[src]) < (cfg.OrderCooldownSec or 0) then
        local wait = (cfg.OrderCooldownSec or 0) - (now - lastOrder[src])
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('cooldown'),
            description = L('try_again_in', wait),
            duration = cfg.NotifyDuration or 5000
        })
        TriggerClientEvent('blackmarket:cartCheckoutResult', src, false)
        return
    end
    lastOrder[src] = now
    -- Validate items and calculate the total cost
    local total = 0
    local validItems = {}
    for _, itemName in ipairs(items) do
        local price = 0
        local valid = false
        for _, section in pairs(cfg.MenuSections or {}) do
            if section.items and section.items[itemName] then
                price = section.items[itemName]
                valid = true
                break
            end
        end
        if valid and price > 0 then
            total = total + price
            validItems[#validItems + 1] = itemName
        end
    end
    -- Reject the order if no valid items were found
    if #validItems == 0 then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('payment_failed'),
            description = L('invalid_order'),
            duration = cfg.NotifyDuration or 5000
        })
        TriggerClientEvent('blackmarket:cartCheckoutResult', src, false)
        return
    end
    -- Process payment for the total amount
    local payType = cfg.DefaultPaymentType
    local paid = false
    if payType == 'cash' then
        paid = removeMoneyFromPlayer(Player, payType, total)
    elseif payType == 'bank' then
        if not playerHasPhone(Player) then
            TriggerClientEvent('ox_lib:notify', src, {
                type = 'error',
                title = L('payment_failed'),
                description = L('no_phone_bank_payment'),
                duration = cfg.NotifyDuration or 5000
            })
            TriggerClientEvent('blackmarket:cartCheckoutResult', src, false)
            return
        end
        paid = removeMoneyFromPlayer(Player, payType, total)
    elseif payType == 'black_money' then
        paid = removeItemFromPlayer(src, 'black_money', total)
    end
    if not paid then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            title = L('payment_failed'),
            description = L('you_need', total),
            duration = cfg.NotifyDuration or 5000
        })
        TriggerClientEvent('blackmarket:cartCheckoutResult', src, false)
        return
    end
    -- Choose a random drop location and generate a lock code
    local dropCoords = cfg.DropZones[math.random(#cfg.DropZones)]
    local lockCode  = tostring(math.random(1000, 9999))
    activeDrops[src] = {
        coords   = dropCoords,
        items    = validItems,
        lockCode = lockCode,
        ready    = false,
        revealed = false
    }
    -- Notify the player of their lock code and drop expiry time
    TriggerClientEvent('blackmarket:showLockCode', src, lockCode, cfg.DropExpiryMin or 1)
    -- Log the order details
    local charinfo = Player.PlayerData.charinfo or {}
    local playerName = (charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')
    local username = GetPlayerName(src)
    logWebhook('Order Placed', ('Player %s (%s) [ID %d] ordered %d items totalling $%d'):format(playerName, username, src, #validItems, total))
    -- Schedule drop spawn and potential police alert
    SetTimeout(cfg.DropTimeMs or 0, function()
        local drop = activeDrops[src]
        if not drop then return end
        drop.ready = true
        drop.revealed = true
        TriggerClientEvent('blackmarket:sendGPS', src, dropCoords, validItems, lockCode, cfg.TrackerRadius or 50.0)
    end)
    -- Inform the client that checkout succeeded so it can clear the cart
    TriggerClientEvent('blackmarket:cartCheckoutResult', src, true)
end)

---Notify all clients of the black market NPC's location so they can display a
---warning before the NPC moves. The client determines whether it is within the
---NotifyRadius and, if so, shows an information notification.
RegisterNetEvent('blackmarket:notifyNearbyPlayers', function(pedCoords)
    local players = QBCore.Functions.GetPlayers()
    for _, id in pairs(players) do
        TriggerClientEvent('blackmarket:checkDistanceAndNotify', id, pedCoords)
    end
end)