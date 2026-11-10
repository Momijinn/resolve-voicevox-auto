local function escape_lua_string(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\"", "\\\"")
  return s
end

local function to_number(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
end

local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_csv(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    local t = trim(part)
    if t ~= "" then
      table.insert(out, t)
    end
  end
  return out
end

local function append_all(dst, src)
  for _, v in ipairs(src) do
    table.insert(dst, v)
  end
end

local function default_voicevox()
  return {
    speaker_id = 1,
    speed_scale = 1.0,
    pitch_scale = 0.0,
    intonation_scale = 1.0,
    volume_scale = 1.0,
    pre_phoneme_length = 0.1,
    post_phoneme_length = 0.1,
    sample_rate = 48000,
    output_stereo = true,
  }
end

local function voicevox_lines(vv, indent)
  return {
    string.format("%sspeaker_id = %d,", indent, math.floor(to_number(vv.speaker_id, 1))),
    string.format("%sspeed_scale = %s,", indent, tostring(to_number(vv.speed_scale, 1.0))),
    string.format("%spitch_scale = %s,", indent, tostring(to_number(vv.pitch_scale, 0.0))),
    string.format("%sintonation_scale = %s,", indent, tostring(to_number(vv.intonation_scale, 1.0))),
    string.format("%svolume_scale = %s,", indent, tostring(to_number(vv.volume_scale, 1.0))),
    string.format("%spre_phoneme_length = %s,", indent, tostring(to_number(vv.pre_phoneme_length, 0.1))),
    string.format("%spost_phoneme_length = %s,", indent, tostring(to_number(vv.post_phoneme_length, 0.1))),
    string.format("%ssample_rate = %d,", indent, math.floor(to_number(vv.sample_rate, 48000))),
    string.format("%soutput_stereo = %s,", indent, vv.output_stereo and "true" or "false"),
  }
end

local function serialize_config(cfg)
  local rs = cfg.resolve or {}
  local rt = cfg.runtime or {}
  local presets = cfg.presets or { selected = "", list = {} }

  local lines = { "return {", "  voicevox = {" }
  append_all(lines, voicevox_lines(cfg.voicevox or {}, "    "))
  append_all(lines, {
    "  },",
    "",
    "  presets = {",
    string.format('    selected = "%s",', escape_lua_string(presets.selected)),
    "    list = {",
  })
  for _, item in ipairs(presets.list) do
    append_all(lines, { "      {", string.format('        name = "%s",', escape_lua_string(item.name)), "        voicevox = {" })
    append_all(lines, voicevox_lines(item.voicevox or {}, "          "))
    append_all(lines, { "        },", "      }," })
  end
  append_all(lines, {
    "    },",
    "  },",
    "",
    "  resolve = {",
    string.format("    text_track_index = %d,", math.floor(to_number(rs.text_track_index, 1))),
    "  },",
    "",
    "  runtime = {",
    string.format('    output_dir = "%s",', escape_lua_string(rt.output_dir or "")),
    string.format('    log_path = "%s",', escape_lua_string(rt.log_path or "./run.log")),
    "  },",
    "}",
    "",
  })

  return table.concat(lines, "\n")
end

local function default_config()
  return {
    voicevox = default_voicevox(),
    resolve = {
      text_track_index = 1,
    },
    runtime = {
      output_dir = "",
      log_path = "./run.log",
    },
  }
end

local function normalize_presets(cfg)
  local vv_now = cfg.voicevox or default_voicevox()
  local p = cfg.presets or {}
  local list = {}
  for _, item in ipairs(p.list or {}) do
    if type(item) == "table" and trim(item.name) ~= "" and type(item.voicevox) == "table" then
      table.insert(list, { name = trim(item.name), voicevox = item.voicevox })
    end
  end
  if #list == 0 then
    table.insert(list, { name = "標準", voicevox = vv_now })
  end

  local selected = trim(p.selected)
  local found = false
  for _, item in ipairs(list) do
    if item.name == selected then
      found = true
      break
    end
  end
  if not found then
    selected = list[1].name
  end

  return { selected = selected, list = list }
end

local function load_or_default_config(config_path)
  local ok, cfg = pcall(dofile, config_path)
  if ok and type(cfg) == "table" then
    return cfg
  end

  return default_config()
end

local function write_text_file(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(text)
  f:close()
  return true, nil
end

local function run_capture(cmd)
  local p = io.popen(cmd)
  if not p then return nil end
  local out = p:read("*a")
  p:close()
  return out
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function execute_ok(...)
  local argc = select("#", ...)
  if argc == 1 then
    local res = ...
    return res == true or res == 0
  end

  local ok, _, code = ...
  if ok == true then return true end
  if type(code) == "number" and code == 0 then return true end
  return false
end

local function resolve_docker_cmd()
  local home = os.getenv("HOME") or ""
  local candidates = {
    home .. "/.rd/bin/docker",
    "/opt/homebrew/bin/docker",
    "/usr/local/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
  }

  for _, cmd in ipairs(candidates) do
    if execute_ok(os.execute("[ -x " .. shell_quote(cmd) .. " ]")) then
      return cmd
    end
  end

  if execute_ok(os.execute("command -v docker >/dev/null 2>&1")) then
    return "docker"
  end

  return nil
end

local function docker_container_running(docker_cmd, name)
  local cmd = shell_quote(docker_cmd) .. " ps --format '{{.Names}}' | grep -q '^" .. tostring(name) .. "$' >/dev/null 2>&1"
  return execute_ok(os.execute(cmd))
end

local function docker_container_exists(docker_cmd, name)
  local cmd = shell_quote(docker_cmd) .. " ps -a --format '{{.Names}}' | grep -q '^" .. tostring(name) .. "$' >/dev/null 2>&1"
  return execute_ok(os.execute(cmd))
end

local function ensure_voicevox_engine_running()
  local docker_cmd = resolve_docker_cmd()
  if not docker_cmd then
    return false, "docker command not found"
  end

  local name = "voicevox_engine"
  local image = "voicevox/voicevox_engine:cpu-ubuntu24.04-0.26.0-dev"
  local port = "50022"

  if not docker_container_running(docker_cmd, name) then
    local ok = false
    if docker_container_exists(docker_cmd, name) then
      ok = execute_ok(os.execute(shell_quote(docker_cmd) .. " start " .. shell_quote(name) .. " >/dev/null 2>&1"))
    else
      ok = execute_ok(os.execute(
        shell_quote(docker_cmd) .. " run -d --name " .. shell_quote(name) ..
        " -p " .. tostring(port) .. ":50021 " .. shell_quote(image) .. " >/dev/null 2>&1"
      ))
    end

    if not ok then
      return false, "failed to start docker container"
    end
  end

  for _ = 1, 90 do
    local out = run_capture("curl -sS --max-time 2 http://127.0.0.1:" .. tostring(port) .. "/version 2>/dev/null")
    if out and #trim(out) > 0 then
      return true, nil
    end
    os.execute("sleep 1")
  end

  return false, "VOICEVOX engine not ready"
end

local function register_docker_stop_guard(docker_cmd, container_name)
  local tmp = string.format("/tmp/vv_guard_%d_%d.sh", os.time(), math.random(10000, 99999))
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write("#!/bin/sh\n")
  f:write("while pgrep -x 'DaVinci Resolve' >/dev/null 2>&1 || pgrep -x Resolve >/dev/null 2>&1; do sleep 10; done\n")
  f:write(shell_quote(docker_cmd) .. " stop " .. shell_quote(container_name) .. " >/dev/null 2>&1\n")
  f:write("rm -f " .. shell_quote(tmp) .. "\n")
  f:close()
  os.execute("/usr/bin/nohup /bin/sh " .. shell_quote(tmp) .. " </dev/null >/dev/null 2>&1 &")
end

-- コンテナを起動するだけ（ヘルスチェック待ちなし）。UIをブロックしない。
local function start_voicevox_docker_nowait()
  local docker_cmd = resolve_docker_cmd()
  if not docker_cmd then return end

  local name = "voicevox_engine"
  local image = "voicevox/voicevox_engine:cpu-ubuntu24.04-0.26.0-dev"
  local port = "50022"

  if docker_container_running(docker_cmd, name) then
    -- 既に起動中 → Resolve 終了時に停止するガードだけ登録
    register_docker_stop_guard(docker_cmd, name)
    return
  end

  local ok = false
  if docker_container_exists(docker_cmd, name) then
    ok = execute_ok(os.execute(shell_quote(docker_cmd) .. " start " .. shell_quote(name) .. " >/dev/null 2>&1"))
  else
    ok = execute_ok(os.execute(
      shell_quote(docker_cmd) .. " run -d --name " .. shell_quote(name) ..
      " -p " .. tostring(port) .. ":50021 " .. shell_quote(image) .. " >/dev/null 2>&1"
    ))
  end

  if ok then
    register_docker_stop_guard(docker_cmd, name)
  end
end

local function decode_json(text)
  local s = tostring(text or "")
  local pos = 1
  local len = #s

  local function skip_ws()
    while pos <= len do
      local c = s:sub(pos, pos)
      if c == " " or c == "\n" or c == "\r" or c == "\t" then
        pos = pos + 1
      else
        break
      end
    end
  end

  local parse_value

  local function parse_string()
    if s:sub(pos, pos) ~= '"' then
      return nil, "expected string"
    end
    pos = pos + 1
    local out = {}

    while pos <= len do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out), nil
      end

      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        if n == '"' or n == "\\" or n == "/" then
          table.insert(out, n)
          pos = pos + 2
        elseif n == "b" then
          table.insert(out, "\b")
          pos = pos + 2
        elseif n == "f" then
          table.insert(out, "\f")
          pos = pos + 2
        elseif n == "n" then
          table.insert(out, "\n")
          pos = pos + 2
        elseif n == "r" then
          table.insert(out, "\r")
          pos = pos + 2
        elseif n == "t" then
          table.insert(out, "\t")
          pos = pos + 2
        elseif n == "u" then
          local hex = s:sub(pos + 2, pos + 5)
          if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
            return nil, "invalid unicode escape"
          end
          table.insert(out, "?")
          pos = pos + 6
        else
          return nil, "invalid escape"
        end
      else
        table.insert(out, c)
        pos = pos + 1
      end
    end

    return nil, "unterminated string"
  end

  local function parse_number()
    local start_pos = pos
    local token = s:match("^-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
    if not token or #token == 0 then
      token = s:match("^-?%d+", pos)
    end
    if not token or #token == 0 then
      return nil, "invalid number"
    end
    pos = start_pos + #token
    local n = tonumber(token)
    if n == nil then
      return nil, "invalid number value"
    end
    return n, nil
  end

  local function parse_array()
    if s:sub(pos, pos) ~= "[" then
      return nil, "expected ["
    end
    pos = pos + 1
    skip_ws()

    local arr = {}
    if s:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr, nil
    end

    while pos <= len do
      local v, err = parse_value()
      if err then return nil, err end
      table.insert(arr, v)

      skip_ws()
      local c = s:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return arr, nil
      elseif c == "," then
        pos = pos + 1
        skip_ws()
      else
        return nil, "expected , or ]"
      end
    end

    return nil, "unterminated array"
  end

  local function parse_object()
    if s:sub(pos, pos) ~= "{" then
      return nil, "expected {"
    end
    pos = pos + 1
    skip_ws()

    local obj = {}
    if s:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj, nil
    end

    while pos <= len do
      local key, err_key = parse_string()
      if err_key then return nil, err_key end

      skip_ws()
      if s:sub(pos, pos) ~= ":" then
        return nil, "expected :"
      end
      pos = pos + 1
      skip_ws()

      local value, err_val = parse_value()
      if err_val then return nil, err_val end
      obj[key] = value

      skip_ws()
      local c = s:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return obj, nil
      elseif c == "," then
        pos = pos + 1
        skip_ws()
      else
        return nil, "expected , or }"
      end
    end

    return nil, "unterminated object"
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(pos, pos)
    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == "-" or c:match("%d") then
      return parse_number()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true, nil
    elseif s:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false, nil
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil, nil
    end
    return nil, "unexpected token"
  end

  local value, err = parse_value()
  if err then return nil, err end

  skip_ws()
  if pos <= len then
    return nil, "trailing characters"
  end

  return value, nil
end

local function parse_speaker_map(speakers_json)
  local id_to_display = {}
  local root, err = decode_json(speakers_json)
  if err or type(root) ~= "table" then
    return id_to_display
  end

  for _, speaker in ipairs(root) do
    if type(speaker) == "table" then
      local speaker_name = tostring(speaker.name or "")
      local styles = speaker.styles
      if speaker_name ~= "" and type(styles) == "table" then
        for _, style in ipairs(styles) do
          if type(style) == "table" then
            local style_id = tonumber(style.id)
            local style_name = tostring(style.name or "")
            if style_id and style_name ~= "" then
              id_to_display[style_id] = string.format("%s（%s）", speaker_name, style_name)
            end
          end
        end
      end
    end
  end

  return id_to_display
end

local BASE_URL = "http://127.0.0.1:50022"

local function fetch_speaker_map()
  local base_url = BASE_URL

  local cmd = "curl -sS " .. shell_quote(base_url .. "/speakers") .. " -w '\nHTTPSTATUS:%{http_code}' 2>&1"
  local out = run_capture(cmd)
  if not out then
    return nil, "curl execution error"
  end

  local status = out:match("HTTPSTATUS:(%d+)")
  local body = out:gsub("\n?HTTPSTATUS:%d+", "")
  if tonumber(status) ~= 200 then
    return nil, "http=" .. tostring(status or "?")
  end

  local speaker_map = parse_speaker_map(body)
  local count = 0
  for _, _ in pairs(speaker_map) do
    count = count + 1
  end
  if count == 0 then
    return nil, "no speakers parsed"
  end

  return speaker_map, nil
end

local function build_speaker_items(speaker_map)
  local ids = {}
  for sid, _ in pairs(speaker_map or {}) do
    table.insert(ids, sid)
  end
  table.sort(ids, function(a, b)
    local la = tostring((speaker_map or {})[a] or "")
    local lb = tostring((speaker_map or {})[b] or "")
    if la == lb then
      return tonumber(a) < tonumber(b)
    end
    return la < lb
  end)

  local items = {}
  for _, sid in ipairs(ids) do
    table.insert(items, { id = sid, label = speaker_map[sid] })
  end
  return items
end

local function main()
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir = script_path:match("^(.*)/") or "."
  local config_path = script_dir .. "/config.data"
  local config_load_path = config_path

  local resolve_obj = resolve or (Resolve and Resolve())
  if not resolve_obj then
    print("Resolve API が見つかりません。Resolve 内から実行してください。")
    return 1
  end

  local fusion = resolve_obj:Fusion()
  if not fusion or not fusion.UIManager or not bmd or not bmd.UIDispatcher then
    print("UIManager が使えません。")
    return 1
  end

  local ui = fusion.UIManager
  local disp = bmd.UIDispatcher(ui)

  start_voicevox_docker_nowait()

  local win = disp:AddWindow({
    ID = "VoiceVoxConfigWin",
    WindowTitle = "Resolve VOICEVOX 設定",
    Geometry = { 120, 120, 820, 940 },
  },
  ui:VGroup {
    ID = "root",
    Spacing = 8,
    Weight = 1,

    ui:Label { Text = "Resolve + VOICEVOX 設定", Weight = 0 },
    ui:Label { ID = "status", Text = "", Weight = 0 },

    ui:VGroup {
      Weight = 0,
      Spacing = 4,
      ui:Label { Text = "プリセット" },
      ui:HGroup {
        ui:ComboBox { ID = "preset_select", Weight = 0.5 },
        ui:Button { ID = "preset_add_btn", Text = "追加", Weight = 0 },
        ui:Button { ID = "preset_update_btn", Text = "更新", Weight = 0 },
        ui:Button { ID = "preset_delete_btn", Text = "削除", Weight = 0 },
      },
    },

    ui:VGroup {
      Weight = 0,
      Spacing = 4,
      ui:Label { Text = "VOICEVOX（音声合成）" },
      ui:HGroup { ui:Label { Text = "話者", Weight = 0.35 }, ui:ComboBox { ID = "speaker_select", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "話速", Weight = 0.35 }, ui:LineEdit { ID = "speed_scale", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "音高", Weight = 0.35 }, ui:LineEdit { ID = "pitch_scale", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "抑揚", Weight = 0.35 }, ui:LineEdit { ID = "intonation_scale", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "音量", Weight = 0.35 }, ui:LineEdit { ID = "volume_scale", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "発話前の無音・秒", Weight = 0.35 }, ui:LineEdit { ID = "pre_phoneme_length", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "発話後の無音・秒", Weight = 0.35 }, ui:LineEdit { ID = "post_phoneme_length", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "サンプリングレート・Hz", Weight = 0.35 }, ui:LineEdit { ID = "sample_rate", Weight = 0.65 } },
      ui:HGroup { ui:Label { Text = "ステレオ出力", Weight = 0.35 }, ui:CheckBox { ID = "output_stereo", Weight = 0.65, Text = "ステレオで出力する" } },
    },

    ui:VGroup {
      Weight = 0,
      Spacing = 4,
      ui:Label { Text = "Resolve（タイムライン）" },
      ui:HGroup { ui:Label { Text = "テキストトラック番号", Weight = 0.35 }, ui:LineEdit { ID = "text_track_index", Weight = 0.65 } },
    },

    ui:VGroup {
      Weight = 0,
      Spacing = 4,
      ui:Label { Text = "実行設定（スクリプト全般）" },
      ui:HGroup {
        ui:Label { Text = "出力先フォルダ", Weight = 0.35 },
        ui:HGroup {
          Weight = 0.65,
          Spacing = 4,
          ui:LineEdit { ID = "output_dir" },
          ui:Button { ID = "output_dir_browse", Text = "参照...", Weight = 0 },
        },
      },
      ui:HGroup { ui:Label { Text = "ログファイル", Weight = 0.35 }, ui:LineEdit { ID = "log_path", Weight = 0.65 } },
    },

    ui:HGroup {
      Weight = 0,
      ui:Button { ID = "test_btn", Text = "VOICEVOX 接続テスト" },
      ui:Button { ID = "reset_btn", Text = "初期値に戻す" },
      ui:Button { ID = "save_btn", Text = "保存" },
      ui:Button { ID = "close_btn", Text = "閉じる" },
    },
  })

  local items = win:GetItems()
  local speaker_map = {}
  local speaker_items = {}
  local current_speaker_id = 1

  local function set_status(msg)
    items.status.Text = tostring(msg or "")
  end

  local function set_speaker_selection_by_id(target_id)
    local tid = tonumber(target_id)
    if not tid then return false end

    for idx, row in ipairs(speaker_items) do
      if tonumber(row.id) == tid then
        items.speaker_select.CurrentIndex = idx - 1
        current_speaker_id = tid
        return true
      end
    end

    return false
  end

  local function get_selected_speaker_id()
    if #speaker_items == 0 then
      return tonumber(current_speaker_id) or 1
    end

    local idx = tonumber(items.speaker_select.CurrentIndex or 0) or 0
    local row = speaker_items[idx + 1]
    if row and row.id then
      return tonumber(row.id) or (tonumber(current_speaker_id) or 1)
    end

    return tonumber(current_speaker_id) or 1
  end

  local function refresh_speakers(show_status)
    local map, err = fetch_speaker_map()
    if map then
      speaker_map = map
      speaker_items = build_speaker_items(speaker_map)

      items.speaker_select:Clear()
      for _, row in ipairs(speaker_items) do
        items.speaker_select:AddItem(row.label)
      end

      if not set_speaker_selection_by_id(current_speaker_id) and #speaker_items > 0 then
        items.speaker_select.CurrentIndex = 0
        current_speaker_id = tonumber(speaker_items[1].id) or current_speaker_id
      end

      if show_status then
        local count = 0
        for _, _ in pairs(speaker_map) do count = count + 1 end
        set_status("speakers loaded: " .. tostring(count))
      end
      return true, nil
    end

    speaker_map = {}
    speaker_items = {}
    items.speaker_select:Clear()
    items.speaker_select:AddItem("(speaker list unavailable)")
    items.speaker_select.CurrentIndex = 0
    if show_status then
      set_status("speaker load failed: " .. tostring(err))
    end
    return false, err
  end

  local presets = { selected = "", list = {} }
  local suppress_preset_event = false

  local function preset_index(name)
    for i, item in ipairs(presets.list) do
      if item.name == name then
        return i
      end
    end
    return nil
  end

  local function set_form_voicevox(vv)
    vv = vv or {}
    current_speaker_id = tonumber(vv.speaker_id or 1) or 1
    set_speaker_selection_by_id(current_speaker_id)
    items.speed_scale.Text = tostring(vv.speed_scale or 1.0)
    items.pitch_scale.Text = tostring(vv.pitch_scale or 0.0)
    items.intonation_scale.Text = tostring(vv.intonation_scale or 1.0)
    items.volume_scale.Text = tostring(vv.volume_scale or 1.0)
    items.pre_phoneme_length.Text = tostring(vv.pre_phoneme_length or 0.1)
    items.post_phoneme_length.Text = tostring(vv.post_phoneme_length or 0.1)
    items.sample_rate.Text = tostring(vv.sample_rate or 48000)
    items.output_stereo.Checked = vv.output_stereo ~= false
  end

  local function read_voicevox_from_form()
    return {
      speaker_id = get_selected_speaker_id(),
      speed_scale = to_number(items.speed_scale.Text, 1.0),
      pitch_scale = to_number(items.pitch_scale.Text, 0.0),
      intonation_scale = to_number(items.intonation_scale.Text, 1.0),
      volume_scale = to_number(items.volume_scale.Text, 1.0),
      pre_phoneme_length = to_number(items.pre_phoneme_length.Text, 0.1),
      post_phoneme_length = to_number(items.post_phoneme_length.Text, 0.1),
      sample_rate = to_number(items.sample_rate.Text, 48000),
      output_stereo = items.output_stereo.Checked == true,
    }
  end

  local function refresh_preset_combo()
    suppress_preset_event = true
    items.preset_select:Clear()
    local idx = 0
    for i, item in ipairs(presets.list) do
      items.preset_select:AddItem(item.name)
      if item.name == presets.selected then
        idx = i - 1
      end
    end
    items.preset_select.CurrentIndex = idx
    suppress_preset_event = false
  end

  local function load_to_form()
    local cfg = load_or_default_config(config_load_path)
    local rs = cfg.resolve or {}
    local rt = cfg.runtime or {}

    presets = normalize_presets(cfg)
    refresh_preset_combo()
    set_form_voicevox(cfg.voicevox)

    items.text_track_index.Text = tostring(rs.text_track_index or 1)

    items.output_dir.Text = tostring(rt.output_dir or "")
    items.log_path.Text = tostring(rt.log_path or "./run.log")

    local speaker_ok, speaker_err = refresh_speakers(false)
    if speaker_ok then
      set_status("loaded: " .. config_load_path)
    else
      set_status("loaded (speaker unavailable: " .. tostring(speaker_err) .. ")")
    end
  end

  local function read_from_form()
    return {
      voicevox = read_voicevox_from_form(),
      presets = { selected = presets.selected, list = presets.list },
      resolve = {
        text_track_index = to_number(items.text_track_index.Text, 1),
      },
      runtime = {
        output_dir = trim(items.output_dir.Text),
        log_path = trim(items.log_path.Text),
      },
    }
  end

  local function confirm_action(message, yes_text)
    local answer = false
    local dlg = disp:AddWindow({
      ID = "VoiceVoxConfirm",
      WindowTitle = "確認",
      Geometry = { 300, 300, 380, 130 },
    },
    ui:VGroup {
      ID = "root",
      Spacing = 8,
      ui:Label { Text = message, WordWrap = true },
      ui:HGroup {
        ui:Button { ID = "confirm_yes_btn", Text = yes_text },
        ui:Button { ID = "confirm_no_btn", Text = "キャンセル" },
      },
    })

    function dlg.On.confirm_yes_btn.Clicked()
      answer = true
      disp:ExitLoop()
    end

    function dlg.On.confirm_no_btn.Clicked()
      disp:ExitLoop()
    end

    function dlg.On.VoiceVoxConfirm.Close()
      disp:ExitLoop()
    end

    dlg:Show()
    disp:RunLoop()
    dlg:Hide()
    return answer
  end

  local function ask_text(title, label)
    local result = nil
    local dlg = disp:AddWindow({
      ID = "VoiceVoxAskText",
      WindowTitle = title,
      Geometry = { 300, 300, 380, 130 },
    },
    ui:VGroup {
      ID = "root",
      Spacing = 8,
      ui:Label { Text = label },
      ui:LineEdit { ID = "ask_text_edit" },
      ui:HGroup {
        ui:Button { ID = "ask_ok_btn", Text = "OK" },
        ui:Button { ID = "ask_cancel_btn", Text = "キャンセル" },
      },
    })
    local dlg_items = dlg:GetItems()

    function dlg.On.ask_ok_btn.Clicked()
      result = trim(dlg_items.ask_text_edit.Text)
      disp:ExitLoop()
    end

    function dlg.On.ask_cancel_btn.Clicked()
      disp:ExitLoop()
    end

    function dlg.On.VoiceVoxAskText.Close()
      disp:ExitLoop()
    end

    dlg:Show()
    disp:RunLoop()
    dlg:Hide()
    return result
  end

  function win.On.output_dir_browse.Clicked()
    local current = trim(items.output_dir.Text)
    -- @プレースホルダーの場合は $HOME/Movies を初期ディレクトリにする
    local initial = current
    if initial:sub(1, 1) == "@" or initial == "" then
      initial = (os.getenv("HOME") or "") .. "/Movies"
    end
    local selected = fusion:RequestDir(initial)
    if selected and trim(tostring(selected)) ~= "" then
      local path = trim(tostring(selected)):gsub("/+$", "")
      items.output_dir.Text = path
    end
  end

  function win.On.test_btn.Clicked()
    local base_url = BASE_URL

    local cmd = "curl -sS " .. shell_quote(base_url .. "/version") .. " -w '\nHTTPSTATUS:%{http_code}' 2>&1"
    local out = run_capture(cmd)
    if not out then
      set_status("test failed: curl execution error")
      return
    end

    local status = out:match("HTTPSTATUS:(%d+)")
    local body = trim(out:gsub("\n?HTTPSTATUS:%d+", ""))
    if tonumber(status) == 200 then
      local ok = refresh_speakers(false)
      if ok then
        set_status("test ok: " .. body)
      else
        set_status("test ok (version): " .. body .. " / speaker list unavailable")
      end
    else
      set_status("test failed: http=" .. tostring(status or "?") .. " body=" .. body)
    end
  end

  function win.On.speaker_select.CurrentIndexChanged()
    current_speaker_id = get_selected_speaker_id()
  end

  function win.On.preset_select.CurrentIndexChanged()
    if suppress_preset_event then return end
    local item = presets.list[(tonumber(items.preset_select.CurrentIndex) or 0) + 1]
    if not item or item.name == presets.selected then return end
    presets.selected = item.name
    set_form_voicevox(item.voicevox)
    set_status("プリセットを読み込みました: " .. item.name)
  end

  function win.On.preset_add_btn.Clicked()
    local name = ask_text("プリセットの追加", "プリセット名")
    if not name then return end
    if name == "" then
      set_status("プリセット名が空です")
      return
    end
    if preset_index(name) then
      set_status("同じ名前のプリセットがあります: " .. name)
      return
    end
    table.insert(presets.list, { name = name, voicevox = read_voicevox_from_form() })
    presets.selected = name
    refresh_preset_combo()
    set_status("プリセットを追加しました: " .. name)
  end

  function win.On.preset_update_btn.Clicked()
    local idx = preset_index(presets.selected)
    if not idx then
      set_status("更新するプリセットがありません")
      return
    end
    presets.list[idx].voicevox = read_voicevox_from_form()
    set_status("プリセットを更新しました: " .. presets.selected)
  end

  function win.On.preset_delete_btn.Clicked()
    local idx = preset_index(presets.selected)
    if not idx then
      set_status("削除するプリセットがありません")
      return
    end
    if #presets.list <= 1 then
      set_status("最後のプリセットは削除できません")
      return
    end
    if not confirm_action("プリセット「" .. presets.selected .. "」を削除しますか？", "削除") then
      set_status("削除をキャンセルしました")
      return
    end
    table.remove(presets.list, idx)
    presets.selected = presets.list[1].name
    refresh_preset_combo()
    set_form_voicevox(presets.list[1].voicevox)
    set_status("プリセットを削除しました")
  end

  function win.On.save_btn.Clicked()
    local cfg = read_from_form()
    if trim(cfg.runtime.output_dir or "") == "" then
      set_status("エラー: output_dir が空です。保存先の親フォルダを指定してください。")
      return
    end
    local text = serialize_config(cfg)
    local ok, err = write_text_file(config_path, text)
    if ok then
      config_load_path = config_path
      set_status("saved: " .. config_path)
    else
      set_status("save failed: " .. tostring(err))
    end
  end

  function win.On.reset_btn.Clicked()
    if not confirm_action("設定を初期値に戻しますか？\n現在の設定内容とプリセットは失われ、初期値で保存されます。", "初期値に戻す") then
      set_status("初期値への変更をキャンセルしました")
      return
    end

    local cfg = load_or_default_config("__non_existing__")
    local rs = cfg.resolve or {}
    local rt = cfg.runtime or {}

    presets = normalize_presets(cfg)
    cfg.presets = presets
    refresh_preset_combo()
    set_form_voicevox(cfg.voicevox)

    items.text_track_index.Text = tostring(rs.text_track_index or 1)

    items.output_dir.Text = tostring(rt.output_dir or "")
    items.log_path.Text = tostring(rt.log_path or "./run.log")

    refresh_speakers(false)

    local text = serialize_config(cfg)
    local ok, err = write_text_file(config_path, text)
    if ok then
      config_load_path = config_path
      set_status("reset to defaults and saved: " .. config_path)
    else
      set_status("reset save failed: " .. tostring(err))
    end
  end

  function win.On.close_btn.Clicked()
    disp:ExitLoop()
  end

  function win.On.VoiceVoxConfigWin.Close()
    disp:ExitLoop()
  end

  load_to_form()
  win:Show()
  disp:RunLoop()
  win:Hide()

  return 0
end

return main()
