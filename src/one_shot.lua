local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function urlencode(str)
  str = tostring(str)
  str = str:gsub("\n", "\r\n")
  str = str:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  return true
end

local function run_capture(cmd)
  local p = io.popen(cmd)
  if not p then return nil end
  local out = p:read("*a")
  p:close()
  return out
end

local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function ensure_dir(path)
  return execute_ok(os.execute("mkdir -p " .. shell_quote(path)))
end

local function is_dir(path)
  local p = trim(path)
  if p == "" then return false end
  return execute_ok(os.execute("[ -d " .. shell_quote(p) .. " ]"))
end

local function resolve_path(base_dir, value)
  if not value or value == "" then return value end
  if value:sub(1, 1) == "/" then return value end
  if value:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "") .. value:sub(2)
  end
  return base_dir .. "/" .. value
end

local function make_temp_json_path(base_dir)
  local ts = tostring(os.time())
  local rnd = tostring(math.random(100000, 999999))
  return base_dir .. "/.vv_payload_" .. ts .. "_" .. rnd .. ".json"
end

local function curl_json(method, url, body)
  local cmd = "curl -sS -X " .. method
  cmd = cmd .. " -H 'Content-Type: application/json'"
  if body and #body > 0 then
    cmd = cmd .. " --data-binary " .. shell_quote(body)
  end
  cmd = cmd .. " " .. shell_quote(url) .. " -w '\nHTTPSTATUS:%{http_code}' 2>&1"
  local out = run_capture(cmd)
  if not out then return nil, "curl failed" end

  local status = out:match("HTTPSTATUS:(%d+)")
  local body_out = out:gsub("\n?HTTPSTATUS:%d+", "")
  if tonumber(status) ~= 200 then
    return nil, "http=" .. tostring(status or "?") .. " body=" .. trim(body_out)
  end
  return body_out, nil
end

local function curl_to_file(method, url, body, out_path, temp_dir)
  local payload_path = nil
  if body and #body > 0 then
    payload_path = make_temp_json_path(temp_dir)
    if not write_file(payload_path, body) then
      return false, "failed to write temp payload"
    end
  end

  local cmd = "curl -sS -X " .. method
  cmd = cmd .. " -H 'Content-Type: application/json'"
  if payload_path then
    cmd = cmd .. " --data-binary @" .. shell_quote(payload_path)
  end
  cmd = cmd .. " " .. shell_quote(url) .. " -o " .. shell_quote(out_path) .. " -w '\nHTTPSTATUS:%{http_code}' 2>&1"

  local out = run_capture(cmd)
  if payload_path then os.remove(payload_path) end
  if not out then return false, "curl failed" end

  local status = out:match("HTTPSTATUS:(%d+)")
  if tonumber(status) ~= 200 then
    return false, "http=" .. tostring(status or "?") .. " body=" .. trim(out:gsub("\n?HTTPSTATUS:%d+", ""))
  end
  if not exists(out_path) then return false, "output file was not created" end
  return true, nil
end

local function notify_mac(title, message)
  local t = tostring(title or "Resolve VOICEVOX")
  local m = tostring(message or "")
  local script = string.format('display notification "%s" with title "%s"',
    m:gsub('"', '\\"'), t:gsub('"', '\\"'))
  os.execute("/usr/bin/osascript -e " .. shell_quote(script))
end

local function alert_mac(title, message)
  local t = tostring(title or "Resolve VOICEVOX")
  local m = tostring(message or "")
  local script = string.format('display dialog "%s" with title "%s" buttons {"OK"} default button "OK" with icon stop',
    m:gsub('"', '\\"'), t:gsub('"', '\\"'))
  os.execute("/usr/bin/osascript -e " .. shell_quote(script))
end

local _log_file_path = nil

local function log_line(msg)
  local line = os.date("%Y-%m-%d %H:%M:%S") .. " | [one_shot] " .. tostring(msg)
  print(line)
  if _log_file_path then
    local f = io.open(_log_file_path, "ab")
    if f then
      f:write(line .. "\n")
      f:close()
    end
  end
end

local function patch_audio_query_json(query_json, vcfg)
  local patched = query_json

  local function replace_number(key, value)
    if value == nil then return end
    local p = '"' .. key .. '"%s*:%s*[-%d%.eE]+'
    local r = string.format('"%s":%s', key, tostring(value))
    patched = patched:gsub(p, r, 1)
  end

  replace_number("speedScale", vcfg.speed_scale)
  replace_number("pitchScale", vcfg.pitch_scale)
  replace_number("intonationScale", vcfg.intonation_scale)
  replace_number("volumeScale", vcfg.volume_scale)
  replace_number("prePhonemeLength", vcfg.pre_phoneme_length)
  replace_number("postPhonemeLength", vcfg.post_phoneme_length)
  replace_number("outputSamplingRate", vcfg.sample_rate)

  local output_stereo = vcfg.output_stereo
  if output_stereo == nil then output_stereo = true end
  local stereo_text = output_stereo and "true" or "false"

  local replaced = 0
  patched, replaced = patched:gsub('"outputStereo"%s*:%s*true', '"outputStereo":' .. stereo_text, 1)
  if replaced == 0 then
    patched, replaced = patched:gsub('"outputStereo"%s*:%s*false', '"outputStereo":' .. stereo_text, 1)
  end
  if replaced == 0 then
    patched = patched:gsub("}%s*$", ',"outputStereo":' .. stereo_text .. "}")
  end

  return patched
end

local function le_u32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 or not b2 or not b3 or not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function le_u16(s, i)
  local b1, b2 = s:byte(i, i + 1)
  if not b1 or not b2 then return nil end
  return b1 + b2 * 256
end

local function u32_to_le(n)
  local v = math.max(0, math.floor(n or 0))
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function replace_u32_at(s, pos, value)
  return s:sub(1, pos - 1) .. u32_to_le(value) .. s:sub(pos + 4)
end

local function append_audio_padding_to_wav(path, padding_sec)
  local pad = tonumber(padding_sec or 0) or 0
  if pad <= 0 then return true, nil end

  local data = read_file(path)
  if not data or #data < 44 then return false, "wav read failed" end
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return false, "not wav" end

  local idx = 13
  local byte_rate = nil
  local block_align = nil
  local data_size = nil
  local data_size_pos = nil
  local data_payload_start = nil

  while idx + 7 <= #data do
    local chunk_id = data:sub(idx, idx + 3)
    local chunk_size = le_u32(data, idx + 4)
    if not chunk_size then break end

    local payload_start = idx + 8
    if chunk_id == "fmt " then
      byte_rate = le_u32(data, payload_start + 8)
      block_align = le_u16(data, payload_start + 12) or 1
    elseif chunk_id == "data" then
      data_size = chunk_size
      data_size_pos = idx + 4
      data_payload_start = payload_start
      break
    end

    idx = payload_start + chunk_size
    if chunk_size % 2 == 1 then idx = idx + 1 end
  end

  if not byte_rate or byte_rate <= 0 or not data_size or not data_size_pos or not data_payload_start then
    return false, "wav format unsupported"
  end

  local data_payload_end = data_payload_start + data_size - 1
  if data_payload_end ~= #data then
    return false, "wav has trailing chunks"
  end

  local pad_bytes = math.floor(byte_rate * pad + 0.5)
  if block_align and block_align > 1 then
    pad_bytes = math.floor(pad_bytes / block_align) * block_align
  end
  if pad_bytes <= 0 then return true, nil end

  local zeros = string.rep("\0", pad_bytes)
  local new_data = data .. zeros
  local new_data_size = data_size + pad_bytes
  local new_riff_size = #new_data - 8

  new_data = replace_u32_at(new_data, data_size_pos, new_data_size)
  new_data = replace_u32_at(new_data, 5, new_riff_size)

  if not write_file(path, new_data) then
    return false, "wav write failed"
  end
  return true, nil
end

local function synthesize_wav(vcfg, text, out_wav, audio_padding_sec)
  local base_url = vcfg.base_url or "http://127.0.0.1:50022"
  local qurl = string.format("%s/audio_query?text=%s&speaker=%d", base_url, urlencode(text), tonumber(vcfg.speaker_id))
  local query_json, qerr = curl_json("POST", qurl, "")
  if not query_json or #query_json == 0 then
    return false, "audio_query failed: " .. tostring(qerr)
  end

  local patched = patch_audio_query_json(query_json, vcfg)
  local surl = string.format("%s/synthesis?speaker=%d", base_url, tonumber(vcfg.speaker_id))
  local out_dir = out_wav:match("^(.*)/[^/]+$") or "."
  local ok, serr = curl_to_file("POST", surl, patched, out_wav, out_dir)
  if not ok then
    return false, "synthesis failed: " .. tostring(serr)
  end

  local ok_pad, perr = append_audio_padding_to_wav(out_wav, audio_padding_sec)
  if not ok_pad then
    return false, "audio padding failed: " .. tostring(perr)
  end
  return true, nil
end

local function get_resolve()
  if resolve then return resolve end
  if Resolve then return Resolve() end
  return nil
end

local function get_text_from_video_clip(item)
  local ok_cnt, comp_count = pcall(function() return item:GetFusionCompCount() end)
  if not (ok_cnt and tonumber(comp_count) and tonumber(comp_count) > 0) then
    return nil
  end

  local ok_cc, comp = pcall(function() return item:GetFusionCompByIndex(1) end)
  if not (ok_cc and comp) then return nil end

  local ok_tl, tools = pcall(function() return comp:GetToolList(false) end)
  if not (ok_tl and tools) then return nil end

  for _, tool in pairs(tools) do
    for _, input_key in ipairs({ "StyledText", "Text" }) do
      local ok_ti, val = pcall(function() return tool:GetInput(input_key) end)
      if ok_ti and type(val) == "string" and #trim(val) > 0 then
        return trim(val)
      end
    end
  end

  return nil
end

local function find_clip_at_playhead(timeline, track_type, track_index, playhead_frame)
  local items = timeline:GetItemListInTrack(track_type, track_index)
  if not items then return nil end

  for _, item in ipairs(items) do
    local s = tonumber(item:GetStart()) or 0
    local e = tonumber(item:GetEnd()) or 0
    if playhead_frame >= s and playhead_frame < e then
      return item
    end
  end
  return nil
end

local function find_audio_item_on_track(timeline, audio_track_index, start_frame, name_hint)
  local items = timeline:GetItemListInTrack("audio", tonumber(audio_track_index))
  if not items then return nil end

  local target_start = math.floor(tonumber(start_frame) or 0)
  for _, item in ipairs(items) do
    local item_start = math.floor(tonumber(item:GetStart()) or -1)
    if item_start == target_start then
      if not name_hint then return item end
      local n = tostring(item:GetName() or "")
      if n == name_hint or n:find(name_hint, 1, true) then
        return item
      end
    end
  end
  return nil
end

local function try_link_timeline_items(timeline, subtitle_item, audio_item)
  if not timeline or not subtitle_item or not audio_item then
    return false, "missing timeline item"
  end

  local attempts = {
    function() return timeline:SetClipsLinked({ subtitle_item, audio_item }, true) end,
    function() return timeline:LinkClips({ subtitle_item, audio_item }) end,
    function() return timeline:SetLinkedClips({ subtitle_item, audio_item }, true) end,
  }

  for _, attempt in ipairs(attempts) do
    local ok, result = pcall(attempt)
    if ok and result ~= false then
      return true, nil
    end
  end

  return false, "link API unavailable"
end

local function import_and_place(media_pool, timeline, wav_path, start_frame, audio_track_index)
  local root_folder = nil
  pcall(function() root_folder = media_pool:GetRootFolder() end)

  local target_bin = nil
  if root_folder then
    local ok_sf, subfolders = pcall(function() return root_folder:GetSubFolderList() end)
    if ok_sf and type(subfolders) == "table" then
      for _, sf in ipairs(subfolders) do
        local ok_n, n = pcall(function() return sf:GetName() end)
        if ok_n and n == "voicevox" then
          target_bin = sf
          break
        end
      end
    end
    if not target_bin then
      local ok_add, new_bin = pcall(function() return media_pool:AddSubFolder(root_folder, "voicevox") end)
      if ok_add and new_bin then
        target_bin = new_bin
      end
    end
  end

  local original_folder = nil
  local ok_gf, cur_folder = pcall(function() return media_pool:GetCurrentFolder() end)
  if ok_gf and cur_folder then original_folder = cur_folder end

  if target_bin then
    pcall(function() media_pool:SetCurrentFolder(target_bin) end)
  end

  local imported = media_pool:ImportMedia({ wav_path })

  if original_folder then
    pcall(function() media_pool:SetCurrentFolder(original_folder) end)
  end

  if not imported or #imported == 0 then return false, nil end

  local media_item = imported[1]
  local info = {
    mediaPoolItem = media_item,
    recordFrame = math.floor(start_frame),
    trackIndex = tonumber(audio_track_index),
    mediaType = 2,
  }

  local ok = media_pool:AppendToTimeline({ info })
  if ok == nil or ok == false then
    return false, nil
  end

  local name_hint = tostring(wav_path):match("([^/]+)$")
  local placed_item = find_audio_item_on_track(timeline, audio_track_index, start_frame, name_hint)
  return true, placed_item
end

local function padding_tag(padding_sec)
  local p = tonumber(padding_sec or 0) or 0
  if p < 0 then p = 0 end
  local ms = math.floor((p * 1000) + 0.5)
  return string.format("p%05d", ms)
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

local function start_voicevox_docker_if_needed()
  local state = {
    started_by_script = false,
    container_name = "voicevox_engine",
    image = "voicevox/voicevox_engine:cpu-ubuntu24.04-0.26.0-dev",
    port = "50022",
  }

  local docker_cmd = resolve_docker_cmd()
  if not docker_cmd then
    return state, "docker command not found"
  end
  state.docker_cmd = docker_cmd

  if docker_container_running(docker_cmd, state.container_name) then
    register_docker_stop_guard(docker_cmd, state.container_name)
    return state, nil
  end

  local ok = false
  if docker_container_exists(docker_cmd, state.container_name) then
    ok = execute_ok(os.execute(shell_quote(docker_cmd) .. " start " .. shell_quote(state.container_name) .. " >/dev/null 2>&1"))
  else
    ok = execute_ok(os.execute(
      shell_quote(docker_cmd) .. " run -d --name " .. shell_quote(state.container_name) ..
      " -p " .. tostring(state.port) .. ":50021 " .. shell_quote(state.image) .. " >/dev/null 2>&1"
    ))
  end

  if ok then
    state.started_by_script = true
    register_docker_stop_guard(docker_cmd, state.container_name)

    local ready = false
    for _ = 1, 90 do
      local out = run_capture("curl -sS --max-time 2 http://127.0.0.1:" .. tostring(state.port) .. "/version 2>/dev/null")
      if out and #trim(out) > 0 then
        ready = true
        break
      end
      os.execute("sleep 1")
    end

    if not ready then
      os.execute(shell_quote(docker_cmd) .. " stop " .. shell_quote(state.container_name) .. " >/dev/null 2>&1")
      state.started_by_script = false
      return state, "docker started but VOICEVOX did not become ready"
    end

    return state, nil
  end

  return state, "failed to start docker container"
end

local function stop_voicevox_docker_if_started(state)
  if not state or not state.started_by_script then return end
  local docker_cmd = state.docker_cmd or resolve_docker_cmd() or "docker"
  os.execute(shell_quote(docker_cmd) .. " stop " .. shell_quote(state.container_name or "voicevox_engine") .. " >/dev/null 2>&1")
end

local function run_one_shot()
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir = script_path:match("^(.*)/") or "."
  local config_path = arg and arg[1] or (script_dir .. "/config.data")

  local ok_cfg, config = pcall(dofile, config_path)
  if not ok_cfg or type(config) ~= "table" then
    print("設定ファイルの読み込みに失敗しました: " .. tostring(config_path))
    return 1
  end

  local vcfg = config.voicevox
  local rcfg = config.resolve
  local rt = config.runtime

  math.randomseed(os.time())

  local output_dir_raw = rt.output_dir or ""
  local log_path = resolve_path(script_dir, rt.log_path or "run.log")
  _log_file_path = log_path

  log_line("=== start one_shot.lua ===")
  log_line("config_path=" .. tostring(config_path))

  -- VOICEVOX ヘルスチェック
  local health = run_capture("curl -sS " .. shell_quote((vcfg.base_url or "http://127.0.0.1:50022") .. "/version"))
  if not health or #trim(health) == 0 then
    log_line("VOICEVOX Engine に接続できません。")
    notify_mac("Resolve VOICEVOX", "VOICEVOX Engine に接続できません")
    return 1
  end
  log_line("VOICEVOX healthcheck ok")

  -- Resolve API 接続
  local r = get_resolve()
  if not r then
    log_line("Resolve APIへの接続に失敗しました。")
    notify_mac("Resolve VOICEVOX", "Resolve API接続に失敗しました")
    return 1
  end

  local pm = r:GetProjectManager()
  local project = pm and pm:GetCurrentProject() or nil
  if not project then
    log_line("現在のプロジェクトが見つかりません。")
    notify_mac("Resolve VOICEVOX", "現在のプロジェクトが見つかりません")
    return 1
  end

  local timeline = project:GetCurrentTimeline()
  local media_pool = project:GetMediaPool()
  if not timeline or not media_pool then
    log_line("タイムラインまたはMedia Poolが取得できません。")
    notify_mac("Resolve VOICEVOX", "タイムラインまたはMedia Pool取得に失敗")
    return 1
  end

  -- 出力先ディレクトリ
  local base_dir = trim(output_dir_raw)
  if base_dir == "" then
    log_line("output_dir が設定されていません。")
    alert_mac("Resolve VOICEVOX - 出力先エラー", "output_dir が設定されていません。\nconfig.data の output_dir に保存先の親フォルダを指定してください。")
    return 1
  end
  base_dir = resolve_path(script_dir, base_dir)
  if not is_dir(base_dir) then
    log_line("出力先フォルダが存在しません: " .. tostring(base_dir))
    alert_mac("Resolve VOICEVOX - 出力先エラー", "出力先フォルダが存在しません:\n" .. tostring(base_dir))
    return 1
  end

  local fps = tonumber(project:GetSetting("timelineFrameRate")) or 30
  local text_track = tonumber(rcfg.text_track_index or 1)

  -- 再生ヘッド位置を取得
  local playhead_tc = timeline:GetCurrentTimecode()
  if not playhead_tc or playhead_tc == "" then
    log_line("再生ヘッドの位置を取得できません。")
    notify_mac("Resolve VOICEVOX", "再生ヘッドの位置を取得できません")
    return 1
  end

  -- タイムコードをフレーム番号に変換
  local h, m, s, f = playhead_tc:match("^(%d+):(%d+):(%d+):(%d+)$")
  if not h then
    h, m, s, f = playhead_tc:match("^(%d+):(%d+):(%d+);(%d+)$")
  end
  if not h then
    log_line("タイムコードの解析に失敗: " .. tostring(playhead_tc))
    notify_mac("Resolve VOICEVOX", "タイムコードの解析に失敗しました")
    return 1
  end
  local playhead_frame = tonumber(h) * 3600 * fps + tonumber(m) * 60 * fps + tonumber(s) * fps + tonumber(f)
  log_line(string.format("playhead tc=%s frame=%d track=%d fps=%s", playhead_tc, playhead_frame, text_track, tostring(fps)))

  -- 再生ヘッド位置の Text+ クリップを検索
  local clip = find_clip_at_playhead(timeline, "video", text_track, playhead_frame)
  if not clip then
    log_line("再生ヘッド位置に Text+ クリップが見つかりません。")
    notify_mac("Resolve VOICEVOX", "再生ヘッド位置に Text+ クリップがありません")
    return 1
  end

  local text = get_text_from_video_clip(clip)
  if not text or #text == 0 then
    log_line("クリップからテキストを取得できません（Text+ 以外の可能性）。")
    notify_mac("Resolve VOICEVOX", "クリップからテキストを取得できません")
    return 1
  end

  local start_frame = tonumber(clip:GetStart()) or 0
  log_line(string.format("text=\"%s\" start_frame=%d", text, start_frame))

  -- 音声合成
  local pad_tag = padding_tag(rt.audio_padding_sec or 0)
  local filename = string.format("oneshot_%08d_s%d_%s.wav", start_frame, tonumber(vcfg.speaker_id) or 1, pad_tag)
  local wav_path = base_dir .. "/" .. filename

  log_line("合成開始: " .. filename)
  local ok_syn, syn_err = synthesize_wav(vcfg, text, wav_path, rt.audio_padding_sec or 0)
  if not ok_syn then
    log_line("合成に失敗: " .. tostring(syn_err))
    alert_mac("Resolve VOICEVOX - 合成エラー", "音声の合成に失敗しました:\n" .. tostring(syn_err))
    return 1
  end
  log_line("合成完了: " .. filename)

  -- 同位置の既存クリップを削除
  local existing_clip = find_audio_item_on_track(timeline, text_track, start_frame, nil)
  if existing_clip then
    pcall(function() timeline:DeleteClips({ existing_clip }, false) end)
    log_line("既存クリップを削除しました")
  end

  -- オーディオトラック（text_track_index と同じ）に配置
  local ok_place, placed_item = import_and_place(media_pool, timeline, wav_path, start_frame, text_track)
  if ok_place then
    log_line(string.format("配置完了: frame=%d track=%d file=%s", start_frame, text_track, filename))

    if rt.link_clips and clip and placed_item then
      local linked, lerr = try_link_timeline_items(timeline, clip, placed_item)
      if linked then
        log_line("リンク完了: text/audio linked")
      else
        log_line("リンクスキップ: " .. tostring(lerr))
      end
    end

    notify_mac("Resolve VOICEVOX", string.format("完了: \"%s\"", text:sub(1, 30)))
  else
    log_line("配置に失敗: " .. filename)
    alert_mac("Resolve VOICEVOX - 配置エラー", "音声クリップの配置に失敗しました")
    return 1
  end

  log_line("=== end one_shot.lua ===")
  return 0
end

local function main()
  local docker_state, docker_err = start_voicevox_docker_if_needed()
  if docker_err then
    print("VOICEVOX Docker auto-start: " .. tostring(docker_err))
  end

  local ok, code_or_err = xpcall(run_one_shot, debug.traceback)
  stop_voicevox_docker_if_started(docker_state)

  if not ok then
    print("one_shot.lua fatal: " .. tostring(code_or_err))
    return 1
  end

  return tonumber(code_or_err) or 1
end

return main()
