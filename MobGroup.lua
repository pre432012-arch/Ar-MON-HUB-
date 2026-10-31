-- ===== MobGroup: ระบบรวมมอนสเตอร์กลาง ใช้ร่วมกับทุกระบบฟาร์ม =====
-- วางแทนฟังก์ชัน BringMob เดิม (ต่อจาก isnetworkowner2 / sizepart / DetectPartMobBring)
local MG = {}
getgenv().MobGroup = MG

MG.Config = {
	Enabled = true,
	Count = 3,      -- จำนวนมอนที่รวม (บังคับ 3..3)
	MinCount = 3,
	MaxCount = 3,
	Radius = 4.5,   -- รัศมีวางมอนแต่ละช่อง
	Range = 300,    -- ระยะหามอนมาเติมช่องจากจุดสปอน
	StuckTime = 3,  -- วินาทีที่ HP ไม่ลด = ข้ามมอนตัวนั้น
	Debounce = 0.1, -- หน่วงรอบการดึง
	HitboxX = 30,   -- ขยายฮิตบ็อกซ์ตอนคำนวณเป้าตี (ใช้กับ AttackAOE)
}

local state = { key = nil, names = {}, slots = {}, watch = {}, orig = {}, anchor = nil, last = 0 }
MG.State = state

local manualNames = nil   -- โหมดเลือกมอนเอง (Select Mob)
local questResolver = nil -- ฟังก์ชันคืนชื่อมอนจากเควส

-- ---------- ตั้งค่า ----------
function MG.SetCount(n)
	local c = MG.Config
	c.Count = math.clamp(math.floor(tonumber(n) or c.MinCount), c.MinCount, c.MaxCount)
	return c.Count
end

-- รับ {"Bandit","Monkey"} หรือ {Bandit=true, Monkey=false} ; nil/ว่าง = ปิดโหมดเลือกเอง
function MG.SetNames(list)
	if type(list) ~= "table" then
		manualNames = nil
		return
	end
	local set, any = {}, false
	for k, v in pairs(list) do
		if type(k) == "number" then
			set[tostring(v)] = true
			any = true
		elseif v then
			set[tostring(k)] = true
			any = true
		end
	end
	manualNames = any and set or nil
end

-- fn() -> ชื่อมอนของเควสปัจจุบัน (เช่น GetLevelQuestMob หรือ GetNameDoubleQuest)
function MG.SetQuestResolver(fn)
	questResolver = type(fn) == "function" and fn or nil
end

-- ---------- ภายใน ----------
local function resolveNames(target)
	if manualNames then
		return manualNames
	end
	if questResolver then
		local ok, n = pcall(questResolver)
		if ok and type(n) == "string" and n ~= "" then
			-- ให้ตัวเป้าหมายอยู่ในกลุ่มเสมอ แม้ชื่อเควสกับชื่อโมเดลต่างกันเล็กน้อย
			return { [n] = true, [target.Name] = true }
		end
	end
	return { [target.Name] = true }
end

local function keyOf(set)
	local t = {}
	for n in pairs(set) do
		t[#t + 1] = n
	end
	table.sort(t)
	return table.concat(t, "|")
end

local function release(m)
	local o = state.orig[m]
	if o then
		pcall(function()
			if m.Parent and m:FindFirstChild("HumanoidRootPart") then
				m.HumanoidRootPart.Size = o
			end
		end)
		state.orig[m] = nil
	end
end

local function valid(m)
	return m ~= nil
		and m.Parent ~= nil
		and state.names[m.Name] == true
		and IsMobAlive(m)
		and not m:FindFirstChild("Ignored")
end

function MG.Reset()
	for m in pairs(state.orig) do
		release(m)
	end
	state.key, state.names, state.slots, state.watch, state.orig, state.anchor = nil, {}, {}, {}, {}, nil
	getgenv().__BringSlots = nil
end

-- ใช้ร่วมกับ AttackAOE: ให้ช่องของกลุ่มอยู่ใน getgenv().__BringSlots.slots
local function publish()
	getgenv().__BringSlots = { name = state.key, slots = state.slots, watch = state.watch, orig = state.orig }
end

-- ---------- หลัก: เรียกจากทุกระบบฟาร์ม ----------
-- คืน true เมื่อรวมครบ Count ตัวแล้ว
function MG.Update(target)
	local cfg = MG.Config
	if not cfg.Enabled or Settings["Bring Mob"] == false then
		return false
	end
	if not IsMobAlive(target) or target:FindFirstChild("Ignored") then
		return false
	end
	local count = MG.SetCount(cfg.Count)

	-- เปลี่ยนกลุ่ม (เปลี่ยนเควส/เปลี่ยนมอน) -> รีเซ็ตและหาจุดรวมใหม่
	local names = resolveNames(target)
	local key = keyOf(names)
	if state.key ~= key then
		MG.Reset()
		state.key, state.names = key, names
		local ok, a = pcall(function()
			local sp = DetectPartMobBring(target.Name, target, true)
			return sp and sp.CFrame
		end)
		state.anchor = (ok and a) or target.HumanoidRootPart.CFrame
		pcall(function()
			local race = t.Data.Race.Value
			if race == "Cyborg" and t.Character:FindFirstChild("RaceTransformed") and t.Character.RaceTransformed.Value then
				state.anchor = getcenter(target.Name)
			end
		end)
		pcall(DeleteIgnoredMob)
	end

	local now = os.clock()
	if now - state.last < cfg.Debounce then
		return false
	end
	local myHRP = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
	if not (state.anchor and myHRP) then
		return false
	end
	if (myHRP.Position - target.HumanoidRootPart.Position).Magnitude > 50 then
		return false
	end
	if not isnetworkowner2(myHRP) then
		return false
	end
	state.last = now

	-- ล้างช่องที่ตาย/ถูกข้าม/ซ้ำ
	local inGroup = {}
	for i = 1, count do
		local m = state.slots[i]
		if valid(m) and not inGroup[m] then
			inGroup[m] = i
		else
			state.slots[i] = nil
		end
	end
	for i = count + 1, #state.slots do
		state.slots[i] = nil
	end

	-- เป้าหมายหลักต้องอยู่ในกลุ่ม
	if not inGroup[target] then
		local free
		for i = 1, count do
			if not state.slots[i] then
				free = i
				break
			end
		end
		if not free then
			free = count
			local ev = state.slots[free]
			if ev then
				inGroup[ev] = nil
				release(ev)
				pcall(function()
					ev.HumanoidRootPart.CFrame = ev.WorldPivot
				end)
			end
		end
		state.slots[free] = target
		inGroup[target] = free
	end

	-- เติมช่องว่าง (มอนตาย) ด้วยมอนในเซ็ตชื่อเดียวกันที่ใกล้จุดรวมที่สุด
	local empty = {}
	for i = 1, count do
		if not state.slots[i] then
			empty[#empty + 1] = i
		end
	end
	if #empty > 0 then
		local cand = {}
		for _, m in ipairs(workspace.Enemies:GetChildren()) do
			if not inGroup[m] and state.names[m.Name] and not m:FindFirstChild("Ignored") and IsMobAlive(m)
				and isnetworkowner2(m.HumanoidRootPart) then
				local d = (m.HumanoidRootPart.Position - state.anchor.Position).Magnitude
				if d <= cfg.Range then
					cand[#cand + 1] = { m = m, d = d }
				end
			end
		end
		table.sort(cand, function(a, b)
			return a.d < b.d
		end)
		for k, i in ipairs(empty) do
			if cand[k] then
				state.slots[i] = cand[k].m
				inGroup[cand[k].m] = i
			end
		end
	end

	publish()

	-- ต้องครบพอดีเท่านั้น
	for i = 1, count do
		if not state.slots[i] then
			return false
		end
	end

	-- วางมอนแต่ละตัวในช่องของตัวเอง (วงกลมเว้นเท่ากัน)
	for i = 1, count do
		local mob = state.slots[i]
		pcall(function()
			if not IsMobAlive(mob) then
				return
			end
			sizepart(mob)
			local hrp = mob.HumanoidRootPart
			hrp.CanCollide = false
			local ang = (2 * math.pi / count) * (i - 1)
			local slot = state.anchor * CFrame.new(math.cos(ang) * cfg.Radius, 0, math.sin(ang) * cfg.Radius)
			if (hrp.Position - slot.Position).Magnitude > 1.5 then
				hrp.CFrame = slot
			end
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			pcall(function()
				mob.Humanoid.WalkSpeed = 0
			end)

			local hp = mob.Humanoid.Health
			local w = state.watch[mob]
			if not w or w.hp ~= hp then
				state.watch[mob] = { hp = hp, t = now }
			elseif now - w.t > cfg.StuckTime then
				release(mob)
				hrp.CFrame = mob.WorldPivot
				Instance.new("IntValue", mob).Name = "Ignored"
				state.watch[mob] = nil
			end
		end)
	end
	return true
end

-- ===== ผูกกับระบบเดิม =====
-- ทุกระบบที่เรียก BringMob(mob) จะใช้ MobGroup อัตโนมัติ
function BringMob(mob)
	return MG.Update(mob)
end

-- ระบบฟาร์ม Level: ใช้ชื่อมอนจากเควสให้อัตโนมัติ (ได้จากเควสปัจจุบันเสมอ)
MG.SetQuestResolver(function()
	return (GetLevelQuestMob and GetLevelQuestMob()) or GetNameDoubleQuest()
end)

-- ===== UI (วางหลัง SettingFarmMainSection) =====
-- Select Mob ของหน้า Farming Other ใช้เลือกมอนเองได้ ; ถ้าไม่เลือก = ใช้มอนจากเควส
--[[
SettingFarmMainSection.CreateToggle({ Title = "Bring Mob", Default = Settings["Bring Mob"] ~= false }, function(v)
	SaveSettings("Bring Mob", v)
	MobGroup.Config.Enabled = v
end)
SettingFarmMainSection.CreateSlider({ Title = "Bring Mob Count", Min = 3, Max = 3, Default = 3 }, function(v)
	SaveSettings("Bring Mob Count", MobGroup.SetCount(v))
end)
SettingFarmMainSection.CreateSlider({ Title = "Bring Mob Radius", Min = 2, Max = 10, Default = 4.5, Precise = true }, function(v)
	MobGroup.Config.Radius = v
end)
-- ใน callback ของ Select Mob (AutoKillMobSection): MobGroup.SetNames(Settings["Select Mob"])
]]

return MG
