--[[
    steff_blackmarket - Client Logic (enhanced)

    This client script extends the original black market experience by
    introducing several quality‑of‑life improvements and now externalises
    all user‑facing strings. Text such as menu titles, descriptions and
    notifications are pulled from the locale table via the L() helper,
    allowing server owners to translate the script without editing the
    code. See locales/en.lua for the English defaults.
]]

if GetCurrentResourceName() ~= 'steff_blackmarket' then
    print('^1[steff_blackmarket] Incorrect resource name. Stopping client.')
    return
end

local QBCore = exports['qb-core']:GetCoreObject()
local cfg    = Config
local ox     = exports['ox_lib']
local dropData = {}
local currentPedIndex = 1
local blackMarketPed, pedBlip = nil, nil

-- Load locale from file if configured. This must be performed before
-- referencing any translated strings. If the file is missing or malformed
-- the script will continue using keys as fallbacks.
do
    if cfg.LocalesFolder and cfg.Locale then
        local path = ('%s/%s.lua'):format(cfg.LocalesFolder, cfg.Locale)
        local contents = LoadResourceFile(GetCurrentResourceName(), path)
        if contents then
            local func, err = load(contents, '@' .. path)
            if not func then
                print(('Failed to load locale file %s: %s'):format(path, err))
            else
                local success, localeTbl = pcall(func)
                if success and type(localeTbl) == 'table' then
                    cfg.Locales = cfg.Locales or {}
                    cfg.Locales[cfg.Locale] = localeTbl
                else
                    print(('Locale file %s did not return a table'):format(path))
                end
            end
        end
    end
end

-- Determine which interfaces to use for inventory, menu, input, target,
-- alert notifications and dispatch. These values come from Config.Interface
local interface = cfg.Interface or {}

-- Shopping cart table. Items are stored as strings representing item names.
local cartItems = {}

---Return a friendly display label for a given item. This function looks up
---custom labels defined in the menu sections before falling back to
---QBCore.Shared.Items or the raw item name.
---@param itemName string
---@return string
local function getItemLabel(itemName)
    -- Check custom labels defined per section.
    if cfg and cfg.MenuSections then
        for _, section in pairs(cfg.MenuSections) do
            if section.labels and section.labels[itemName] then
                return section.labels[itemName]
            end
        end
    end
    -- Fallback to the global shared items table.
    local itemData = QBCore.Shared.Items[itemName]
    if itemData and itemData.label then
        return itemData.label
    end
    return itemName
end

---Return a localised string defined in Config.Locales.
---@param key string
---@param ... any
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

---Display a notification to the player.
---@param params table Parameters accepted by ox_lib:notify (type, title, description, duration)
local function notify(params)
    if interface.alert == 'qb' then
        -- QBCore notify: params.type should be 'success', 'error' or 'inform'
        local msg = (params.description and params.title) and (params.title .. ': ' .. params.description)
            or params.description or params.title or ''
        local typ = params.type or 'inform'
        QBCore.Functions.Notify(msg, typ)
    else
        -- Default to ox_lib
        ox:notify(params)
    end
end

---Display an alert dialog. For ox this uses lib.alertDialog. For qb we
---fallback to a simple notify as qb-core does not provide modal dialogs.
---@param params table Parameters for the dialog: header, content, centered, cancel
local function alertDialog(params)
    if interface.alert == 'qb' then
        -- Fallback: just show the content as a notification
        notify({ type = 'inform', title = params.header or '', description = params.content or '', duration = cfg.NotifyDuration or 5000 })
    else
        lib.alertDialog(params)
    end
end

---Prompt the user for input. Currently only ox input dialog is supported. If
---the configured input is 'qb', this will still call ox:inputDialog as
---qb-input integration is not implemented yet.
---@param title string Title of the dialog
---@param fields table Array of input definitions
---@return table|nil Result from the dialog or nil if cancelled
local function inputDialog(title, fields)
    -- ox_lib supports custom input dialogs
    return ox:inputDialog(title, fields)
end

---Register and show a context menu. Only ox_lib is currently supported.
---@param id string Menu identifier
---@param title string Menu title
---@param options table Array of menu options
local function openContextMenu(id, title, options)
    -- For qb-menu, this would need a conversion to qb-menu syntax. Not implemented.
    ox:registerContext({ id = id, title = title, options = options })
    ox:showContext(id)
end

---Add a targeting entry for an entity. Uses ox_target by default. qb-target
---integration is reserved for future implementation.
---@param entity number Entity handle
---@param opts table Array of target options
local function addTargetEntity(entity, opts)
    if interface.target == 'qb' then
        -- Future: qb-target integration
        -- exports['qb-target']:AddTargetEntity(entity, {...})
        -- For now, fall back to ox_target
        exports.ox_target:addLocalEntity(entity, opts)
    else
        exports.ox_target:addLocalEntity(entity, opts)
    end
end

---Add an item to the shopping cart and notify the player.
---@param itemName string
---@param quantity number? optional quantity, default 1
local function addToCart(itemName, quantity)
    quantity = quantity or 1
    for i = 1, quantity do
        cartItems[#cartItems + 1] = itemName
    end
    -- Determine a human‑readable label for the item using custom labels or
    -- fallback to the shared item definition.
    local label = getItemLabel(itemName)
    if quantity > 1 then
        notify({
            type = 'success',
            title = L('cart_title'),
            description = L('cart_added_quantity', label, quantity),
            duration = cfg.NotifyDuration or 5000
        })
    else
        notify({
            type = 'success',
            title = L('cart_title'),
            description = L('cart_added', label),
            duration = cfg.NotifyDuration or 5000
        })
    end
end

---Remove a single instance of an item from the shopping cart.
---@param itemName string
local function removeFromCart(itemName)
    for i, itm in ipairs(cartItems) do
        if itm == itemName then
            table.remove(cartItems, i)
            return
        end
    end
end

local function openContextMenu(id, title, options, parentMenu, onBack)
    ox:registerContext({
        id     = id,
        title  = title,
        menu   = parentMenu,  -- this enables the back arrow
        onBack = onBack,      -- called when arrow is pressed
        options = options,
    })
    ox:showContext(id)
end


---Open the cart management menu. Displays a summary of items in the cart with
---their quantities and prices, allows removing individual items, and
---purchasing all items at once.
function openCartMenu()
    local options = {}
    -- Build a count of each item in the cart
    local counts = {}
    for _, itemName in ipairs(cartItems) do
        counts[itemName] = (counts[itemName] or 0) + 1
    end

    local total = 0
    for itemName, count in pairs(counts) do
        local price = 0
        for _, section in pairs(cfg.MenuSections or {}) do
            if section.items and section.items[itemName] then
                price = section.items[itemName]
                break
            end
        end
        total = total + price * count
        local label = getItemLabel(itemName)
        options[#options + 1] = {
            title       = label .. ' x' .. count,
            description = '$' .. (price * count),
            icon        = 'fa-solid fa-trash',
            onSelect    = function()
                removeFromCart(itemName)
                openCartMenu()
            end
        }
    end

    -- Checkout button
    options[#options + 1] = {
        title       = L('checkout_title'),
        description = L('checkout_description', total),
        icon        = 'fa-solid fa-credit-card',
        onSelect    = function()
            if #cartItems == 0 then
                notify({
                    type        = 'error',
                    title       = L('cart_title'),
                    description = L('cart_empty_description'),
                    duration    = cfg.NotifyDuration or 5000
                })
                return
            end
            TriggerServerEvent('blackmarket:orderCart', cartItems)
        end
    }

    -- Now show the cart menu with a back arrow to main
    openContextMenu(
        'blackmarket_cart',
        L('your_cart'),
        options,
        'blackmarket_main',         -- parent menu ID
        function()                  -- onBack callback
            TriggerEvent('blackmarket:openMenu')
        end
    )
end

-- Spawn the black market ped at the current index
local function spawnBlackMarketPed()
    local coords = cfg.PedLocations[currentPedIndex]
    if not coords then return end
    local hash = cfg.PedModel
    RequestModel(hash)
    while not HasModelLoaded(hash) do Wait(10) end
    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z, coords.w, false, true)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetEntityHeading(ped, coords.w)
    blackMarketPed = ped
    -- Optional: Add a blip if enabled in the config
    if cfg.ShowBlackMarketBlip then
        pedBlip = AddBlipForEntity(ped)
        SetBlipSprite(pedBlip, cfg.PedBlip.sprite or 500)
        SetBlipDisplay(pedBlip, 4)
        SetBlipScale(pedBlip, cfg.PedBlip.scale or 0.8)
        SetBlipColour(pedBlip, cfg.PedBlip.color or 1)
        SetBlipAsShortRange(pedBlip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(cfg.PedBlip.label or L('black_market'))
        EndTextCommandSetBlipName(pedBlip)
    end
    addTargetEntity(ped, {
        {
            event = 'blackmarket:openMenu',
            icon  = 'fa-solid fa-gun',
            label = L('access_black_market'),
            distance = 2.5
        }
    })
    -- Play idle animation on ped if configured
    if cfg.PedAnimation then
        if cfg.PedAnimation.scenario then
            TaskStartScenarioInPlace(ped, cfg.PedAnimation.scenario, 0, true)
        elseif cfg.PedAnimation.dict and cfg.PedAnimation.clip then
            RequestAnimDict(cfg.PedAnimation.dict)
            while not HasAnimDictLoaded(cfg.PedAnimation.dict) do Wait(10) end
            TaskPlayAnim(ped, cfg.PedAnimation.dict, cfg.PedAnimation.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
        end
    end
end

-- Initialise black market ped and movement logic
local function initBlackMarket()
    spawnBlackMarketPed()
end

-- Ensure ox_lib is ready before initialising
CreateThread(function()
    repeat Wait(10) until type(ox.registerContext) == 'function'
    initBlackMarket()
end)

-- Periodically move the ped to a new location and notify nearby players
CreateThread(function()
    while true do
        local interval = (cfg.PedMoveIntervalMin or 300) * 60 * 1000
        Wait(interval - (cfg.NotifyBeforePedMovesSec or 30) * 1000)
        if blackMarketPed then
            local pedCoords = GetEntityCoords(blackMarketPed)
            TriggerServerEvent('blackmarket:notifyNearbyPlayers', pedCoords)
        end
        Wait((cfg.NotifyBeforePedMovesSec or 30) * 1000)
        currentPedIndex = (currentPedIndex % #cfg.PedLocations) + 1
        if blackMarketPed then DeleteEntity(blackMarketPed) end
        if pedBlip then RemoveBlip(pedBlip) pedBlip = nil end
        spawnBlackMarketPed()
    end
end)

-- Open the main purchase menu. Sections defined in Config.MenuSections are
-- displayed in the order specified by Config.MenuSectionOrder. Each entry
-- uses the arrow property to indicate that a submenu is available.
RegisterNetEvent('blackmarket:openMenu', function()
    local Player = QBCore.Functions.GetPlayerData()
    local jobName = Player.job and Player.job.name or 'none'
    -- Disallow blacklisted jobs
    for _, blockedJob in pairs(cfg.BlockedJobs) do
        if jobName == blockedJob then
            notify({
                type = 'error',
                title = L('access_denied_title'),
                description = L('access_denied_desc'),
                duration = cfg.NotifyDuration or 5000
            })
            return
        end
    end
    local options = {}
    local ordered = {}
    -- Add sections in the configured order
    if cfg.MenuSectionOrder and cfg.MenuSections then
        -- Insert a cart entry at the top of the menu so players can quickly
        -- review and checkout their current selections. The arrow property
        -- indicates that a submenu exists.
        local cartCount = #cartItems
        table.insert(options, {
            icon        = 'fa-solid fa-shopping-cart',
            title       = L('cart_with_items', cartCount),
            description = L('cart_review'),
            arrow       = true,
            onSelect    = function()
                openCartMenu()
            end
        })
        for _, key in ipairs(cfg.MenuSectionOrder) do
            local section = cfg.MenuSections[key]
            if section then
                ordered[key] = true
                options[#options + 1] = {
                    icon        = section.icon,
                    title       = section.label,
                    description = section.description,
                    arrow       = true,
                    onSelect    = function()
                        openSectionMenu(key)
                    end
                }
            end
        end
        -- Append any additional sections not explicitly ordered
        for key, section in pairs(cfg.MenuSections) do
            if not ordered[key] then
                options[#options + 1] = {
                    icon        = section.icon,
                    title       = section.label,
                    description = section.description,
                    arrow       = true,
                    onSelect    = function()
                        openSectionMenu(key)
                    end
                }
            end
        end
    end
    openContextMenu('blackmarket_main', L('black_market'), options)
end)

-- Called when the player uses a gps_chip. Simply forwards the request back
-- to the server where validation and drop revealing takes place.
RegisterNetEvent('blackmarket:useGPS', function()
    TriggerServerEvent('blackmarket:useGPSItem')
end)

-- Display a submenu for a given section. Builds a list of items defined in
-- Config.MenuSections[sectionKey].items and allows the player to purchase them.
function openSectionMenu(sectionKey)
    local section = cfg.MenuSections and cfg.MenuSections[sectionKey]
    if not section then return end
    local options = {}
    for item, price in pairs(section.items) do
        local label = getItemLabel(item)
        local opt = {
            title       = label,
            description = '$' .. price,
            onSelect    = function()
                if section.allowQuantity then
                    local input = inputDialog(L('select_quantity'), {
                        { type = 'number', label = L('quantity'), min = 1, max = 500, default = 1, required = true }
                    })
                    if not input or #input < 1 then return end
                    local qty = tonumber(input[1]) or 1
                    if qty < 1 then qty = 1 end
                    addToCart(item, qty)
                else
                    addToCart(item)
                end
                openSectionMenu(sectionKey)
            end
        }
        if interface.menu == 'ox' and section.images and section.images[item] then
            opt.image = section.images[item]
        end
        options[#options + 1] = opt
    end

    -- cart entry
    options[#options + 1] = {
        title       = L('cart_with_items', #cartItems),
        description = L('cart_review'),
        icon        = 'fa-solid fa-shopping-cart',
        arrow       = true,
        onSelect    = function() openCartMenu() end
    }

    -- show submenu with back arrow pointing at 'blackmarket_main'
    openContextMenu(
        'blackmarket_' .. sectionKey,
        section.label,
        options,
        'blackmarket_main',
        function()
            -- onBack: reopen main menu
            TriggerEvent('blackmarket:openMenu')
        end
    )
end


-- Receive GPS data from the server and spawn the drop plus a radius blip
RegisterNetEvent('blackmarket:sendGPS', function(coords, items, lockCode, radius)
    local obj = CreateObject(cfg.BoxProp, coords.x, coords.y, coords.z - 1, false, false, false)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    -- Draw a circular area on the map instead of marking the exact point
    local areaBlip = AddBlipForRadius(coords.x, coords.y, coords.z, radius or 50.0)
    SetBlipColour(areaBlip, 1)
    SetBlipAlpha(areaBlip, 128)
    SetBlipHighDetail(areaBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(L('drop_area'))
    EndTextCommandSetBlipName(areaBlip)
    -- Normalise items into a list. If a single string is passed, wrap it
    local itemList
    if type(items) == 'table' then
        itemList = items
    else
        itemList = { items }
    end
    dropData[obj] = { items = itemList, blip = areaBlip, lockCode = lockCode }
    notify({
        type = 'success',
        title = L('drop_landed'),
        description = L('drop_hint', cfg.DropExpiryMin or 1),
        duration = cfg.NotifyDuration or 5000
    })
    -- Allow players to attempt to unlock the box when nearby
    addTargetEntity(obj, {
        {
            label = L('unlock_drop'),
            icon  = 'fa-solid fa-lock',
            distance = 1.5,
            onSelect = function()
                local data = dropData[obj]
                if not data then return end
                local input = inputDialog(L('enter_lock_code'), {
                    { type = 'input', label = L('code'), required = true }
                })
                if not input or #input < 1 then return end
                if input[1] == data.lockCode then
                    -- Play custom animation for unpacking and show a progress bar/circle
                    local animDict  = cfg.UnpackAnimation and cfg.UnpackAnimation.dict or 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@'
                    local animClip  = cfg.UnpackAnimation and cfg.UnpackAnimation.clip or 'machinic_loop_mechandplayer'
                    local duration  = cfg.UnpackAnimation and cfg.UnpackAnimation.duration or 5000
                    local barType   = cfg.UnpackAnimation and cfg.UnpackAnimation.progressType or 'bar'
                    -- Load and play the animation on the player
                    if animDict and animClip then
                        RequestAnimDict(animDict)
                        while not HasAnimDictLoaded(animDict) do Wait(10) end
                        TaskPlayAnim(PlayerPedId(), animDict, animClip, 8.0, -8.0, -1, 1, 0, false, false, false)
                    end
                    local progressFun = (barType == 'circle') and lib.progressCircle or lib.progressBar
                    local success = progressFun({
                        duration = duration,
                        position = cfg.UnpackAnimation.position,
                        label    = L('unpacking_drop'),
                        canCancel = false,
                        disable = { move = true, car = true, combat = true }
                    })
                    ClearPedTasks(PlayerPedId())
                    if success then
                        -- Give all items contained in this drop to the player
                        TriggerServerEvent('blackmarket:giveWeaponsBulk')

                        DeleteEntity(obj)
                        RemoveBlip(areaBlip)
                        dropData[obj] = nil
                    else
                        notify({ type = 'error', title = L('canceled'), description = L('you_canceled_unpacking'), duration = cfg.NotifyDuration or 5000 })
                    end
                else
                    notify({ type = 'error', title = L('wrong_code'), description = L('access_denied_code'), duration = cfg.NotifyDuration or 5000 })
                end
            end
        }
    })
    -- Automatically clean up expired drops
    SetTimeout((cfg.DropExpiryMin or 1) * 60 * 1000, function()
        if dropData[obj] then
            local dist = #(GetEntityCoords(PlayerPedId()) - coords)
            local rad = radius or (cfg.TrackerRadius or 50.0)
            if dist > rad then
                DeleteEntity(obj)
                RemoveBlip(areaBlip)
                dropData[obj] = nil
                notify({
                    type = 'error',
                    title = L('drop_expired'),
                    description = L('too_far_drop_stolen'),
                    duration = cfg.NotifyDuration or 5000
                })
            else
                SetTimeout(30 * 1000, function()
                    if dropData[obj] then
                        TriggerEvent('blackmarket:retryDropCleanup', obj)
                    end
                end)
            end
        end
    end)
end)

-- Retry cleaning up a drop if the player remains within the search area
RegisterNetEvent('blackmarket:retryDropCleanup', function(obj)
    if not dropData[obj] then return end
    local coords = GetEntityCoords(obj)
    local dist = #(GetEntityCoords(PlayerPedId()) - coords)
    local rad = cfg.TrackerRadius or 50.0
    if dist > rad then
        DeleteEntity(obj)
        RemoveBlip(dropData[obj].blip)
        dropData[obj] = nil
        notify({
            type = 'error',
            title = L('drop_expired'),
            description = L('drop_stolen'),
            duration = cfg.NotifyDuration or 5000
        })
    else
        SetTimeout(30 * 1000, function()
            if dropData[obj] then
                TriggerEvent('blackmarket:retryDropCleanup', obj)
            end
        end)
    end
end)

-- Show the lock code to the player in an alert dialog along with the drop expiry time
RegisterNetEvent('blackmarket:showLockCode', function(lockCode, minutes)
    alertDialog({
        header  = L('order_confirmed'),
        content = L('lock_code_msg', lockCode, minutes or (cfg.DropExpiryMin or 1)),
        centered = true,
        cancel  = false
    })
end)

-- Receive the result of a cart checkout from the server. On success the
-- shopping cart is cleared; on failure it is left intact. A notification
-- informs the player of the outcome.
RegisterNetEvent('blackmarket:cartCheckoutResult', function(success)
    if success then
        cartItems = {}
        notify({
            type  = 'success',
            title = L('cart_title'),
            -- Inform the player that their order has been placed. The drop
            -- location will appear automatically once it is ready.
            description = L('order_success'),
            duration    = cfg.NotifyDuration or 5000
        })
    else
        notify({
            type        = 'error',
            title       = L('cart_title'),
            description = L('order_failure'),
            duration    = cfg.NotifyDuration or 5000
        })
    end
end)

-- Notify players close to the PED before it moves
RegisterNetEvent('blackmarket:checkDistanceAndNotify', function(pedCoords)
    local myCoords = GetEntityCoords(PlayerPedId())
    local distance = #(myCoords - pedCoords)
    if distance <= (cfg.NotifyRadius or 5.0) then
        notify({
            type        = 'inform',
            title       = L('black_market'),
            description = L('ped_moving_soon', cfg.NotifyBeforePedMovesSec or 30),
            duration    = cfg.NotifyDuration or 5000
        })
    end
end)