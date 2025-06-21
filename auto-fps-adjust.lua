-- auto-fps-adjust.lua
-- Automatically adjusts video fps filter based on frame drop performance
-- Place in ~/.config/mpv/scripts/ or mpv portable/scripts/

local msg = require 'mp.msg'
local utils = require 'mp.utils'

local config = {
    initial_sample_count = 10, -- take 10 samples (1 per second) for initial measurement
    sample_interval = 10,      -- seconds between measurements after initialization
    sample_count = 6,          -- number of samples to keep for outlier filtering
    fps_step = 5,             -- snap to 5fps increments (25, 30, 35, 40, etc.)
    min_fps = 25,             -- minimum fps before warning, unless file < warning_threshold
    warning_threshold = 30,    -- show warning below this fps
    initial_delay = 2,        -- wait 2 seconds before starting initial sampling
    drop_threshold = 2        -- consider drops "significant" if > 2 per measurement period
}
local drop_samples = {}
local initial_samples = {}
local last_drop_count = 0
local video_fps = 60
local current_target_fps = 60
local timer = nil
local initial_timer = nil
local initialized = false
local in_initial_sampling = false

local function is_video_file()
	local is_image = mp.get_property_native("current-tracks/video/image")
    local is_album_art = mp.get_property_native("current-tracks/video/albumart")
    if is_image or is_album_art then
        return false
    end  
    return true
end
local function table_copy(t)
    local copy = {}
    for i, v in ipairs(t) do
        copy[i] = v
    end
    return copy
end

local function get_video_fps()
    local fps = mp.get_property_number("container-fps")
    if not fps then
        fps = mp.get_property_number("fps")
    end
    if fps and fps > 0 then
        return math.floor(fps + 0.5)  -- round to nearest integer
    end
    return 60  -- fallback
end

-- Snap fps to nearest step
local function snap_to_step(fps)
    local snapped = math.floor((fps + config.fps_step/2) / config.fps_step) * config.fps_step
    return math.max(snapped, config.min_fps)
end

local function apply_fps_filter(target_fps)
    if target_fps == current_target_fps then
        return
    end
    current_target_fps = target_fps

    if target_fps >= video_fps then
        -- Remove fps filter if target matches original
        mp.set_property("vf", "")
        -- msg.info("Removed fps filter - running at native " .. video_fps .. "fps")
        mp.osd_message("Native " .. video_fps .. "fps", 2)
    else
        -- Use command method, set property doesn't work
        mp.set_property("vf", "")  -- clear first
        mp.command("vf add fps=" .. target_fps)
		mp.set_property("display-fps-override", target_fps)
        -- msg.info("Applied fps filter: " .. target_fps .. "fps")
        mp.osd_message("Adjusted to " .. target_fps .. "fps", 2)
    end
end

local function check_and_adjust()
    if not initialized then
        msg.debug("check_and_adjust called but not initialized")
        return
    end
    local paused = mp.get_property_bool("pause")
    if paused then
        msg.debug("Video paused, skipping adjustment")
        return
    end
    local current_drops = mp.get_property_number("frame-drop-count")
    if not current_drops then
        msg.warn("Could not get frame drop count")
        return
    end
    local drops_in_window = current_drops - last_drop_count
    local drop_rate = drops_in_window / config.sample_interval
    -- msg.info("Regular check - drops in window: " .. drops_in_window .. ", drop rate: " .. drop_rate)
    -- Add to sample history
    table.insert(drop_samples, drop_rate)
    if #drop_samples > config.sample_count then
        table.remove(drop_samples, 1)
    end
    if #drop_samples >= 3 then
        -- remove highest and lowest, average the rest
        local sorted = table_copy(drop_samples)
        table.sort(sorted)
        local sum = 0
        local count = 0
        for i = 2, #sorted - 1 do  -- skip first and last (outliers)
            sum = sum + sorted[i]
            count = count + 1
        end
        local filtered_drop_rate = count > 0 and (sum / count) or 0
        -- msg.info("Filtered drop rate: " .. filtered_drop_rate .. ", current target: " .. current_target_fps)
        -- Incremental adjustment logic
        local new_target_fps = current_target_fps
        if filtered_drop_rate > config.drop_threshold then
            new_target_fps = current_target_fps - config.fps_step
            -- msg.info("Drops detected (" .. filtered_drop_rate .. "), reducing fps to " .. new_target_fps)
        elseif filtered_drop_rate == 0 then
            new_target_fps = current_target_fps + config.fps_step
            new_target_fps = math.min(new_target_fps, video_fps)
            -- if new_target_fps > current_target_fps then
                -- msg.info("Low drops (" .. filtered_drop_rate .. "), increasing fps to " .. new_target_fps)
            -- end
        -- else
            -- msg.info("Drop rate acceptable (" .. filtered_drop_rate .. "), keeping current fps: " .. current_target_fps)
        end
        new_target_fps = math.max(new_target_fps, config.min_fps)
        -- Show warning for low performance
        if (new_target_fps < config.warning_threshold and video_fps > config.warning_threshold) or (filtered_drop_rate > config.drop_threshold) then
            mp.osd_message("Low performance: " .. new_target_fps .. "fps", 3)
            msg.warn("Performance warning") -- : " .. new_target_fps .. "fps"
        end
        -- Apply the fps filter if changed
        if new_target_fps ~= current_target_fps then
            apply_fps_filter(new_target_fps)
        end
    -- else
        -- msg.info("Not enough samples yet for adjustment (" .. #drop_samples .. "/3)")
    end
    last_drop_count = current_drops
end

local function initial_sample()
    if not in_initial_sampling then
        msg.warn("initial_sample called but not in sampling mode")
        return
    end
    -- Check if video is paused
    local paused = mp.get_property_bool("pause")
    if paused then
        -- msg.debug("Video paused during initial sampling, skipping")
        return
    end
    
    local current_drops = mp.get_property_number("frame-drop-count")
    if not current_drops then
        -- msg.warn("Could not get frame drop count during initial sampling")
        return
    end
    local drops_in_last_second = current_drops - last_drop_count
    table.insert(initial_samples, drops_in_last_second)
    last_drop_count = current_drops
    -- msg.info("Initial sample " .. #initial_samples .. "/10: " .. drops_in_last_second .. " drops/sec")
    mp.osd_message("Sampling performance: " .. #initial_samples .. "/10", 1)
    
    if #initial_samples >= config.initial_sample_count then
        -- Calculate initial target fps
        local total_drops = 0
        for _, drops in ipairs(initial_samples) do
            total_drops = total_drops + drops
        end
        local avg_drop_rate = total_drops / config.initial_sample_count
        local effective_fps = video_fps - avg_drop_rate
        local target_fps = snap_to_step(effective_fps)
        -- msg.info("Initial sampling complete. Average drop rate: " .. avg_drop_rate .. ", target fps: " .. target_fps)
        apply_fps_filter(target_fps)
        if initial_timer then
            initial_timer:kill()
            initial_timer = nil
        end
        in_initial_sampling = false
        initialized = true
        timer = mp.add_periodic_timer(config.sample_interval, function()
            check_and_adjust()
        end)
        mp.osd_message("Auto fps initialized: " .. target_fps .. "fps", 3)
    end
end

-- Initialize when file starts playing
local function on_file_loaded()
    if not is_video_file() then
        return
    end
    -- Reset any existing fps filter from previous files
    mp.set_property("vf", "")
    -- msg.info("Reset video filters for new file")
    video_fps = get_video_fps()
	mp.set_property("display-fps-override", video_fps)
    current_target_fps = video_fps
    drop_samples = {}
    initial_samples = {}
    last_drop_count = 0
    initialized = false
    in_initial_sampling = false
    -- msg.info("Auto fps adjustment loaded - video fps: " .. video_fps)
    mp.osd_message("Auto fps: " .. video_fps .. "fps detected", 2)
    
    -- Reset any existing timers
    if timer then
        timer:kill()
        timer = nil
    end
    if initial_timer then
        initial_timer:kill()
        initial_timer = nil
    end
    mp.add_timeout(config.initial_delay, function()
        last_drop_count = mp.get_property_number("frame-drop-count") or 0
        in_initial_sampling = true
        mp.osd_message("Starting performance analysis...", 2)
        initial_timer = mp.add_periodic_timer(1, function()
            initial_sample()
        end)
    end)
end

local function on_file_end()
    if timer then
        timer:kill()
        timer = nil
    end
    if initial_timer then
        initial_timer:kill()
        initial_timer = nil
    end
    initialized = false
    in_initial_sampling = false
    -- msg.info("Auto fps adjustment stopped")
end

-- Manual reset command, expose as needed
local function reset_fps()
    drop_samples = {}
    apply_fps_filter(video_fps)
    mp.osd_message("Auto fps reset to native " .. video_fps .. "fps", 2)
    -- msg.info("Manual reset to native fps")
end
-- Manual toggle command
local function toggle_auto_fps()
    -- msg.info("toggle_auto_fps called")
    if timer then
        timer:kill()
        timer = nil
        mp.osd_message("Auto fps adjustment disabled", 2)
    else
        if initialized then
            timer = mp.add_periodic_timer(config.sample_interval, function()
                check_and_adjust()
            end)
            mp.osd_message("Auto fps adjustment enabled", 2)
        else
            mp.osd_message("Auto fps not initialized yet", 2)
        end
    end
end

-- Register event handlers
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_file_end)

-- Register key bindings with explicit binding names for input.conf
mp.add_key_binding(nil, "auto-fps-reset", reset_fps)
mp.add_key_binding(nil, "auto-fps-toggle", toggle_auto_fps)
mp.add_key_binding(nil, "auto-fps-test", test_script)

-- useful for debugging
local function test_script()
    mp.osd_message("Auto fps: Current state: " .. 
                   (initialized and "active" or "inactive"), 3)
    msg.info("Script test - initialized: " .. tostring(initialized) .. ", in_initial_sampling: " .. tostring(in_initial_sampling))
end

mp.add_key_binding(nil, "auto-fps-test", test_script)
