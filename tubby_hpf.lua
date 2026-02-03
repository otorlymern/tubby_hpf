-- tubby_hpf.lua
-- King Tubby Altec 9069
--high-pass emulation for norns
engine.name = "TubbyHPF"

local audio = require 'audio'

-- Altec 9069B steps (Hz)
local STEPS = {70,100,150,250,500,1000,2000,3000,5000,7500}
local step_idx = 1
local step_mode = true
local bypass = false

-- sweep tracking
local last_sweep_hz = STEPS[1]

-- acceleration for long-press
local k2_down, k3_down = false, false
local accel_task = nil
local hold_seconds = 0

-- params
local drive_db = 0     -- E2 mapped
local outlevel = 1.0   -- E3 mapped
local mode = 0         -- 0 flat, 1 bump, 2 tub

-- click trigger toggle so SC sees changes
local click_state = 0
local function trigger_step_click()
  click_state = 1 - click_state
  engine.click(click_state)
end

local function nearest_step_idx(hz)
  local nearest = 1
  local mind = 1e9
  for i,f in ipairs(STEPS) do
    local dd = math.abs(f-hz)
    if dd < mind then mind = dd; nearest=i end
  end
  return nearest
end

-- utility
local function set_cutoff_from_idx(idx, click)
  step_idx = util.clamp(idx, 1, #STEPS)
  engine.cutoff(STEPS[step_idx])
  if click then trigger_step_click() end
end

local function set_cutoff_continuous(hz, update_nearest)
  last_sweep_hz = util.clamp(hz, 70, 7500)
  engine.cutoff(last_sweep_hz)
  if update_nearest then
    step_idx = nearest_step_idx(last_sweep_hz)
  end
end

local function toggle_bypass()
  bypass = not bypass
  engine.bypass(bypass and 1 or 0)
  redraw()
end

-- long press acceleration with slight exponential growth
local function stop_accel()
  if accel_task then
    clock.cancel(accel_task)
    accel_task = nil
  end
end

local function start_accel(direction) -- +1 up, -1 down
  stop_accel()
  if direction == 0 then return end
  hold_seconds = 0
  accel_task = clock.run(function()
    while (direction==1 and k3_down) or (direction==-1 and k2_down) do
      clock.sleep(0.2)
      hold_seconds = hold_seconds + 0.2
      -- exponential-ish step size: 1,1,1,2,2,3,4...
      local step = math.floor(1 + (hold_seconds^1.25))
      local newidx = util.clamp(step_idx + (direction*step), 1, #STEPS)
      if newidx ~= step_idx then
        set_cutoff_from_idx(newidx, true)
        redraw()
      end
    end
    accel_task = nil
  end)
end

-- encoders:
-- E1: sweep when holding K2 (both modes)
-- E2: input drive (dB), subtle console saturation
-- E3: output level (post-filter)
function enc(n, d)
  if n==1 then
    if k2_down then
      if step_mode then
        -- snap through steps with the knob feel
        if d ~= 0 then
          set_cutoff_from_idx(step_idx + d, true)
          redraw()
        end
      else
        -- SWEEP while holding K2
        local cur = params:get("sweep_hz")
        cur = util.clamp(cur * math.pow(2, d/24), 70, 7500)
        params:set("sweep_hz", cur) -- drives engine via param action
      end
    else
      -- when not sweeping, E1 changes bump mode
      if d ~= 0 then
        mode = (mode + (d > 0 and 1 or -1)) % 3
        engine.mode(mode)
        redraw()
      end
    end
  elseif n==2 then
    params:delta("drive_db", d)
  elseif n==3 then
    params:delta("outlevel", d)
  end
end

-- keys:
-- K1: cycle bump mode (FLAT -> BUMP -> TUB)
-- K2: step down (tap), hold for accel; with E1 sweeps
-- K3: step up (tap), hold for accel
-- K2+K3 together: toggle bypass (latch)
local last_combo_time = 0
function key(n, z)
  -- detect combo for bypass
  local now = util.time()
  if n==2 then k2_down = (z==1)
  elseif n==3 then k3_down = (z==1) end

  if k2_down and k3_down then
    stop_accel()
    if now - last_combo_time > 0.25 then
      last_combo_time = now
      toggle_bypass()
    end
    return
  end

  if n==1 and z==1 then
    -- cycle bump mode
    mode = (mode + 1) % 3
    engine.mode(mode)
    redraw()
  end

  if step_mode then
    if n==2 then
      if z==1 then
        -- tap = one step down
        set_cutoff_from_idx(step_idx-1, true); redraw(); start_accel(-1)
      else
        stop_accel()
      end
    elseif n==3 then
      if z==1 then
        set_cutoff_from_idx(step_idx+1, true); redraw(); start_accel(1)
      else
        stop_accel()
      end
    end
  end
end

-- params and init
function init()
  audio.level_monitor(0)

  params:add{type="option", id="step_mode", name="STEP MODE", options={"off","on"}, default=2,
    action=function(v)
      local new_state = (v==2)
      if step_mode ~= new_state then
        step_mode = new_state
        if not step_mode then
          stop_accel()
        end
        if step_mode then
          set_cutoff_from_idx(step_idx, false)
        else
          params:set("sweep_hz", STEPS[step_idx])
        end
      end
      redraw()
    end
  }

  params:add{
    type="control", id="sweep_hz", name="Sweep (Hz)",
    controlspec=controlspec.new(70,7500,'exp',0,STEPS[1],'Hz'),
    action=function(x)
      if not step_mode then
        set_cutoff_continuous(x, true)
      else
        -- keep UI aligned even if set from param menu
        step_idx = nearest_step_idx(x)
      end
      redraw()
    end
  }

  params:add{
    type="control", id="drive_db", name="Input Drive (dB)",
    controlspec=controlspec.new(-6,24,'lin',0,0,'dB'),
    action=function(x) drive_db=x; engine.drive(x); redraw() end
  }

  params:add{
    type="control", id="outlevel", name="Output Level",
    controlspec=controlspec.new(0,2,'lin',0,1.0,'x'),
    action=function(x) outlevel=x; engine.outlevel(x); redraw() end
  }

  -- set initial cutoff
  set_cutoff_from_idx(step_idx,false)
  engine.mode(mode)
  engine.bypass(0)
  engine.drive(drive_db)
  engine.outlevel(outlevel)

  params:bang() -- push defaults to engine and UI
  redraw()      -- paint immediately before UI loop kicks in

end

-- drawing helpers ------------------------------------------------------------
local function draw_big_knob(cx, cy, R)
  -- ring
  screen.level(bypass and 4 or 15)
  screen.circle(cx, cy, R); screen.stroke()
  local inner = R-8
  screen.level(1); screen.circle(cx, cy, inner); screen.stroke()
  -- notches + labels
  for i,f in ipairs(STEPS) do
    local t = (i-1)/(#STEPS-1)           -- 0..1 around arc
    local ang = util.linlin(0,1, -5*math.pi/6, 11*math.pi/6, t) -- ~260° sweep
    local x1 = cx + (R+2) * math.cos(ang)
    local y1 = cy + (R+2) * math.sin(ang)
    local x2 = cx + (R-2) * math.cos(ang)
    local y2 = cy + (R-2) * math.sin(ang)
    screen.level(i==step_idx and 15 or 5)
    screen.move(x1,y1); screen.line(x2,y2); screen.stroke()
    -- tiny freq label
    local lbl = (f>=1000) and (tostring(f/1000).."k") or tostring(f)
    screen.level(i==step_idx and 15 or 5)
    screen.move(cx + (R+10)*math.cos(ang), cy + (R+10)*math.sin(ang))
    screen.text_center(lbl)
  end
  -- pointer based on current step/sweep
  local t
  if step_mode then
    t = (step_idx-1)/(#STEPS-1)
  else
    t = util.explin(70, 7500, 0, 1, last_sweep_hz)
  end
  local ang = util.linlin(0,1, -5*math.pi/6, 11*math.pi/6, t)
  local px = cx + (inner-2)*math.cos(ang)
  local py = cy + (inner-2)*math.sin(ang)
  screen.level(bypass and 4 or 15)
  screen.move(cx,cy); screen.line(px,py); screen.stroke()
end

local function draw_small_input_knob(x,y,r)
  -- simple arc suggests a knob; position maps to drive range
  screen.level(5); screen.circle(x,y,r); screen.stroke()
  local norm = util.linlin(-6,24,0,1, drive_db)
  local ang = util.linlin(0,1, -3.14*3/4, 3.14*3/4, norm)
  local px = x + (r-2)*math.cos(ang)
  local py = y + (r-2)*math.sin(ang)
  screen.level(15); screen.move(x,y); screen.line(px,py); screen.stroke()
  screen.move(x-12,y+r+8); screen.level(10); screen.text("INPUT")
end

function redraw()
  screen.clear()
  -- big knob
  draw_big_knob(64, 34, 24)
  -- bump mode indicator (top-right)
  local names = {"FLAT","BUMP","TUB"}
  for i=1,3 do
    screen.level((i-1)==mode and 15 or 5)
    screen.move(96, 10 + i*10)
    screen.text(names[i])
  end
  -- input knob bottom-left
  draw_small_input_knob(22, 53, 8)
  -- output value bottom-right
  screen.level(10); screen.move(96, 58); screen.text("OUT "..string.format("%.2f", outlevel).."x")
  -- bypass state overlay
  if bypass then
    screen.level(10); screen.move(8,10); screen.text("BYPASS")
  else
    screen.level(10); screen.move(8,10); screen.text(step_mode and "STEP" or "SWEEP")
  end
  -- selected freq readout
  screen.level(bypass and 10 or 15)
  screen.move(8, 22)
  local freq = step_mode and STEPS[step_idx] or last_sweep_hz
  screen.text(string.format("%0.1f Hz", freq))
  screen.update()
end

function cleanup()
  stop_accel()
end
