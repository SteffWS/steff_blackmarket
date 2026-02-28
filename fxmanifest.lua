fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Steff'
description 'QBCore Black Market'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'locales/*.lua',
    'config.lua'
}

client_scripts {
    'client/cl_main.lua'
}

server_scripts {
    'server/sv_main.lua'
}

escrow_ignore {
    'server/*.lua',
    'client/*.lua'
}

dependencies {
    'qb-core',
    'ox_lib',
    'ox_target',
    'ox_inventory'
}

dependency '/assetpacks'