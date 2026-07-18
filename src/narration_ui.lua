-- narration_ui.lua
-- VOICEVOX Narration UI: multi-line text → audio + subtitle (SRT) + clip link

-- ============================================================
-- Utility
-- ============================================================

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

local function to_number(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
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

local function append_log(path, message)
  if not path or trim(path) == "" then return end
  local f = io.open(path, "ab")
  if not f then return end
  local line = string.format("%s | [narration_ui] %s", os.date("%Y-%m-%d %H:%M:%S"), tostring(message or ""))
  f:write(line .. "\n")
  f:close()
end

local function show_mac_dialog(title, message)
  local t = tostring(title or "Resolve VOICEVOX")
  local m = tostring(message or "")
  local script = string.format('display dialog "%s" with title "%s" buttons {"OK"} default button "OK"',
    m:gsub('"', '\\"'), t:gsub('"', '\\"'))
  os.execute("/usr/bin/osascript -e " .. shell_quote(script))
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

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
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

-- ============================================================
-- HTTP / Audio synthesis
-- ============================================================

local function make_temp_json_path(base_dir)
  local ts  = tostring(os.time())
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

  local status   = out:match("HTTPSTATUS:(%d+)")
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

local function patch_audio_query_json(query_json, vcfg)
  local patched = query_json

  local function replace_number(key, value)
    if value == nil then return end
    local p = '"' .. key .. '"%s*:%s*[-%d%.eE]+'
    local r = string.format('"%s":%s', key, tostring(value))
    patched = patched:gsub(p, r, 1)
  end

  replace_number("speedScale",        vcfg.speed_scale)
  replace_number("pitchScale",        vcfg.pitch_scale)
  replace_number("intonationScale",   vcfg.intonation_scale)
  replace_number("volumeScale",       vcfg.volume_scale)
  replace_number("prePhonemeLength",  vcfg.pre_phoneme_length)
  replace_number("postPhonemeLength", vcfg.post_phoneme_length)
  replace_number("outputSamplingRate",vcfg.sample_rate)

  local output_stereo = vcfg.output_stereo
  if output_stereo == nil then output_stereo = true end
  local stereo_text = output_stereo and "true" or "false"

  local replaced = 0
  patched, replaced = patched:gsub('"outputStereo"%s*:%s*true',  '"outputStereo":' .. stereo_text, 1)
  if replaced == 0 then
    patched, replaced = patched:gsub('"outputStereo"%s*:%s*false', '"outputStereo":' .. stereo_text, 1)
  end
  if replaced == 0 then
    patched = patched:gsub("}%s*$", ',"outputStereo":' .. stereo_text .. "}")
  end

  return patched
end

local function le_u16(s, i)
  local b1, b2 = s:byte(i, i + 1)
  if not b1 or not b2 then return nil end
  return b1 + b2 * 256
end

local function le_u32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 or not b2 or not b3 or not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
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

  local idx               = 13
  local byte_rate         = nil
  local block_align       = nil
  local data_size         = nil
  local data_size_pos     = nil
  local data_payload_start = nil

  while idx + 7 <= #data do
    local chunk_id   = data:sub(idx, idx + 3)
    local chunk_size = le_u32(data, idx + 4)
    if not chunk_size then break end

    local payload_start = idx + 8
    if chunk_id == "fmt " then
      byte_rate   = le_u32(data, payload_start + 8)
      block_align = le_u16(data, payload_start + 12) or 1
    elseif chunk_id == "data" then
      data_size           = chunk_size
      data_size_pos       = idx + 4
      data_payload_start  = payload_start
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

  local zeros         = string.rep("\0", pad_bytes)
  local new_data      = data .. zeros
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
  local surl    = string.format("%s/synthesis?speaker=%d", base_url, tonumber(vcfg.speaker_id))
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

local function parse_wav_duration_sec(path)
  local data = read_file(path)
  if not data or #data < 44 then return nil end
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return nil end

  local idx       = 13
  local byte_rate = nil
  local data_size = nil

  while idx + 7 <= #data do
    local chunk_id   = data:sub(idx, idx + 3)
    local chunk_size = le_u32(data, idx + 4)
    if not chunk_size then break end
    local payload_start = idx + 8

    if chunk_id == "fmt " then
      byte_rate = le_u32(data, payload_start + 8)
    elseif chunk_id == "data" then
      data_size = chunk_size
      break
    end

    idx = payload_start + chunk_size
    if chunk_size % 2 == 1 then idx = idx + 1 end
  end

  if not byte_rate or byte_rate <= 0 or not data_size then return nil end
  return data_size / byte_rate
end

-- ============================================================
-- Docker / VOICEVOX engine management
-- ============================================================

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
    container_name    = "voicevox_engine",
    image             = "voicevox/voicevox_engine:cpu-ubuntu24.04-0.26.0-dev",
    port              = "50022",
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

-- ============================================================
-- Resolve API helpers
-- ============================================================

local function get_resolve()
  if resolve then return resolve end
  if Resolve then return Resolve() end
  return nil
end

-- Tries multiple GetItemListInTrack variants for cross-version compatibility.
local function get_track_items(timeline, track_type, track_index)
  local methods = {
    function() return timeline:GetItemListInTrack(track_type, track_index) end,
    function() return timeline.GetItemListInTrack and timeline.GetItemListInTrack(timeline, track_type, track_index) end,
    function() return timeline:GetItemsInTrack(track_type, track_index) end,
    function() return timeline.GetItemsInTrack and timeline.GetItemsInTrack(timeline, track_type, track_index) end,
  }

  for _, m in ipairs(methods) do
    local ok, result = pcall(m)
    if ok and result then return result end
  end

  return nil
end

-- Snapshot all clip object-keys and start frames on a track for delta detection.
local function snapshot_track_item_ids(timeline, track_type, track_index)
  local ids     = {}
  local entries = {}
  for _, item in ipairs(get_track_items(timeline, track_type, track_index) or {}) do
    local key    = tostring(item)
    ids[key]     = true
    entries[key] = { item = item, start = math.floor(tonumber(item:GetStart()) or -1) }
  end
  return { ids = ids, entries = entries }
end

-- Return the new item (not in before_snap) closest to target_start, or nil.
local function find_new_item_from_snapshot(before_snap, after_snap, target_start)
  local best      = nil
  local best_dist = nil
  local before_ids = (before_snap and before_snap.ids)    or {}
  local after_ent  = (after_snap  and after_snap.entries) or {}
  local target     = math.floor(tonumber(target_start) or 0)

  for key, entry in pairs(after_ent) do
    if not before_ids[key] then
      local dist = math.abs((entry.start or -1) - target)
      if not best_dist or dist < best_dist then
        best      = entry.item
        best_dist = dist
      end
    end
  end
  return best
end

-- Add tracks until timeline has at least target_index tracks of the given type.
local function ensure_track_count(timeline, track_type, target_index)
  local desired = math.max(1, math.floor(tonumber(target_index) or 1))
  local current = tonumber(timeline:GetTrackCount(track_type)) or 0
  while current < desired do
    if track_type == "audio" then
      pcall(function() timeline:AddTrack("audio", "stereo") end)
    else
      pcall(function() timeline:AddTrack(track_type) end)
    end
    local new_count = tonumber(timeline:GetTrackCount(track_type)) or current
    if new_count <= current then break end
    current = new_count
  end
end

-- Find the first audio item at start_frame on the given track (with optional name hint).
local function find_audio_item_on_track(timeline, audio_track_index, start_frame, name_hint)
  local items  = get_track_items(timeline, "audio", tonumber(audio_track_index))
  if not items then return nil end
  local target = math.floor(tonumber(start_frame) or 0)
  for _, item in ipairs(items) do
    if math.floor(tonumber(item:GetStart()) or -1) == target then
      if not name_hint then return item end
      local n = tostring(item:GetName() or "")
      if n == name_hint or n:find(name_hint, 1, true) then return item end
    end
  end
  return nil
end

-- Return (track, start_frame, end_frame) of target_item, or (nil, nil, nil).
local function find_item_location(timeline, track_type, target_item)
  if not timeline or not target_item then return nil, nil, nil end
  local target_key  = tostring(target_item)
  local track_count = tonumber(timeline:GetTrackCount(track_type)) or 0
  for track = 1, track_count do
    for _, item in ipairs(get_track_items(timeline, track_type, track) or {}) do
      if tostring(item) == target_key then
        return track,
          math.floor(tonumber(item:GetStart()) or -1),
          math.floor(tonumber(item:GetEnd())   or -1)
      end
    end
  end
  return nil, nil, nil
end

-- Import a WAV into the "voicevox" Media Pool bin and place it on an audio track.
-- Returns (ok, placed_timeline_item).
local function import_and_place_audio(media_pool, timeline, wav_path, start_frame, audio_track_index)
  -- Locate or create the root-level "voicevox" bin (prevents nesting on re-import).
  local root_folder = nil
  pcall(function() root_folder = media_pool:GetRootFolder() end)

  local target_bin = nil
  if root_folder then
    local ok_sf, subfolders = pcall(function() return root_folder:GetSubFolderList() end)
    if ok_sf and type(subfolders) == "table" then
      for _, sf in ipairs(subfolders) do
        local ok_n, n = pcall(function() return sf:GetName() end)
        if ok_n and n == "voicevox" then target_bin = sf; break end
      end
    end
    if not target_bin then
      local ok_add, new_bin = pcall(function() return media_pool:AddSubFolder(root_folder, "voicevox") end)
      if ok_add and new_bin then target_bin = new_bin end
    end
  end

  local original_folder = nil
  local ok_gf, cur_folder = pcall(function() return media_pool:GetCurrentFolder() end)
  if ok_gf and cur_folder then original_folder = cur_folder end
  if target_bin then pcall(function() media_pool:SetCurrentFolder(target_bin) end) end

  local imported = media_pool:ImportMedia({ wav_path })
  if original_folder then pcall(function() media_pool:SetCurrentFolder(original_folder) end) end
  if not imported or #imported == 0 then return false, nil end

  local frame = math.floor(tonumber(start_frame) or 0)
  local track = tonumber(audio_track_index)
  local before_snap = snapshot_track_item_ids(timeline, "audio", track)

  local info = {
    mediaPoolItem = imported[1],
    recordFrame   = frame,
    trackIndex    = track,
    mediaType     = 2,
  }
  local ok, result = pcall(function() return media_pool:AppendToTimeline({ info }) end)
  if not ok or result == nil or result == false then return false, nil end

  local after_snap  = snapshot_track_item_ids(timeline, "audio", track)
  local placed_item = find_new_item_from_snapshot(before_snap, after_snap, start_frame)
  local name_hint   = tostring(wav_path):match("([^/]+)$")

  if not placed_item then
    placed_item = find_audio_item_on_track(timeline, audio_track_index, start_frame, name_hint)
  end
  if not placed_item then
    local items = get_track_items(timeline, "audio", track) or {}
    for idx = #items, 1, -1 do
      local n = tostring(items[idx]:GetName() or "")
      if n == name_hint or n:find(name_hint, 1, true) then
        placed_item = items[idx]; break
      end
    end
  end
  return true, placed_item
end

-- ============================================================
-- SRT export and subtitle import
-- ============================================================

-- Convert integer milliseconds to an SRT timestamp string "HH:MM:SS,mmm".
local function ms_to_srt(ms)
  ms = math.max(0, math.floor(ms + 0.5))
  local h   = math.floor(ms / 3600000)
  local m_v = math.floor((ms % 3600000) / 60000)
  local s   = math.floor((ms % 60000) / 1000)
  local f   = ms % 1000
  return string.format("%02d:%02d:%02d,%03d", h, m_v, s, f)
end

-- Clear ALL subtitle clips on track 1, then place subtitles at exact audio
-- frame positions using a probe-and-correct two-pass approach.
--
-- PROBLEM: Resolve's AppendToTimeline for SRT ignores both recordFrame and
-- SetCurrentTimecode. It uses an internal "current_pos" that advances with
-- each AppendToTimeline call and cannot be set directly.
--
-- SOLUTION (probe approach):
--   1. Place a 1-frame dummy SRT → observe probe_frame = sub1.GetStart().
--      After this, Resolve's current_pos = probe_frame + 1.
--   2. Delete probe clips (current_pos stays at probe_frame + 1).
--   3. Build corrected SRT: entry_i_time = (audio_i_start - (probe_frame+1)) / fps
--   4. Place corrected SRT → sub_i = (probe_frame+1) + entry_i = audio_i_start ✓
--
-- srt_entries: array of {start_frame, dur_frames, text}  (audio clip positions)
-- srt_path:    where to write the final SRT file
-- Returns (ok, all_sub_items_sorted_by_start).
local function rebuild_subtitle_track(media_pool, timeline, srt_entries, fps, srt_path, log_fn)
  local function dlog(m) if log_fn then log_fn(m) end end

  pcall(function()
    if (tonumber(timeline:GetTrackCount("subtitle")) or 0) < 1 then
      timeline:AddTrack("subtitle")
    end
  end)

  -- NOTE: We intentionally do NOT delete existing subtitle clips here.
  -- Each narration run APPENDS new subtitles so that clips from previous
  -- runs are preserved on the timeline.
  local existing_n = 0
  pcall(function()
    local ex = timeline:GetItemListInTrack("subtitle", 1)
    existing_n = ex and #ex or 0
  end)
  dlog(string.format("subtitle track: existing_clips=%d (preserved)", existing_n))

  -- PROBE PASS: place a 1-frame dummy SRT to discover Resolve's current_pos.
  local one_frame_ms = math.ceil(1000 / fps)
  local probe_text   = "1\n" .. ms_to_srt(0) .. " --> " .. ms_to_srt(one_frame_ms) .. "\nprobe\n\n"
  local probe_path   = srt_path:gsub("%.srt$", "") .. "_probe.srt"
  local probe_frame  = nil

  if write_file(probe_path, probe_text) then
    local ok_pi, probe_imp = pcall(function() return media_pool:ImportMedia({probe_path}) end)
    if ok_pi and probe_imp and #probe_imp > 0 then
      -- Snapshot items BEFORE placing probe so we can identify only the new clip.
      local pre_items = {}
      local pre_set   = {}
      pcall(function()
        local t = timeline:GetItemListInTrack("subtitle", 1)
        if t then
          for _, it in ipairs(t) do
            table.insert(pre_items, it)
            pre_set[tostring(it)] = true
          end
        end
      end)

      pcall(function()
        media_pool:AppendToTimeline({{mediaPoolItem = probe_imp[1], trackIndex = 1}})
      end)

      -- Find ONLY the newly added probe clip (not existing clips from prev runs).
      local new_clip = nil
      pcall(function()
        local post = timeline:GetItemListInTrack("subtitle", 1)
        if post then
          -- Sort by start desc; the probe is the last-placed clip.
          table.sort(post, function(a, b)
            return (tonumber(a:GetStart()) or 0) > (tonumber(b:GetStart()) or 0)
          end)
          for _, it in ipairs(post) do
            if not pre_set[tostring(it)] then
              new_clip = it
              break
            end
          end
          -- Fallback: if we can't distinguish by identity, take the last by position.
          if not new_clip and #post > #pre_items then
            new_clip = post[1]  -- sorted desc, so post[1] is the rightmost = probe
          end
        end
      end)

      if new_clip then
        probe_frame = math.floor(tonumber(new_clip:GetStart()) or -1)
        dlog(string.format("probe: current_pos=%d", probe_frame))
        -- Delete ONLY the probe clip. Existing subtitle clips are preserved.
        pcall(function() timeline:DeleteClips({new_clip}, false) end)
      end
    end
    pcall(function() os.remove(probe_path) end)
  end

  if not probe_frame or probe_frame < 0 then
    dlog("probe failed: cannot determine current_pos")
    return false, {}
  end

  -- After probe, Resolve's current_pos = probe_frame (the probe clip has 0 effective
  -- frame advancement in Resolve's internal position tracking).
  -- Build real SRT: entry_i_time = ceil(N * 1000 / fps) where N = audio_i_start - probe_frame.
  -- Placement: sub_i = probe_frame + floor(entry_i_time * fps / 1000) = audio_i_start ✓
  local origin = probe_frame
  local parts = {}
  for idx, entry in ipairs(srt_entries) do
    local N     = entry.start_frame - origin
    local N_end = entry.start_frame + entry.dur_frames - origin
    local t_ms  = math.max(0, math.ceil( N     * 1000 / fps))
    local e_ms  = math.max(0, math.ceil( N_end * 1000 / fps))
    e_ms = math.max(t_ms + 1, e_ms)
    table.insert(parts, tostring(idx))
    table.insert(parts, ms_to_srt(t_ms) .. " --> " .. ms_to_srt(e_ms))
    table.insert(parts, tostring(entry.text))
    table.insert(parts, "")
  end

  if not write_file(srt_path, table.concat(parts, "\n")) then
    dlog("SRT write failed")
    return false, {}
  end

  local ok_imp, imp_result = pcall(function() return media_pool:ImportMedia({srt_path}) end)
  if not ok_imp or not imp_result or #imp_result == 0 then
    dlog("SRT import failed")
    return false, {}
  end

  local sub_ok = false
  pcall(function()
    local r = media_pool:AppendToTimeline({{mediaPoolItem = imp_result[1], trackIndex = 1}})
    sub_ok = (r ~= nil and r ~= false)
  end)
  if not sub_ok then return false, {} end

  local all_items = nil
  pcall(function() all_items = timeline:GetItemListInTrack("subtitle", 1) end)
  all_items = all_items or {}
  table.sort(all_items, function(a, b)
    return (tonumber(a:GetStart()) or 0) < (tonumber(b:GetStart()) or 0)
  end)

  for i = 1, math.min(3, #all_items) do
    local got = math.floor(tonumber(all_items[i]:GetStart()) or -1)
    local exp = (srt_entries[i] and srt_entries[i].start_frame) or -1
    dlog(string.format("  placed sub %d at frame=%d (expected=%d diff=%d)",
      i, got, exp, got - exp))
  end

  return true, all_items
end


-- ============================================================
-- Misc helpers
-- ============================================================

local function timecode_to_frame(tc, fps)
  local h, m, s, f = tostring(tc or ""):match("^(%d+):(%d+):(%d+):(%d+)$")
  if not h then
    h, m, s, f = tostring(tc or ""):match("^(%d+):(%d+):(%d+);(%d+)$")
  end
  if not h then return nil end
  return tonumber(h) * 3600 * fps + tonumber(m) * 60 * fps + tonumber(s) * fps + tonumber(f)
end

local function split_non_empty_lines(text)
  local out    = {}
  local source = tostring(text or "")
  source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in source:gmatch("([^\n]*)\n?") do
    if line == "" and source:sub(-1) ~= "\n" then break end
    local t = trim(line)
    if t ~= "" then table.insert(out, t) end
  end
  return out
end

-- Normalise a {[1]=..., [2]=...} or array table of lines into an ordered,
-- non-empty, trimmed string array.
local function normalize_line_list(line_tbl)
  local indexed = {}
  for k, v in pairs(line_tbl or {}) do
    local nk = tonumber(k)
    if nk and nk >= 1 then
      table.insert(indexed, { idx = nk, text = tostring(v or "") })
    end
  end
  table.sort(indexed, function(a, b) return a.idx < b.idx end)

  local out = {}
  for _, row in ipairs(indexed) do
    local t = trim(row.text)
    if t ~= "" then table.insert(out, t) end
  end
  return out
end

-- Return the duration of audio_item in frames, falling back to WAV header parse.
local function audio_duration_frames(audio_item, fps, wav_path)
  if audio_item then
    local d = tonumber(audio_item:GetDuration())
    if d and d > 0 then return math.max(1, math.floor(d + 0.5)) end

    local s = tonumber(audio_item:GetStart())
    local e = tonumber(audio_item:GetEnd())
    if s and e and e > s then return math.max(1, math.floor((e - s) + 0.5)) end
  end

  local sec = parse_wav_duration_sec(wav_path)
  if sec and sec > 0 then return math.max(1, math.floor(sec * fps + 0.5)) end

  return 1
end

local function load_config(config_path)
  local ok, cfg = pcall(dofile, config_path)
  if not ok or type(cfg) ~= "table" then return nil end
  return cfg
end

-- ============================================================
-- Main
-- ============================================================

local function main()
  math.randomseed(os.time())

  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir  = script_path:match("^(.*)/") or "."
  local config_path = script_dir .. "/config.data"

  local resolve_obj = get_resolve()
  if not resolve_obj then
    print("Resolve API が見つかりません。Resolve 内から実行してください。")
    return 1
  end

  local fusion = resolve_obj:Fusion()
  if not fusion or not fusion.UIManager or not bmd or not bmd.UIDispatcher then
    print("UIManager が使えません。")
    return 1
  end

  local ui   = fusion.UIManager
  local disp = bmd.UIDispatcher(ui)

  local docker_state, docker_err = start_voicevox_docker_if_needed()
  if docker_err then
    print("VOICEVOX Docker auto-start: " .. tostring(docker_err))
  end

  -- ---- Main window ----
  local win = disp:AddWindow({
    ID = "NarrationUiWin",
    WindowTitle = "Resolve VOICEVOX Narration UI",
    Geometry = { 120, 120, 520, 860 },
  },
  ui:VGroup {
    ID = "root",
    Spacing = 8,
    Weight = 1,

    ui:Label { Text = "Narration Input (1 line = 1 clip)", Weight = 0 },
    ui:Label { ID = "status", Text = "", Weight = 0 },

    ui:TextEdit { ID = "text_input", Weight = 2, PlainText = "" },

    ui:HGroup {
      Weight = 0,
      ui:Button { ID = "split_btn", Text = "Split Lines" },
      ui:Button { ID = "clear_btn", Text = "Clear Lines" },
    },

    ui:Label { ID = "preview_header", Text = "Split preview (read-only):", Weight = 0 },
    ui:TextEdit { ID = "lines_preview", Weight = 1, PlainText = "", Enabled = false },

    ui:HGroup {
      Weight = 0,
      ui:Button { ID = "place_btn", Text = "Generate + Place" },
      ui:Button { ID = "close_btn", Text = "Close" },
    },
  })

  local items = win:GetItems()

  -- State
  local lines                 = {}
  local last_split_source     = ""
  local last_place_started_at = 0
  local is_processing         = false
  local cancel_requested      = false
  local in_split_view         = false

  -- ---- Progress dialog ----
  local loading_win = disp:AddWindow({
    ID = "VvProgressWin",
    WindowTitle = "Generating...",
    Geometry = { 260, 400, 400, 100 },
  },
  ui:VGroup {
    Spacing = 10,
    ui:Label { ID = "prog_label", Text = "Starting...", Alignment = { AlignHCenter = true }, Weight = 1 },
    ui:Button { ID = "prog_cancel_btn", Text = "Cancel", Weight = 0 },
  })
  local prog_items = loading_win:GetItems()

  function loading_win.On.prog_cancel_btn.Clicked()
    cancel_requested = true
    prog_items.prog_label.Text = "Cancelling..."
  end
  function loading_win.On.VvProgressWin.Close()
    cancel_requested = true
  end

  -- ---- Helpers ----

  local function set_status(msg)
    items.status.Text = tostring(msg or "")
  end

  local function ensure_lines_from_input()
    if in_split_view and #lines > 0 then
      set_status(string.format("%d lines prepared", #lines))
      return
    end
    local src     = tostring(items.text_input.PlainText or "")
    lines             = split_non_empty_lines(src)
    last_split_source = src
    in_split_view     = false
    set_status(string.format("%d lines prepared", #lines))
  end

  -- ---- Core: generate audio + SRT, place on timeline ----

  local function perform_generate_and_place()
    if is_processing then
      set_status("already running; press Cancel to stop")
      return
    end

    local now_sec = os.time()
    if now_sec - (tonumber(last_place_started_at) or 0) < 2 then
      set_status("Generate is already running")
      return
    end
    last_place_started_at = now_sec

    -- Sync lines from text_input when not already in split view
    local current_source = tostring(items.text_input.PlainText or "")
    if trim(current_source) ~= "" and current_source ~= last_split_source then
      lines             = split_non_empty_lines(current_source)
      last_split_source = current_source
    end

    lines = normalize_line_list(lines)
    if #lines == 0 then
      ensure_lines_from_input()
      if #lines == 0 then
        set_status("input is empty")
        return
      end
    end

    -- Load config
    local config = load_config(config_path)
    if not config then
      set_status("config.data read failed")
      return
    end

    local vcfg    = config.voicevox or {}
    local rcfg    = config.resolve  or {}
    local rt      = config.runtime  or {}
    local do_link = rt.link_clips ~= false
    local log_path = resolve_path(script_dir, rt.log_path or "./run.log")
    local function log(msg) append_log(log_path, msg) end

    -- Validate output directory
    local output_dir = resolve_path(script_dir, rt.output_dir or "")
    if trim(output_dir or "") == "" then
      log("output_dir is empty")
      set_status("output_dir is empty (open config.lua)")
      return
    end
    if not is_dir(output_dir) then
      log("output_dir not found: " .. tostring(output_dir))
      set_status("output_dir not found: " .. tostring(output_dir))
      return
    end

    -- Get Resolve objects
    local pm      = resolve_obj:GetProjectManager()
    local project = pm and pm:GetCurrentProject() or nil
    if not project then set_status("project not found"); return end

    local timeline   = project:GetCurrentTimeline()
    local media_pool = project:GetMediaPool()
    if not timeline or not media_pool then
      log("timeline/media_pool unavailable")
      set_status("timeline/media_pool unavailable")
      return
    end

    local fps         = tonumber(project:GetSetting("timelineFrameRate")) or 30
    local track_index = tonumber(rcfg.text_track_index or 1)

    ensure_track_count(timeline, "video", track_index)
    ensure_track_count(timeline, "audio", track_index)

    local playhead_tc   = timeline:GetCurrentTimecode()
    local current_frame = timecode_to_frame(playhead_tc, fps)
    if not current_frame then
      log("playhead timecode parse failed: " .. tostring(playhead_tc))
      set_status("playhead timecode parse failed")
      return
    end

    local ordered_lines = normalize_line_list(lines)
    log(string.format("start lines=%d playhead_tc=%s frame=%d track=%d fps=%s",
      #ordered_lines, tostring(playhead_tc), current_frame, track_index, tostring(fps)))

    local placed               = 0
    local failed               = 0
    local cancelled            = false
    local srt_entries          = {}
    local audio_items_this_run = {}  -- parallel to srt_entries; may contain nil entries

    is_processing    = true
    cancel_requested = false
    prog_items.prog_label.Text = string.format("0 / %d lines", #ordered_lines)
    loading_win:Show()

    -- ----------------------------------------------------------------
    -- Phase 1: Synthesize all WAVs (no timeline placement yet).
    -- Compute srt_entries from WAV file durations so SRT can be placed
    -- BEFORE audio clips.  Placing SRT first is critical because Resolve's
    -- AppendToTimeline for SRT uses the "current record position" (end of
    -- last placed content), which is the playhead position before any audio
    -- has been placed in this run.
    -- ----------------------------------------------------------------
    local wav_paths = {}  -- [i] = wav path or nil
    local srt_frame = current_frame  -- advances per line to compute start frames
    for i = 1, #ordered_lines do
      prog_items.prog_label.Text = string.format("Synthesizing %d / %d ...", i, #ordered_lines)
      pcall(function() bmd.wait(0.01) end)

      if cancel_requested then
        cancelled = true
        log(string.format("cancel requested: stopping before line %d (synth phase)", i))
        break
      end

      local line     = ordered_lines[i]
      local filename = string.format("vvnarr_%d_%03d_s%d.wav", os.time(), i, tonumber(vcfg.speaker_id) or 1)
      local wav_path = output_dir .. "/" .. filename

      local ok_syn, syn_err = synthesize_wav(vcfg, line, wav_path, rt.audio_padding_sec or 0)
      if not ok_syn then
        log(string.format("line %d synth failed: %s", i, tostring(syn_err)))
        failed = failed + 1
        wav_paths[i] = nil
      else
        log(string.format("line %d synth ok: %s", i, tostring(wav_path)))
        wav_paths[i] = wav_path

        local dur_frames = audio_duration_frames(nil, fps, wav_path)
        table.insert(srt_entries, {
          start_frame = srt_frame,
          dur_frames  = dur_frames,
          text        = line,
        })
        srt_frame = srt_frame + dur_frames
      end

      set_status(string.format("synthesizing %d/%d ...", i, #ordered_lines))
    end

    -- ----------------------------------------------------------------
    -- Place SRT FIRST (before any audio AppendToTimeline calls).
    -- At this point the "current record position" is the playhead frame,
    -- so entry1 (00:00:00,000) lands exactly at playhead. ✓
    -- ----------------------------------------------------------------
    local srt_path = nil
    if #srt_entries > 0 then
      local srt_filename = string.format("vvnarr_%d.srt", os.time())
      srt_path = output_dir .. "/" .. srt_filename

      log(string.format("SRT: probe-and-correct  base=%d", srt_entries[1].start_frame))
      local sub_ok, all_subs = rebuild_subtitle_track(media_pool, timeline, srt_entries, fps, srt_path, log)
      if sub_ok then
        log(string.format("subtitle track rebuilt (clips=%d)", #all_subs))
      else
        log("subtitle track rebuild failed")
        srt_path = nil
      end
    end

    -- ----------------------------------------------------------------
    -- Phase 2: Place audio clips now (after SRT).
    -- ----------------------------------------------------------------
    local audio_cursor = current_frame  -- = playhead_frame (unchanged so far)
    for i = 1, #ordered_lines do
      prog_items.prog_label.Text = string.format("Placing audio %d / %d ...", i, #ordered_lines)
      pcall(function() bmd.wait(0.01) end)

      if cancel_requested then
        cancelled = true
        log(string.format("cancel requested: stopping before audio line %d (place phase)", i))
        break
      end

      local wav_path = wav_paths[i]
      if wav_path then
        local ok_audio, audio_item = import_and_place_audio(media_pool, timeline, wav_path, audio_cursor, track_index)
        if not ok_audio then
          log(string.format("line %d audio place failed frame=%d track=%d", i, audio_cursor, track_index))
          failed = failed + 1
          table.insert(audio_items_this_run, nil)
        else
          local dur_frames       = audio_duration_frames(audio_item, fps, wav_path)
          local a_track, a_start = find_item_location(timeline, "audio", audio_item)
          log(string.format("line %d audio placed frame=%d dur=%d actual=(A%s@%s)",
            i, audio_cursor, dur_frames, tostring(a_track or "?"), tostring(a_start or "?")))

          local base_start = audio_cursor
          if a_start and a_start >= 0 then base_start = math.max(base_start, a_start) end
          audio_cursor = base_start + dur_frames

          table.insert(audio_items_this_run, audio_item)
          placed = placed + 1
        end
      else
        table.insert(audio_items_this_run, nil)
      end

      set_status(string.format("placing audio %d/%d ...", i, #ordered_lines))
    end

    -- Link subtitle + audio pairs.
    -- Match by proximity: find the subtitle clip nearest to each audio clip's
    -- start frame. This is correct even when the subtitle track has clips from
    -- previous runs (which would be at different positions).
    if do_link and #srt_entries > 0 then
      local all_subs = {}
      pcall(function()
        local si = timeline:GetItemListInTrack("subtitle", 1)
        if si then all_subs = si end
      end)
      local linked_count = 0
      for i = 1, #audio_items_this_run do
        local ai    = audio_items_this_run[i]
        local entry = srt_entries[i]
        if ai and entry then
          local expected = entry.start_frame
          local best_si, best_dist = nil, 5  -- tolerance: ±4 frames
          for _, si in ipairs(all_subs) do
            local sf = math.floor(tonumber(si:GetStart()) or -1)
            if sf >= 0 then
              local dist = math.abs(sf - expected)
              if dist < best_dist then
                best_dist = dist
                best_si   = si
              end
            end
          end
          if best_si then
            local ok_l = pcall(function() timeline:SetClipsLinked({ai, best_si}, true) end)
            if ok_l then linked_count = linked_count + 1 end
          end
        end
      end
      if linked_count > 0 then
        log(string.format("auto-linked %d audio+subtitle pair(s)", linked_count))
      end
    end

    is_processing = false
    loading_win:Hide()

    log(string.format("done lines=%d placed=%d failed=%d", #ordered_lines, placed, failed))

    local srt_msg    = srt_path and ("\nSRT: " .. srt_path) or ""
    local result_tag = cancelled and "cancelled" or "done"
    local msg = string.format("%s: lines=%d placed=%d failed=%d%s",
      result_tag, #ordered_lines, placed, failed, srt_msg)
    set_status(msg)
    show_mac_dialog("Resolve VOICEVOX Narration UI", msg)
  end

  -- ---- UI event handlers ----

  function win.On.split_btn.Clicked()
    local src = tostring(items.text_input.PlainText or "")
    lines             = split_non_empty_lines(src)
    last_split_source = src
    if #lines > 0 then
      local preview = {}
      for i, line in ipairs(lines) do
        table.insert(preview, string.format("%d. %s", i, line))
      end
      items.lines_preview.PlainText = table.concat(preview, "\n")
      in_split_view = true
      set_status(string.format("%d lines prepared", #lines))
    else
      in_split_view = false
      items.lines_preview.PlainText = ""
      set_status("no lines found")
    end
  end

  function win.On.text_input.TextChanged()
    if in_split_view then
      in_split_view = false
      lines         = {}
      items.lines_preview.PlainText = "(text changed — click Split Lines again)"
    end
  end

  function win.On.clear_btn.Clicked()
    lines         = {}
    in_split_view = false
    items.text_input.PlainText    = ""
    items.lines_preview.PlainText = ""
    set_status("lines cleared")
  end

  function win.On.place_btn.Clicked()
    perform_generate_and_place()
  end

  function win.On.close_btn.Clicked()
    disp:ExitLoop()
  end

  function win.On.NarrationUiWin.Close()
    disp:ExitLoop()
  end

  set_status("paste text, then Generate + Place")
  win:Show()
  disp:RunLoop()
  win:Hide()

  stop_voicevox_docker_if_started(docker_state)
  return 0
end

return main()
