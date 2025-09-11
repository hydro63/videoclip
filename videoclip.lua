--[[
Videoclip - mp4/webm clips creator for mpv.

Copyright (C) 2021 Ren Tatsumoto

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

local NAME = 'videoclip'
local mp = require('mp')
local mpopt = require('mp.options')
local utils = require('mp.utils')
local OSD = require('osd_styler')
local p = require('platform')
local h = require('helpers')
local encoder = require('encoder')
local Timings = require('timings_mgr')

------------------------------------------------------------
-- System-dependent variables

-- Options can be changed here or in a separate config file.
-- Config path: ~/.config/mpv/script-opts/videoclip.conf
local config = {
    -- absolute paths
    -- relative paths (e.g. ~ for home dir) do NOT work.
    video_folder_path = p.default_video_folder,
    audio_folder_path = p.default_audio_folder,
    -- The range of the CRF scale is 0–51, where 0 is lossless,
    -- 23 is the default, and 51 is worst quality possible.
    -- Insane values like 9999 still work but produce the worst quality.
    video_quality = 23,
    -- Use the slowest preset that you have patience for.
    -- https://trac.ffmpeg.org/wiki/Encode/H.264
    preset = 'faster',
    video_format = 'mp4', -- mp4, vp9, vp8
    video_bitrate = '1M',
    video_width = -2,
    video_height = 480,
    video_fps = 'auto',
    audio_format = 'opus', -- aac, opus
    audio_bitrate = '32k', -- 32k, 64k, 128k, 256k. aac requires higher bitrates.
    font_size = 16,
    osd_align = 7,         -- https://aegisub.org/docs/3.2/ASS_Tags/#\an
    osd_outline = 1.5,
    clean_filename = true,
    -- Whether to upload to catbox (permanent) or litterbox (temporary)
    litterbox = true,
    -- Determines expire time of files uploaded to litterbox
    litterbox_expire = '72h', -- 1h, 12h, 24h, 72h
    sub_font = 'Noto Sans CJK JP',
    -- Filename format
    -- Available tags: %n = filename, %t = title, %s = start, %e = end, %d = duration,
    --                 %Y = year, %M = months, %D = day, %H = hours (24), %I = hours (12),
    --                 %P = am/pm %N = minutes, %S = seconds
    filename_template = '%n_%s-%e',
    cache_path = '/temp/videoclip/',
    use_cache = false
}

mpopt.read_options(config, NAME)

local main_menu
local pref_menu
local crop_menu

local allowed_presets = {
    ultrafast = true,
    superfast = true,
    veryfast = true,
    faster = true,
    fast = true,
    medium = true,
    slow = true,
    slower = true,
    veryslow = true,
}

------------------------------------------------------------
-- Utility functions

local function force_resolution(width, height, clip_fn, ...)
    local cached_prefs = {
        video_width = config.video_width,
        video_height = config.video_height,
    }
    config.video_width = width
    config.video_height = height
    clip_fn(...)
    config.video_width = cached_prefs.video_width
    config.video_height = cached_prefs.video_height
end

local function cleanup()
    p.remove_folder(config.cache_path)
end

local function set_encoding_settings()
    if config.video_format == 'mp4' then
        config.video_codec = 'libx264'
        config.video_extension = '.mp4'
    elseif config.video_format == 'vp9' then
        config.video_codec = 'libvpx-vp9'
        config.video_extension = '.webm'
    else
        config.video_codec = 'libvpx'
        config.video_extension = '.webm'
    end

    if config.audio_format == 'aac' then
        config.audio_codec = 'aac'
        config.audio_extension = '.aac'
    else
        config.audio_codec = 'libopus'
        config.audio_extension = '.opus'
    end
end

local function validate_config()
    if not config.audio_bitrate:match('^%d+[kK]$') then
        config.audio_bitrate = (tonumber(config.audio_bitrate) or 32) .. 'k'
    end

    if not config.video_bitrate:match('^%d+[kKmM]$') then
        config.video_bitrate = '1M'
    end

    if not allowed_presets[config.preset] then
        config.preset = 'faster'
    end

    set_encoding_settings()
end

local function upload_to_catbox(outfile)
    local endpoint = config.litterbox and 'https://litterbox.catbox.moe/resources/internals/api.php' or
        'https://catbox.moe/user/api.php'
    h.notify("Uploading to " .. (config.litterbox and "litterbox.catbox.moe..." or "catbox.moe..."), "info", 9999)

    -- This uses cURL to send a request to the cat-/litterbox API.
    -- cURL is included on Windows 10 and up, most Linux distributions and macOS.

    local r = h.subprocess({ -- This is technically blocking, but I don't think it has any real consequences ..?
        p.curl_exe, '-s',
        '-F', 'reqtype=fileupload',
        '-F', 'time=' .. config['litterbox_expire'],
        '-F', 'fileToUpload=@"' .. outfile .. '"',
        endpoint
    })

    -- Exit codes in the range [0, 99] are returned by cURL itself.
    -- Any other exit code means the shell failed to execute cURL.
    if r.status < 0 or r.status > 99 then
        h.notify_error("Error: Failed to upload. Make sure cURL is installed and in your PATH.", "error", 3)
        return
    elseif r.status ~= 0 then
        h.notify_error("Error: Failed to upload to " .. (config.litterbox and "litterbox.catbox.moe" or "catbox.moe"),
            "error", 2)
        return
    end

    mp.msg.info("Catbox URL: " .. r.stdout)
    -- Copy to clipboard
    p.copy_or_open_url(r.stdout)
end

------------------------------------------------------------
-- Menu interface

local Menu = {}
Menu.__index = Menu

function Menu:new(parent)
    local o = {
        parent = parent,
        overlay = parent and parent.overlay or mp.create_osd_overlay('ass-events'),
        keybindings = {},
    }
    return setmetatable(o, self)
end

function Menu:overlay_draw(text)
    self.overlay.data = text
    self.overlay:update()
end

function Menu:open()
    if self.parent then
        self.parent:close()
    end
    for _, val in pairs(self.keybindings) do
        mp.add_forced_key_binding(val.key, val.key, val.fn)
    end
    self:update()
end

function Menu:close()
    for _, val in pairs(self.keybindings) do
        mp.remove_key_binding(val.key)
    end
    if self.parent then
        self.parent:open()
    else
        self.overlay:remove()
    end
end

function Menu:update()
    local osd = OSD:new():config(config)
    osd:append('Dummy menu.'):newline()
    self:overlay_draw(osd:get_text())
end

------------------------------------------------------------
-- Main menu

main_menu = Menu:new()
main_menu.timings = Timings:new()

main_menu.keybindings = {
    { key = 's',   fn = function() main_menu:set_time('start') end },
    { key = 'e',   fn = function() main_menu:set_time('end') end },
    { key = 'S',   fn = function() main_menu:set_time_sub('start') end },
    { key = 'E',   fn = function() main_menu:set_time_sub('end') end },
    { key = 'r',   fn = function() main_menu:reset_timings() end },
    { key = 'c',   fn = function() main_menu:create_clip('video') end },
    { key = 'C',   fn = function() force_resolution(1920, -2, encoder.create_clip, 'video') end },
    { key = 'a',   fn = function() main_menu:create_clip('audio') end },
    { key = 'x',   fn = function() main_menu:create_clip('video', upload_to_catbox) end },
    { key = 'X',   fn = function() force_resolution(1920, -2, main_menu.create_clip, 'video', upload_to_catbox) end },
    { key = 'p',   fn = function() pref_menu:open() end },
    { key = 'o',   fn = function() p.open('https://streamable.com/') end },
    { key = 'ESC', fn = function() main_menu:close() end },
    { key = 'k',   fn = function() encoder.kill_job() end }
}

function main_menu:set_time(property)
    self.timings[property] = math.max(0, mp.get_property_number('time-pos'))
    self:update()
end

function main_menu:set_time_sub(property)
    local sub_delay = mp.get_property_native("sub-delay")
    local time_pos = mp.get_property_number(string.format("sub-%s", property))

    if time_pos == nil then
        h.notify_error("Warning: No subtitles visible.", "warn", 2)
        return
    end

    self.timings[property] = math.max(0, time_pos + sub_delay)
    self:update()
end

function main_menu:reset_timings()
    self.timings:reset()
    self:update()
end

main_menu.open = function()
    Menu.open(main_menu)
end

function main_menu:update()
    local osd = OSD:new():config(config)
    if encoder.alive == false then
        osd:red("Error: "):append("mpv is not found in the PATH."):newline()
    end
    osd:submenu('Timings '):italics('(+shift use sub timings)'):newline()
    osd:tab():item('s: '):append('start time '):item(h.human_readable_time(self.timings['start'])):newline()
    osd:tab():item('e: '):append('end time '):item(h.human_readable_time(self.timings['end'])):newline()
    osd:tab():item('r: '):append('reset'):newline()
    osd:submenu('Create clip '):italics('(+shift to force fullHD preset)'):newline()
    osd:tab():item('c: '):append('video clip'):newline()
    osd:tab():item('a: '):append('audio clip'):newline()
    osd:tab():item('x: '):append('video clip to ' ..
        (config.litterbox and 'litterbox.catbox.moe (' .. config.litterbox_expire .. ')' or 'catbox.moe')):newline()
    osd:submenu('Options '):newline()
    osd:tab():item('p: '):append('Open preferences'):newline()
    osd:tab():item('o: '):append('Open streamable.com'):newline()
    osd:tab():item('k: '):append('Kill running process'):newline()
    osd:tab():item('ESC: '):append('Close'):newline()

    self:overlay_draw(osd:get_text())
end

function main_menu:create_clip(clip_type, on_complete_fn)
    self:close()
    encoder.create_clip(clip_type, on_complete_fn)
end

------------------------------------------------------------
-- Preferences


pref_menu = Menu:new(main_menu)

pref_menu.keybindings = {
    { key = 'f',   fn = function() pref_menu:cycle_video_formats() end },
    { key = 'a',   fn = function() pref_menu:cycle_audio_formats() end },
    { key = 'm',   fn = function() pref_menu:toggle_mute_audio() end },
    { key = 'r',   fn = function() pref_menu:cycle_resolutions() end },
    { key = 'b',   fn = function() pref_menu:cycle_audio_bitrates() end },
    { key = 'e',   fn = function() pref_menu:toggle_embed_subtitles() end },
    { key = 'c',   fn = function() crop_open() end },
    { key = 'd',   fn = function() pref_menu:toggle_use_cache() end },
    { key = 'x',   fn = function() pref_menu:toggle_catbox() end },
    { key = 'z',   fn = function() pref_menu:cycle_litterbox_expiration() end },
    { key = 's',   fn = function() pref_menu:save() end },
    { key = 'ESC', fn = function() pref_menu:close() end },
    { key = 'q',   fn = function() pref_menu:close() end },
}

pref_menu.resolutions = {
    { w = config.video_width, h = config.video_height, },
    { w = -2,                 h = -2, },
    { w = -2,                 h = 240, },
    { w = -2,                 h = 360, },
    { w = -2,                 h = 480, },
    { w = -2,                 h = 720, },
    { w = -2,                 h = 1080, },
    { w = -2,                 h = 1440, },
    { w = -2,                 h = 2160, },
    selected = 1,
}
pref_menu.audio_bitrates = {
    config.audio_bitrate,
    '32k',
    '64k',
    '128k',
    '256k',
    '384k',
    selected = 1,
}

pref_menu.vid_formats = { 'mp4', 'vp9', 'vp8', }
pref_menu.aud_formats = { 'aac', 'opus', }
pref_menu.litterbox_expirations = { '1h', '12h', '24h', '72h', }

function pref_menu:get_selected_resolution()
    return string.format(
        '%s x %s',
        config.video_width == -2 and 'auto' or config.video_width,
        config.video_height == -2 and 'auto' or config.video_height
    )
end

function pref_menu:cycle_resolutions()
    self.resolutions.selected = self.resolutions.selected + 1 > #self.resolutions and 1 or self.resolutions.selected + 1
    local res = self.resolutions[self.resolutions.selected]
    config.video_width = res.w
    config.video_height = res.h
    self:update()
end

function pref_menu:cycle_audio_bitrates()
    self.audio_bitrates.selected = self.audio_bitrates.selected + 1 > #self.audio_bitrates and 1 or
        self.audio_bitrates.selected + 1
    config.audio_bitrate = self.audio_bitrates[self.audio_bitrates.selected]
    self:update()
end

function pref_menu:cycle_formats(config_type)
    local formats
    if config_type == 'video_format' then
        formats = pref_menu.vid_formats
    else
        formats = pref_menu.aud_formats
    end

    local selected = 1
    for i, format in ipairs(formats) do
        if config[config_type] == format then
            selected = i
            break
        end
    end
    config[config_type] = formats[selected + 1] or formats[1]
    set_encoding_settings()
    self:update()
end

function pref_menu:cycle_video_formats()
    pref_menu:cycle_formats('video_format')
end

function pref_menu:cycle_audio_formats()
    pref_menu:cycle_formats('audio_format')
end

function pref_menu:toggle_mute_audio()
    mp.commandv("cycle", "mute")
    self:update()
end

function pref_menu:toggle_embed_subtitles()
    mp.commandv("cycle", "sub-visibility")
    self:update()
end

function pref_menu:toggle_catbox()
    config['litterbox'] = not config['litterbox']
    self:update()
end

function pref_menu:toggle_use_cache()
    cleanup()
    config['use_cache'] = not config['use_cache']
    self:update()
end

function pref_menu:cycle_litterbox_expiration()
    if not config['litterbox'] then
        return
    end
    local expirations = pref_menu.litterbox_expirations

    local selected = 1
    for i, expiration in ipairs(expirations) do
        if config['litterbox_expire'] == expiration then
            selected = i
            break
        end
    end
    config['litterbox_expire'] = expirations[selected + 1] or expirations[1]
    self:update()
end

function pref_menu:update()
    local osd = OSD:new():config(config)
    local crop = get_crop();
    local crop_value = "NONE";
    if (crop.x0) then crop_value = 'INVALID'; end;
    if (crop.x1) then crop_value = 'yes'; end;

    osd:submenu('Preferences'):newline()
    osd:tab():item('r: Video resolution: '):append(self:get_selected_resolution()):newline()
    osd:tab():item('f: Video format: '):append(config.video_format):newline()
    osd:tab():item('a: Audio format: '):append(config.audio_format):newline()
    osd:tab():item('b: Audio bitrate: '):append(config.audio_bitrate):newline()
    osd:tab():item('m: Mute audio: '):append(mp.get_property("mute")):newline()
    osd:tab():item('e: Embed subtitles: '):append(mp.get_property("sub-visibility")):newline()
    osd:tab():item('c: Crop: '):append(crop_value):newline()
    osd:submenu('Catbox'):newline()
    osd:tab():item('x: Using: '):append(config.litterbox and 'Litterbox (temporary)' or 'Catbox (permanent)'):newline()
    if config.litterbox then
        osd:tab():item('z: Litterbox expires after: '):append(config.litterbox_expire):newline()
    else
        osd:tab():color("b0b0b0"):text('x: Litterbox expires after: '):append("N/A"):newline()
    end
    osd:submenu('Use internal cache (on streams)'):newline()
    osd:tab():item('d: Use cache: '):append(config.use_cache):newline()
    osd:tab():append(
        'There are no guardrails against clipping beyond cached time, so it is recommended to increase cache'):newline()
    osd:submenu('Save'):newline()
    osd:tab():item('s: Save preferences'):newline()
    self:overlay_draw(osd:get_text())
end

function pref_menu:save()
    local function lua_to_mpv(config_value)
        if type(config_value) == 'boolean' then
            return config_value and 'yes' or 'no'
        else
            return config_value
        end
    end
    local ignore_list = {
        video_extension = true,
        audio_extension = true,
        video_codec = true,
        audio_codec = true,
    }
    local mpv_dirpath = string.gsub(mp.get_script_directory(), "scripts[\\/][^\\/]+", "")
    local config_filepath = utils.join_path(utils.join_path(mpv_dirpath, "script-opts"), string.format('%s.conf', NAME))
    local handle = io.open(config_filepath, 'w')
    if handle ~= nil then
        handle:write(string.format("# Written by %s on %s.\n", NAME, os.date()))
        for key, value in pairs(config) do
            if ignore_list[key] == nil then
                handle:write(string.format('%s=%s\n', key, lua_to_mpv(value)))
            end
        end
        handle:close()
        h.notify("Settings saved.", "info", 2)
    else
        h.notify_error(string.format("Couldn't open %s.", config_filepath), "error", 4)
    end
end

crop_menu = Menu:new(pref_menu)

crop_menu.keybindings = {
    { key = 'MBTN_LEFT', fn = function() crop_menu:crop_click() end },
    { key = 'r',         fn = function() crop_menu:reset() end },
    { key = 'ESC',       fn = function() crop_close() end },
    { key = 'q',         fn = function() crop_close() end },
}

function crop_open()
    mp.commandv("set", 'osc', 'no')
    print("REMOVED")
    crop_menu:open()
end

function crop_close()
    mp.commandv('set', 'osc', 'yes')
    mp.command_native({ "osd-overlay", 63, 'none', 'dummy' })
    crop_menu:close();
end

function crop_menu:reset()
    config['crop'] = nil
    crop_menu:update();
end

function get_crop()
    local crop = config['crop'];
    local osd = mp.get_property_native('osd-dimensions')
    if (crop == nil) then
        return {
            width = osd.w,
            height = osd.h,
            raw_x0 = "NONE",
            raw_y0 = "NONE",
            raw_x1 = "NONE",
            raw_y1 = "NONE"
        }
    end


    local video_width = osd.w - osd.ml - osd.mr;
    local video_height = osd.h - osd.mt - osd.mb;
    for i, v in ipairs(crop) do
        print(i, 'x', v.x, 'y', v.y)
    end

    if (#crop == 1) then
        return {
            x0 = (osd.ml + crop[1].x * video_width) / osd.w,
            y0 = (osd.mt + crop[1].y * video_height) / osd.h,
            raw_x0 = string.format("%.2f%%", crop[1].x * 100),
            raw_y0 = string.format("%.2f%%", crop[1].y * 100),
            raw_x1 = "NONE",
            raw_y1 = 'NONE'
        }
    end

    return {
        x0 = (osd.ml + math.min(crop[1].x, crop[2].x) * video_width) / osd.w,
        y0 = (osd.mt + math.min(crop[1].y, crop[2].y) * video_height) / osd.h,
        x1 = (osd.ml + math.max(crop[1].x, crop[2].x) * video_width) / osd.w,
        y1 = (osd.mt + math.max(crop[1].y, crop[2].y) * video_height) / osd.h,
        raw_x0 = string.format("%.2f%%", math.min(crop[1].x, crop[2].x) * 100),
        raw_y0 = string.format("%.2f%%", math.min(crop[1].y, crop[2].y) * 100),
        raw_x1 = string.format("%.2f%%", math.max(crop[1].x, crop[2].x) * 100),
        raw_y1 = string.format("%.2f%%", math.max(crop[1].y, crop[2].y) * 100),
    }
end

function crop_menu:update()
    local crop = get_crop()
    local osd = OSD:new():outline(0)

    local w, h = mp.get_osd_size()

    osd:new_layer():config(config);

    osd:submenu('Crop'):newline()
    osd:tab():item('CLICK: Set crop point'):newline();
    osd:tab():item('r: Reset crop'):newline();
    osd:submenu("POS"):newline();
    osd:tab():item("START_X:"):append(crop.raw_x0):newline();
    osd:tab():item("START_Y:"):append(crop.raw_y0):newline();
    osd:tab():item("END_X:"):append(crop.raw_x1):newline();
    osd:tab():item("END_Y:"):append(crop.raw_y1):newline();
    self:overlay_draw(osd:get_text())

    local crop_osd = OSD:new()
    crop_osd:draw_start()
    crop_osd:append('{\\bord0\\shad0\\1c&HFF0000&\\alpha&H80}')
    --crop_osd:rect(0, 0, 960, 540)
    if (crop.x0) then crop_osd:rect(0, 0, math.floor(crop.x0 * w), h) end
    if (crop.y0) then crop_osd:rect(0, 0, w, math.floor(crop.y0 * h)) end
    if (crop.x1) then crop_osd:rect(math.floor(crop.x1 * w), 0, w, h) end
    if (crop.y1) then crop_osd:rect(0, math.floor(crop.y1 * h), w, h) end
    crop_osd:draw_stop()

    local margin_x = mp.get_property_native('osd-margin-x');
    local margin_y = mp.get_property_native('osd-margin-y');

    mp.commandv('set', 'osd-margin-x', 0);
    mp.commandv('set', 'osd-margin-y', 0);
    mp.command_native({
        "osd-overlay",
        63,                  -- overlay id
        "ass-events",        -- format
        crop_osd:get_text(), -- data
        w, h                 -- res_x, res_y
    })
    mp.commandv('set', 'osd-margin-x', margin_x);
    mp.commandv('set', 'osd-margin-y', margin_y);
end

local function clamp(value, bottom, top)
    if (value < bottom) then return bottom end;
    if (value > top) then return top end;
    return value;
end

function crop_menu:crop_click()
    local mouse_pos = mp.get_property_native('mouse-pos');
    if (mouse_pos == nil) then return end

    local osd = mp.get_property_native('osd-dimensions');
    if (osd == nil) then return end;

    if (osd.ml == nil or osd.mr == nil or osd.mb == nil or osd.mt == nil) then return end;

    local video_width = osd.w - osd.ml - osd.mr;
    local video_height = osd.h - osd.mt - osd.mb;
    local x_percent = clamp(mouse_pos.x - osd.ml, 0, video_width) / video_width;
    local y_percent = clamp(mouse_pos.y - osd.mt, 0, video_height) / video_height;

    local current = config['crop'];
    if (current == nil) then current = {} end;

    current[#current + 1] = { x = x_percent, y = y_percent };
    if (#current > 2) then table.remove(current, 1); end

    config['crop'] = current
    crop_menu:update()
end

validate_config()
encoder.init(config, main_menu.timings)
mp.add_key_binding('c', 'videoclip-menu-open', main_menu.open)
mp.register_event('shutdown', cleanup)
mp.msg.warn("Press 'c' to open the videoclip menu.")
