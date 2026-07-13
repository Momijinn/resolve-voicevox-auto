local function resolve_path(base_dir, value)
  if not value or value == "" then
    return value
  end
  if value:sub(1, 1) == "/" then
    return value
  end
  if value:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "") .. value:sub(2)
  end
  return base_dir .. "/" .. value
end

local function write_file(path, content)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function main()
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir = script_path:match("^(.*)/") or "."
  local config_path = script_dir .. "/config.data"

  local ok_cfg, config = pcall(dofile, config_path)
  if not ok_cfg or type(config) ~= "table" then
    print("設定ファイルの読み込みに失敗しました: " .. tostring(config_path))
    return 1
  end

  local rt = config.runtime or {}
  local stop_file = resolve_path(script_dir, rt.watch_stop_file or "./watch.stop")
  local lock_file = resolve_path(script_dir, rt.watch_lock_file or "./watch.lock")

  local ok = write_file(stop_file, os.date("%Y-%m-%d %H:%M:%S") .. " stop")
  os.remove(lock_file)
  if ok then
    print("watch stop signal created: " .. stop_file)
    print("watch lock cleared: " .. lock_file)
    return 0
  end

  print("failed to create stop signal: " .. stop_file)
  return 1
end

return main()
