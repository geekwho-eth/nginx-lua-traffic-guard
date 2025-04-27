# Nginx Lua Traffic Guard

A lightweight Lua-based Nginx traffic control system that limits total network traffic (default 1 TB). Once the limit is reached, further requests are blocked with a 403 error.

## Features

- Accurately tracks total request traffic.
- Automatically persists traffic data every 60 seconds.
- Automatically loads traffic data after Nginx reload/restart.
- Provides a `/getTrafficStatus` API endpoint returning real-time usage data.
- Supports customizable traffic limit thresholds.
- Sends an alert (via a shell script) when traffic exceeds the threshold.

## Project Structure

```shell
/etc/nginx/lua/traffic_control.lua
/etc/nginx/lua/traffic_alert.sh
/etc/nginx/logs/traffic_counter.txt
/etc/nginx/lua_traffic_limit.conf
```

## Setup

1. Install OpenResty or Nginx with Lua module.
2. Place `traffic_control.lua` under `/etc/nginx/lib/lua/`. you can set own config.
3. Add Lua configurations to your `nginx.conf` as shown in the sample config.
4. Prepare the alert script `/etc/nginx/lua/traffic_alert.sh`.
5. Restart Nginx.
6. visit your site: https://your.domain/getTrafficStatus. Don't forget to add auth_basic.

## traffic status API

- **Endpoint**: `/getTrafficStatus`
- **Response Example**:

```json
{
  "timestamp": 1714380297,
  "total_out_traffic": "512.36 GB",
  "limit_traffic": "1024.00 GB",
  "used_percent": "50.03%",
  "current_month": "2025-05"
}
```


## Alert Script Example

```shell
#!/bin/bash
echo "Traffic limit exceeded!" | mail -s "Traffic Alert" your_email@example.com
```

Make sure the script has executable permissions:

```shell
chmod +x /etc/nginx/lua/traffic_alert.sh
```

## Notes

Lua modules must be enabled in Nginx.

The default traffic limit is set to 1TB. You can adjust it inside traffic_control.lua.

You can extend the alert mechanism to Telegram, Slack, SMS, etc.