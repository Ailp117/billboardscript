fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'esx_billboardscript'
author 'Codex'
description 'ESX billboard overlay with admin UI'
version '1.0.0'

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js'
}

shared_script 'config.lua'
client_script 'client/main.lua'
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

dependencies {
    'es_extended',
    'oxmysql'
}
