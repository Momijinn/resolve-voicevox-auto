local exists

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

local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
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

local function ensure_dir(path)
  return execute_ok(os.execute("mkdir -p " .. shell_quote(path)))
end

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

local function parent_dir(path)
  local p = tostring(path or "")
  if p == "" then return nil end
  p = p:gsub("\\", "/")
  p = p:gsub("/+$", "")
  local d = p:match("^(.*)/[^/]+$")
  if d and d ~= "" then
    return d
  end
  return nil
end

local function is_dir(path)
  local p = trim(path)
  if p == "" then return false end
  return execute_ok(os.execute("[ -d " .. shell_quote(p) .. " ]"))
end

local function maybe_dir(path)
  local p = trim(path)
  if p == "" then return nil end
  if is_dir(p) then return p end
  if exists(p) then return parent_dir(p) end
  local d = parent_dir(p)
  if d and is_dir(d) then return d end
  return nil
end

local function detect_project_root(project)
  if not project then return nil end

  local setting_keys = {
    "projectPath",
    "ProjectPath",
    "MediaStorageLocation",
    "CaptureLocation",
    "CacheClipLocation",
    "GalleryStillsLocation",
    "ProxyPath",
  }

  for _, key in ipairs(setting_keys) do
    local ok, value = pcall(function() return project:GetSetting(key) end)
    if ok and type(value) == "string" then
      local d = maybe_dir(value)
      if d then return d end
    end
  end

  local timeline = project:GetCurrentTimeline()
  if not timeline then return nil end

  for _, track_type in ipairs({ "video", "audio" }) do
    local ok_tc, track_count = pcall(function() return tonumber(timeline:GetTrackCount(track_type)) or 0 end)
    if ok_tc and track_count > 0 then
      for track_index = 1, track_count do
        local items = timeline:GetItemListInTrack(track_type, track_index) or {}
        for _, item in ipairs(items) do
          local mpi = item and item:GetMediaPoolItem() or nil
          if mpi then
            local ok_fp, file_path = pcall(function() return mpi:GetClipProperty("File Path") end)
            if ok_fp and type(file_path) == "string" then
              local d = maybe_dir(file_path)
              if d then return d end
            end
          end
        end
      end
    end
  end

  return nil
end

local function detect_timeline_dir(project)
  if not project then return nil end
  local timeline = project:GetCurrentTimeline()
  if not timeline then return nil end

  local project_name = ""
  local ok_pn, pn = pcall(function() return project:GetName() end)
  if ok_pn and type(pn) == "string" then
    project_name = trim(pn)
  end

  local timeline_name = ""
  local ok_name, name = pcall(function() return timeline:GetName() end)
  if ok_name and type(name) == "string" then
    timeline_name = trim(name)
  end

  local dir_count = {}
  local best_dir = nil
  local best_count = 0
  for _, track_type in ipairs({ "video", "audio" }) do
    local ok_tc, track_count = pcall(function() return tonumber(timeline:GetTrackCount(track_type)) or 0 end)
    if ok_tc and track_count > 0 then
      for track_index = 1, track_count do
        local items = timeline:GetItemListInTrack(track_type, track_index) or {}
        for _, item in ipairs(items) do
          local mpi = item and item:GetMediaPoolItem() or nil
          if mpi then
            local ok_fp, file_path = pcall(function() return mpi:GetClipProperty("File Path") end)
            if ok_fp and type(file_path) == "string" then
              local d = maybe_dir(file_path)
              if d then
                local c = (dir_count[d] or 0) + 1
                dir_count[d] = c
                if c > best_count then
                  best_count = c
                  best_dir = d
                end
              end
            end
          end
        end
      end
    end
  end

  if best_dir then
    return best_dir
  end

  local capture_base = nil
  for _, key in ipairs({ "CaptureLocation", "MediaStorageLocation" }) do
    local ok, value = pcall(function() return project:GetSetting(key) end)
    if ok and type(value) == "string" then
      local d = maybe_dir(value)
      if d then
        capture_base = d
        break
      end
    end
  end

  if capture_base and timeline_name ~= "" then
    if project_name ~= "" then
      if capture_base:sub(-(#project_name + 1)) == "/" .. project_name then
        return capture_base .. "/" .. timeline_name
      end
      return capture_base .. "/" .. project_name .. "/" .. timeline_name
    end
    return capture_base .. "/" .. timeline_name
  end

  return nil
end

local function detect_media_pool_current_dir(project)
  if not project then return nil end
  local media_pool = project:GetMediaPool()
  if not media_pool then return nil end

  local folder = nil
  local ok_folder, current_folder = pcall(function() return media_pool:GetCurrentFolder() end)
  if ok_folder and current_folder then
    folder = current_folder
  end
  if not folder then return nil end

  local function collect_clips_from_folder(f)
    local ok1, r1 = pcall(function() return f:GetClipList() end)
    if ok1 and r1 then return r1 end
    local ok2, r2 = pcall(function() return f:GetClips() end)
    if ok2 and r2 then return r2 end
    return nil
  end

  local clips = collect_clips_from_folder(folder)
  local dir_count = {}
  local best_dir = nil
  local best_count = 0

  local function ingest_clip(clip)
    if not clip then return end
    local ok_fp, file_path = pcall(function() return clip:GetClipProperty("File Path") end)
    if ok_fp and type(file_path) == "string" then
      local d = maybe_dir(file_path)
      if d then
        local c = (dir_count[d] or 0) + 1
        dir_count[d] = c
        if c > best_count then
          best_count = c
          best_dir = d
        end
      end
    end
  end

  if type(clips) == "table" then
    local n = #clips
    if n > 0 then
      for _, clip in ipairs(clips) do
        ingest_clip(clip)
      end
    else
      for _, clip in pairs(clips) do
        ingest_clip(clip)
      end
    end
  end

  local folder_name = ""
  local ok_name, name = pcall(function() return folder:GetName() end)
  if ok_name and type(name) == "string" then
    folder_name = trim(name)
  end

  if best_dir then
    return parent_dir(best_dir) or best_dir
  end

  if folder_name ~= "" then
    local root = detect_project_root(project)
    if root then
      return root .. "/" .. folder_name
    end
  end

  return nil
end

local function resolve_output_dir(script_dir, output_dir_value)
  local raw = trim(output_dir_value or "")
  if raw == "" then
    return nil, "output_dir が設定されていません。\nconfig.lua の output_dir に保存先の親フォルダを指定してください。"
  end
  return resolve_path(script_dir, raw), nil
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

local function start_voicevox_docker_if_needed()
  local state = {
    started_by_script = false,
    container_name = "voicevox_engine",
    image = "voicevox/voicevox_engine:cpu-ubuntu20.04-latest",
    port = "50021",
  }

  local docker_cmd = resolve_docker_cmd()
  if not docker_cmd then
    return state, "docker command not found"
  end
  state.docker_cmd = docker_cmd

  if docker_container_running(docker_cmd, state.container_name) then
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
    local guard_cmd =
      "(while pgrep -f 'DaVinci Resolve' >/dev/null 2>&1 || pgrep -x Resolve >/dev/null 2>&1; do sleep 10; done; " ..
      shell_quote(docker_cmd) .. " stop " .. shell_quote(state.container_name) .. " >/dev/null 2>&1) >/dev/null 2>&1 &"
    os.execute(guard_cmd)

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
  if not state or not state.started_by_script then
    return
  end
  local docker_cmd = state.docker_cmd or resolve_docker_cmd() or "docker"
  os.execute(shell_quote(docker_cmd) .. " stop " .. shell_quote(state.container_name or "voicevox_engine") .. " >/dev/null 2>&1")
end

local function safe_get_current_project(resolve_obj)
  if not resolve_obj then return nil end
  local ok_pm, pm = pcall(function() return resolve_obj:GetProjectManager() end)
  if not ok_pm or not pm then return nil end
  local ok_prj, project = pcall(function() return pm:GetCurrentProject() end)
  if not ok_prj then return nil end
  return project
end

exists = function(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
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
  if not out then
    return nil, "curl failed"
  end

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
  if payload_path then
    os.remove(payload_path)
  end

  if not out then
    return false, "curl failed"
  end

  local status = out:match("HTTPSTATUS:(%d+)")
  if tonumber(status) ~= 200 then
    return false, "http=" .. tostring(status or "?") .. " body=" .. trim(out:gsub("\n?HTTPSTATUS:%d+", ""))
  end

  if not exists(out_path) then
    return false, "output file was not created"
  end

  return true, nil
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

local function le_u16_local(s, i)
  local b1, b2 = s:byte(i, i + 1)
  if not b1 or not b2 then return nil end
  return b1 + b2 * 256
end

local function le_u32_local(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 or not b2 or not b3 or not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function u32_to_le_local(n)
  local v = math.max(0, math.floor(n or 0))
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function replace_u32_at_local(s, pos, value)
  return s:sub(1, pos - 1) .. u32_to_le_local(value) .. s:sub(pos + 4)
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
    local chunk_size = le_u32_local(data, idx + 4)
    if not chunk_size then break end

    local payload_start = idx + 8
    if chunk_id == "fmt " then
      byte_rate = le_u32_local(data, payload_start + 8)
      block_align = le_u16_local(data, payload_start + 12) or 1
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

  new_data = replace_u32_at_local(new_data, data_size_pos, new_data_size)
  new_data = replace_u32_at_local(new_data, 5, new_riff_size)

  if not write_file(path, new_data) then
    return false, "wav write failed"
  end
  return true, nil
end

local function synthesize_wav(vcfg, text, out_wav, audio_padding_sec)
  local qurl = string.format("%s/audio_query?text=%s&speaker=%d", vcfg.base_url, urlencode(text), tonumber(vcfg.speaker_id))
  local query_json, qerr = curl_json("POST", qurl, "")
  if not query_json or #query_json == 0 then
    return false, "audio_query failed: " .. tostring(qerr)
  end

  local patched = patch_audio_query_json(query_json, vcfg)
  local surl = string.format("%s/synthesis?speaker=%d", vcfg.base_url, tonumber(vcfg.speaker_id))
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

local function get_subtitle_segments_from_timeline(timeline, subtitle_track_index, text_keys)
  if not timeline then return {}, "timeline is nil" end
  local function get_track_items(track_type, track_index)
    local methods = {
      function() return timeline:GetItemListInTrack(track_type, track_index) end,
      function() return timeline.GetItemListInTrack and timeline.GetItemListInTrack(timeline, track_type, track_index) end,
      function() return timeline:GetItemsInTrack(track_type, track_index) end,
      function() return timeline.GetItemsInTrack and timeline.GetItemsInTrack(timeline, track_type, track_index) end,
    }

    for _, m in ipairs(methods) do
      local ok, result = pcall(m)
      if ok and result then
        return result
      end
    end
    return nil
  end

  local segments = {}
  local items = get_track_items("subtitle", subtitle_track_index)
  if not items then return segments end

  for _, item in ipairs(items) do
    local text = nil
    for _, key in ipairs(text_keys) do
      if key == "Name" then
        local name = item:GetName()
        if name and #trim(name) > 0 then
          text = trim(name)
          break
        end
      else
        local ok, prop = pcall(function() return item:GetProperty(key) end)
        if ok and prop and tostring(prop) ~= "" then
          text = trim(tostring(prop))
          break
        end
      end
    end

    if text and #text > 0 then
      local start_frame = tonumber(item:GetStart()) or 0
      table.insert(segments, { text = text, start_frame = start_frame, timeline_item = item })
    end
  end

  return segments
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

local function hash_text(s)
  local h = 5381
  for i = 1, #s do
    h = ((h * 33) + string.byte(s, i)) % 4294967296
  end
  return string.format("%08x", h)
end

local function padding_tag(padding_sec)
  local p = tonumber(padding_sec or 0) or 0
  if p < 0 then p = 0 end
  local ms = math.floor((p * 1000) + 0.5)
  return string.format("p%05d", ms)
end

local function segment_key(seg, pad_tag)
  return tostring(seg.start_frame) .. "_" .. hash_text(seg.text) .. "_" .. tostring(pad_tag or "p00000")
end

local function filename_for_segment(prefix, seg, pad_tag)
  return string.format("%s_%08d_%s_%s.wav", prefix, seg.start_frame, hash_text(seg.text), tostring(pad_tag or "p00000"))
end

local function parse_managed_clip_name(name, prefix)
  local p, start, hh, pad = tostring(name):match("^(.-)_(%d+)_([0-9a-fA-F]+)_(p%d+)")
  if not p or p ~= prefix then return nil end
  if not pad or #pad == 0 then
    pad = "p00000"
  end
  return tostring(tonumber(start)) .. "_" .. string.lower(hh) .. "_" .. pad
end

local function get_clip_name_candidates(item)
  local names = {}
  local n1 = item:GetName()
  if n1 and n1 ~= "" then table.insert(names, tostring(n1)) end

  local ok_mp, mp_item = pcall(function() return item:GetMediaPoolItem() end)
  if ok_mp and mp_item then
    local ok_n2, n2 = pcall(function() return mp_item:GetName() end)
    if ok_n2 and n2 and n2 ~= "" then
      table.insert(names, tostring(n2))
    end
  end

  return names
end

local function import_and_place(media_pool, wav_path, start_frame, audio_track_index)
  -- 現在のフォルダを保存し、"voicevox" ビンを取得または作成してからインポート
  local original_folder = nil
  local ok_gf, cur_folder = pcall(function() return media_pool:GetCurrentFolder() end)
  if ok_gf and cur_folder then
    original_folder = cur_folder
  end

  local target_bin = nil
  if original_folder then
    local ok_sf, subfolders = pcall(function() return original_folder:GetSubFolderList() end)
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
      local ok_add, new_bin = pcall(function() return media_pool:AddSubFolder(original_folder, "voicevox") end)
      if ok_add and new_bin then
        target_bin = new_bin
      end
    end
    if target_bin then
      pcall(function() media_pool:SetCurrentFolder(target_bin) end)
    end
  end

  local imported = media_pool:ImportMedia({ wav_path })

  if original_folder then
    pcall(function() media_pool:SetCurrentFolder(original_folder) end)
  end

  if not imported or #imported == 0 then return false end

  local media_item = imported[1]
  local info = {
    mediaPoolItem = media_item,
    recordFrame = math.floor(start_frame),
    trackIndex = tonumber(audio_track_index),
    mediaType = 2,
  }

  local ok = media_pool:AppendToTimeline({ info })
  return ok ~= nil and ok ~= false
end

local function collect_existing_managed_audio(timeline, audio_track_index, prefix)
  local map = {}
  local duplicates = {}
  if not timeline then return map, duplicates end

  local function get_track_items(track_type, track_index)
    local methods = {
      function() return timeline:GetItemListInTrack(track_type, track_index) end,
      function() return timeline.GetItemListInTrack and timeline.GetItemListInTrack(timeline, track_type, track_index) end,
      function() return timeline:GetItemsInTrack(track_type, track_index) end,
      function() return timeline.GetItemsInTrack and timeline.GetItemsInTrack(timeline, track_type, track_index) end,
    }

    for _, m in ipairs(methods) do
      local ok, result = pcall(m)
      if ok and result then
        return result
      end
    end
    return nil
  end

  local items = get_track_items("audio", tonumber(audio_track_index))
  if not items then return map, duplicates end

  for _, item in ipairs(items) do
    local names = get_clip_name_candidates(item)
    local key = nil
    for _, name in ipairs(names) do
      key = parse_managed_clip_name(name, prefix)
      if key then break end
    end

    if key then
      if not map[key] then
        map[key] = item
      else
        table.insert(duplicates, item)
      end
    end
  end

  return map, duplicates
end

local function build_signature(desired)
  local keys = {}
  for k, _ in pairs(desired) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return table.concat(keys, "|")
end

local function delete_timeline_items(timeline, items)
  if not items or #items == 0 then return true end
  local ok, result = pcall(function()
    return timeline:DeleteClips(items, false)
  end)
  if ok and result ~= false and result ~= nil then return true end

  ok, result = pcall(function()
    return timeline:DeleteClips(items)
  end)
  if ok and result ~= false and result ~= nil then return true end

  return false
end

local function run_watch_job()
  math.randomseed(os.time())

  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir = script_path:match("^(.*)/") or "."
  local config_path = script_dir .. "/config.data"

  local ok_cfg, config = pcall(dofile, config_path)
  if not ok_cfg or type(config) ~= "table" then
    print("設定ファイルの読み込みに失敗しました: " .. tostring(config_path))
    return 1
  end

  local vcfg = config.voicevox or {}
  local rcfg = config.resolve or {}
  local rt = config.runtime or {}

  local output_dir_raw = rt.output_dir or ""
  local log_path = resolve_path(script_dir, rt.log_path or "./run.log")
  local stop_file = resolve_path(script_dir, rt.watch_stop_file or "./watch.stop")
  local lock_file = resolve_path(script_dir, rt.watch_lock_file or "./watch.lock")
  local interval_sec = tonumber(rt.watch_interval_sec) or 2
  if interval_sec < 1 then interval_sec = 1 end
  local stable_cycles_required = tonumber(rt.watch_stable_cycles) or 2
  if stable_cycles_required < 1 then stable_cycles_required = 1 end
  local delete_grace_cycles = tonumber(rt.watch_delete_grace_cycles) or 4
  if delete_grace_cycles < 1 then delete_grace_cycles = 1 end
  local prefix = rt.managed_clip_prefix or "vvauto"
  local pad_tag = padding_tag(rt.audio_padding_sec or 0)

  if exists(stop_file) then
    os.remove(stop_file)
  end

  local lock_token = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) .. "-" .. tostring({})
  write_file(lock_file, lock_token)

  local function log_line(msg)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " | [watch] " .. tostring(msg)
    print(line)
    local f = io.open(log_path, "ab")
    if f then
      f:write(line .. "\n")
      f:close()
    end
  end

  local health = run_capture("curl -sS " .. shell_quote((vcfg.base_url or "http://127.0.0.1:50021") .. "/version"))
  if not health or #trim(health) == 0 then
    log_line("VOICEVOX Engine に接続できません。")
    return 1
  end

  local resolve_obj = resolve or (Resolve and Resolve())
  if not resolve_obj then
    log_line("Resolve APIへの接続に失敗しました。")
    return 1
  end

  local project = safe_get_current_project(resolve_obj)
  if not project then
    log_line("現在のプロジェクトが見つかりません。")
    return 1
  end

  local base_dir, base_dir_err = resolve_output_dir(script_dir, output_dir_raw)
  if not base_dir then
    log_line("出力先の解決に失敗: " .. tostring(base_dir_err))
    return 1
  end

  if not is_dir(base_dir) then
    log_line("出力先フォルダが存在しません: " .. tostring(base_dir))
    return 1
  end

  local output_dir = base_dir .. "/voicevox"
  if not ensure_dir(output_dir) then
    log_line("voicevox フォルダの作成に失敗: " .. tostring(output_dir))
    return 1
  end
  log_line("output_dir=" .. tostring(output_dir))

  log_line("start auto watch interval=" .. tostring(interval_sec) .. "s track=" .. tostring(rcfg.audio_track_index or 1))
  log_line("stable cycles required=" .. tostring(stable_cycles_required))
  log_line("delete grace cycles=" .. tostring(delete_grace_cycles))
  log_line("stop file: " .. tostring(stop_file))
  log_line("lock file: " .. tostring(lock_file))

  local last_signature = nil
  local stable_cycles = 0
  local applied_signature = nil
  local missing_cycles = {}
  local timeline_unavailable_logged = false

  while true do
    local current_lock = trim(read_file(lock_file) or "")
    if current_lock ~= lock_token then
      log_line("lock ownership lost. watch stopped.")
      break
    end

    if exists(stop_file) then
      os.remove(stop_file)
      log_line("stop file detected. watch stopped.")
      break
    end

    local ok_cycle, err_cycle = pcall(function()
      local current_project = safe_get_current_project(resolve_obj)
      if not current_project then
        if not timeline_unavailable_logged then
          log_line("current project unavailable. waiting...")
          timeline_unavailable_logged = true
        end
        return
      end

      local timeline = current_project:GetCurrentTimeline()
      local media_pool = current_project:GetMediaPool()
      local fps = tonumber(current_project:GetSetting("timelineFrameRate")) or 30
      if not timeline or not media_pool then
        if not timeline_unavailable_logged then
          log_line("timeline or media_pool unavailable. waiting...")
          timeline_unavailable_logged = true
        end
        return
      end

      timeline_unavailable_logged = false

      local segments = get_subtitle_segments_from_timeline(
        timeline,
        tonumber(rcfg.subtitle_track_index or 1),
        rcfg.subtitle_text_property_candidates or { "Text", "StyledText", "Name" }
      )

      local desired = {}
      for _, seg in ipairs(segments) do
        local key = segment_key(seg, pad_tag)
        desired[key] = seg
      end

      local signature = build_signature(desired)
      if signature ~= last_signature then
        last_signature = signature
        stable_cycles = 1
        log_line("detected subtitle change. waiting stabilize...")
        return
      end

      stable_cycles = stable_cycles + 1
      if stable_cycles < stable_cycles_required then
        return
      end

      if signature == applied_signature then
        return
      end

      local existing, duplicates = collect_existing_managed_audio(timeline, tonumber(rcfg.audio_track_index or 1), prefix)

      local generated_count = 0
      local placed_count = 0
      local deleted_count = 0
      local linked_count = 0

      for key, seg in pairs(desired) do
        local filename = filename_for_segment(prefix, seg, pad_tag)
        local wav_path = output_dir .. "/" .. filename

        -- テキスト内容ベースのキャッシュファイル（移動しても再合成しない）
        local cache_filename = string.format("_cache_%s_%s.wav", hash_text(seg.text), pad_tag)
        local cache_path = output_dir .. "/" .. cache_filename

        if rt.overwrite or (not exists(cache_path)) then
          local ok_syn, syn_err = synthesize_wav(vcfg, seg.text, cache_path, rt.audio_padding_sec or 0)
          if ok_syn then
            generated_count = generated_count + 1
          else
            log_line("synthesis failed key=" .. key .. " / " .. tostring(syn_err))
          end
        end

        -- キャッシュから配置用ファイルへコピー（start_frame が変わった場合も再合成不要）
        if exists(cache_path) and (rt.overwrite or not exists(wav_path)) then
          os.execute("cp " .. shell_quote(cache_path) .. " " .. shell_quote(wav_path))
        end

        if not existing[key] and exists(wav_path) then
          local ok_place = import_and_place(media_pool, wav_path, seg.start_frame, tonumber(rcfg.audio_track_index or 1))
          if ok_place then
            placed_count = placed_count + 1
          else
            log_line("place failed key=" .. key .. " file=" .. filename)
          end
        end
      end

      -- リンクパス: 配置済み・新規問わず全セグメントの字幕と音声をリンク
      do
        local all_audio = collect_existing_managed_audio(timeline, tonumber(rcfg.audio_track_index or 1), prefix)
        for key, seg in pairs(desired) do
          local audio_item = all_audio[key]
          if seg.timeline_item and audio_item then
            local linked, lerr = try_link_timeline_items(timeline, seg.timeline_item, audio_item)
            if linked then
              linked_count = linked_count + 1
            end
          end
        end
      end

      if #duplicates > 0 then
        -- DeleteClips API は意図しないクリップを削除する場合があるため自動削除しない
        log_line(string.format("duplicate clips (not deleted, please remove manually): %d", #duplicates))
      end

      local to_delete = {}
      for key, item in pairs(existing) do
        if not desired[key] then
          local count = (missing_cycles[key] or 0) + 1
          missing_cycles[key] = count
          if count >= delete_grace_cycles then
            table.insert(to_delete, item)
          end
        else
          missing_cycles[key] = 0
        end
      end

      for key, _ in pairs(desired) do
        if missing_cycles[key] then
          missing_cycles[key] = 0
        end
      end

      if #to_delete > 0 then
        -- DeleteClips API は意図しないクリップを削除する場合があるため自動削除しない
        -- 古い音声クリップはタイムライン上に残るが手動で削除してください
        log_line(string.format("stale clips (not deleted, please remove manually): %d", #to_delete))
        -- 削除扱いにして missing_cycles をリセット
        deleted_count = deleted_count + #to_delete
        for key, item in pairs(existing) do
          if not desired[key] and missing_cycles[key] and missing_cycles[key] >= delete_grace_cycles then
            missing_cycles[key] = 0
          end
        end
      end

      if generated_count > 0 or placed_count > 0 or deleted_count > 0 then
        log_line(string.format("synced generated=%d placed=%d linked=%d deleted=%d subtitles=%d", generated_count, placed_count, linked_count, deleted_count, #segments))
      else
        log_line(string.format("synced no-op subtitles=%d", #segments))
      end

      applied_signature = signature
    end)

    if not ok_cycle then
      log_line("cycle error: " .. tostring(err_cycle))
    end

    os.execute("sleep " .. tostring(interval_sec))
  end

  local current_lock = trim(read_file(lock_file) or "")
  if current_lock == lock_token then
    os.remove(lock_file)
  end

  return 0
end

local function main()
  local docker_state, docker_err = start_voicevox_docker_if_needed()
  if docker_err then
    print("VOICEVOX Docker auto-start: " .. tostring(docker_err))
  end

  local ok, code_or_err = xpcall(run_watch_job, debug.traceback)
  stop_voicevox_docker_if_started(docker_state)

  if not ok then
    print("auto_watch.lua fatal: " .. tostring(code_or_err))
    return 1
  end

  return tonumber(code_or_err) or 1
end

return main()
