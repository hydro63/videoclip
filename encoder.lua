--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Encoder provides interface for creating audio/video clips.
]]

local mp = require('mp')
local h = require('helpers')
local utils = require('mp.utils')
local p = require('platform')
local this = {}

local function toms(timestamp)
    --- Trim timestamp down to milliseconds.
    return string.format("%.3f", timestamp)
end

local function clean_filename(filename)
    filename = h.remove_extension(filename)
    if this.config.clean_filename then
        filename = h.remove_text_in_brackets(filename)
        filename = h.remove_special_characters(filename)
        -- remove_text_in_brackets might leave spaces at the start or the end, so trim those
        filename = h.strip(filename)
    end
    return filename
end

local function clean_forbidden_characters(title)
    return title:gsub('[<>:"/\\|%?%*]+', '.')
end

local function construct_output_filename_noext()
    local filename = mp.get_property("filename") -- filename without path
    local title = mp.get_property("media-title") -- if the video doesn't have a title, it will fallback to filename
    local date = os.date("*t")                   -- get current date and time as table

    -- Apply the same operation when the video doesn't have a title
    -- thus it will be the same as filename
    if title == filename then
        filename = clean_filename(filename)
        title = filename
    else
        filename = clean_filename(filename)
        title = clean_forbidden_characters(title)
    end

    -- Available tags: %n = filename, %t = title, %s = start, %e = end, %d = duration,
    --                 %Y = year, %M = months, %D = day, %H = hours (24), %I = hours (12),
    --                 %P = am/pm %N = minutes, %S = seconds
    filename = this.config.filename_template
        :gsub("%%n", filename)
        :gsub("%%t", title)
        :gsub("%%s", h.human_readable_time(this.timings['start']))
        :gsub("%%e", h.human_readable_time(this.timings['end']))
        :gsub("%%d", h.human_readable_time(this.timings['end'] - this.timings['start']))
        :gsub("%%Y", date.year)
        :gsub("%%M", h.two_digit(date.month))
        :gsub("%%D", h.two_digit(date.day))
        :gsub("%%H", h.two_digit(date.hour))
        :gsub("%%I", h.two_digit(h.twelve_hour(date.hour)['hour']))
        :gsub("%%P", h.twelve_hour(date.hour)['sign'])
        :gsub("%%N", h.two_digit(date.min))
        :gsub("%%S", h.two_digit(date.sec))

    return filename
end

function this.get_ext_subs_paths()
    local track_list = mp.get_property_native('track-list')
    local external_subs_list = {}
    for _, track in pairs(track_list) do
        if track.type == 'sub' and track.external == true then
            external_subs_list[track.id] = track['external-filename']
        end
    end
    return external_subs_list
end

function this.append_embed_subs_args(args)
    local ext_subs_paths = this.get_ext_subs_paths()
    for _, ext_subs_path in pairs(ext_subs_paths) do
        args[#args + 1] = table.concat { '--sub-files-append=', ext_subs_path, }
    end
    return args
end

local allowed_extensions = {
    ['mkv'] = true,
    ['mov'] = true,
    ['mp4'] = true,
    ['m4a'] = true,
    ['3gp'] = true,
    ['3g2'] = true,
    ['mj2'] = true
}

function this.use_cache(processes, out_clip_path)
    local format = mp.get_property('file-format')
    local _, _, ext = string.find(format, '(%w+)')
    if (allowed_extensions[ext] == nil) then ext = 'mkv' end

    local temp_folder = h.expand_path(this.config.cache_path)
    local cache_file = utils.join_path(temp_folder, "cached." .. ext)
    local normalized_file = utils.join_path(temp_folder, 'normalized.' .. ext)

    local ok = p.create_folder(temp_folder)
    if (not ok) then
        print('Failed to create folder')
        return
    end

    h.notify('Dumping cache ...', 'info', 9999)
    local cache_args = { "dump-cache", toms(this.timings['start']), toms(this.timings['end'] + 5), cache_file }
    print('Cache dump >', table.concat(cache_args, ' '))
    ok = mp.commandv(table.unpack(cache_args))
    if (not ok) then
        h.notify_error('Failed to dump cache, switching to normal clipping', 'warn', 2)
        return
    end
    h.notify('Cache dumped successfully', 'info', 2)

    h.insert_table(processes[1], {
        cache_file,
        table.concat { '--o=', normalized_file }
    })

    mp.commandv('set', 'pause', 'yes')
    mp.commandv('seek', toms(this.timings['start']), 'absolute+keyframes')

    local interval_start = os.clock()
    while os.clock() - interval_start < 0.3 do end

    local cache_start = mp.get_property('time-pos')

    local sub_track = mp.get_property_native('current-tracks/sub')

    if sub_track ~= nil and sub_track.external == true then
        h.insert_table(processes[1], {
            table.concat { '--sub-delay=', tonumber(mp.get_property("sub-delay")) - cache_start },
        })
    end

    processes[#processes + 1] = {
        this.player,
        normalized_file,
        '--loop-file=no',
        '--keep-open=no',
        '--no-ocopy-metadata',
        '--no-sub',
        '--audio-channels=2',
        table.concat { '--start=', this.timings['start'] - tonumber(cache_start) },
        table.concat { '--length=', this.timings['end'] - this.timings['start'] },
        table.concat { '--o=', out_clip_path }
    }

    return processes
end

this.mk_out_path_video = function(clip_filename_noext)
    return utils.join_path(h.expand_path(this.config.video_folder_path),
        clip_filename_noext .. this.config.video_extension)
end

local quote = function(str)
    return str
end

this.mkargs_video = function(out_clip_path)
    local record_video = {
        this.player,
        '--loop-file=no',
        '--keep-open=no',
        '--no-ocopy-metadata',
        '--no-sub',
        '--audio-channels=2',
        '--oacopts-add=vbr=on',
        '--oacopts-add=application=voip',
        '--oacopts-add=compression_level=10',
        '--vf-add=format=yuv420p',
        '--sub-font-provider=auto',
        '--embeddedfonts=yes',
        table.concat { '--sub-font=', quote(this.config.sub_font) },
        table.concat { '--ovc=', quote(this.config.video_codec) },
        table.concat { '--oac=', quote(this.config.audio_codec) },
        table.concat { '--aid=', mp.get_property("aid") }, -- track number
        table.concat { '--mute=', mp.get_property("mute") },
        table.concat { '--volume=', mp.get_property('volume') },
        table.concat { '--ovcopts-add=b=', this.config.video_bitrate },
        table.concat { '--oacopts-add=b=', this.config.audio_bitrate },
        table.concat { '--ovcopts-add=crf=', this.config.video_quality },
        table.concat { '--ovcopts-add=preset=', this.config.preset },
        table.concat { '--vf-add=scale=', this.config.video_width, ':', this.config.video_height },
        table.concat { '--ytdl-format=', quote(mp.get_property("ytdl-format")) },
        table.concat { '--sid=', mp.get_property("sid") },
        table.concat { '--secondary-sid=', mp.get_property("secondary-sid") },
        table.concat { '--sub-visibility=', mp.get_property("sub-visibility") },
        table.concat { '--secondary-sub-visibility=', mp.get_property("secondary-sub-visibility") },
        table.concat { '--sub-back-color=', mp.get_property("sub-back-color") },
        table.concat { '--sub-border-style=', mp.get_property("sub-border-style") },
        table.concat { "--video-aspect-override=", mp.get_property('video-aspect-override') }
    }

    local crop = this.config.crop;
    if (crop and #crop == 2) then
        local video_width = mp.get_property_native('width');
        local video_height = mp.get_property_native('height');
        if (this.config.video_height ~= -2) then
            video_width = video_width * this.config.video_height / video_height;
            video_height = this.config.video_height;
        end

        local start_x = math.floor(math.min(crop[1].x, crop[2].x) * video_width)
        local start_y = math.floor(math.min(crop[1].y, crop[2].y) * video_height)
        local end_x = math.floor(math.max(crop[1].x, crop[2].x) * video_width)
        local end_y = math.floor(math.max(crop[1].y, crop[2].y) * video_height)
        local crop_format = string.format("%d:%d:%d:%d", end_x - start_x, end_y - start_y, start_x, start_y)
        record_video[#record_video + 1] = table.concat { '--vf-add=crop=', crop_format }
    end

    local referrer = mp.get_property('referrer')
    if referrer ~= '' then
        record_video[#record_video + 1] = table.concat { '--referrer=', quote(referrer) }
    end

    if this.config.video_fps ~= 'auto' then
        record_video[#record_video + 1] = table.concat { '--vf-add=fps=', this.config.video_fps }
    end

    print(table.concat(record_video, ' '))

    record_video = this.append_embed_subs_args(record_video)

    local processes = {
        record_video
    }

    if this.config.use_cache and mp.get_property('demuxer-via-network') == 'yes' then
        local ret = this.use_cache(processes, out_clip_path)
        if (ret ~= nil) then return ret end
    end

    h.insert_table(processes[1], {
        quote(mp.get_property('path')),
        table.concat { '--start=', toms(this.timings['start']) },
        table.concat { '--end=', toms(this.timings['end']) },
        table.concat { '--sub-delay=', mp.get_property("sub-delay") },
        table.concat { '--o=', out_clip_path }
    })

    return processes
end

this.mk_out_path_audio = function(clip_filename_noext)
    return utils.join_path(h.expand_path(this.config.audio_folder_path),
        clip_filename_noext .. this.config.audio_extension)
end

this.mkargs_audio = function(out_clip_path)
    local record_audio = {
        this.player,
        '--loop-file=no',
        '--keep-open=no',
        '--no-ocopy-metadata',
        '--no-sub',
        '--audio-channels=2',
        '--video=no',
        '--oacopts-add=vbr=on',
        '--oacopts-add=application=voip',
        '--oacopts-add=compression_level=10',
        table.concat { '--oac=', this.config.audio_codec },
        table.concat { '--volume=', mp.get_property('volume') },
        table.concat { '--aid=', mp.get_property("aid") }, -- track number
        table.concat { '--oacopts-add=b=', this.config.audio_bitrate },
        table.concat { '--ytdl-format=', mp.get_property("ytdl-format") },
    }


    local referrer = mp.get_property('referrer')
    if referrer ~= '' then
        record_audio[#record_audio + 1] = table.concat { '--referrer=', quote(referrer) }
    end


    local processes = {
        record_audio
    }

    if this.config.use_cache and mp.get_property('demuxer-via-network') == 'yes' then
        local ret = this.use_cache(processes, out_clip_path)
        if (ret ~= nil) then return ret end
    end

    h.insert_table(processes[1], {
        quote(mp.get_property('path')),
        table.concat { '--start=', toms(this.timings['start']) },
        table.concat { '--end=', toms(this.timings['end']) },
        table.concat { '--o=', out_clip_path }
    })

    return processes
end

local job = nil

this.kill_job = function()
    h.notify_error('Killing jobs', 'warn', 2)
    if (job == nil) then return end

    mp.abort_async_command(job)
end

this.proxy_subprocess_async = h.subprocess_async

--[[
this.proxy_subprocess_async = function(args, callback)
    job = h.subprocess_async(args, callback)
end
]]

this.create_clip = function(clip_type, on_complete)
    if clip_type == nil then
        return
    end

    if not this.timings:validate() then
        h.notify_error("Wrong timings. Aborting.", "warn", 2)
        return
    end

    h.notify("Please wait...", "info", 9999)

    local output_file_path, args = (function()
        local clip_filename_noext = construct_output_filename_noext()
        if clip_type == 'video' then
            local output_path = this.mk_out_path_video(clip_filename_noext)
            return output_path, this.mkargs_video(output_path)
        else
            local output_path = this.mk_out_path_audio(clip_filename_noext)
            return output_path, this.mkargs_audio(output_path)
        end
    end)()

    local output_dir_path = utils.split_path(output_file_path)
    local location_info = utils.file_info(output_dir_path)
    if not location_info or not location_info.is_dir then
        h.notify_error(string.format("Error: location %s doesn't exist.", output_dir_path), "error", 5)
        return
    end

    h.run_async_flow(function()
        for _, process in pairs(args) do
            print("The following args will be executed:", table.concat(h.quote_if_necessary(process), " "))
            local _, ret, _ = h.await(this.proxy_subprocess_async, process)
            if ret.status ~= 0 or string.match(ret.stdout, "could not open") then
                h.notify_error(string.format("Error: couldn't create clip %s.", output_file_path), "error", 5)
                return
            end
        end

        h.notify(string.format("Clip saved to %s.", output_file_path), "info", 2)
        if on_complete then
            on_complete(output_file_path)
        end
        job = nil
    end)
    this.config.crop = nil
    this.timings:reset()
end

this.set_encoder_alive = function()
    local args_mpvnet = { 'mpvnet', '--version' }
    local args = { 'mpv', '--version' }
    h.run_async_flow(function()
        local _, ret, _ = h.await(h.subprocess_async, args)
        if ret.status == 0 and string.match(ret.stdout, "mpv") ~= nil then
            this.alive = true
            this.player = 'mpv'
            return
        end

        _, ret, _ = h.await(h.subprocess_async, args_mpvnet)
        if ret.status == 0 then
            this.alive = true
            this.player = 'mpvnet'
            return
        end

        this.alive = false
    end)
end

this.init = function(config, timings_mgr)
    this.config = config
    this.timings = timings_mgr
    this.set_encoder_alive()
end

return this
