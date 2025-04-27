-- Author: geekwho-eth
-- Date: 2025-04-28
-- Description: Traffic control module for OpenResty
-- This module tracks and limits traffic usage on a monthly basis.
-- It uses a shared dictionary to store traffic data and provides functions
-- to check, reset, and save traffic usage.
-- It also includes a status page to display current traffic usage and limits.
-- It can trigger an alert when the traffic limit is exceeded.
-- It is designed to be used with OpenResty and Nginx.

local _M = {}

-- ========= Configuration =========
local config = {
    traffic_limit_per_month = 900 * 1024 * 1024 * 1024, -- monthly traffic limit (bytes)
    save_interval = 60,                                  -- Save traffic usage every 60 seconds
    alert_command = "/etc/nginx/lua/traffic_alert.sh  &",   -- Shell script to run when traffic exceeds
    log_level = ngx.INFO,                                 -- Log level
    month_format = "%Y-%m",                              -- Month format for display
    time_format = "%m",                                    -- Month number format for logic
    traffic_key = "current_traffic",                    -- Shared dict key for traffic
    month_key = "last_reset_month",                     -- Shared dict key for month
    traffic_file_path="/etc/nginx/logs/traffic_counter.txt" -- File path for persistent storage
}

-- ========= Modules =========
local cjson = require("cjson")
local traffic_data = ngx.shared.traffic_limit

-- ========= Utility Functions =========
local function format_bytes(bytes)
    -- Formats bytes into human-readable format (e.g., KB, MB, GB)
    local units = {"Bytes", "KB", "MB", "GB"}
    local i = 1
    -- #units Get array length
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format("%.2f %s", bytes, units[i])
end

local function get_traffic()
    -- Gets current traffic from shared dict
    local value, err = traffic_data:get(config.traffic_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get value: " .. err)
        return 0
    end
    return tonumber(value) or 0
end

local function set_traffic(bytes)
    -- Sets current traffic to shared dict
    local ok,err = traffic_data:set(config.traffic_key, bytes)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set value: " .. err)
        return false
    end
    return true
end

local function get_month()
    -- Gets current month (1-12)
    return tonumber(os.date(config.time_format, ngx.time()))
end

-- os.date("*t").month get month number 
local function get_last_reset_month()
    -- Gets last reset month from shared dict
    local month_str, err = traffic_data:get(config.month_key)
    if err then
        ngx.log(ngx.ERR, "Failed to get last reset month: " .. err)
        return nil
    end
    return tonumber(month_str)
end

local function set_last_reset_month(month)
    -- Sets last reset month to shared dict
    local success, err = traffic_data:set(config.month_key, month)
    if not success then
        ngx.log(ngx.ERR, "Failed to set last reset month: " .. err)
        return false
    end
    return true
end

-- ========= File Synchronization =========
local function save_to_file(traffic, month)
    -- Saves current traffic and month to a file
    local file, err = io.open(config.traffic_file_path, "w")
    if not file then
        ngx.log(ngx.ERR, "Failed to open file: " .. tostring(err))
        return false
    end

    local data = cjson.encode({traffic = traffic, month = month})
    local success, write_err = file:write(data .. "\n")
    file:close()

    if not success then
        ngx.log(ngx.ERR, "Failed to write file: " .. tostring(write_err))
        return false
    end

    ngx.log(ngx.INFO, string.format("Traffic data saved to file: %s, Traffic size: %s, last reset month: %d",config.traffic_file_path, format_bytes(traffic), month))
    return true
end

local function load_from_file()
    -- Loads traffic and month data from a file
    local file, err = io.open(config.traffic_file_path, "r")
    if not file then
        ngx.log(ngx.WARN, "Failed to open file for reading: " .. tostring(err))
        return nil, nil
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        ngx.log(ngx.WARN, "File is empty")
        return nil, nil
    end

    local success, data = pcall(cjson.decode, content)
    if not success or not data.traffic or not data.month then
        ngx.log(ngx.ERR, "Failed to decode file data: " .. tostring(data))
        return nil, nil
    end

    return data.traffic, data.month
end

-- ========= Core Functions =========
function _M.load_traffic()
    -- Loads traffic data from shared dict or file on module initialization
    local traffic_data = get_traffic()
    local last_reset_month = get_last_reset_month()

    if traffic_data and last_reset_month then
        ngx.log(ngx.INFO, string.format("Traffic loaded: %s, last reset month: %d", format_bytes(traffic_data), last_reset_month))
        -- sync to file
        -- save_to_file(traffic_data, last_reset_month)
        return 
    end

    -- Load from file if not in shared dict
    local file_traffic, file_month = load_from_file()
    if file_traffic and file_month then
        traffic = file_traffic
        last_reset_month = file_month
        set_traffic(traffic)
        set_last_reset_month(last_reset_month)
        ngx.log(ngx.INFO, string.format("Traffic loaded from file: %s, month: %d", format_bytes(traffic), last_reset_month))
    else
        -- Initialize with defaults if no data found
        traffic = 0
        last_reset_month = get_month()
        set_traffic(traffic)
        set_last_reset_month(last_reset_month)
        ngx.log(ngx.ERR, "Traffic data not found in shared dict, initializing...")
    end
end

function _M.save_traffic(premature)
    -- Saves current traffic data to file (used by timer)
    if premature then
        return -- Skip save if timer is being shut down
    end

    local traffic = get_traffic()
    local month = get_last_reset_month()
    if not traffic or not month then
        ngx.log(ngx.ERR, "No traffic data to save")
        return
    end

    -- Save to file
    save_to_file(traffic, month)
end

local function trigger_alert(current)
    -- Triggers an alert command if traffic limit is reached and not already alerted
    local alerted, err = traffic_data:get("alerted")
    if alerted then
        return
    end

    traffic_data:set("alerted", true) -- Set alerted status

    -- Run command in a non-blocking timer
    ngx.timer.at(0, function()
        local handle,popen_err = io.popen(config.alert_command, "r") -- Use io.popen for safer execution
        if not handle then
            ngx.log(ngx.ERR, "Failed to execute alert command: " .. tostring(popen_err))
            return
        end

        local result = handle:read("*a")
        local status = handle:close()
        if status ~= 0 then
            ngx.log(ngx.ERR, "Alert command failed: ", result)
        else
            ngx.log(ngx.INFO, "Alert command executed successfully.")
        end
    end)

    ngx.log(ngx.ERR, string.format("Traffic limit reached: %s", format_bytes(current)))
end

function _M.reset_month_traffic()
    -- Resets traffic counter at the beginning of a new month
    local now_month = get_month()
    local last_reset_month = get_last_reset_month()

    if last_reset_month ~= now_month then
        set_traffic(0) -- Reset traffic
        set_last_reset_month(now_month) -- Update reset month
        traffic_data:delete("alerted") -- Reset alert status
        _M.save_traffic(false) -- Save the reset state
        ngx.log(ngx.INFO, "Monthly traffic reset.")
    end
end

function _M.check_limit_before_response()
    -- Checks traffic limit before sending response headers. Denies request if exceeded.

    local current_traffic = get_traffic()

    if current_traffic >= config.traffic_limit_per_month then
        trigger_alert(current_traffic)
        ngx.header["Content-Type"] = "text/plain; charset=utf-8"
        ngx.status = ngx.HTTP_FORBIDDEN
        ngx.say("Traffic limit exceeded for this month. Service unavailable.")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end

function _M.record_traffic_after_response()
    -- Records traffic bytes after the response is sent
    local bytes = tonumber(ngx.var.bytes_sent or 0) or 0
    if bytes > 0 then
        local current_traffic = get_traffic()
        current_traffic = current_traffic + bytes
        set_traffic(current_traffic)
    end
    ngx.log(ngx.INFO, string.format("bytes_sent: %s", format_bytes(bytes)))
end

function _M.status_page()
    -- Generates a JSON status page with current traffic usage
    ngx.header.content_type = "application/json; charset=utf-8"
    local now = ngx.time()
    local safe_limit = config.traffic_limit_per_month > 0 and config.traffic_limit_per_month or 1
    local current_traffic = get_traffic()

    local used_percent = (current_traffic / safe_limit) * 100

    ngx.say(cjson.encode({
        timestamp = now,
        total_out_traffic = format_bytes(current_traffic),
        traffic_limit_per_month = format_bytes(config.traffic_limit_per_month),
        used_percent = string.format("%.2f%%", used_percent),
        current_month = os.date(config.month_format, ngx.time())
    }))
end

function _M.safe_save_traffic(premature)
    -- Wrapper function for timer to catch errors during save_traffic
    if premature then return end
    local ok, err = pcall(_M.save_traffic)
    if not ok then
        ngx.log(ngx.ERR, "Timer task save_traffic failed: ", err)
    end
end

function _M.init_timer_with_lock()
    -- Initializes a timer to save traffic data periodically using shared dict lock

    -- try lock: add is atomic. if success then get the lock
    local ok, err = traffic_data:add("timer_lock_started", true, 1)
    if not ok then
        -- if lock fail ,then other worker has started the timer
        ngx.log(ngx.ERR, "Timer already started by another worker.")
        return
    end

    -- only get the lock worker, start the timer
    local ok, err = ngx.timer.every(config.save_interval, _M.safe_save_traffic)
    if not ok then
        ngx.log(ngx.ERR, "Failed to start traffic timer: ", err)
        -- if started failed, then release the lock.
        traffic_data:delete("timer_lock_started")
        return
    end

    ngx.log(ngx.INFO, "Traffic timer started by worker ", ngx.worker.id())
end

return _M