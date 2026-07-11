---@diagnostic disable: undefined-global, lowercase-global
--[[
  Данные: VigArticles.json, VigGwarnBinder.json (настройки), VigGwarnBinderDefault.json (шаблон отыгровки) в moonloader/VigMenu/
  (создаётся при первом запуске). Обновление .lua с GitHub не затирает эту папку.
  VigArticles.json только с GitHub (старые копии из moonloader не подхватываются).
  /vigmenu [id] or /gw [id] opens menu; gear: RP chains then /gwarn or /demoute. Optional hotkey opens chat with /vigmenu .
  Diagnose: MoonLoader console shows [gwarnn] main() OK. If STOP, install sampfuncs. If no lines, script crashed on require.
  Uses sampRegisterChatCommand + samp.events onSendCommand only (onSendChat removed � Arizona conflict).
]]

script_name("Меню выговоров (Vig)")
script_description("VigMenu: /vigmenu [id] → /gwarn или /demoute")
script_author("AlexBuhoi")
script_version("6.1.2")

require("lib.moonloader")
require("encoding").default = "CP1251"
local u8 = require("encoding").UTF8

--- ImGui + mimgui expect UTF-8. VigArticles.json is UTF-8 � do NOT wrap in u8() (that path is for CP1251).
local function im_utf8(s)
	if s == nil then
		return ""
	end
	return tostring(s)
end

--- UTF-8 (ImGui, JSON, строка отыгровки) → кодировка чата (CP1251 при encoding.default).
local function chat_from_utf8(s)
	s = tostring(s or "")
	if s == "" then
		return s
	end
	local ok, r = pcall(function()
		return u8:decode(s)
	end)
	if ok and type(r) == "string" then
		return r
	end
	return s
end

local function sampSendChatUtf8(text)
	sampSendChat(chat_from_utf8(text))
end

local function sampAddChatMessageUtf8(text, color)
	sampAddChatMessage(chat_from_utf8(text), color)
end

-- Case-insensitive search for UTF-8 JSON (VigArticles) + ASCII; no CP1251 literals in file
local function utf8_rupper(s)
	if not s or s == "" then
		return ""
	end
	local t = {}
	local i = 1
	while i <= #s do
		local b1 = s:byte(i)
		if not b1 then
			break
		end
		if b1 < 128 then
			local c = string.char(b1)
			t[#t + 1] = string.upper(c)
			i = i + 1
		elseif b1 == 0xD0 and i + 1 <= #s then
			local b2 = s:byte(i + 1)
			if b2 >= 0xB0 and b2 <= 0xBF then
				t[#t + 1] = string.char(0xD0, b2 - 0x20)
			elseif b2 == 0x81 then
				t[#t + 1] = string.char(0xD0, 0x81)
			else
				t[#t + 1] = s:sub(i, i + 1)
			end
			i = i + 2
		elseif b1 == 0xD1 and i + 1 <= #s then
			local b2 = s:byte(i + 1)
			if b2 >= 0x80 and b2 <= 0x8F then
				t[#t + 1] = string.char(0xD0, b2 + 0x20)
			elseif b2 == 0x91 then
				t[#t + 1] = string.char(0xD0, 0x81)
			else
				t[#t + 1] = s:sub(i, i + 1)
			end
			i = i + 2
		else
			t[#t + 1] = s:sub(i, i)
			i = i + 1
		end
	end
	return table.concat(t)
end

--- SmartUK JSON uses "item"; some files use "items"
local function chapter_items(ch)
	if not ch or type(ch) ~= "table" then
		return nil
	end
	return ch.item or ch.items or ch.Item or ch.Items
end

local function article_matches_query(item, query)
	if not item or type(item) ~= "table" then
		return false
	end
	if query == "" then
		return true
	end
	local q = utf8_rupper(query)
	local ok, hit = pcall(function()
		for _, key in ipairs({ "text", "reason", "lvl", "article" }) do
			local f = item[key]
			if f and utf8_rupper(tostring(f)):find(q, 1, true) then
				return true
			end
		end
		return false
	end)
	return ok and hit
end

local function chapter_matches_query(chapter, query)
	if query == "" then
		return true
	end
	local name = chapter and chapter.name
	if not name then
		return false
	end
	local ok, hit = pcall(function()
		local n = utf8_rupper(tostring(name)):find(utf8_rupper(query), 1, true)
		return n ~= nil
	end)
	return ok and hit
end

local function article_row_visible(item, chapter, query)
	if query == "" then
		return true
	end
	if article_matches_query(item, query) then
		return true
	end
	return chapter_matches_query(chapter, query)
end

--- Fix alternate JSON keys once after load
local function normalize_articles_root(data)
	if type(data) ~= "table" then
		return
	end
	for _, ch in ipairs(data) do
		if type(ch) == "table" and not chapter_items(ch) then
			if ch.articles then
				ch.item = ch.articles
			elseif ch.Items then
				ch.item = ch.Items
			end
		end
	end
end

local ffi = require("ffi")
local imgui = require("mimgui")

local dkok, dkjson = pcall(require, "dkjson")
local sizeX, sizeY = getScreenResolution()

local worked_dir = getWorkingDirectory():gsub("\\", "/")
--- Синхронно с script_version() ниже (только приветствие / лог)
local SCRIPT_VERSION_TEXT = "6.1.2"
--- Манифест: VigUpdate.json в репозитории на GitHub (ветка main/master).
local UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/Alex140219899/VIGMENU/main/VigUpdate.json"
--- Тот же репозиторий через jsDelivr: у части игроков WinInet с игры не получает raw.githubusercontent.com (таймаут без колбэка).
local UPDATE_MANIFEST_URL_JS = "https://cdn.jsdelivr.net/gh/Alex140219899/VIGMENU@main/VigUpdate.json"
local VIGARTICLES_URL_JS = "https://cdn.jsdelivr.net/gh/Alex140219899/VIGMENU@main/VigArticles.json"
local UPDATE_SCRIPT_URL_JS = "https://cdn.jsdelivr.net/gh/Alex140219899/VIGMENU@main/VigMenu.lua"
local BINDER_DEFAULT_JSON_URL_JS = "https://cdn.jsdelivr.net/gh/Alex140219899/VIGMENU@main/VigGwarnBinderDefault.json"
local BINDER_DEFAULT_JSON_URL = "https://raw.githubusercontent.com/Alex140219899/VIGMENU/main/VigGwarnBinderDefault.json"

--- Постоянная папка данных внутри moonloader (не перезаписывается при обновлении .lua).
local VIG_DATA_DIR_NAME = "VigMenu"

local function get_spec_data_dir()
	return (worked_dir .. "/" .. VIG_DATA_DIR_NAME):gsub("\\", "/")
end

--- Один раз за сессию: без повторного os.execute (на Windows мигало консолью/cmd).
local vig_spec_data_dir_ready = false

local function ensure_spec_data_dir()
	if vig_spec_data_dir_ready then
		return
	end
	vig_spec_data_dir_ready = true
	local d = get_spec_data_dir()
	if type(createDirectory) == "function" then
		pcall(createDirectory, d)
	else
		pcall(function()
			local ml = package.loaded["moonloader"] or require("moonloader")
			if ml and type(ml.createDirectory) == "function" then
				ml.createDirectory(d)
			end
		end)
	end
end

local function spec_copy_file(src, dst)
	local r = io.open(src, "rb")
	if not r then
		return false
	end
	local body = r:read("*a")
	r:close()
	local w = io.open(dst, "wb")
	if not w then
		return false
	end
	w:write(body or "")
	w:close()
	return true
end

--- Один раз при загрузке: перенос только VigGwarnBinder.json из старых путей (статьи — только с GitHub).
local function migrate_legacy_spec_files()
	ensure_spec_data_dir()
	local data_dir = get_spec_data_dir()
	local data_binder = data_dir .. "/VigGwarnBinder.json"
	local old_data = worked_dir .. "/SpecRosysk"
	if not doesFileExist(data_binder) then
		local candidates = {}
		pcall(function()
			local path = thisScript().path
			if path and path ~= "" then
				local dir = path:gsub("\\", "/"):match("^(.*)/[^/]+$") or worked_dir
				candidates[#candidates + 1] = dir .. "/VigGwarnBinder.json"
				candidates[#candidates + 1] = dir .. "/SpecGwarnBinder.json"
			end
		end)
		candidates[#candidates + 1] = worked_dir .. "/VigGwarnBinder.json"
		candidates[#candidates + 1] = worked_dir .. "/SpecGwarnBinder.json"
		candidates[#candidates + 1] = old_data .. "/SpecGwarnBinder.json"
		for _, p in ipairs(candidates) do
			if doesFileExist(p) then
				if spec_copy_file(p, data_binder) then
					print("[gwarnn] перенесён VigGwarnBinder.json → " .. data_binder)
				end
				break
			end
		end
	end
end

migrate_legacy_spec_files()

--- VigArticles.json: всегда moonloader/VigMenu/ (после migrate).
local function get_spec_json_path()
	ensure_spec_data_dir()
	return (get_spec_data_dir() .. "/VigArticles.json"):gsub("\\", "/")
end

local SPEC_JSON_PATH = get_spec_json_path()

local sampev_ok, sampev = pcall(require, "samp.events")
local gwarn_inner_onSendCommand = nil

local custom_dpi = 1.0
local GWARN_MENU_CMD = "vigmenu"
local GWARN_MENU_CMD_ALT = "gw"
local GWARN_RELOAD_CMD = "vigmenu_reload"
local GWARN_SERVER_CMD = "gwarn"
local DEMOTE_SERVER_CMD = "demoute"
local DISCIPLINE_ACTION_GWARN = "gwarn"
local DISCIPLINE_ACTION_FIRE = "fire"
local message_color = 0x009eff

local commands_registered_log = false
local spec_theme_lazy_done = false

--- Colors only (SwitchContext must run inside an ImGui frame � see OnFrame)
local function apply_spec_dark_theme_core()
	local a = 0.98
	local s = imgui.GetStyle()
	s.WindowPadding = imgui.ImVec2(8 * custom_dpi, 8 * custom_dpi)
	s.FramePadding = imgui.ImVec2(6 * custom_dpi, 5 * custom_dpi)
	s.ItemSpacing = imgui.ImVec2(6 * custom_dpi, 6 * custom_dpi)
	s.ItemInnerSpacing = imgui.ImVec2(4 * custom_dpi, 4 * custom_dpi)
	s.ScrollbarSize = 8 * custom_dpi
	s.WindowRounding = 8 * custom_dpi
	s.ChildRounding = 6 * custom_dpi
	s.FrameRounding = 6 * custom_dpi
	s.PopupRounding = 8 * custom_dpi
	s.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
	s.ButtonTextAlign = imgui.ImVec2(0.5, 0.5)
	s.Colors[imgui.Col.Text] = imgui.ImVec4(0.93, 0.94, 0.96, 1.0)
	s.Colors[imgui.Col.TextDisabled] = imgui.ImVec4(0.45, 0.46, 0.5, 1.0)
	s.Colors[imgui.Col.WindowBg] = imgui.ImVec4(0.06, 0.07, 0.09, a)
	s.Colors[imgui.Col.ChildBg] = imgui.ImVec4(0.05, 0.06, 0.08, a)
	s.Colors[imgui.Col.PopupBg] = imgui.ImVec4(0.07, 0.08, 0.1, a)
	s.Colors[imgui.Col.Border] = imgui.ImVec4(0.18, 0.2, 0.24, 0.9)
	s.Colors[imgui.Col.FrameBg] = imgui.ImVec4(0.12, 0.13, 0.16, a)
	s.Colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.16, 0.17, 0.21, a)
	s.Colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.2, 0.22, 0.27, a)
	s.Colors[imgui.Col.TitleBg] = imgui.ImVec4(0.08, 0.09, 0.11, a)
	s.Colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.1, 0.11, 0.14, a)
	s.Colors[imgui.Col.Button] = imgui.ImVec4(0.14, 0.15, 0.18, a)
	s.Colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.22, 0.24, 0.3, a)
	s.Colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.28, 0.32, 0.4, a)
	s.Colors[imgui.Col.Header] = imgui.ImVec4(0.12, 0.13, 0.17, a)
	s.Colors[imgui.Col.HeaderHovered] = imgui.ImVec4(0.18, 0.2, 0.26, a)
	s.Colors[imgui.Col.HeaderActive] = imgui.ImVec4(0.22, 0.24, 0.32, a)
	s.Colors[imgui.Col.Separator] = imgui.ImVec4(0.2, 0.22, 0.27, 0.85)
	s.Colors[imgui.Col.ScrollbarGrab] = imgui.ImVec4(0.28, 0.3, 0.36, 0.85)
	s.Colors[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(0.38, 0.4, 0.48, 0.9)
	s.Colors[imgui.Col.CheckMark] = imgui.ImVec4(0.45, 0.75, 1.0, 1.0)
	s.Colors[imgui.Col.TextSelectedBg] = imgui.ImVec4(0.25, 0.45, 0.85, 0.45)
	s.Colors[imgui.Col.ModalWindowDimBg] = imgui.ImVec4(0.0, 0.0, 0.0, 0.65)
end

local function apply_spec_dark_theme()
	pcall(function()
		imgui.SwitchContext()
	end)
	apply_spec_dark_theme_core()
end

local articles_data = {}
local spec_target_id = 0
local spec_menu_warned_invalid = false
local spec_imgui_ready = false
local SpecMenu = {
	Window = imgui.new.bool(),
	input = imgui.new.char[256](),
}

local GWARN_BINDER_MODAL_TITLE = "Настройки VigMenu##gwarn_binder_modal"

local SpecBinderUi = {
	buf_script_gwarn = imgui.new.char[8192](),
	buf_script_fire = imgui.new.char[8192](),
	buf_bind = imgui.new.char[512](),
	buf_delay_gwarn = imgui.new.char[16](),
	buf_delay_fire = imgui.new.char[16](),
	buf_fire_ban_days = imgui.new.char[8](),
	buf_cmd_gwarn = imgui.new.char[64](),
	buf_cmd_fire = imgui.new.char[64](),
	buf_ogk_search = imgui.new.char[256](),
	buf_log_search = imgui.new.char[256](),
	buf_ogk_log_title = imgui.new.char[128](),
	buf_ogk_add_nick = imgui.new.char[128](),
	buf_ogk_add_tag = imgui.new.char[64](),
	ogk_enabled = imgui.new.bool(false),
	ogk_show_log = imgui.new.bool(true),
	ogk_notify = imgui.new.bool(false),
	ogk_max_dist = imgui.new.int(15),
	ogk_log_corner = imgui.new.int(1),
	modal_open = imgui.new.bool(false),
}

local function utf8_to_charbuf(str, buf, max_bytes)
	str = tostring(str or "")
	ffi.fill(buf, max_bytes, 0)
	local n = math.min(#str, max_bytes - 1)
	if n > 0 then
		ffi.copy(buf, str, n)
	end
end

--- ImGui пишет NUL в конец строки, но не затирает байты после него.
local function charbuf_to_utf8(buf, max_bytes)
	local raw = ffi.string(buf, max_bytes)
	local z = raw:find("\0", 1, true)
	if z then
		raw = raw:sub(1, z - 1)
	end
	return (raw:gsub("%z", "")):match("^%s*(.-)%s*$") or ""
end

local GWARN_BINDER_HOTKEY_NAME = "VigMenuGwarnBinderOpen"
VigBinderStopHotKey = nil
vig_binder_rp_active = false
vig_binder_rp_stop = false

local gwarn_binder = {
	rp_script_gwarn = "",
	delay_ms_gwarn = 900,
	server_cmd_gwarn = "gwarn",
	rp_script_fire = "",
	delay_ms_fire = 900,
	fire_ban_days = 0,
	server_cmd_fire = "demoute",
	bind_chat_open = "[]",
	bind_stop_rp = "[]",
	ogk_enabled = false,
	ogk_log_title = "Отображение",
	ogk_show_log = true,
	ogk_notify = false,
	ogk_max_dist = 15,
	ogk_log_corner = 1,
	ogk_log_pos_x = nil,
	ogk_log_pos_y = nil,
	ogk_tagged_nicks = {},
}

local SPEC_BINDER_JSON_PATH = ""

--- Список сотрудников ОГК (только просмотр в настройках).
local OGK_STAFF = {
	{ role = "Ген.Аудитор", name = "Kane Drake" },
	{ role = "Заместитель Ген.Аудитора", name = "Mae West" },
	{ role = "Заместитель Ген.Аудитора", name = "Robert Padalecki" },
	{ role = "Заместитель Ген.Аудитора", name = "Alan Crawford" },
	{ role = "Федеральный Аудитор", name = "Ludwig Hohenberg" },
	{ role = "Федеральный Аудитор", name = "Artiom Bounteiro" },
	{ role = "Федеральный Аудитор", name = "Dominic Fox" },
	{ role = "Федеральный Аудитор", name = "Danilka Gill" },
	{ role = "Федеральный Аудитор", name = "Вакантно" },
	{ role = "Федеральный Аудитор", name = "Kelly Line" },
	{ role = "Федеральный Аудитор", name = "Kama Pullya" },
	{ role = "Федеральный Аудитор", name = "Dmitriy Muller" },
	{ role = "Федеральный Аудитор", name = "Jennifer Fox" },
	{ role = "Федеральный Аудитор", name = "Huston Sweet" },
	{ role = "Федеральный Аудитор", name = "Sophie Rein" },
	{ role = "Окружной Аудитор", name = "Вакантно" },
	{ role = "Окружной Аудитор", name = "Вакантно" },
	{ role = "Окружной Аудитор", name = "Вакантно" },
	{ role = "Окружной Аудитор", name = "Chappa Crack" },
	{ role = "Окружной Аудитор", name = "Chill Henderson" },
	{ role = "Окружной Аудитор", name = "Maras Crown" },
	{ role = "Окружной Аудитор", name = "Torino Mavrodi" },
	{ role = "Помощник Аудитора", name = "Egor Mokrivsky" },
	{ role = "Помощник Аудитора", name = "Roni Krey" },
	{ role = "Помощник Аудитора", name = "Luis Love" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Soda Lykas" },
	{ role = "Помощник Аудитора", name = "Patrick Kingston" },
	{ role = "Помощник Аудитора", name = "Dante Fraze" },
	{ role = "Помощник Аудитора", name = "Mike Vendetta" },
	{ role = "Помощник Аудитора", name = "Mark Devin" },
	{ role = "Помощник Аудитора", name = "Alek Lester" },
	{ role = "Помощник Аудитора", name = "Yoshi Swager" },
	{ role = "Помощник Аудитора", name = "Kirill Mamont" },
	{ role = "Помощник Аудитора", name = "Risotto Secco" },
	{ role = "Помощник Аудитора", name = "Timothy Zanic" },
	{ role = "Помощник Аудитора", name = "August Cashin" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
	{ role = "Помощник Аудитора", name = "Вакантно" },
}

local ogk_nearby = {}
local ogk_notified = {}
local ogk_staff_lookup = nil
local ogk_scan_tick = 0
local ogk_log_move_mode = false
local ogk_reopen_binder_modal = false
local ogk_tag_edit_idx = nil
local save_gwarn_binder_settings

local OGK_LOG_CORNER_FREE = 4
OGK_LOG_PANEL_W = 232

local function vig_ogk_ensure_defaults()
	if gwarn_binder.ogk_enabled == nil then
		gwarn_binder.ogk_enabled = false
	end
	gwarn_binder.ogk_log_title = "Отображение"
	if type(gwarn_binder.ogk_tagged_nicks) ~= "table" then
		gwarn_binder.ogk_tagged_nicks = {}
	end
	if gwarn_binder.ogk_show_log == nil then
		gwarn_binder.ogk_show_log = true
	end
	if gwarn_binder.ogk_notify == nil then
		gwarn_binder.ogk_notify = false
	end
	gwarn_binder.ogk_max_dist = math.max(0, math.min(15, tonumber(gwarn_binder.ogk_max_dist) or 15))
	gwarn_binder.ogk_log_corner = math.max(0, math.min(OGK_LOG_CORNER_FREE, tonumber(gwarn_binder.ogk_log_corner) or 1))
	if not gwarn_binder.ogk_log_pos_x or not gwarn_binder.ogk_log_pos_y then
		gwarn_binder.ogk_log_pos_x = sizeX * 0.78
		gwarn_binder.ogk_log_pos_y = sizeY * 0.25
	end
end

local function vig_ogk_normalize_compare_name(name)
	name = tostring(name or "")
	local tagged = name:match("^%[.-%]%s*(.+)$")
	if tagged then
		name = tagged
	end
	name = name:gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
	return utf8_rupper(name)
end

local function vig_ogk_get_staff_lookup()
	if ogk_staff_lookup then
		return ogk_staff_lookup
	end
	ogk_staff_lookup = {}
	for _, entry in ipairs(OGK_STAFF) do
		if entry.name ~= "Вакантно" then
			ogk_staff_lookup[vig_ogk_normalize_compare_name(entry.name)] = entry.role
		end
	end
	return ogk_staff_lookup
end

local function vig_ogk_get_tagged_norm_set()
	local set = {}
	for _, entry in ipairs(gwarn_binder.ogk_tagged_nicks or {}) do
		local norm = vig_ogk_normalize_compare_name(entry.nick)
		if norm ~= "" then
			set[norm] = true
		end
	end
	return set
end

local function vig_ogk_corner_pos(corner)
	local pad = 12 * custom_dpi
	local w = OGK_LOG_PANEL_W * custom_dpi
	corner = tonumber(corner) or 1
	if corner == 0 then
		return pad, pad
	end
	if corner == 1 then
		return sizeX - w - pad, pad
	end
	if corner == 2 then
		return pad, sizeY - 200 * custom_dpi - pad
	end
	if corner == 3 then
		return sizeX - w - pad, sizeY - 200 * custom_dpi - pad
	end
	return tonumber(gwarn_binder.ogk_log_pos_x) or (sizeX * 0.78), tonumber(gwarn_binder.ogk_log_pos_y) or (sizeY * 0.25)
end

local function vig_ogk_format_dist_m(dist)
	dist = tonumber(dist) or 0
	if dist < 1 then
		return string.format("%.1f м", dist)
	end
	return tostring(math.floor(dist + 0.5)) .. " м"
end

local function vig_ogk_trim(s)
	return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function vig_ogk_get_tag_for_nick(nick)
	local norm = vig_ogk_normalize_compare_name(nick)
	if norm == "" then
		return ""
	end
	for _, entry in ipairs(gwarn_binder.ogk_tagged_nicks or {}) do
		if vig_ogk_normalize_compare_name(entry.nick) == norm then
			return vig_ogk_trim(entry.tag)
		end
	end
	return ""
end

local function vig_ogk_clear_add_form()
	utf8_to_charbuf("", SpecBinderUi.buf_ogk_add_nick, 128)
	utf8_to_charbuf("", SpecBinderUi.buf_ogk_add_tag, 64)
	ogk_tag_edit_idx = nil
end

local function vig_ogk_add_or_update_tagged_nick(nick, tag, edit_idx)
	nick = vig_ogk_trim(nick)
	tag = vig_ogk_trim(tag)
	if nick == "" then
		return false
	end
	if type(gwarn_binder.ogk_tagged_nicks) ~= "table" then
		gwarn_binder.ogk_tagged_nicks = {}
	end
	local norm = vig_ogk_normalize_compare_name(nick)
	if edit_idx then
		local entry = gwarn_binder.ogk_tagged_nicks[edit_idx]
		if not entry then
			return false
		end
		for i, e in ipairs(gwarn_binder.ogk_tagged_nicks) do
			if i ~= edit_idx and vig_ogk_normalize_compare_name(e.nick) == norm then
				return false
			end
		end
		entry.nick = nick
		entry.tag = tag
	else
		for _, e in ipairs(gwarn_binder.ogk_tagged_nicks) do
			if vig_ogk_normalize_compare_name(e.nick) == norm then
				return false
			end
		end
		gwarn_binder.ogk_tagged_nicks[#gwarn_binder.ogk_tagged_nicks + 1] = {
			nick = nick,
			tag = tag,
		}
	end
	save_gwarn_binder_settings()
	return true
end

local function vig_ogk_remove_tagged_nick(idx)
	if type(gwarn_binder.ogk_tagged_nicks) ~= "table" then
		return
	end
	if idx < 1 or idx > #gwarn_binder.ogk_tagged_nicks then
		return
	end
	table.remove(gwarn_binder.ogk_tagged_nicks, idx)
	if ogk_tag_edit_idx == idx then
		ogk_tag_edit_idx = nil
	elseif ogk_tag_edit_idx and ogk_tag_edit_idx > idx then
		ogk_tag_edit_idx = ogk_tag_edit_idx - 1
	end
	save_gwarn_binder_settings()
end

local function vig_ogk_start_edit_tagged_nick(idx)
	local entry = gwarn_binder.ogk_tagged_nicks and gwarn_binder.ogk_tagged_nicks[idx]
	if not entry then
		return
	end
	ogk_tag_edit_idx = idx
	utf8_to_charbuf(entry.nick or "", SpecBinderUi.buf_ogk_add_nick, 128)
	utf8_to_charbuf(entry.tag or "", SpecBinderUi.buf_ogk_add_tag, 64)
end

local function vig_ogk_try_submit_tagged_nick()
	local nick = charbuf_to_utf8(SpecBinderUi.buf_ogk_add_nick, 128)
	local tag = charbuf_to_utf8(SpecBinderUi.buf_ogk_add_tag, 64)
	if vig_ogk_add_or_update_tagged_nick(nick, tag, ogk_tag_edit_idx) then
		vig_ogk_clear_add_form()
		return true
	end
	return false
end

local function vig_ogk_format_player_line(index, p)
	local nick = tostring(p.nick or "")
	local id = tostring(p.id or "")
	local dist = vig_ogk_format_dist_m(p.dist)
	local tag = vig_ogk_get_tag_for_nick(nick)
	local prefix = tostring(index) .. ". "
	if tag ~= "" then
		return prefix .. tag .. " " .. nick .. " [" .. id .. "] — " .. dist
	end
	return prefix .. nick .. " [" .. id .. "] — " .. dist
end

local function vig_ogk_fix_log_position()
	local px = tonumber(gwarn_binder.ogk_log_pos_x)
	local py = tonumber(gwarn_binder.ogk_log_pos_y)
	if not px or not py then
		return false
	end
	gwarn_binder.ogk_log_corner = OGK_LOG_CORNER_FREE
	SpecBinderUi.ogk_log_corner[0] = OGK_LOG_CORNER_FREE
	ogk_log_move_mode = false
	ogk_reopen_binder_modal = true
	save_gwarn_binder_settings()
	sampAddChatMessageUtf8(
		"{009EFF}[Vigmenu]{ffffff} Положение сохранено.",
		message_color
	)
	return true
end

local function vig_ogk_start_log_move_mode()
	ogk_log_move_mode = true
	gwarn_binder.ogk_log_corner = OGK_LOG_CORNER_FREE
	SpecBinderUi.ogk_log_corner[0] = OGK_LOG_CORNER_FREE
	SpecBinderUi.modal_open[0] = false
	if imgui.CloseCurrentPopup then
		imgui.CloseCurrentPopup()
	end
end

local function vig_ogk_scan_nearby()
	if not gwarn_binder.ogk_enabled then
		return {}
	end
	if not sampIsPlayerConnected or not sampGetPlayerNickname or not sampGetCharHandleBySampPlayerId then
		return {}
	end
	local lookup = vig_ogk_get_staff_lookup()
	local tagged_set = vig_ogk_get_tagged_norm_set()
	local mx, my, mz = getCharCoordinates(PLAYER_PED)
	local max_dist = tonumber(gwarn_binder.ogk_max_dist) or 15
	local found = {}
	for id = 0, 999 do
		if sampIsPlayerConnected(id) then
			local nick = tostring(sampGetPlayerNickname(id) or "")
			local norm = vig_ogk_normalize_compare_name(nick)
			local role = lookup[norm]
			if role or tagged_set[norm] then
				local ok, ped = sampGetCharHandleBySampPlayerId(id)
				if ok and ped and doesCharExist(ped) then
					local x, y, z = getCharCoordinates(ped)
					local dist = getDistanceBetweenCoords3d(mx, my, mz, x, y, z)
					if max_dist <= 0 or dist <= max_dist then
						found[#found + 1] = {
							id = id,
							nick = nick,
							role = role,
							dist = dist,
						}
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return (a.dist or 0) < (b.dist or 0)
	end)
	return found
end

local function vig_ogk_update_scan()
	local prev_ids = {}
	for _, p in ipairs(ogk_nearby) do
		prev_ids[p.id] = true
	end
	ogk_nearby = vig_ogk_scan_nearby()
	local current_ids = {}
	for _, p in ipairs(ogk_nearby) do
		current_ids[p.id] = p
	end
	if gwarn_binder.ogk_notify then
		for id, p in pairs(current_ids) do
			if not ogk_notified[id] and not prev_ids[id] then
				ogk_notified[id] = true
				sampAddChatMessageUtf8(
					"{009EFF}[Vigmenu]{ffffff} В радиусе: "
						.. tostring(p.nick)
						.. " ["
						.. tostring(id)
						.. "] — "
						.. vig_ogk_format_dist_m(p.dist),
					message_color
				)
			end
		end
	end
	for id in pairs(ogk_notified) do
		if not current_ids[id] then
			ogk_notified[id] = nil
		end
	end
end

local function vig_ogk_draw_log_overlay(player)
	local title = "Отображение"
	local corner = tonumber(gwarn_binder.ogk_log_corner) or OGK_LOG_CORNER_FREE
	if ogk_log_move_mode then
		corner = OGK_LOG_CORNER_FREE
	end
	local px, py = vig_ogk_corner_pos(corner)
	local wflags = imgui.WindowFlags.NoCollapse
		+ imgui.WindowFlags.AlwaysAutoResize
		+ imgui.WindowFlags.NoScrollbar
		+ (imgui.WindowFlags.NoTitleBar or 0)
	if ogk_log_move_mode then
		imgui.SetNextWindowPos(imgui.ImVec2(px, py), imgui.Cond.Appearing)
	else
		imgui.SetNextWindowPos(imgui.ImVec2(px, py), imgui.Cond.Always)
		if imgui.WindowFlags.NoMove then
			wflags = wflags + imgui.WindowFlags.NoMove
		end
	end
	local panel_w = OGK_LOG_PANEL_W * custom_dpi
	imgui.SetNextWindowSize(imgui.ImVec2(panel_w, 0), imgui.Cond.Always)
	local st = imgui.GetStyle and imgui.GetStyle()
	local old_border = st and st.WindowBorderSize or 0
	local old_pad
	if st then
		st.WindowBorderSize = 0
		old_pad = st.WindowPadding
		st.WindowPadding = imgui.ImVec2(6 * custom_dpi, 4 * custom_dpi)
	end
	local ogk_style_pushed = 0
	if imgui.PushStyleColor then
		imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.04, 0.05, 0.07, 0.35))
		imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
		ogk_style_pushed = 2
	end
	imgui.Begin(im_utf8("##ogk_nearby_log"), nil, wflags)
	if not ogk_log_move_mode and player and not sampIsChatInputActive() and not sampIsDialogActive() then
		player.HideCursor = true
	end
	if ogk_log_move_mode then
		imgui.TextColored(imgui.ImVec4(1.0, 0.82, 0.35, 0.95), im_utf8("Перетащите окно мышью"))
	end
	imgui.TextColored(imgui.ImVec4(0.55, 0.85, 1.0, 0.92), im_utf8(title))
	if imgui.PushStyleColor then
		imgui.PushStyleColor(imgui.Col.Separator, imgui.ImVec4(0.45, 0.75, 1.0, 0.42))
	end
	imgui.Separator()
	if imgui.PopStyleColor and imgui.PushStyleColor then
		imgui.PopStyleColor()
	end
	if #ogk_nearby == 0 then
		imgui.TextColored(imgui.ImVec4(0.75, 0.75, 0.8, 0.7), im_utf8("—"))
	else
		for i, p in ipairs(ogk_nearby) do
			imgui.TextColored(
				imgui.ImVec4(0.93, 0.94, 0.96, 0.88),
				im_utf8(vig_ogk_format_player_line(i, p))
			)
		end
	end
	local posX, posY = imgui.GetWindowPos().x, imgui.GetWindowPos().y
	local posW, posH = imgui.GetWindowSize().x, imgui.GetWindowSize().y
	if ogk_log_move_mode then
		gwarn_binder.ogk_log_pos_x = posX
		gwarn_binder.ogk_log_pos_y = posY
		imgui.Spacing()
		imgui.Separator()
		if imgui.Button(im_utf8("Зафиксировать##ogk_log_fix"), imgui.ImVec2(-1, 20 * custom_dpi)) then
			gwarn_binder.ogk_log_pos_x = posX
			gwarn_binder.ogk_log_pos_y = posY
			vig_ogk_fix_log_position()
		end
	end
	imgui.End()
	if st then
		st.WindowBorderSize = old_border
		if old_pad then
			st.WindowPadding = old_pad
		end
	end
	if ogk_style_pushed > 0 and imgui.PopStyleColor then
		imgui.PopStyleColor(ogk_style_pushed)
	end
end

local function normalize_charbuf_input(buf, max_bytes)
	local raw = ffi.string(buf, max_bytes)
	local z = raw:find("\0", 1, true)
	if z then
		raw = raw:sub(1, z - 1)
	end
	return (raw:gsub("%z", "")):match("^%s*(.-)%s*$") or ""
end

local function vig_query_matches(text, query)
	query = tostring(query or ""):match("^%s*(.-)%s*$") or ""
	if query == "" then
		return true
	end
	text = tostring(text or "")
	local ok, hit = pcall(function()
		return utf8_rupper(text):find(utf8_rupper(query), 1, true) ~= nil
	end)
	return ok and hit
end

local function vig_imgui_content_w(min_w)
	min_w = min_w or 120
	return math.max(min_w, imgui.GetContentRegionAvail().x)
end

local function vig_binder_tab_inner_height(panel_h, search_row_h)
	local tab_bar_h = 30 * custom_dpi
	search_row_h = search_row_h or 0
	return math.max(100 * custom_dpi, panel_h - tab_bar_h - search_row_h)
end

local function vig_push_content_text_wrap()
	if not imgui.PushTextWrapPos then
		return false
	end
	local avail = vig_imgui_content_w()
	if avail <= 0 then
		return false
	end
	local wrap_x = imgui.GetCursorPosX() + avail
	local ok = pcall(function()
		imgui.PushTextWrapPos(wrap_x)
	end)
	return ok
end

local function vig_pop_content_text_wrap(pushed)
	if pushed == false then
		return
	end
	if imgui.PopTextWrapPos then
		pcall(imgui.PopTextWrapPos)
	end
end

local function vig_copy_text_to_clipboard(text)
	text = tostring(text or ""):gsub("\r", ""):gsub("\n", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return false
	end
	if imgui.SetClipboardText then
		local ok = pcall(function()
			imgui.SetClipboardText(im_utf8(text))
		end)
		if ok then
			return true
		end
	end
	return false
end

local function vig_render_ogk_staff_content(scroll_h)
	imgui.InputTextWithHint(
		"##ogk_search",
		im_utf8("Поиск (должность / ФИО)"),
		SpecBinderUi.buf_ogk_search,
		256
	)
	local q = normalize_charbuf_input(SpecBinderUi.buf_ogk_search, 256)
	local list_h = vig_binder_tab_inner_height(scroll_h, 32 * custom_dpi)
	imgui.BeginChild("##ogk_staff_scroll", imgui.ImVec2(0, list_h), true)
	local last_role = nil
	local shown = 0
	for _, entry in ipairs(OGK_STAFF) do
		if vig_query_matches(entry.name, q) or vig_query_matches(entry.role, q) then
			if entry.role ~= last_role then
				if last_role then
					imgui.Spacing()
				end
				imgui.TextColored(imgui.ImVec4(0.55, 0.75, 1.0, 1.0), im_utf8(entry.role))
				last_role = entry.role
			end
			local vacant = entry.name == "Вакантно"
			if vacant then
				imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.55, 1.0), im_utf8("  — Вакантно"))
			else
				imgui.Text(im_utf8("  — " .. entry.name))
			end
			shown = shown + 1
		end
	end
	if shown == 0 then
		imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.6, 1.0), im_utf8("Ничего не найдено."))
	end
	imgui.EndChild()
end

--- ImGui обнуляет только префикс до NUL; ffi.string(buf,256)+gsub("%z") склеивал хвост — «пустой» поиск оставлял старый мусор и скрывал все статьи до перезапуска.
local function normalize_search_input()
	local raw = ffi.string(SpecMenu.input, 256)
	local z = raw:find("\0", 1, true)
	if z then
		raw = raw:sub(1, z - 1)
	end
	return (raw:gsub("%z", "")):match("^%s*(.-)%s*$") or ""
end

local function decode_json_str(s)
	if dkok then
		local ok, dec = pcall(dkjson.decode, s)
		if ok then
			return dec
		end
	end
	local ok, dec = pcall(decodeJson, s)
	if ok then
		return dec
	end
end

--- Версия из файла на диске (после скачивания/перезагрузки MoonLoader часто оставляет старый thisScript().version).
local function vig_read_script_version_from_path(path)
	path = tostring(path or "")
	if path == "" then
		return nil
	end
	for _, pv in ipairs({ path, path:gsub("\\", "/"), path:gsub("/", "\\") }) do
		local f = io.open(pv, "rb")
		if f then
			local head = f:read(65536) or ""
			f:close()
			local v = head:match("script_version%s*%(%s*[\"']([^\"']+)[\"']%s*%)")
			if v and v ~= "" then
				return v
			end
		end
	end
	return nil
end

local function vig_version_trim(s)
	s = tostring(s or ""):match("^%s*(.-)%s*$") or ""
	return s
end

--- Разбор "4.0.10" → {4,0,10}. Сравнение: -1 если a<b, 0 если равны, 1 если a>b.
local function vig_parse_version_parts(s)
	local parts = {}
	for num in tostring(s or ""):gmatch("(%d+)") do
		parts[#parts + 1] = tonumber(num) or 0
	end
	if #parts == 0 then
		parts[1] = 0
	end
	return parts
end

local function vig_compare_versions(a, b)
	local pa = vig_parse_version_parts(a)
	local pb = vig_parse_version_parts(b)
	local n = math.max(#pa, #pb)
	for i = 1, n do
		local va = pa[i] or 0
		local vb = pb[i] or 0
		if va < vb then
			return -1
		end
		if va > vb then
			return 1
		end
	end
	return 0
end

local function vig_version_to_int(s)
	return tonumber(tostring(s or ""):match("^%s*(%d+)")) or 0
end

local function get_local_script_version()
	local p = thisScript and thisScript().path
	local from_disk = p and vig_read_script_version_from_path(p)
	if from_disk then
		return vig_version_trim(from_disk)
	end
	if thisScript and thisScript().version and tostring(thisScript().version) ~= "" then
		return vig_version_trim(thisScript().version)
	end
	return vig_version_trim(SCRIPT_VERSION_TEXT)
end

local function get_articles_version_file_path()
	return (get_spec_json_path() .. ".articles_ver"):gsub("\\", "/")
end

local function read_local_articles_version()
	local p = get_articles_version_file_path()
	if not doesFileExist(p) then
		return ""
	end
	local f = io.open(p, "r")
	if not f then
		return ""
	end
	local t = f:read("*a") or ""
	f:close()
	return (t:match("^%s*(.-)%s*$") or "")
end

local function write_local_articles_version(ver)
	ver = tostring(ver or ""):match("^%s*(.-)%s*$") or ""
	local p = get_articles_version_file_path()
	local f = io.open(p, "w")
	if not f then
		return false
	end
	f:write(ver)
	f:close()
	return true
end

local last_manifest_cache = nil

local function download_url_to_file_sync(dest, url, timeout_sec)
	if type(downloadUrlToFile) ~= "function" then
		print("[gwarnn] downloadUrlToFile недоступна (старая сборка MoonLoader?)")
		return false
	end
	local ml = package.loaded["moonloader"] or require("moonloader")
	local st = ml and ml.download_status
	if not st or st.STATUS_ENDDOWNLOADDATA == nil then
		print("[gwarnn] moonloader.download_status недоступен — загрузка с URL не работает")
		return false
	end
	local done, ok = false, false
	pcall(function()
		downloadUrlToFile(url, dest, function(_id, status, _p1, _p2)
			--- wiki.blast.hk: успех часто = 6; на части сборок константа может не совпасть с типом status
			if status == st.STATUS_ENDDOWNLOADDATA or tonumber(status) == 6 then
				ok = true
				done = true
			elseif st.STATUS_ENDDOWNLOADERR ~= nil and status == st.STATUS_ENDDOWNLOADERR then
				ok = false
				done = true
			end
		end)
	end)
	local n, lim = 0, math.floor((timeout_sec or 60) * 10)
	while not done and n < lim do
		wait(100)
		n = n + 1
	end
	if not done then
		print(
			"[gwarnn] таймаут загрузки ("
				.. tostring(timeout_sec or 60)
				.. " с), колбэк не завершился: "
				.. tostring(url)
		)
		pcall(
			sampAddChatMessageUtf8,
			"{009EFF}[Vigmenu]{ffffff} Таймаут загрузки. С raw GitHub из игры часто так (сеть/регион). Скрипт пробует зеркало jsDelivr — обновите VigMenu.lua. Или положите VigArticles.json вручную в moonloader/VigMenu/",
			message_color
		)
		pcall(os.remove, dest)
		return false
	end
	if not ok then
		print("[gwarnn] загрузка завершилась с ошибкой: " .. tostring(url))
	end
	return ok and doesFileExist(dest)
end

local function vig_urls_dedupe(urls)
	local seen, out = {}, {}
	for _, u in ipairs(urls) do
		u = tostring(u or ""):match("^%s*(.-)%s*$") or ""
		if u ~= "" and not seen[u] then
			seen[u] = true
			out[#out + 1] = u
		end
	end
	return out
end

local function vig_url_with_cache_bust(base)
	base = tostring(base or "")
	if base == "" then
		return base
	end
	local sep = base:find("?", 1, true) and "&" or "?"
	return base .. sep .. "t=" .. tostring(os.time())
end

--- jsDelivr кэширует файлы: сначала raw GitHub с cache-bust, затем зеркало.
local function vig_build_download_urls(jsdelivr_static, manifest_url, version_tag)
	local raw = {}
	if manifest_url and manifest_url ~= "" then
		if version_tag and version_tag ~= "" then
			local sep = manifest_url:find("?", 1, true) and "&" or "?"
			raw[#raw + 1] = manifest_url .. sep .. "v=" .. tostring(version_tag)
		end
		raw[#raw + 1] = vig_url_with_cache_bust(manifest_url)
		raw[#raw + 1] = manifest_url
	end
	if jsdelivr_static and jsdelivr_static ~= "" then
		if version_tag and version_tag ~= "" then
			local sep = jsdelivr_static:find("?", 1, true) and "&" or "?"
			raw[#raw + 1] = jsdelivr_static .. sep .. "v=" .. tostring(version_tag)
		end
		raw[#raw + 1] = vig_url_with_cache_bust(jsdelivr_static)
		raw[#raw + 1] = jsdelivr_static
	end
	return vig_urls_dedupe(raw)
end

--- Скачивает VigMenu.lua со всех URL и берёт файл с максимальной версией (jsDelivr часто отдаёт старый кэш).
local function vig_download_best_script(script_urls, tmp, local_v, manifest_v)
	local best_body, best_ver, best_url = nil, nil, nil
	for _, su in ipairs(script_urls) do
		if doesFileExist(tmp) then
			pcall(os.remove, tmp)
		end
		if download_url_to_file_sync(tmp, su, 120) then
			local f = io.open(tmp, "rb")
			if f then
				local body = f:read("*a") or ""
				f:close()
				local ver = body:match("script_version%s*%(%s*[\"']([^\"']+)[\"']%s*%)")
				if ver and ver ~= "" then
					print("[gwarnn] VigMenu.lua v." .. ver .. " ← " .. tostring(su))
					if vig_compare_versions(ver, local_v) > 0 then
						if manifest_v == "" or vig_compare_versions(ver, manifest_v) >= 0 then
							if not best_ver or vig_compare_versions(ver, best_ver) > 0 then
								best_body = body
								best_ver = ver
								best_url = su
							end
						end
					end
				end
			end
		end
	end
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	if best_ver then
		print("[gwarnn] выбран VigMenu.lua v." .. best_ver .. " ← " .. tostring(best_url))
	end
	return best_body, best_ver, best_url
end

--- Версия из VigMenu.lua на GitHub (обход устаревшего VigUpdate.json на jsDelivr).
local function vig_probe_remote_script_max_version(update_url)
	update_url = tostring(update_url or "")
	if update_url == "" then
		return nil
	end
	local tmp = (worked_dir .. "/.gwarnn_probe.lua"):gsub("\\", "/")
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	local urls = vig_build_download_urls(UPDATE_SCRIPT_URL_JS, update_url, "")
	local best_ver = nil
	local probe_limit = math.min(2, #urls)
	for i = 1, probe_limit do
		local su = urls[i]
		if doesFileExist(tmp) then
			pcall(os.remove, tmp)
		end
		if download_url_to_file_sync(tmp, su, 120) then
			local f = io.open(tmp, "rb")
			if f then
				local head = f:read(65536) or ""
				f:close()
				local ver = head:match("script_version%s*%(%s*[\"']([^\"']+)[\"']%s*%)")
				if ver and ver ~= "" then
					ver = vig_version_trim(ver)
					print("[gwarnn] probe VigMenu.lua v." .. ver .. " ← " .. tostring(su))
					if not best_ver or vig_compare_versions(ver, best_ver) > 0 then
						best_ver = ver
					end
				end
			end
		end
	end
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	return best_ver
end

--- Если VigUpdate.json от CDN старый, подставляем версию из скачанного VigMenu.lua.
local function vig_manifest_with_fresh_script_version(m)
	if type(m) ~= "table" then
		return m
	end
	local update_url = type(m.update_url) == "string" and m.update_url or ""
	if update_url == "" then
		return m
	end
	local manifest_v = vig_version_trim(m.current_version or "")
	local local_v = vig_version_trim(get_local_script_version())
	if manifest_v ~= "" and vig_compare_versions(manifest_v, local_v) > 0 then
		return m
	end
	local probed = nil
	local probe_ok, probe_err = pcall(function()
		probed = vig_probe_remote_script_max_version(update_url)
	end)
	if not probe_ok then
		print("[gwarnn] probe VigMenu.lua: " .. tostring(probe_err))
		return m
	end
	if not probed or probed == "" then
		return m
	end
	if vig_compare_versions(probed, manifest_v) <= 0 and vig_compare_versions(probed, local_v) <= 0 then
		return m
	end
	if manifest_v ~= "" and vig_compare_versions(probed, manifest_v) > 0 then
		print(
			"[gwarnn] VigUpdate.json v."
				.. manifest_v
				.. " устарел (CDN), в VigMenu.lua на GitHub v."
				.. probed
		)
	end
	local out = {}
	for k, v in pairs(m) do
		out[k] = v
	end
	out.current_version = probed
	return out
end

--- jsDelivr кэширует @main надолго — сначала raw GitHub с cache-bust, затем зеркало. Берём манифест с максимальной версией.
local function fetch_update_manifest()
	local tmp = (worked_dir .. "/.gwarnn_manifest_tmp.json"):gsub("\\", "/")
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	local raw_urls = {}
	local u = UPDATE_MANIFEST_URL
	--- Свежий GitHub первым (после push актуальнее jsDelivr).
	raw_urls[#raw_urls + 1] = vig_url_with_cache_bust(u)
	raw_urls[#raw_urls + 1] = u
	raw_urls[#raw_urls + 1] = vig_url_with_cache_bust(UPDATE_MANIFEST_URL_JS)
	raw_urls[#raw_urls + 1] = UPDATE_MANIFEST_URL_JS
	if u:find("/main/", 1, true) then
		local m = u:gsub("/main/", "/master/", 1)
		raw_urls[#raw_urls + 1] = vig_url_with_cache_bust(m)
		raw_urls[#raw_urls + 1] = m
	elseif u:find("/master/", 1, true) then
		local m = u:gsub("/master/", "/main/", 1)
		raw_urls[#raw_urls + 1] = vig_url_with_cache_bust(m)
		raw_urls[#raw_urls + 1] = m
	end
	local urls = vig_urls_dedupe(raw_urls)
	local last_err = "не удалось скачать манифест (GitHub и зеркало)"
	local best_data, best_src = nil, nil
	for _, manifest_url in ipairs(urls) do
		if doesFileExist(tmp) then
			pcall(os.remove, tmp)
		end
		if download_url_to_file_sync(tmp, manifest_url, 55) then
			local f = io.open(tmp, "r")
			if f then
				local txt = f:read("*a") or ""
				f:close()
				pcall(os.remove, tmp)
				local data = decode_json_str(txt)
				if type(data) == "table" and data.current_version ~= nil and tostring(data.current_version) ~= "" then
					local ver = vig_version_trim(data.current_version)
					local pick = false
					if not best_data then
						pick = true
					else
						local cmp = vig_compare_versions(ver, vig_version_trim(best_data.current_version))
						if cmp > 0 then
							pick = true
						elseif cmp == 0 then
							local art_new = vig_version_to_int(data.articles_version)
							local art_best = vig_version_to_int(best_data.articles_version)
							if art_new > art_best then
								pick = true
							end
						end
					end
					if pick then
						best_data = data
						best_src = manifest_url
					end
					print("[gwarnn] VigUpdate.json v." .. ver .. " ← " .. tostring(manifest_url))
				else
					last_err = "в манифесте нет current_version"
				end
			end
		end
	end
	if best_data then
		last_manifest_cache = best_data
		print(
			"[gwarnn] выбран манифест v."
				.. vig_version_trim(best_data.current_version)
				.. " (статьи "
				.. tostring(best_data.articles_version or "?")
				.. ") ← "
				.. tostring(best_src)
		)
		return best_data, nil
	end
	return nil, last_err
end

local function fetch_update_manifest_resolved()
	return fetch_update_manifest()
end

local function manifest_script_needs_update(m)
	if not m or m.current_version == nil then
		return false
	end
	local rem = vig_version_trim(m.current_version)
	if rem == "" then
		return false
	end
	local local_v = vig_version_trim(get_local_script_version())
	return vig_compare_versions(rem, local_v) > 0
end

local function manifest_articles_needs_update(m)
	if not m or m.articles_version == nil then
		return false
	end
	local remote_n = vig_version_to_int(m.articles_version)
	if remote_n <= 0 then
		return false
	end
	local local_v = read_local_articles_version()
	if local_v == "" then
		return true
	end
	return remote_n > vig_version_to_int(local_v)
end

local UpdateUi = {
	busy = false,
	need_script = false,
	need_articles = false,
	remote_script_ver = "",
	remote_articles_ver = "",
	changelog_script = "",
	changelog_articles = "",
	script_url = "",
	articles_url = "",
	pending_check = false,
	pending_update = false,
	pending_update_opts = nil,
	worker_started = false,
}

-- Forward declaration: используется в функции обновления, которая объявлена выше фактической реализации.
local load_articles

local function apply_updates_from_manifest(m)
	if not m then
		return
	end
	UpdateUi.need_script = manifest_script_needs_update(m)
	UpdateUi.need_articles = manifest_articles_needs_update(m)
	UpdateUi.remote_script_ver = vig_version_trim(m.current_version)
	UpdateUi.remote_articles_ver = vig_version_trim(m.articles_version)
	UpdateUi.changelog_script = type(m.update_info) == "string" and m.update_info or ""
	UpdateUi.changelog_articles = type(m.articles_info) == "string" and m.articles_info or ""
	UpdateUi.script_url = type(m.update_url) == "string" and m.update_url or ""
	UpdateUi.articles_url = type(m.articles_url) == "string" and m.articles_url or ""
end

local function try_reload_script()
	local reloaded = false
	_G.VIGMENU_GWARNN_LOADED = nil
	pcall(function()
		local ts = thisScript and thisScript()
		if ts and type(ts.reload) == "function" then
			ts:reload()
			reloaded = true
		end
	end)
	if reloaded then
		return
	end
	pcall(function()
		local ml = package.loaded["moonloader"] or require("moonloader")
		if ml and type(ml.reload_script) == "function" and thisScript and thisScript().path then
			ml.reload_script(thisScript().path)
			reloaded = true
		end
	end)
	if not reloaded and type(reloadScript) == "function" then
		pcall(reloadScript)
	end
end

local function vig_do_download_script()
	local url = UpdateUi.script_url
	if url == "" then
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} В манифесте нет update_url.", message_color)
		return false
	end
	local sp = thisScript().path
	if not sp or sp == "" then
		return false
	end
	local tmp = (worked_dir .. "/.gwarnn_new.lua"):gsub("\\", "/")
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	local script_urls = vig_build_download_urls(UPDATE_SCRIPT_URL_JS, url, UpdateUi.remote_script_ver)
	local local_v = vig_version_trim(get_local_script_version())
	local manifest_v = vig_version_trim(UpdateUi.remote_script_ver)
	local body, new_ver = vig_download_best_script(script_urls, tmp, local_v, manifest_v)
	if not body or body == "" then
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Не удалось скачать VigMenu.lua v."
				.. manifest_v
				.. "+ (GitHub недоступен, jsDelivr отдал старый кэш). Замените .lua вручную с GitHub.",
			message_color
		)
		return false
	end
	local target = tostring(sp)
	local out = io.open(target, "wb") or io.open(target:gsub("/", "\\"), "wb")
	if not out then
		out = io.open(target:gsub("\\", "/"), "wb")
	end
	if not out then
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Не удалось записать .lua (права?).", message_color)
		return false
	end
	out:write(body or "")
	if out.flush then
		pcall(out.flush, out)
	end
	out:close()
	pcall(os.remove, tmp)
	if new_ver and new_ver ~= "" then
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Записан VigMenu.lua, версия в файле: "
				.. new_ver
				.. ". Перезагрузка…",
			message_color
		)
	else
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Скрипт записан. Перезагрузка…", message_color)
	end
	local mc = last_manifest_cache
	if mc and type(mc.update_info) == "string" and vig_version_trim(mc.update_info) ~= "" then
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. mc.update_info, message_color)
	end
	wait(900)
	try_reload_script()
	return true
end

local function start_download_script_thread()
	if UpdateUi.busy then
		return
	end
	UpdateUi.busy = true
	if not lua_thread or not lua_thread.create then
		UpdateUi.busy = false
		return
	end
	lua_thread.create(function()
		wait(100)
		local ok_run, err_run = pcall(vig_do_download_script)
		if not ok_run then
			print("[gwarnn] ошибка скачивания скрипта: " .. tostring(err_run))
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Ошибка скачивания скрипта (см. консоль MoonLoader).",
				message_color
			)
		end
		UpdateUi.busy = false
	end)
end

--- Запуск обновления вне колбэка ImGui (кнопка во вкладках иначе крашит игру).
local function vig_queue_github_check()
	if UpdateUi.busy or UpdateUi.pending_check or UpdateUi.pending_update then
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Дождитесь окончания операции.", message_color)
		return
	end
	UpdateUi.pending_check = true
end

local function vig_queue_github_update(opts)
	if UpdateUi.busy or UpdateUi.pending_check or UpdateUi.pending_update then
		sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Подождите, идёт загрузка…", message_color)
		return
	end
	UpdateUi.pending_update = true
	UpdateUi.pending_update_opts = opts
end

local function vig_do_check_updates()
	UpdateUi.busy = true
	local ok_run, err_run = pcall(function()
		local m, err = fetch_update_manifest()
		if not m then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Проверка: " .. tostring(err), message_color)
			return
		end
		apply_updates_from_manifest(m)
		local loc = vig_version_trim(get_local_script_version())
		local rem = vig_version_trim(m.current_version or "")
		if not UpdateUi.need_script and not UpdateUi.need_articles then
			if vig_compare_versions(loc, rem) > 0 then
				sampAddChatMessageUtf8(
					"{009EFF}[Vigmenu]{ffffff} CDN/GitHub отдал старый VigUpdate.json (v."
						.. rem
						.. "). У вас v."
						.. loc
						.. ". Нажмите «Обновить с GitHub» — скрипт проверит .lua на сервере.",
					message_color
				)
			else
				sampAddChatMessageUtf8(
					"{009EFF}[Vigmenu]{ffffff} Обновлений нет. Скрипт у вас: "
						.. loc
						.. " | в манифесте: "
						.. rem
						.. ".",
					message_color
				)
			end
			return
		end
		if UpdateUi.need_script then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Доступно обновление скрипта: у вас v."
					.. loc
					.. ", на GitHub v."
					.. rem
					.. ". Ниже — текст из VigUpdate.json.",
				message_color
			)
			if type(m.update_info) == "string" and vig_version_trim(m.update_info) ~= "" then
				sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. m.update_info, message_color)
			end
		end
		if UpdateUi.need_articles and not UpdateUi.need_script then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Доступно обновление только статей VigArticles.json.",
				message_color
			)
		end
		if UpdateUi.need_articles and type(m.articles_info) == "string" and vig_version_trim(m.articles_info) ~= "" then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. m.articles_info, message_color)
		end
	end)
	if not ok_run then
		print("[gwarnn] ошибка «Проверить»: " .. tostring(err_run))
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Ошибка проверки обновлений (см. консоль MoonLoader).",
			message_color
		)
	end
	UpdateUi.busy = false
end

local function vig_do_github_update(opts)
	opts = type(opts) == "table" and opts or {}
	UpdateUi.busy = true
	local ok_run, err_run = pcall(function()
		local m, err = fetch_update_manifest()
		if not m then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Не удалось получить VigUpdate.json: " .. tostring(err), message_color)
			return
		end
		last_manifest_cache = m
		apply_updates_from_manifest(m)
		if opts.force_articles and type(m.articles_url) == "string" and vig_version_trim(m.articles_url) ~= "" then
			UpdateUi.need_articles = true
		end
		if not UpdateUi.need_script and not UpdateUi.need_articles then
			local probed = nil
			pcall(function()
				probed = vig_probe_remote_script_max_version(m.update_url or "")
			end)
			if probed and probed ~= "" then
				local loc = vig_version_trim(get_local_script_version())
				if vig_compare_versions(probed, loc) > 0 then
					UpdateUi.need_script = true
					UpdateUi.remote_script_ver = probed
					m.current_version = probed
				end
			end
		end
		if not UpdateUi.need_script and not UpdateUi.need_articles then
			local loc = vig_version_trim(get_local_script_version())
			local rem = vig_version_trim(m.current_version or "")
			if vig_compare_versions(loc, rem) > 0 then
				sampAddChatMessageUtf8(
					"{009EFF}[Vigmenu]{ffffff} У вас новее: v."
						.. loc
						.. " | в VigUpdate.json: v."
						.. rem
						.. " (кэш CDN). Обновление не требуется.",
					message_color
				)
			else
				sampAddChatMessageUtf8(
					"{009EFF}[Vigmenu]{ffffff} Актуально. Скрипт у вас: "
						.. loc
						.. " | в VigUpdate.json: "
						.. rem
						.. ".",
					message_color
				)
			end
			return
		end
		if UpdateUi.need_articles then
			local url = UpdateUi.articles_url
			if url == "" then
				sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} В манифесте нет articles_url.", message_color)
			else
				local tmp = (worked_dir .. "/.gwarnn_new_articles.json"):gsub("\\", "/")
				if doesFileExist(tmp) then
					pcall(os.remove, tmp)
				end
				local au_list = vig_build_download_urls(VIGARTICLES_URL_JS, url, UpdateUi.remote_articles_ver)
				local dl_ok = false
				for _, au in ipairs(au_list) do
					if doesFileExist(tmp) then
						pcall(os.remove, tmp)
					end
					if download_url_to_file_sync(tmp, au, 120) then
						dl_ok = true
						if au ~= url then
							print("[gwarnn] VigArticles.json: успех с зеркала jsDelivr")
						end
						break
					end
				end
				if dl_ok then
					local f = io.open(tmp, "rb")
					if f then
						local body = f:read("*a")
						f:close()
						SPEC_JSON_PATH = get_spec_json_path()
						local out = io.open(SPEC_JSON_PATH, "wb")
						if out then
							out:write(body or "")
							out:close()
							pcall(os.remove, tmp)
							if m.articles_version ~= nil then
								write_local_articles_version(tostring(m.articles_version))
							end
							load_articles(true)
							sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} VigArticles.json обновлён.", message_color)
							if type(m.articles_info) == "string" and vig_version_trim(m.articles_info) ~= "" then
								sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. m.articles_info, message_color)
							end
						else
							sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Не удалось записать VigArticles.json.", message_color)
						end
					end
				else
					sampAddChatMessageUtf8(
						"{009EFF}[Vigmenu]{ffffff} Ошибка скачивания VigArticles.json (GitHub и зеркало).",
						message_color
					)
				end
			end
			UpdateUi.need_articles = false
		end
		if UpdateUi.need_script then
			vig_do_download_script()
		end
	end)
	if not ok_run then
		print("[gwarnn] ошибка «Обновить с GitHub»: " .. tostring(err_run))
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Ошибка обновления (см. консоль MoonLoader).",
			message_color
		)
	end
	UpdateUi.busy = false
end

local function vig_process_pending_update_actions()
	if UpdateUi.busy then
		return
	end
	if UpdateUi.pending_check then
		UpdateUi.pending_check = false
		vig_do_check_updates()
		return
	end
	if UpdateUi.pending_update then
		local opts = UpdateUi.pending_update_opts
		UpdateUi.pending_update = false
		UpdateUi.pending_update_opts = nil
		vig_do_github_update(opts)
	end
end

local function start_update_worker_loop()
	if UpdateUi.worker_started or not lua_thread or not lua_thread.create then
		return
	end
	UpdateUi.worker_started = true
	lua_thread.create(function()
		wait(500)
		while true do
			wait(200)
			pcall(vig_process_pending_update_actions)
		end
	end)
end

--- Одна кнопка «Обновить» в настройках (только очередь — работу делает start_update_worker_loop).
local function vig_run_github_update_from_settings(opts)
	vig_queue_github_update(opts)
end

--- Только проверка VigUpdate.json — в чат (только очередь).
local function vig_check_updates_chat_only()
	vig_queue_github_check()
end

--- После приветствия — только сообщение в чат, если есть обновление (скачивание по кнопке в настройках).
local function vig_delayed_update_hint_after_welcome()
	if not lua_thread or not lua_thread.create then
		return
	end
	lua_thread.create(function()
		wait(4500)
		if UpdateUi.busy then
			return
		end
		local m, err = fetch_update_manifest()
		if not m then
			return
		end
		apply_updates_from_manifest(m)
		if not UpdateUi.need_script and not UpdateUi.need_articles then
			return
		end
		local loc = vig_version_trim(get_local_script_version())
		local rem = vig_version_trim(m.current_version or "")
		if UpdateUi.need_script then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Доступно обновление скрипта (у вас v."
					.. loc
					.. ", на GitHub v."
					.. rem
					.. "). Настройки → «Проверить» / «Обновить с GitHub».",
				message_color
			)
			if type(m.update_info) == "string" and vig_version_trim(m.update_info) ~= "" then
				sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. m.update_info, message_color)
			end
		elseif UpdateUi.need_articles then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Доступно обновление статей VigArticles.json. Настройки → «Обновить с GitHub».",
				message_color
			)
		end
		if UpdateUi.need_articles and type(m.articles_info) == "string" and vig_version_trim(m.articles_info) ~= "" then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff}" .. m.articles_info, message_color)
		end
	end)
end

local function get_spec_binder_json_path()
	ensure_spec_data_dir()
	return (get_spec_data_dir() .. "/VigGwarnBinder.json"):gsub("\\", "/")
end

local function get_binder_default_json_path()
	ensure_spec_data_dir()
	return (get_spec_data_dir() .. "/VigGwarnBinderDefault.json"):gsub("\\", "/")
end

local function binder_default_template_candidates()
	local candidates = {}
	pcall(function()
		local path = thisScript().path
		if path and path ~= "" then
			local dir = path:gsub("\\", "/"):match("^(.*)/[^/]+$") or worked_dir
			candidates[#candidates + 1] = dir .. "/VigGwarnBinderDefault.json"
		end
	end)
	candidates[#candidates + 1] = worked_dir .. "/VigGwarnBinderDefault.json"
	return candidates
end

local function parse_binder_delay_ms(v, default)
	default = default or 900
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" then
		return tonumber(v) or default
	end
	return default
end

local function clamp_fire_ban_days(v)
	v = math.floor(tonumber(v) or 0)
	if v < 0 then
		v = 0
	end
	if v > 14 then
		v = 14
	end
	return v
end

local function normalize_server_cmd(s, default)
	s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	s = s:gsub("^/", "")
	if s == "" then
		return default
	end
	if not s:match("^[%w_]+$") then
		return default
	end
	return s
end

local function get_binder_server_cmd(action_type)
	if action_type == DISCIPLINE_ACTION_FIRE then
		return normalize_server_cmd(gwarn_binder.server_cmd_fire, DEMOTE_SERVER_CMD)
	end
	return normalize_server_cmd(gwarn_binder.server_cmd_gwarn, GWARN_SERVER_CMD)
end

local function apply_binder_table(data)
	if type(data) ~= "table" then
		return false
	end
	if type(data.rp_script_gwarn) == "string" then
		gwarn_binder.rp_script_gwarn = data.rp_script_gwarn
	elseif type(data.rp_script) == "string" then
		gwarn_binder.rp_script_gwarn = data.rp_script
	end
	if type(data.rp_script_fire) == "string" then
		gwarn_binder.rp_script_fire = data.rp_script_fire
	end
	if data.delay_ms_gwarn ~= nil then
		gwarn_binder.delay_ms_gwarn = parse_binder_delay_ms(data.delay_ms_gwarn, 900)
	elseif data.delay_ms ~= nil then
		gwarn_binder.delay_ms_gwarn = parse_binder_delay_ms(data.delay_ms, 900)
	end
	if data.delay_ms_fire ~= nil then
		gwarn_binder.delay_ms_fire = parse_binder_delay_ms(data.delay_ms_fire, 900)
	end
	if data.fire_ban_days ~= nil then
		gwarn_binder.fire_ban_days = clamp_fire_ban_days(data.fire_ban_days)
	end
	if type(data.server_cmd_gwarn) == "string" then
		gwarn_binder.server_cmd_gwarn = normalize_server_cmd(data.server_cmd_gwarn, GWARN_SERVER_CMD)
	end
	if type(data.server_cmd_fire) == "string" then
		gwarn_binder.server_cmd_fire = normalize_server_cmd(data.server_cmd_fire, DEMOTE_SERVER_CMD)
	end
	if type(data.bind_chat_open) == "string" then
		gwarn_binder.bind_chat_open = data.bind_chat_open
	end
	if type(data.bind_stop_rp) == "string" then
		gwarn_binder.bind_stop_rp = data.bind_stop_rp
	end
	if data.ogk_enabled ~= nil then
		gwarn_binder.ogk_enabled = data.ogk_enabled and true or false
	end
	if type(data.ogk_log_title) == "string" then
		gwarn_binder.ogk_log_title = data.ogk_log_title
	end
	if data.ogk_show_log ~= nil then
		gwarn_binder.ogk_show_log = data.ogk_show_log and true or false
	end
	if data.ogk_notify ~= nil then
		gwarn_binder.ogk_notify = data.ogk_notify and true or false
	end
	if data.ogk_max_dist ~= nil then
		gwarn_binder.ogk_max_dist = math.max(0, math.min(15, tonumber(data.ogk_max_dist) or 15))
	end
	if data.ogk_log_corner ~= nil then
		gwarn_binder.ogk_log_corner = math.max(0, math.min(OGK_LOG_CORNER_FREE, tonumber(data.ogk_log_corner) or 1))
	end
	if data.ogk_log_pos_x ~= nil then
		gwarn_binder.ogk_log_pos_x = tonumber(data.ogk_log_pos_x)
	end
	if data.ogk_log_pos_y ~= nil then
		gwarn_binder.ogk_log_pos_y = tonumber(data.ogk_log_pos_y)
	end
	if type(data.ogk_tagged_nicks) == "table" then
		gwarn_binder.ogk_tagged_nicks = {}
		for _, item in ipairs(data.ogk_tagged_nicks) do
			if type(item) == "table" and type(item.nick) == "string" then
				local nick = vig_ogk_trim(item.nick)
				if nick ~= "" then
					gwarn_binder.ogk_tagged_nicks[#gwarn_binder.ogk_tagged_nicks + 1] = {
						nick = nick,
						tag = vig_ogk_trim(item.tag),
					}
				end
			end
		end
	elseif type(data.ogk_self_nick) == "string" and vig_ogk_trim(data.ogk_self_nick) ~= "" then
		gwarn_binder.ogk_tagged_nicks = {
			{
				nick = vig_ogk_trim(data.ogk_self_nick),
				tag = type(data.ogk_self_tag) == "string" and vig_ogk_trim(data.ogk_self_tag) or "",
			},
		}
	end
	vig_ogk_ensure_defaults()
	return true
end

local function binder_script_nonempty(s)
	return (tostring(s or ""):match("^%s*(.-)%s*$") or "") ~= ""
end

local function binder_template_has_scripts(tpl)
	if type(tpl) ~= "table" then
		return false
	end
	local g = tpl.rp_script_gwarn
	if type(g) ~= "string" or not g:match("%S") then
		g = tpl.rp_script
	end
	local f = tpl.rp_script_fire
	if type(g) == "string" and g:match("%S") then
		return true
	end
	if type(f) == "string" and f:match("%S") then
		return true
	end
	return false
end

local function binder_default_template_valid(path)
	return binder_template_has_scripts(read_binder_json_file(path))
end

local function read_binder_json_file(path)
	if not path or path == "" or not doesFileExist(path) then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local txt = f:read("*a") or ""
	f:close()
	local ok, data = pcall(decode_json_str, txt)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

--- Шаблон отыгровки в moonloader/VigMenu/VigGwarnBinderDefault.json (из папки скрипта или с GitHub).
local function ensure_binder_default_template()
	local dest = get_binder_default_json_path()
	if binder_default_template_valid(dest) then
		return true
	end
	if doesFileExist(dest) then
		print("[gwarnn] повреждён VigGwarnBinderDefault.json — восстановление шаблона...")
		pcall(os.remove, dest)
	end
	for _, p in ipairs(binder_default_template_candidates()) do
		if binder_default_template_valid(p) and spec_copy_file(p, dest) then
			print("[gwarnn] скопирован шаблон → " .. dest)
			return true
		end
	end
	if not download_url_to_file_sync then
		return false
	end
	local tmp = (worked_dir .. "/.gwarnn_binder_default_tmp.json"):gsub("\\", "/")
	if doesFileExist(tmp) then
		pcall(os.remove, tmp)
	end
	local urls = vig_build_download_urls(BINDER_DEFAULT_JSON_URL_JS, BINDER_DEFAULT_JSON_URL, "")
	for _, u in ipairs(urls) do
		if doesFileExist(tmp) then
			pcall(os.remove, tmp)
		end
		if download_url_to_file_sync(tmp, u, 60) and doesFileExist(tmp) and binder_default_template_valid(tmp) then
			if spec_copy_file(tmp, dest) then
				print("[gwarnn] скачан шаблон отыгровки → " .. dest)
				pcall(os.remove, tmp)
				return true
			end
		end
	end
	pcall(os.remove, tmp)
	return false
end

local function read_binder_template_table()
	if not ensure_binder_default_template() then
		return nil
	end
	local tpl = read_binder_json_file(get_binder_default_json_path())
	if binder_template_has_scripts(tpl) then
		return tpl
	end
	for _, p in ipairs(binder_default_template_candidates()) do
		tpl = read_binder_json_file(p)
		if binder_template_has_scripts(tpl) then
			return tpl
		end
	end
	return nil
end

--- Первый запуск: VigGwarnBinder.json из шаблона (редактируется в настройках и сохраняется отдельно).
local function create_user_binder_from_default()
	if not ensure_binder_default_template() then
		print("[gwarnn] нет VigGwarnBinderDefault.json — создаётся пустой VigGwarnBinder.json")
		gwarn_binder.rp_script_gwarn = ""
		gwarn_binder.delay_ms_gwarn = 900
		gwarn_binder.rp_script_fire = ""
		gwarn_binder.delay_ms_fire = 900
		gwarn_binder.fire_ban_days = 0
		gwarn_binder.server_cmd_gwarn = GWARN_SERVER_CMD
		gwarn_binder.server_cmd_fire = DEMOTE_SERVER_CMD
		gwarn_binder.bind_chat_open = "[]"
		gwarn_binder.bind_stop_rp = "[]"
		return save_gwarn_binder_settings()
	end
	local src = get_binder_default_json_path()
	local dst = get_spec_binder_json_path()
	if spec_copy_file(src, dst) then
		print("[gwarnn] создан VigGwarnBinder.json из шаблона")
		return true
	end
	return false
end

local function ensure_binder_scripts_from_template()
	local need_g = not binder_script_nonempty(gwarn_binder.rp_script_gwarn)
	local need_f = not binder_script_nonempty(gwarn_binder.rp_script_fire)
	if not need_g and not need_f then
		return false
	end
	local tpl = read_binder_template_table()
	if not tpl then
		print("[gwarnn] не удалось загрузить шаблон отыгровок (VigGwarnBinderDefault.json)")
		return false
	end
	if need_g then
		if type(tpl.rp_script_gwarn) == "string" and tpl.rp_script_gwarn:match("%S") then
			gwarn_binder.rp_script_gwarn = tpl.rp_script_gwarn
		elseif type(tpl.rp_script) == "string" and tpl.rp_script:match("%S") then
			gwarn_binder.rp_script_gwarn = tpl.rp_script
		end
	end
	if need_f and type(tpl.rp_script_fire) == "string" and tpl.rp_script_fire:match("%S") then
		gwarn_binder.rp_script_fire = tpl.rp_script_fire
	end
	return need_g or need_f
end

local function encode_binder_json(t)
	if dkok then
		local ok, s = pcall(function()
			return dkjson.encode(t, { indent = true })
		end)
		if ok and type(s) == "string" and s ~= "" then
			return s
		end
		local ok2, s2 = pcall(dkjson.encode, t)
		if ok2 and type(s2) == "string" and s2 ~= "" then
			return s2
		end
	end
	local ok, s = pcall(encodeJson, t)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
	return "{}"
end

local function binder_ui_sync_from_runtime()
	utf8_to_charbuf(gwarn_binder.rp_script_gwarn, SpecBinderUi.buf_script_gwarn, 8192)
	utf8_to_charbuf(gwarn_binder.rp_script_fire, SpecBinderUi.buf_script_fire, 8192)
	utf8_to_charbuf(gwarn_binder.bind_chat_open, SpecBinderUi.buf_bind, 512)
	utf8_to_charbuf(tostring(gwarn_binder.delay_ms_gwarn or 900), SpecBinderUi.buf_delay_gwarn, 16)
	utf8_to_charbuf(tostring(gwarn_binder.delay_ms_fire or 900), SpecBinderUi.buf_delay_fire, 16)
	utf8_to_charbuf(tostring(gwarn_binder.fire_ban_days or 0), SpecBinderUi.buf_fire_ban_days, 8)
	utf8_to_charbuf(get_binder_server_cmd(DISCIPLINE_ACTION_GWARN), SpecBinderUi.buf_cmd_gwarn, 64)
	utf8_to_charbuf(get_binder_server_cmd(DISCIPLINE_ACTION_FIRE), SpecBinderUi.buf_cmd_fire, 64)
	vig_ogk_ensure_defaults()
	SpecBinderUi.ogk_enabled[0] = gwarn_binder.ogk_enabled and true or false
	SpecBinderUi.ogk_show_log[0] = gwarn_binder.ogk_show_log and true or false
	SpecBinderUi.ogk_notify[0] = gwarn_binder.ogk_notify and true or false
	SpecBinderUi.ogk_max_dist[0] = tonumber(gwarn_binder.ogk_max_dist) or 15
	SpecBinderUi.ogk_log_corner[0] = tonumber(gwarn_binder.ogk_log_corner) or 1
	vig_ogk_clear_add_form()
end

local function clamp_binder_delay_ms(dm)
	dm = tonumber(dm) or 900
	if dm < 50 then
		dm = 50
	end
	if dm > 60000 then
		dm = 60000
	end
	return dm
end

local function binder_ui_apply_to_runtime()
	gwarn_binder.rp_script_gwarn = charbuf_to_utf8(SpecBinderUi.buf_script_gwarn, 8192)
	gwarn_binder.rp_script_fire = charbuf_to_utf8(SpecBinderUi.buf_script_fire, 8192)
	gwarn_binder.delay_ms_gwarn = clamp_binder_delay_ms(charbuf_to_utf8(SpecBinderUi.buf_delay_gwarn, 16))
	gwarn_binder.delay_ms_fire = clamp_binder_delay_ms(charbuf_to_utf8(SpecBinderUi.buf_delay_fire, 16))
	gwarn_binder.fire_ban_days = clamp_fire_ban_days(charbuf_to_utf8(SpecBinderUi.buf_fire_ban_days, 8))
	gwarn_binder.server_cmd_gwarn = normalize_server_cmd(charbuf_to_utf8(SpecBinderUi.buf_cmd_gwarn, 64), GWARN_SERVER_CMD)
	gwarn_binder.server_cmd_fire = normalize_server_cmd(charbuf_to_utf8(SpecBinderUi.buf_cmd_fire, 64), DEMOTE_SERVER_CMD)
	gwarn_binder.ogk_enabled = SpecBinderUi.ogk_enabled[0] and true or false
	gwarn_binder.ogk_show_log = SpecBinderUi.ogk_show_log[0] and true or false
	gwarn_binder.ogk_notify = SpecBinderUi.ogk_notify[0] and true or false
	gwarn_binder.ogk_max_dist = math.max(0, math.min(15, tonumber(SpecBinderUi.ogk_max_dist[0]) or 15))
	gwarn_binder.ogk_log_corner = math.max(0, math.min(OGK_LOG_CORNER_FREE, tonumber(SpecBinderUi.ogk_log_corner[0]) or 1))
	gwarn_binder.ogk_log_title = "Отображение"
	if gwarn_binder.ogk_log_corner ~= OGK_LOG_CORNER_FREE then
		gwarn_binder.ogk_log_pos_x, gwarn_binder.ogk_log_pos_y = vig_ogk_corner_pos(gwarn_binder.ogk_log_corner)
	end
	vig_ogk_ensure_defaults()
	if not gwarn_binder.ogk_enabled then
		ogk_nearby = {}
		ogk_log_move_mode = false
		for id in pairs(ogk_notified) do
			ogk_notified[id] = nil
		end
	end
end

local function build_discipline_chat_line(player_id, article_reason, action_type)
	local reason = tostring(article_reason or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local id = tonumber(player_id)
	local cmd = get_binder_server_cmd(action_type)
	if action_type == DISCIPLINE_ACTION_FIRE then
		local days = clamp_fire_ban_days(gwarn_binder.fire_ban_days)
		return "/" .. cmd .. " " .. tostring(id) .. " " .. tostring(days) .. " " .. reason
	end
	return "/" .. cmd .. " " .. tostring(id) .. " " .. reason
end

function vig_binder_request_rp_stop()
	if vig_binder_rp_active then
		vig_binder_rp_stop = true
	end
end

function try_register_binder_hotkeys()
	pcall(function()
		local ok_hk, hotkey = pcall(require, "mimgui_hotkeys")
		if not ok_hk or not hotkey or not hotkey.RemoveHotKey or not hotkey.RegisterHotKey then
			return
		end
		hotkey.RemoveHotKey(GWARN_BINDER_HOTKEY_NAME)
		local raw = gwarn_binder.bind_chat_open
		if raw and raw ~= "" and raw ~= "[]" then
			local keys = decodeJson(raw)
			if type(keys) == "table" then
				hotkey.RegisterHotKey(GWARN_BINDER_HOTKEY_NAME, false, keys, function()
					if sampIsCursorActive and sampIsCursorActive() then
						return
					end
					if sampSetChatInputEnabled and sampSetChatInputText then
						sampSetChatInputEnabled(true)
						sampSetChatInputText("/" .. GWARN_MENU_CMD .. " ")
					end
				end)
			end
		end
		hotkey.RemoveHotKey("VigMenuBinderStop")
		VigBinderStopHotKey = nil
		local stop_keys = {}
		local raw_stop = gwarn_binder.bind_stop_rp
		if raw_stop and raw_stop ~= "" and raw_stop ~= "[]" then
			local decoded = decodeJson(raw_stop)
			if type(decoded) == "table" then
				stop_keys = decoded
			end
		end
		VigBinderStopHotKey = hotkey.RegisterHotKey("VigMenuBinderStop", false, stop_keys, function()
			if sampIsCursorActive and sampIsCursorActive() then
				return
			end
			vig_binder_request_rp_stop()
		end)
	end)
end

save_gwarn_binder_settings = function()
	SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
	local f, err = io.open(SPEC_BINDER_JSON_PATH, "w")
	if not f then
		print("[gwarnn] не удалось записать VigGwarnBinder.json: " .. tostring(err))
		return false
	end
	f:write(
		encode_binder_json({
			rp_script_gwarn = gwarn_binder.rp_script_gwarn,
			delay_ms_gwarn = gwarn_binder.delay_ms_gwarn,
			rp_script_fire = gwarn_binder.rp_script_fire,
			delay_ms_fire = gwarn_binder.delay_ms_fire,
			fire_ban_days = gwarn_binder.fire_ban_days,
			server_cmd_gwarn = gwarn_binder.server_cmd_gwarn,
			server_cmd_fire = gwarn_binder.server_cmd_fire,
			bind_chat_open = gwarn_binder.bind_chat_open,
			bind_stop_rp = gwarn_binder.bind_stop_rp,
			ogk_enabled = gwarn_binder.ogk_enabled and true or false,
			ogk_log_title = gwarn_binder.ogk_log_title,
			ogk_show_log = gwarn_binder.ogk_show_log and true or false,
			ogk_notify = gwarn_binder.ogk_notify and true or false,
			ogk_max_dist = tonumber(gwarn_binder.ogk_max_dist) or 15,
			ogk_log_corner = tonumber(gwarn_binder.ogk_log_corner) or 1,
			ogk_log_pos_x = tonumber(gwarn_binder.ogk_log_pos_x),
			ogk_log_pos_y = tonumber(gwarn_binder.ogk_log_pos_y),
			ogk_tagged_nicks = gwarn_binder.ogk_tagged_nicks or {},
		})
	)
	f:write("\n")
	f:close()
	try_register_binder_hotkeys()
	return true
end

local function load_gwarn_binder_settings()
	SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
	gwarn_binder.rp_script_gwarn = ""
	gwarn_binder.delay_ms_gwarn = 900
	gwarn_binder.rp_script_fire = ""
	gwarn_binder.delay_ms_fire = 900
	gwarn_binder.fire_ban_days = 0
	gwarn_binder.server_cmd_gwarn = GWARN_SERVER_CMD
	gwarn_binder.server_cmd_fire = DEMOTE_SERVER_CMD
	gwarn_binder.bind_chat_open = "[]"
	gwarn_binder.bind_stop_rp = "[]"
	gwarn_binder.ogk_enabled = false
	gwarn_binder.ogk_log_title = "Отображение"
	gwarn_binder.ogk_show_log = true
	gwarn_binder.ogk_notify = false
	gwarn_binder.ogk_max_dist = 15
	gwarn_binder.ogk_log_corner = 1
	gwarn_binder.ogk_log_pos_x = sizeX * 0.78
	gwarn_binder.ogk_log_pos_y = sizeY * 0.25
	gwarn_binder.ogk_tagged_nicks = {}
	if not doesFileExist(SPEC_BINDER_JSON_PATH) then
		create_user_binder_from_default()
	end
	local data = read_binder_json_file(SPEC_BINDER_JSON_PATH)
	if data then
		apply_binder_table(data)
		if ensure_binder_scripts_from_template() then
			save_gwarn_binder_settings()
		end
	else
		if not doesFileExist(SPEC_BINDER_JSON_PATH) then
			create_user_binder_from_default()
			data = read_binder_json_file(SPEC_BINDER_JSON_PATH)
			if data then
				apply_binder_table(data)
			end
		else
			print("[gwarnn] не удалось прочитать VigGwarnBinder.json")
		end
	end
	try_register_binder_hotkeys()
	vig_ogk_ensure_defaults()
end

local function apply_binder_placeholders(line, player_id, reason)
	local r = tostring(reason or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local nid = tonumber(player_id)
	local nick = ""
	if nid and sampGetPlayerNickname then
		nick = tostring(sampGetPlayerNickname(nid) or "")
	end
	line = line:gsub("{id}", tostring(player_id or ""))
	line = line:gsub("{reason}", r)
	line = line:gsub("{article}", r)
	local nick_utf8 = nick
	if nick ~= "" then
		local okn, nu = pcall(function()
			return u8(nick)
		end)
		if okn and nu then
			nick_utf8 = nu
		end
	end
	line = line:gsub("{nick}", nick_utf8)
	return line
end

local function split_binder_script(script)
	script = tostring(script or ""):gsub("\r\n", "\n")
	local lines = {}
	if script:find("&", 1, true) then
		for seg in script:gmatch("([^&]+)") do
			local t = seg:match("^%s*(.-)%s*$") or ""
			if t ~= "" then
				lines[#lines + 1] = t
			end
		end
	else
		for seg in script:gmatch("([^\n]+)") do
			local t = seg:match("^%s*(.-)%s*$") or ""
			if t ~= "" then
				lines[#lines + 1] = t
			end
		end
	end
	return lines
end

local DISCIPLINE_LOG_NAME = "VigDisciplineLog.txt"

local function get_discipline_log_path()
	return (get_spec_data_dir() .. "/" .. DISCIPLINE_LOG_NAME):gsub("\\", "/")
end

local function vig_discipline_log_has_date(content, date_str)
	if content == "" then
		return false
	end
	local esc = date_str:gsub("([%.])", "%%%1")
	if content:match("^" .. esc .. "\n") then
		return true
	end
	return content:find("\n" .. date_str .. "\n", 1, true) ~= nil
end

local vig_log_pending = nil

local function vig_strip_chat_formatting(text)
	text = tostring(text or "")
	text = text:gsub("{%x+}", "")
	return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function vig_chat_to_utf8(text)
	text = vig_strip_chat_formatting(text)
	if text == "" then
		return ""
	end
	local ok, r = pcall(function()
		return u8(text)
	end)
	if ok and type(r) == "string" and r ~= "" then
		return r
	end
	return text
end

local function vig_reason_loose_match(msg, reason)
	reason = tostring(reason or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if reason == "" then
		return true
	end
	if msg:find(reason, 1, true) then
		return true
	end
	local num = reason:match("^([%d%.]+)")
	if num and msg:find(num, 1, true) then
		return true
	end
	return false
end

local function vig_append_log_raw_line(line)
	line = tostring(line or ""):gsub("\r", ""):gsub("\n", " ")
	line = line:gsub("^%s+", ""):gsub("%s+$", "")
	if line == "" then
		return
	end
	ensure_spec_data_dir()
	local path = get_discipline_log_path()
	local today = os.date("%d.%m.%Y")

	local existing = ""
	if doesFileExist(path) then
		local rf = io.open(path, "r")
		if rf then
			existing = rf:read("*a") or ""
			rf:close()
		end
	end

	local out = existing
	if not vig_discipline_log_has_date(existing, today) then
		if existing ~= "" and not existing:match("\n$") then
			out = out .. "\n"
		end
		if existing ~= "" then
			out = out .. "\n"
		end
		out = out .. today .. "\n"
	end
	out = out .. "[" .. os.date("%d.%m.%Y %H:%M:%S") .. "] " .. line .. "\n"

	local wf, err = io.open(path, "w")
	if not wf then
		print("[gwarnn] не удалось записать лог наказаний: " .. tostring(err))
		return
	end
	wf:write(out)
	wf:close()
end

local function vig_parse_discipline_log_sections()
	local path = get_discipline_log_path()
	if not doesFileExist(path) then
		return {}
	end
	local rf = io.open(path, "r")
	if not rf then
		return {}
	end
	local content = rf:read("*a") or ""
	rf:close()
	local sections = {}
	local current = nil
	for line in content:gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			if line:match("^%d%d%.%d%d%.%d%d%d%d$") then
				current = { date = line, entries = {} }
				sections[#sections + 1] = current
			elseif current then
				current.entries[#current.entries + 1] = line
			end
		end
	end
	return sections
end

local vig_disc_log = {
	codes = { "ЗоГС", "МЮ", "МО", "ЦА" },
	short = {
		["Правительство LS"] = "Прав. LS",
		["Полиция ЛС"] = "ЛСПД",
		["Полиция СФ"] = "СФПД",
		["Полиция ЛВ"] = "ЛВПД",
		["Армия ЛС"] = "Армия LS",
		["Армия SF"] = "Армия SF",
		["Областная полиция"] = "Обл. пол.",
		["Центр лицензирования"] = "Центр лиц.",
		["Пожарный департамент"] = "Пожар.",
		["Тюрьма строгого режима"] = "Тюрьма",
	},
	faction_aliases = {
		["Автошкола"] = "Центр лицензирования",
	},
	no_faction_key = "",
	zogs_expanded = false,
	zogs_ca_expanded = false,
	zogs_fire_label = "17 ЗоГС",
	mju_factions = {
		["Полиция ЛС"] = true,
		["Полиция СФ"] = true,
		["Полиция ЛВ"] = true,
		["Областная полиция"] = true,
	},
	mo_factions = {
		["Армия ЛС"] = true,
		["Армия SF"] = true,
		["Тюрьма строгого режима"] = true,
	},
	ca_factions = {
		"Правительство LS",
		"Центр лицензирования",
		"Пожарный департамент",
	},
	stats_measured_h = nil,
	stats_measured_key = nil,
}

function vig_disc_log.line_body(line)
	line = tostring(line or "")
	return line:match("^%[%d%d%.%d%d%.%d%d%d%d %d%d:%d%d:%d%d%]%s*(.+)$") or line
end

function vig_disc_log.line_reason(body)
	body = tostring(body or "")
	local reason = body:match("[Пп]ричина:%s*(.+)") or ""
	reason = reason:gsub("%(%d+%)$", ""):gsub("^%s+", ""):gsub("%s+$", "")
	return reason
end

function vig_disc_log.code_from_line(body)
	local reason = utf8_rupper(vig_disc_log.line_reason(body))
	if reason == "" then
		return nil
	end
	if reason:find("У%.ЦА", 1, true) or reason:find(" ЦА", 1, true) or reason:match("ЦА$") then
		return "ЦА"
	end
	if reason:find("У%.МЮ", 1, true) or reason:find(" МЮ", 1, true) or reason:match("МЮ$") then
		return "МЮ"
	end
	if reason:find("У%.МО", 1, true) or reason:find(" МО", 1, true) or reason:match("МО$") then
		return "МО"
	end
	if reason:find("ЗОГС", 1, true) then
		return "ЗоГС"
	end
	return nil
end

function vig_disc_log.line_kind(body)
	body = tostring(body or "")
	if body:find("Уволил", 1, true) or utf8_rupper(body):find("УВОЛИЛ", 1, true) then
		return "fire"
	end
	local u = utf8_rupper(body)
	if u:find("СПЕЦ", 1, true) and u:find("ВЫГОВОР", 1, true) then
		return "gwarn"
	end
	return nil
end

function vig_disc_log.line_matches_filter(sec, line, q)
	if q == "" then
		return true
	end
	if vig_query_matches(sec.date, q) then
		return true
	end
	return vig_query_matches(line, q)
end

function vig_disc_log.normalize_faction(name)
	if name == nil or name == vig_disc_log.no_faction_key then
		return name
	end
	return vig_disc_log.faction_aliases[name] or name
end

function vig_disc_log.line_faction(body)
	body = tostring(body or "")
	local faction = body:match("игроку%s+%S+%s+%[([^%]]+)%]")
	if faction and faction ~= "" then
		return vig_disc_log.normalize_faction(faction)
	end
	faction = body:match("Уволил%s+%S+%s+%[([^%]]+)%]")
	if faction and faction ~= "" then
		return vig_disc_log.normalize_faction(faction)
	end
	return vig_disc_log.no_faction_key
end

function vig_disc_log.org_label(name)
	if name == nil or name == vig_disc_log.no_faction_key then
		return "без орг."
	end
	return vig_disc_log.short[name] or name
end

function vig_disc_log.org_bucket(name)
	if name == vig_disc_log.no_faction_key then
		return "none"
	end
	if vig_disc_log.mju_factions[name] then
		return "mju"
	end
	if vig_disc_log.mo_factions[name] then
		return "mo"
	end
	return "ca"
end

function vig_disc_log.row_total(row)
	return (row.fire or 0) + (row.gwarn or 0)
end

function vig_disc_log.ensure_org(map, name)
	local org = map[name]
	if not org then
		org = { name = name, fire = 0, gwarn = 0 }
		map[name] = org
	end
	return org
end

function vig_disc_log.add_zogs_hit(tree, maps, faction, kind)
	if faction == vig_disc_log.no_faction_key then
		if kind == "fire" then
			tree.none.fire = tree.none.fire + 1
		else
			tree.none.gwarn = tree.none.gwarn + 1
		end
		return
	end
	local bucket = vig_disc_log.org_bucket(faction)
	local org = vig_disc_log.ensure_org(maps[bucket], faction)
	if kind == "fire" then
		org.fire = org.fire + 1
	else
		org.gwarn = org.gwarn + 1
	end
	if bucket == "mju" or bucket == "mo" then
		local group = tree[bucket]
		if kind == "fire" then
			group.fire = group.fire + 1
		else
			group.gwarn = group.gwarn + 1
		end
	end
end

function vig_disc_log.add_ca_display_hit(maps, faction, kind)
	if faction == vig_disc_log.no_faction_key then
		return
	end
	if vig_disc_log.org_bucket(faction) ~= "ca" then
		return
	end
	local org = vig_disc_log.ensure_org(maps.ca, faction)
	if kind == "fire" then
		org.fire = org.fire + 1
	else
		org.gwarn = org.gwarn + 1
	end
end

function vig_disc_log.sort_orgs(list)
	table.sort(list, function(a, b)
		local ta = vig_disc_log.row_total(a)
		local tb = vig_disc_log.row_total(b)
		if ta ~= tb then
			return ta > tb
		end
		return vig_disc_log.org_label(a.name) < vig_disc_log.org_label(b.name)
	end)
	return list
end

function vig_disc_log.orgs_from_map(map)
	local list = {}
	for _, org in pairs(map or {}) do
		if vig_disc_log.row_total(org) > 0 then
			list[#list + 1] = org
		end
	end
	return vig_disc_log.sort_orgs(list)
end

function vig_disc_log.finish_zogs_tree(tree, maps)
	local list = {}
	local seen = {}
	for _, name in ipairs(vig_disc_log.ca_factions) do
		local org = maps.ca[name]
		if not org then
			org = { name = name, fire = 0, gwarn = 0 }
		end
		list[#list + 1] = org
		seen[name] = true
	end
	for name, org in pairs(maps.ca or {}) do
		if not seen[name] and vig_disc_log.row_total(org) > 0 then
			list[#list + 1] = org
		end
	end
	tree.ca.factions = list
	tree.ca.fire = 0
	tree.ca.gwarn = 0
	for _, org in ipairs(list) do
		tree.ca.fire = tree.ca.fire + (org.fire or 0)
		tree.ca.gwarn = tree.ca.gwarn + (org.gwarn or 0)
	end
	return tree
end

function vig_disc_log.new_zogs_tree()
	return {
		mju = { fire = 0, gwarn = 0 },
		mo = { fire = 0, gwarn = 0 },
		ca = { fire = 0, gwarn = 0, factions = {} },
		none = { fire = 0, gwarn = 0 },
	}
end

function vig_disc_log.new_zogs_maps()
	return { mju = {}, mo = {}, ca = {} }
end

function vig_disc_log.build(sections, q)
	local counts = {}
	local total = { fire = 0, gwarn = 0 }
	local zogs_tree = vig_disc_log.new_zogs_tree()
	local zogs_maps = vig_disc_log.new_zogs_maps()
	for _, code in ipairs(vig_disc_log.codes) do
		counts[code] = { fire = 0, gwarn = 0 }
	end
	q = tostring(q or ""):match("^%s*(.-)%s*$") or ""
	for _, sec in ipairs(sections or {}) do
		for _, line in ipairs(sec.entries or {}) do
			if vig_disc_log.line_matches_filter(sec, line, q) then
				local body = vig_disc_log.line_body(line)
				local kind = vig_disc_log.line_kind(body)
				local code = vig_disc_log.code_from_line(body)
				if kind then
					if kind == "fire" then
						total.fire = total.fire + 1
					else
						total.gwarn = total.gwarn + 1
					end
				end
				if kind and code and counts[code] then
					if kind == "fire" then
						counts[code].fire = counts[code].fire + 1
					else
						counts[code].gwarn = counts[code].gwarn + 1
					end
					if code == "ЗоГС" then
						vig_disc_log.add_zogs_hit(
							zogs_tree,
							zogs_maps,
							vig_disc_log.line_faction(body),
							kind
						)
					elseif code == "ЦА" then
						vig_disc_log.add_ca_display_hit(
							zogs_maps,
							vig_disc_log.line_faction(body),
							kind
						)
					end
				end
			end
		end
	end
	return counts, vig_disc_log.finish_zogs_tree(zogs_tree, zogs_maps), total
end

function vig_disc_log.zogs_detail_rows(tree)
	local rows = 0
	tree = tree or {}
	if vig_disc_log.row_total(tree.mju) > 0 then
		rows = rows + 1
	end
	if vig_disc_log.row_total(tree.mo) > 0 then
		rows = rows + 1
	end
	if (tree.none and tree.none.fire or 0) > 0 then
		rows = rows + 1
	end
	rows = rows + 1
	if vig_disc_log.zogs_ca_expanded then
		rows = rows + #(tree.ca and tree.ca.factions or vig_disc_log.ca_factions)
	end
	return rows
end

function vig_disc_log.stats_layout_key(zogs_tree)
	if not vig_disc_log.zogs_expanded then
		return "c"
	end
	local ca = vig_disc_log.zogs_ca_expanded and "1" or "0"
	return "e:" .. tostring(vig_disc_log.zogs_detail_rows(zogs_tree)) .. ":ca" .. ca
end

function vig_disc_log.stats_height(zogs_tree)
	local key = vig_disc_log.stats_layout_key(zogs_tree)
	if vig_disc_log.stats_measured_h and vig_disc_log.stats_measured_key == key then
		return vig_disc_log.stats_measured_h
	end
	local style = imgui.GetStyle()
	local pad_y = style.WindowPadding.y * 2
	local row_h = imgui.GetTextLineHeightWithSpacing()
	local rows = 1 + #vig_disc_log.codes + 2
	if vig_disc_log.zogs_expanded then
		rows = rows + vig_disc_log.zogs_detail_rows(zogs_tree)
	end
	return pad_y + rows * row_h + 2 * custom_dpi
end

function vig_disc_log.render_row_counts(row, col_uvol, col_spec)
	imgui.SameLine(col_uvol)
	imgui.Text(im_utf8(tostring(row.fire or 0)))
	imgui.SameLine(col_spec)
	imgui.Text(im_utf8(tostring(row.gwarn or 0)))
end

function vig_disc_log.render_zogs_row(label, row, col_uvol, col_spec)
	if vig_disc_log.row_total(row) <= 0 then
		return
	end
	imgui.Text(im_utf8(label))
	vig_disc_log.render_row_counts(row, col_uvol, col_spec)
end

function vig_disc_log.render_sub_label(text, full_name)
	local sub_col = imgui.ImVec4(0.68, 0.7, 0.76, 1.0)
	imgui.TextColored(sub_col, im_utf8(text))
	if full_name and imgui.IsItemHovered() then
		imgui.SetTooltip(im_utf8(full_name))
	end
end

function vig_disc_log.render_zogs_details(zogs_tree, col_uvol, col_spec)
	local tree = zogs_tree or {}
	local lvl1 = 12 * custom_dpi
	local lvl2 = 26 * custom_dpi
	local ca_clicked = false
	imgui.Indent(lvl1)
	vig_disc_log.render_zogs_row("МЮ", tree.mju, col_uvol, col_spec)
	vig_disc_log.render_zogs_row("МО", tree.mo, col_uvol, col_spec)
	if (tree.none and tree.none.fire or 0) > 0 then
		vig_disc_log.render_sub_label(
			vig_disc_log.zogs_fire_label,
			"Увольнение по ЗоГС без [фракции] в строке лога"
		)
		vig_disc_log.render_row_counts(tree.none, col_uvol, col_spec)
	end
	local ca_arrow = vig_disc_log.zogs_ca_expanded and "[-] " or "[+] "
	if imgui.Selectable(
		im_utf8(ca_arrow .. "ЦА##disc_zogs_ca"),
		false,
		0,
		imgui.ImVec2(col_uvol - lvl1 - 8 * custom_dpi, 18 * custom_dpi)
	) then
		ca_clicked = true
	end
	vig_disc_log.render_row_counts(tree.ca or { fire = 0, gwarn = 0 }, col_uvol, col_spec)
	if vig_disc_log.zogs_ca_expanded then
		imgui.Indent(lvl2 - lvl1)
		for _, org in ipairs((tree.ca and tree.ca.factions) or {}) do
			local label = vig_disc_log.org_label(org.name)
			vig_disc_log.render_sub_label(label, org.name)
			vig_disc_log.render_row_counts(org, col_uvol, col_spec)
		end
		imgui.Unindent(lvl2 - lvl1)
	end
	imgui.Unindent(lvl1)
	return ca_clicked
end

function vig_disc_log.render_stats_body(counts, zogs_tree, total, filtered, col_uvol, col_spec, muted)
	imgui.TextColored(muted, im_utf8("Статья"))
	if filtered then
		imgui.SameLine()
		imgui.TextColored(muted, im_utf8("(фильтр)"))
	end
	imgui.SameLine(col_uvol)
	imgui.TextColored(muted, im_utf8("Увол"))
	imgui.SameLine(col_spec)
	imgui.TextColored(muted, im_utf8("Спец"))
	local zogs_clicked = false
	local ca_clicked = false
	for _, code in ipairs(vig_disc_log.codes) do
		local row = counts[code] or { fire = 0, gwarn = 0 }
		if code == "ЗоГС" then
			local arrow = vig_disc_log.zogs_expanded and "[-] " or "[+] "
			if imgui.Selectable(
				im_utf8(arrow .. code .. "##disc_zogs"),
				false,
				0,
				imgui.ImVec2(col_uvol - 8 * custom_dpi, 18 * custom_dpi)
			) then
				zogs_clicked = true
			end
			vig_disc_log.render_row_counts(row, col_uvol, col_spec)
			if vig_disc_log.zogs_expanded then
				local ca_click = vig_disc_log.render_zogs_details(zogs_tree, col_uvol, col_spec)
				if ca_click then
					ca_clicked = true
				end
			end
		else
			imgui.Text(im_utf8(code))
			vig_disc_log.render_row_counts(row, col_uvol, col_spec)
		end
	end
	if imgui.Separator then
		imgui.Separator()
	end
	local total_col = imgui.ImVec4(0.82, 0.84, 0.9, 1.0)
	imgui.TextColored(total_col, im_utf8("Всего"))
	if imgui.IsItemHovered() then
		imgui.SetTooltip(im_utf8("Все увольнения и спец. выговоры в логе"))
	end
	vig_disc_log.render_row_counts(total or { fire = 0, gwarn = 0 }, col_uvol, col_spec)
	return zogs_clicked, ca_clicked
end

function vig_disc_log.render(counts, zogs_tree, total, filtered)
	local muted = imgui.ImVec4(0.55, 0.55, 0.6, 1.0)
	local col_uvol = 82 * custom_dpi
	local col_spec = col_uvol + 42 * custom_dpi
	local stats_flags = imgui.WindowFlags and imgui.WindowFlags.NoScrollbar or 0
	imgui.BeginChild(
		"##disc_log_stats",
		imgui.ImVec2(0, vig_disc_log.stats_height(zogs_tree)),
		true,
		stats_flags
	)
	local zogs_clicked, ca_clicked = vig_disc_log.render_stats_body(
		counts,
		zogs_tree,
		total,
		filtered,
		col_uvol,
		col_spec,
		muted
	)
	local style = imgui.GetStyle()
	vig_disc_log.stats_measured_h = imgui.GetCursorPosY() + style.WindowPadding.y
	vig_disc_log.stats_measured_key = vig_disc_log.stats_layout_key(zogs_tree)
	imgui.EndChild()
	if zogs_clicked then
		vig_disc_log.zogs_expanded = not vig_disc_log.zogs_expanded
		if not vig_disc_log.zogs_expanded then
			vig_disc_log.zogs_ca_expanded = false
		end
	end
	if ca_clicked then
		vig_disc_log.zogs_ca_expanded = not vig_disc_log.zogs_ca_expanded
	end
end

local function vig_render_binder_gwarn_fields(script_h)
	imgui.TextColored(imgui.ImVec4(0.55, 0.75, 1.0, 1.0), im_utf8("Спец. выговор"))
	imgui.TextWrapped(im_utf8("Команда после отыгровки (без /):"))
	imgui.InputText("##binder_cmd_gwarn", SpecBinderUi.buf_cmd_gwarn, 64)
	if imgui.IsItemHovered() then
		imgui.SetTooltip(im_utf8("Формат: gwarn — подставятся id и статья"))
	end
	imgui.TextWrapped(im_utf8("Задержка между сообщениями (мс):"))
	imgui.InputText("##binder_delay_gwarn", SpecBinderUi.buf_delay_gwarn, 16)
	local multiline_h = script_h or 140 * custom_dpi
	imgui.InputTextMultiline(
		"##binder_script_gwarn",
		SpecBinderUi.buf_script_gwarn,
		8192,
		imgui.ImVec2(vig_imgui_content_w(), multiline_h)
	)
end

local function vig_render_binder_fire_fields(script_h)
	imgui.TextColored(imgui.ImVec4(0.55, 0.75, 1.0, 1.0), im_utf8("Увольнение"))
	imgui.TextWrapped(im_utf8("Команда после отыгровки (без /):"))
	imgui.InputText("##binder_cmd_fire", SpecBinderUi.buf_cmd_fire, 64)
	if imgui.IsItemHovered() then
		imgui.SetTooltip(im_utf8("Формат: demoute — подставятся id, дни запрета и статья"))
	end
	imgui.TextWrapped(im_utf8("Дней запрета вступления (0–14, 0 = без запрета):"))
	imgui.InputText("##binder_fire_ban_days", SpecBinderUi.buf_fire_ban_days, 8)
	imgui.TextWrapped(im_utf8("Задержка между сообщениями (мс):"))
	imgui.InputText("##binder_delay_fire", SpecBinderUi.buf_delay_fire, 16)
	local multiline_h = script_h or 140 * custom_dpi
	imgui.InputTextMultiline(
		"##binder_script_fire",
		SpecBinderUi.buf_script_fire,
		8192,
		imgui.ImVec2(vig_imgui_content_w(), multiline_h)
	)
end

function vig_render_binder_rp_tab(panel_h)
	local list_h = vig_binder_tab_inner_height(panel_h, 0)
	imgui.BeginChild("##binder_rp_scroll", imgui.ImVec2(0, list_h), true)
	local half_h = math.max(100 * custom_dpi, (list_h - 120 * custom_dpi) * 0.42)
	vig_render_binder_gwarn_fields(half_h)
	imgui.Separator()
	vig_render_binder_fire_fields(half_h)
	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()
	imgui.TextWrapped(im_utf8("Приостановить отыгровку:"))
	if VigBinderStopHotKey and VigBinderStopHotKey.ShowHotKey then
		if VigBinderStopHotKey:ShowHotKey(imgui.ImVec2(-1, 28 * custom_dpi)) then
			local ok, keys = pcall(function()
				return VigBinderStopHotKey:GetHotKey()
			end)
			if ok and keys then
				local ok_json, encoded = pcall(encodeJson, keys)
				if ok_json and type(encoded) == "string" then
					gwarn_binder.bind_stop_rp = encoded
					save_gwarn_binder_settings()
				end
			end
		end
		imgui.TextColored(
			imgui.ImVec4(0.5, 0.55, 0.65, 1.0),
			im_utf8("Нажмите на кнопку и задайте клавишу. Во время отыгровки нажатие остановит её.")
		)
	else
		imgui.TextColored(
			imgui.ImVec4(0.55, 0.55, 0.6, 1.0),
			im_utf8("Недоступно: нужна библиотека mimgui_hotkeys")
		)
	end
	imgui.EndChild()
end

local function vig_render_binder_update_tab()
	imgui.TextWrapped(
		im_utf8("Обновление с GitHub (VigUpdate.json). Скачивает статьи и/или скрипт, если в манифесте версия новее.")
	)
	if UpdateUi.busy then
		imgui.Text(im_utf8("Идёт загрузка…"))
	else
		if imgui.Button(im_utf8("Проверить##vig_chk"), imgui.ImVec2(236 * custom_dpi, 30 * custom_dpi)) then
			vig_queue_github_check()
		end
		imgui.SameLine()
		if imgui.Button(im_utf8("Обновить с GitHub##vig_git_upd"), imgui.ImVec2(236 * custom_dpi, 30 * custom_dpi)) then
			vig_queue_github_update()
		end
	end
end

local function vig_render_ogk_tracker_settings_tab(panel_h)
	local list_h = vig_binder_tab_inner_height(panel_h, 0)
	imgui.BeginChild("##ogk_tracker_settings_scroll", imgui.ImVec2(0, list_h), true)
	imgui.TextWrapped(
		im_utf8(
			"Показывает сотрудников ОГК и добавленные вами ники рядом. В штате «Ken Yager» = Ken_Yager в игре. «Вакантно» не учитывается. Свой ник с тегом в логе: [тег] Ken_Yager [id] — расстояние."
		)
	)
	imgui.Spacing()
	imgui.Checkbox(im_utf8("Включить отображение##ogk_en"), SpecBinderUi.ogk_enabled)
	imgui.Spacing()
	imgui.Text(im_utf8("Ник:"))
	imgui.InputTextWithHint("##ogk_add_nick", im_utf8("Ken_Yager"), SpecBinderUi.buf_ogk_add_nick, 128)
	imgui.Text(im_utf8("Тег:"))
	imgui.InputTextWithHint("##ogk_add_tag", im_utf8("[Я]"), SpecBinderUi.buf_ogk_add_tag, 64)
	local add_btn_w = 220 * custom_dpi
	if ogk_tag_edit_idx then
		if imgui.Button(im_utf8("Сохранить##ogk_tag_save"), imgui.ImVec2(add_btn_w, 28 * custom_dpi)) then
			vig_ogk_try_submit_tagged_nick()
		end
		imgui.SameLine()
		if imgui.Button(im_utf8("Отмена##ogk_tag_cancel"), imgui.ImVec2(56 * custom_dpi, 28 * custom_dpi)) then
			vig_ogk_clear_add_form()
		end
	else
		if imgui.Button(im_utf8("Добавить##ogk_tag_add"), imgui.ImVec2(add_btn_w, 28 * custom_dpi)) then
			vig_ogk_try_submit_tagged_nick()
		end
		imgui.SameLine()
		if imgui.Button(im_utf8("+##ogk_tag_plus"), imgui.ImVec2(56 * custom_dpi, 28 * custom_dpi)) then
			vig_ogk_try_submit_tagged_nick()
		end
	end
	imgui.Spacing()
	imgui.Text(im_utf8("Добавленные ники (нажмите на строку для изменения):"))
	local tagged = gwarn_binder.ogk_tagged_nicks or {}
	if #tagged == 0 then
		imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.6, 1.0), im_utf8("—"))
	else
		local del_w = 72 * custom_dpi
		local row_gap = 8 * custom_dpi
		for i, entry in ipairs(tagged) do
			local tag_text = vig_ogk_trim(entry.tag)
			local nick_text = vig_ogk_trim(entry.nick)
			local row_label = nick_text
			if tag_text ~= "" and nick_text ~= "" then
				row_label = tag_text .. "  " .. nick_text
			elseif tag_text ~= "" then
				row_label = tag_text
			elseif nick_text == "" then
				row_label = "—"
			end
			local editing = ogk_tag_edit_idx == i
			local row_w = imgui.GetContentRegionAvail().x - del_w - row_gap
			if row_w < 80 * custom_dpi then
				row_w = 80 * custom_dpi
			end
			if imgui.Selectable(
				im_utf8(row_label .. "##ogk_list_row_" .. i),
				editing,
				0,
				imgui.ImVec2(row_w, 0)
			) then
				vig_ogk_start_edit_tagged_nick(i)
			end
			imgui.SameLine(0, row_gap)
			if imgui.Button(im_utf8("Удалить##ogk_list_del_" .. i), imgui.ImVec2(del_w, 0)) then
				vig_ogk_remove_tagged_nick(i)
			end
		end
	end
	imgui.Spacing()
	imgui.Checkbox(im_utf8("Показывать список в углу##ogk_log"), SpecBinderUi.ogk_show_log)
	imgui.Checkbox(im_utf8("Оповещение в чат при появлении##ogk_ntf"), SpecBinderUi.ogk_notify)
	imgui.Spacing()
	imgui.Text(im_utf8("Радиус (м):"))
	if imgui.SliderInt("##ogk_dist", SpecBinderUi.ogk_max_dist, 0, 15, im_utf8("%d м")) then
		if SpecBinderUi.ogk_max_dist[0] < 0 then
			SpecBinderUi.ogk_max_dist[0] = 0
		end
		if SpecBinderUi.ogk_max_dist[0] > 15 then
			SpecBinderUi.ogk_max_dist[0] = 15
		end
	end
	if SpecBinderUi.ogk_max_dist[0] == 0 then
		imgui.TextColored(
			imgui.ImVec4(0.55, 0.55, 0.6, 1.0),
			im_utf8("0 м — вся зона прорисовки (без фильтра по метрам)")
		)
	end
	imgui.Spacing()
	imgui.Text(im_utf8("Положение лога:"))
	local corner_labels = {
		im_utf8("Слева сверху"),
		im_utf8("Справа сверху"),
		im_utf8("Слева снизу"),
		im_utf8("Справа снизу"),
		im_utf8("Своё положение"),
	}
	local corner_idx = (tonumber(SpecBinderUi.ogk_log_corner[0]) or 1) + 1
	if corner_idx < 1 or corner_idx > #corner_labels then
		corner_idx = 2
	end
	if imgui.BeginCombo("##ogk_corner", corner_labels[corner_idx]) then
		for i = 0, OGK_LOG_CORNER_FREE do
			if imgui.Selectable(corner_labels[i + 1], SpecBinderUi.ogk_log_corner[0] == i) then
				SpecBinderUi.ogk_log_corner[0] = i
				ogk_log_move_mode = false
			end
		end
		imgui.EndCombo()
	end
	imgui.Spacing()
	if imgui.Button(im_utf8("Изменить расположение##ogk_move_set"), imgui.ImVec2(280 * custom_dpi, 28 * custom_dpi)) then
		vig_ogk_start_log_move_mode()
	end
	imgui.TextColored(
		imgui.ImVec4(0.5, 0.55, 0.65, 1.0),
		im_utf8("Настройки скроются — перетащите окно и нажмите «Зафиксировать». Меню вернётся само.")
	)
	imgui.Spacing()
	imgui.TextColored(
		imgui.ImVec4(0.5, 0.55, 0.65, 1.0),
		im_utf8("Настройки сохраняются в VigGwarnBinder.json и остаются после перезахода на сервер.")
	)
	imgui.EndChild()
end

local log_date_expanded = {}

local function vig_render_discipline_log_content(panel_h)
	imgui.InputTextWithHint(
		"##log_search",
		im_utf8("Поиск по логу (дата, ник, статья…)"),
		SpecBinderUi.buf_log_search,
		256
	)
	local q = normalize_charbuf_input(SpecBinderUi.buf_log_search, 256)
	local sections = vig_parse_discipline_log_sections()
	local disc_counts, disc_zogs, disc_total = vig_disc_log.build(sections, q)
	vig_disc_log.render(disc_counts, disc_zogs, disc_total, q ~= "")
	local stats_h = vig_disc_log.stats_height(disc_zogs)
	imgui.Spacing()
	local list_h = vig_binder_tab_inner_height(panel_h, 32 * custom_dpi + stats_h)
	imgui.BeginChild("##discipline_log_scroll", imgui.ImVec2(0, list_h), true)
	local ok, err = pcall(function()
		if #sections == 0 then
			imgui.TextWrapped(
				im_utf8("Лог пуст. Записи появятся после выдачи спец. выговора или увольнения.")
			)
			return
		end
		local shown_dates = 0
		for i = #sections, 1, -1 do
			local sec = sections[i]
			local date_hit = vig_query_matches(sec.date, q)
			local filtered = {}
			if date_hit then
				filtered = sec.entries
			else
				for _, ent in ipairs(sec.entries) do
					if vig_query_matches(ent, q) then
						filtered[#filtered + 1] = ent
					end
				end
			end
			if date_hit or #filtered > 0 then
				local expand_key = "logdt_" .. i
				if log_date_expanded[expand_key] == nil then
					log_date_expanded[expand_key] = false
				end
				local arrow = log_date_expanded[expand_key] and "[-] " or "[+] "
				if imgui.Selectable(im_utf8(arrow .. sec.date .. "##" .. expand_key), false) then
					log_date_expanded[expand_key] = not log_date_expanded[expand_key]
				end
				if log_date_expanded[expand_key] then
					imgui.Indent()
					for j, ent in ipairs(filtered) do
						if imgui.SmallButton(im_utf8("Коп.##logcpy_" .. i .. "_" .. j)) then
							if vig_copy_text_to_clipboard(ent) then
								sampAddChatMessageUtf8(
									"{009EFF}[Vigmenu]{ffffff} Строка лога скопирована в буфер обмена.",
									message_color
								)
							end
						end
						if imgui.IsItemHovered() then
							imgui.SetTooltip(im_utf8("Копировать строку в буфер обмена"))
						end
						imgui.SameLine(0, 6 * custom_dpi)
						imgui.TextWrapped(im_utf8(tostring(ent or "")))
						imgui.Spacing()
					end
					imgui.Unindent()
				end
				shown_dates = shown_dates + 1
			end
		end
		if shown_dates == 0 then
			imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.6, 1.0), im_utf8("Ничего не найдено."))
		end
	end)
	if not ok then
		imgui.TextColored(imgui.ImVec4(1.0, 0.45, 0.45, 1.0), im_utf8("Ошибка отображения лога."))
		print("[gwarnn] лог наказаний UI: " .. tostring(err))
	end
	imgui.EndChild()
end

local function vig_render_binder_settings_tabs(panel_h)
	panel_h = panel_h or math.max(280 * custom_dpi, imgui.GetContentRegionAvail().y)
	if imgui.BeginTabBar("##binder_tabs") then
		if imgui.BeginTabItem(im_utf8("Отыгровки##binder_tab_rp")) then
			vig_render_binder_rp_tab(panel_h)
			imgui.EndTabItem()
		end
		if imgui.BeginTabItem(im_utf8("Сотрудники ОГК##binder_tab_ogk")) then
			vig_render_ogk_staff_content(panel_h)
			imgui.EndTabItem()
		end
		if imgui.BeginTabItem(im_utf8("Отображение##binder_tab_ogk_track")) then
			vig_render_ogk_tracker_settings_tab(panel_h)
			imgui.EndTabItem()
		end
		if imgui.BeginTabItem(im_utf8("Лог##binder_tab_log")) then
			vig_render_discipline_log_content(panel_h)
			imgui.EndTabItem()
		end
		if imgui.BeginTabItem(im_utf8("Обновление##binder_tab_upd")) then
			vig_render_binder_update_tab()
			imgui.EndTabItem()
		end
		imgui.EndTabBar()
	end
end

local function vig_set_log_pending(action_type, player_id, article_reason)
	vig_log_pending = {
		action_type = action_type,
		reason = tostring(article_reason or ""):gsub("^%s+", ""):gsub("%s+$", ""),
		target_id = tonumber(player_id),
		expires = os.clock() + 25,
	}
end

local function vig_try_log_from_server_message(text)
	if not vig_log_pending then
		return
	end
	if os.clock() > vig_log_pending.expires then
		vig_log_pending = nil
		return
	end

	local msg = vig_chat_to_utf8(text)
	if msg == "" then
		return
	end

	local p = vig_log_pending
	local function has_word(m, ...)
		for i = 1, select("#", ...) do
			local w = select(i, ...)
			if w and m:find(w, 1, true) then
				return true
			end
		end
		return false
	end

	if p.action_type == DISCIPLINE_ACTION_GWARN then
		if not has_word(msg, "спец", "Спец") or not has_word(msg, "выговор", "Выговор") then
			return
		end
		if not has_word(msg, "причина", "Причина") then
			return
		end
		if not vig_reason_loose_match(msg, p.reason) then
			return
		end
		vig_append_log_raw_line(msg)
		vig_log_pending = nil
		return
	end

	if p.action_type == DISCIPLINE_ACTION_FIRE then
		if not has_word(msg, "уволил", "Уволил") then
			return
		end
		if not has_word(msg, "причина", "Причина") then
			return
		end
		if not vig_reason_loose_match(msg, p.reason) then
			return
		end
		local days = clamp_fire_ban_days(gwarn_binder.fire_ban_days)
		vig_append_log_raw_line(msg .. " (" .. tostring(days) .. ")")
		vig_log_pending = nil
	end
end

local function vig_normalize_incoming_message(text)
	if type(text) == "string" then
		return text
	end
	if type(text) == "table" then
		return tostring(text.text or text[1] or text.msg or text.message or "")
	end
	return tostring(text or "")
end

local function send_discipline_command(player_id, article_reason, action_type)
	local id = tonumber(player_id)
	local chat_line = build_discipline_chat_line(id, article_reason, action_type)
	local reason = tostring(article_reason or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local script, dms
	if action_type == DISCIPLINE_ACTION_FIRE then
		script = tostring(gwarn_binder.rp_script_fire or ""):gsub("^%s+", ""):gsub("%s+$", "")
		dms = clamp_binder_delay_ms(gwarn_binder.delay_ms_fire)
	else
		script = tostring(gwarn_binder.rp_script_gwarn or ""):gsub("^%s+", ""):gsub("%s+$", "")
		dms = clamp_binder_delay_ms(gwarn_binder.delay_ms_gwarn)
	end
	local lines = split_binder_script(script)
	local function finish_discipline()
		sampSendChatUtf8(chat_line)
		vig_set_log_pending(action_type, id, reason)
	end
	if #lines == 0 or not lua_thread or not lua_thread.create then
		finish_discipline()
		return
	end
	vig_binder_rp_active = true
	vig_binder_rp_stop = false
	lua_thread.create(function()
		local stopped = false
		for i, raw in ipairs(lines) do
			if vig_binder_rp_stop then
				stopped = true
				break
			end
			local lt = raw:match("^%s*(.-)%s*$") or ""
			if lt ~= "" then
				local w = lt:match("^{wait%((%d+)%)}$")
				if w then
					wait(math.min(tonumber(w) or 0, 60000))
					if vig_binder_rp_stop then
						stopped = true
						break
					end
				else
					local out = apply_binder_placeholders(lt, id, reason)
					if out ~= "" then
						sampSendChatUtf8(out)
						wait(dms)
						if vig_binder_rp_stop then
							stopped = true
							break
						end
					end
				end
			end
		end
		vig_binder_rp_active = false
		vig_binder_rp_stop = false
		if stopped then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Отыгровка приостановлена.",
				message_color
			)
			return
		end
		finish_discipline()
	end)
end

local function ensure_json_file_exists()
	if doesFileExist(SPEC_JSON_PATH) then
		return
	end
	local f, err = io.open(SPEC_JSON_PATH, "w")
	if f then
		f:write("[]")
		f:close()
	else
		print("[gwarnn] не удалось создать VigArticles.json: " .. tostring(err))
	end
end

load_articles = function(quiet)
	ensure_json_file_exists()
	if not doesFileExist(SPEC_JSON_PATH) then
		articles_data = {}
		if not quiet then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Нет VigArticles.json. Путь: " .. SPEC_JSON_PATH,
				message_color
			)
		end
		return
	end
	local f, err = io.open(SPEC_JSON_PATH, "r")
	if not f then
		articles_data = {}
		if not quiet then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Не удалось прочитать JSON: " .. tostring(err),
				message_color
			)
		end
		return
	end
	local contents = f:read("*a")
	f:close()
	if not contents or #contents == 0 then
		articles_data = {}
		if not quiet then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} VigArticles.json пуст.", message_color)
		end
		return
	end
	local ok, data = pcall(decode_json_str, contents)
	if ok and type(data) == "table" then
		articles_data = data
		normalize_articles_root(articles_data)
		if not quiet then
			sampAddChatMessageUtf8(
				"{009EFF}[Vigmenu]{ffffff} Загружено разделов: "
					.. #articles_data
					.. " | "
					.. SPEC_JSON_PATH,
				message_color
			)
		end
	else
		articles_data = {}
		if not quiet then
			sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Ошибка разбора JSON.", message_color)
		end
	end
end

local function is_valid_target_id(id)
	id = tonumber(id)
	if not id or id < 0 or id > 999 then
		return false
	end
	local my = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))
	return id == my or sampIsPlayerConnected(id)
end

local function process_gwarn_menu_command_arg(arg)
	SPEC_JSON_PATH = get_spec_json_path()
	SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
	load_gwarn_binder_settings()
	load_articles(true)
	arg = arg and arg:match("^%s*(.-)%s*$") or ""
	if arg == "" then
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Используйте /" .. GWARN_MENU_CMD .. " [id игрока]",
			message_color
		)
		return
	end
	if not is_valid_target_id(arg) then
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Неверный ID или игрок не в сети (0–999).",
			message_color
		)
		return
	end
	spec_target_id = tonumber(arg)
	spec_menu_warned_invalid = false
	if not spec_imgui_ready then
		local ok, err = pcall(register_spec_imgui)
		if not ok then
			print("[gwarnn] ошибка register_spec_imgui: " .. tostring(err))
		end
	end
	if not spec_imgui_ready then
		sampAddChatMessageUtf8(
			"{009EFF}[Vigmenu]{ffffff} Ошибка меню ImGui (см. консоль MoonLoader).",
			message_color
		)
		return
	end
	SpecMenu.Window[0] = true
end

--- samp.events sometimes passes string, sometimes table (compat)
local function normalize_outgoing_text(text)
	if type(text) == "string" then
		return text
	end
	if type(text) == "table" then
		return tostring(text.text or text[1] or text.msg or text.message or "")
	end
	return ""
end

local function parse_slash_command(text)
	text = normalize_outgoing_text(text)
	if text == "" then
		return nil, nil
	end
	local s = text:gsub("^%s+", ""):gsub("%s+$", "")
	if s:sub(1, 1) == "/" then
		s = s:sub(2)
	end
	local cmd, a = s:match("^(%S+)%s*(.*)$")
	if not cmd then
		return nil, nil
	end
	return cmd:lower(), a or ""
end

local function try_intercept_outgoing_command(text)
	local cmd, a = parse_slash_command(text)
	if cmd == GWARN_MENU_CMD or cmd == GWARN_MENU_CMD_ALT then
		local ok, err = pcall(process_gwarn_menu_command_arg, a or "")
		if not ok then
			print("[gwarnn] ошибка обработчика /" .. GWARN_MENU_CMD .. ": " .. tostring(err))
		end
		return true
	end
	if cmd == GWARN_RELOAD_CMD then
		local ok, err = pcall(function()
			SPEC_JSON_PATH = get_spec_json_path()
			SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
			load_gwarn_binder_settings()
			load_articles(false)
		end)
		if not ok then
			print("[gwarnn] ошибка перезагрузки: " .. tostring(err))
		end
		return true
	end
	return false
end

local gwarn_inner_onSendCommand
local gwarn_inner_onServerMessage

local function gwarn_onServerMessage(color, text)
	vig_try_log_from_server_message(vig_normalize_incoming_message(text))
	if gwarn_inner_onServerMessage then
		return gwarn_inner_onServerMessage(color, text)
	end
end

local function gwarn_onSendCommand(text)
	if try_intercept_outgoing_command(text) then
		return false
	end
	if gwarn_inner_onSendCommand then
		return gwarn_inner_onSendCommand(text)
	end
end

--- Only onSendCommand (onSendChat hook broke Arizona / second message went to server)
local function ensure_sampev_hooks()
	if not sampev_ok or not sampev then
		return
	end
	if sampev.onSendCommand ~= gwarn_onSendCommand then
		gwarn_inner_onSendCommand = sampev.onSendCommand
		sampev.onSendCommand = gwarn_onSendCommand
	end
	if sampev.onServerMessage ~= gwarn_onServerMessage then
		gwarn_inner_onServerMessage = sampev.onServerMessage
		sampev.onServerMessage = gwarn_onServerMessage
	end
end

function split_text_into_lines(text, max_length)
	local lines = {}
	local current_line = ""
	for word in text:gmatch("%S+") do
		local new_line = current_line .. (current_line == "" and "" or " ") .. word
		if #new_line > max_length then
			table.insert(lines, current_line)
			current_line = word
		else
			current_line = new_line
		end
	end
	if current_line ~= "" then
		table.insert(lines, current_line)
	end
	return table.concat(lines, "\n")
end

function count_lines_in_text(text, max_length)
	local lines = {}
	local current_line = ""
	for word in text:gmatch("%S+") do
		local new_line = current_line .. (current_line == "" and "" or " ") .. word
		if #new_line > max_length then
			table.insert(lines, current_line)
			current_line = word
		else
			current_line = new_line
		end
	end
	if current_line ~= "" then
		table.insert(lines, current_line)
	end
	return #lines
end

local function vig_text_width_utf8(text)
	local ok, sz = pcall(function()
		return imgui.CalcTextSize(im_utf8(tostring(text or "")))
	end)
	if ok and sz then
		return sz.x, sz.y
	end
	return 0, 16 * custom_dpi
end

local function vig_wrap_text_for_width(text, max_width_px)
	text = tostring(text or "")
	max_width_px = math.max(80, max_width_px or 200)
	local lines = {}
	local current_line = ""
	for word in text:gmatch("%S+") do
		local candidate = current_line == "" and word or (current_line .. " " .. word)
		local w = vig_text_width_utf8(candidate)
		if w > max_width_px and current_line ~= "" then
			lines[#lines + 1] = current_line
			current_line = word
		elseif w > max_width_px then
			lines[#lines + 1] = word
			current_line = ""
		else
			current_line = candidate
		end
	end
	if current_line ~= "" then
		lines[#lines + 1] = current_line
	end
	if #lines == 0 then
		lines[1] = ""
	end
	local wrapped = table.concat(lines, "\n")
	local _, text_h = vig_text_width_utf8(wrapped)
	if text_h <= 0 then
		local max_chars = math.max(16, math.floor(max_width_px / (8 * custom_dpi)))
		wrapped = split_text_into_lines(text, max_chars)
		text_h = count_lines_in_text(text, max_chars) * 16 * custom_dpi
	end
	return wrapped, #lines, text_h
end

function imgui.GetMiddleButtonX(count)
	count = tonumber(count) or 1
	if count < 1 then
		count = 1
	end
	local width = imgui.GetContentRegionAvail().x
	if width <= 0 and imgui.GetWindowContentRegionWidth then
		width = imgui.GetWindowContentRegionWidth()
	end
	local space = imgui.GetStyle().ItemSpacing.x
	if count == 1 then
		return width
	end
	return (width - space * (count - 1)) / count
end

--- Nickname from SAMP is often CP1251; JSON fields are UTF-8 (use im_utf8).
local function im_samp_nick(s)
	local ok, r = pcall(function()
		return u8(tostring(s or ""))
	end)
	if ok and r then
		return r
	end
	return tostring(s or "")
end

--- Видимый курсор в меню; без sampToggleCursor (он блокирует ходьбу). Вариант safery_disable_cursor (HideCursor=true) на части сборок даёт пропажу курсора и залипание ввода — здесь всегда false при открытом меню.
local function vig_apply_cursor_arizona(player)
	if not SpecMenu.Window[0] then
		return
	end
	if not player then
		return
	end
	player.HideCursor = false
end

local function vig_spec_ensure_theme_once()
	if spec_theme_lazy_done then
		return
	end
	spec_theme_lazy_done = true
	local ok, err = pcall(function()
		imgui.SwitchContext()
		apply_spec_dark_theme_core()
	end)
	if not ok then
		print("[gwarnn] сбой темы в кадре: " .. tostring(err))
	end
end

function register_spec_imgui()
	if spec_imgui_ready then
		return
	end
	imgui.OnFrame(
		function()
			return SpecMenu.Window[0]
		end,
		function(player)
			vig_apply_cursor_arizona(player)
			vig_spec_ensure_theme_once()
			if not SpecMenu.Window[0] then
				return
			end
			imgui.SetNextWindowPos(imgui.ImVec2(sizeX / 2, sizeY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
			imgui.SetNextWindowSize(imgui.ImVec2(600 * custom_dpi, 413 * custom_dpi), imgui.Cond.FirstUseEver)
			imgui.SetNextWindowSizeConstraints(
				imgui.ImVec2(380 * custom_dpi, 280 * custom_dpi),
				imgui.ImVec2(sizeX, sizeY)
			)
			imgui.Begin(im_utf8("VigMenu (/" .. GWARN_MENU_CMD .. ")##spec_menu"), SpecMenu.Window, imgui.WindowFlags.NoCollapse)
			if not is_valid_target_id(spec_target_id) then
				if not spec_menu_warned_invalid then
					sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Игрок не в сети или неверный ID.", message_color)
					spec_menu_warned_invalid = true
				end
				imgui.TextWrapped(
					im_utf8("Неверный ID. Закройте меню и снова откройте через /" .. GWARN_MENU_CMD .. " [id].")
				)
				if imgui.Button(im_utf8("Закрыть##badid"), imgui.ImVec2(140 * custom_dpi, 28 * custom_dpi)) then
					SpecMenu.Window[0] = false
				end
			elseif #articles_data == 0 then
				imgui.TextColored(
					imgui.ImVec4(0.85, 0.85, 0.9, 1),
					im_utf8("Меню пусто.")
				)
				imgui.Spacing()
				imgui.TextWrapped(
					im_utf8("Отредактируйте VigArticles.json, сохраните файл, затем /" .. GWARN_RELOAD_CMD)
				)
				imgui.Spacing()
				imgui.TextWrapped(im_utf8("Или нажмите кнопку ниже, чтобы автоматически скачать статьи и обновления с GitHub."))
				if UpdateUi.busy then
					imgui.Text(im_utf8("Загрузка…"))
				else
					if imgui.Button(im_utf8("Скачать статьи с GitHub##empty_sync"), imgui.ImVec2(260 * custom_dpi, 30 * custom_dpi)) then
						vig_queue_github_update({ force_articles = true })
					end
				end
				imgui.Separator()
				imgui.TextWrapped(im_utf8("ID игрока: ") .. tostring(spec_target_id))
				if imgui.Button(im_utf8("Закрыть##empty"), imgui.ImVec2(140 * custom_dpi, 28 * custom_dpi)) then
					SpecMenu.Window[0] = false
				end
			else
				do
					local row_w = imgui.GetContentRegionAvail().x
					local cfg_w = 40 * custom_dpi
					imgui.PushItemWidth(math.max(120, row_w - cfg_w - 10 * custom_dpi))
					imgui.InputTextWithHint(
						"##input_spec",
						im_utf8("Поиск (статья / основание)"),
						SpecMenu.input,
						256
					)
					imgui.PopItemWidth()
					imgui.SameLine(0, 6 * custom_dpi)
					if imgui.Button(im_utf8("Настр.##gwarn_cfg"), imgui.ImVec2(cfg_w, 0)) then
						binder_ui_sync_from_runtime()
						SpecBinderUi.modal_open[0] = true
						imgui.OpenPopup(im_utf8(GWARN_BINDER_MODAL_TITLE))
					end
					if imgui.IsItemHovered() then
						imgui.SetTooltip(
						im_utf8(
							"Отыгровки и команды (moonloader/"
								.. VIG_DATA_DIR_NAME
								.. "/VigGwarnBinder.json)"
						)
					)
					end
				end
				imgui.SetNextWindowSizeConstraints(
					imgui.ImVec2(400 * custom_dpi, 420 * custom_dpi),
					imgui.ImVec2(sizeX, sizeY)
				)
				imgui.SetNextWindowSize(imgui.ImVec2(520 * custom_dpi, 560 * custom_dpi), imgui.Cond.FirstUseEver)
				if ogk_reopen_binder_modal then
					ogk_reopen_binder_modal = false
					SpecBinderUi.modal_open[0] = true
					imgui.OpenPopup(im_utf8(GWARN_BINDER_MODAL_TITLE))
				end
				if
					imgui.BeginPopupModal(
						im_utf8(GWARN_BINDER_MODAL_TITLE),
						SpecBinderUi.modal_open,
						imgui.WindowFlags.NoCollapse
							+ (imgui.WindowFlags.NoScrollbar or 0)
					)
				then
					imgui.TextColored(
						imgui.ImVec4(0.55, 0.75, 1.0, 1.0),
						im_utf8("Активная версия: v." .. get_local_script_version())
					)
					imgui.Separator()
					local binder_footer_btn_h = 28 * custom_dpi
					local binder_footer_pad = 8 * custom_dpi
					local binder_footer_h = binder_footer_btn_h + binder_footer_pad * 2
					local panel_h = math.max(220 * custom_dpi, imgui.GetContentRegionAvail().y - binder_footer_h)
					imgui.BeginChild("##binder_tabs_host", imgui.ImVec2(0, panel_h), false)
					vig_render_binder_settings_tabs(panel_h)
					imgui.EndChild()
					imgui.Separator()
					local footer_flags = imgui.WindowFlags and imgui.WindowFlags.NoScrollbar or 0
					local footer_st = imgui.GetStyle and imgui.GetStyle()
					local footer_old_pad
					if footer_st then
						footer_old_pad = footer_st.WindowPadding
						footer_st.WindowPadding = imgui.ImVec2(binder_footer_pad, binder_footer_pad)
					end
					imgui.BeginChild("##binder_footer", imgui.ImVec2(0, binder_footer_h), false, footer_flags)
					local footer_gap = 6 * custom_dpi
					local footer_avail_w = imgui.GetContentRegionAvail().x
					local footer_btn_w = math.floor((footer_avail_w - footer_gap) * 0.5)
					if imgui.Button(im_utf8("Сохранить##binder_save"), imgui.ImVec2(footer_btn_w, binder_footer_btn_h)) then
						binder_ui_apply_to_runtime()
						save_gwarn_binder_settings()
						sampAddChatMessageUtf8("{009EFF}[Vigmenu]{ffffff} Настройки сохранены.", message_color)
						imgui.CloseCurrentPopup()
					end
					imgui.SameLine(0, footer_gap)
					if imgui.Button(im_utf8("Отмена##binder_can"), imgui.ImVec2(footer_btn_w, binder_footer_btn_h)) then
						imgui.CloseCurrentPopup()
					end
					imgui.EndChild()
					if footer_st and footer_old_pad then
						footer_st.WindowPadding = footer_old_pad
					end
					imgui.EndPopup()
				end
				imgui.Separator()
				local list_avail = imgui.GetContentRegionAvail()
				imgui.BeginChild("##spec_articles_scroll", imgui.ImVec2(list_avail.x, list_avail.y), true)
				local input_decoded = normalize_search_input()
				for chapter_idx, chapter in ipairs(articles_data) do
					local items_t = chapter_items(chapter)
					local chapter_has_matching_item = false
					if items_t then
						for _, item in ipairs(items_t) do
							if article_row_visible(item, chapter, input_decoded) then
								chapter_has_matching_item = true
								break
							end
						end
					end
					if chapter_has_matching_item and items_t then
						if imgui.CollapsingHeader(im_utf8(chapter.name or ("Раздел " .. chapter_idx))) then
							for index, item in ipairs(items_t) do
								if article_row_visible(item, chapter, input_decoded) then
									local popup_id = "##specpop_" .. chapter_idx .. "_" .. index
									imgui.GetStyle().ButtonTextAlign = imgui.ImVec2(0.0, 0.5)
									imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.85, 0.42, 0.08, 0.55))
									local t = item.text or ""
									local reason_label = tostring(item.reason or ""):gsub("^%s+", ""):gsub("%s+$", "")
									if reason_label == "" then
										reason_label = "без основания"
									end
									local row_title = "Статья: " .. reason_label .. "\n" .. tostring(t)
									local btn_w = imgui.GetMiddleButtonX(1)
									local wrapped_title, _, title_h = vig_wrap_text_for_width(
										row_title,
										math.max(120, btn_w - 12 * custom_dpi)
									)
									local btn_h = math.max(28 * custom_dpi, title_h + 10 * custom_dpi)
									if
										imgui.Button(
											"> " .. im_utf8(wrapped_title) .. "##" .. index,
											imgui.ImVec2(btn_w, btn_h)
										)
									then
										imgui.OpenPopup(popup_id)
									end
									imgui.PopStyleColor()
									imgui.GetStyle().ButtonTextAlign = imgui.ImVec2(0.5, 0.5)
									imgui.SetNextWindowPos(
										imgui.ImVec2(sizeX / 2, sizeY / 2),
										imgui.Cond.Appearing,
										imgui.ImVec2(0.5, 0.5)
									)
									imgui.SetNextWindowSizeConstraints(
										imgui.ImVec2(430 * custom_dpi, 0),
										imgui.ImVec2(560 * custom_dpi, 320 * custom_dpi)
									)
									if
										imgui.BeginPopupModal(
											popup_id,
											nil,
											imgui.WindowFlags.NoCollapse
												+ imgui.WindowFlags.AlwaysAutoResize
										)
									then
										local close_sz = 26 * custom_dpi
										local header_y = imgui.GetCursorPosY()
										imgui.Text(im_utf8("Информация по статье"))
										imgui.SetCursorPos(
											imgui.ImVec2(
												math.max(8 * custom_dpi, imgui.GetWindowWidth() - close_sz - 8 * custom_dpi),
												header_y
											)
										)
										if
											imgui.Button(
												im_utf8("X##close_spec"),
												imgui.ImVec2(close_sz, close_sz)
											)
										then
											imgui.CloseCurrentPopup()
										end
										imgui.SetCursorPosY(math.max(imgui.GetCursorPosY(), header_y + close_sz + 4 * custom_dpi))
										imgui.Separator()
										imgui.Text(
											im_utf8("Игрок: ")
												.. im_samp_nick(sampGetPlayerNickname(spec_target_id))
												.. " ["
												.. spec_target_id
												.. "]"
										)
										imgui.Text(im_utf8("Тип: ") .. im_utf8(item.lvl))
										imgui.Text(
											im_utf8("Статья: ")
												.. im_utf8(item.reason)
										)
										local pushed_wrap = vig_push_content_text_wrap()
										imgui.TextWrapped(im_utf8(item.text))
										vig_pop_content_text_wrap(pushed_wrap)
										imgui.Separator()
										local btn_w = imgui.GetMiddleButtonX(3)
										local btn_h = 28 * custom_dpi
										if
											imgui.Button(
												im_utf8("Закрыть##spec"),
												imgui.ImVec2(btn_w, btn_h)
											)
										then
											imgui.CloseCurrentPopup()
										end
										imgui.SameLine()
										if
											imgui.Button(
												im_utf8("Выговор##spec_gwarn"),
												imgui.ImVec2(btn_w, btn_h)
											)
										then
											SpecMenu.Window[0] = false
											send_discipline_command(spec_target_id, item.reason, DISCIPLINE_ACTION_GWARN)
											imgui.CloseCurrentPopup()
										end
										imgui.SameLine()
										if
											imgui.Button(
												im_utf8("Уволить##spec_fire"),
												imgui.ImVec2(btn_w, btn_h)
											)
										then
											SpecMenu.Window[0] = false
											send_discipline_command(spec_target_id, item.reason, DISCIPLINE_ACTION_FIRE)
											imgui.CloseCurrentPopup()
										end
										imgui.EndPopup()
									end
								end
							end
						end
					end
				end
				imgui.EndChild()
			end
			imgui.End()
		end
	)
	imgui.OnFrame(
		function()
			return gwarn_binder.ogk_enabled and true or false
		end,
		function(player)
			vig_spec_ensure_theme_once()
			ogk_scan_tick = ogk_scan_tick + 1
			if ogk_scan_tick >= 12 then
				ogk_scan_tick = 0
				vig_ogk_update_scan()
			end
			if gwarn_binder.ogk_show_log or ogk_log_move_mode then
				vig_ogk_draw_log_overlay(player)
			end
		end
	)
	spec_imgui_ready = true
end

function initialize_commands()
	pcall(sampUnregisterChatCommand, GWARN_MENU_CMD)
	pcall(sampUnregisterChatCommand, GWARN_MENU_CMD_ALT)
	pcall(sampUnregisterChatCommand, GWARN_RELOAD_CMD)
	sampRegisterChatCommand(GWARN_MENU_CMD, function(arg)
		process_gwarn_menu_command_arg(arg or "")
	end)
	sampRegisterChatCommand(GWARN_MENU_CMD_ALT, function(arg)
		process_gwarn_menu_command_arg(arg or "")
	end)
	sampRegisterChatCommand(GWARN_RELOAD_CMD, function()
		SPEC_JSON_PATH = get_spec_json_path()
		SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
		load_gwarn_binder_settings()
		load_articles(false)
	end)
	if not commands_registered_log then
		commands_registered_log = true
		print(
			"[gwarnn] команды: /"
				.. GWARN_MENU_CMD
				.. " /"
				.. GWARN_MENU_CMD_ALT
				.. " /"
				.. GWARN_RELOAD_CMD
		)
	end
end

local function start_sampev_hooks_loop()
	if not lua_thread or not lua_thread.create then
		return
	end
	lua_thread.create(function()
		while true do
			wait(4000)
			pcall(ensure_sampev_hooks)
		end
	end)
end

function welcome_gwarn_message()
	local sp = thisScript and thisScript().path or "?"
	local ver_show = vig_read_script_version_from_path(sp) or SCRIPT_VERSION_TEXT
	sampAddChatMessageUtf8(
		"{009EFF}[Vigmenu]{ffffff} Создатель AlexBuhoi | версия "
			.. ver_show
			.. " | FBI/INSD/DRAKE",
		message_color
	)
	print("[gwarnn] AlexBuhoi | версия " .. ver_show .. " (файл) / константа " .. SCRIPT_VERSION_TEXT)
	print("[gwarnn] путь скрипта: " .. tostring(sp))
	print("[gwarnn] папка данных: " .. get_spec_data_dir())
	print("[gwarnn] VigArticles.json: " .. SPEC_JSON_PATH)
	print("[gwarnn] лог наказаний: " .. get_discipline_log_path())
	print("[gwarnn] манифест обновлений: " .. UPDATE_MANIFEST_URL)
	if not sampev_ok then
		print("[gwarnn] samp.events нет — работает только sampRegisterChatCommand")
	end
end

function main()
	if not isSampLoaded() or not isSampfuncsLoaded() then
		print("[gwarnn] СТОП: не загружены SAMP или sampfuncs (установите sampfuncs, запускайте в мультиплеере)")
		return
	end
	while not isSampAvailable() do
		wait(0)
	end
	if _G.VIGMENU_GWARNN_LOADED then
		print("[gwarnn] Уже запущен другой VigMenu — удалите дубликат .lua из папки moonloader (два скрипта = два сообщения в чат).")
		return
	end
	_G.VIGMENU_GWARNN_LOADED = true
	print("[gwarnn] main() OK — сначала команды, затем ImGui (так /vigmenu работает даже при сбое темы)")

	SPEC_JSON_PATH = get_spec_json_path()
	SPEC_BINDER_JSON_PATH = get_spec_binder_json_path()
	load_gwarn_binder_settings()
	load_articles(true)

	initialize_commands()
	pcall(ensure_sampev_hooks)
	if lua_thread and lua_thread.create then
		lua_thread.create(function()
			wait(1500)
			initialize_commands()
			pcall(ensure_sampev_hooks)
		end)
	end
	start_sampev_hooks_loop()
	start_update_worker_loop()

	local imgui_ok, imgui_err = pcall(register_spec_imgui)
	if not imgui_ok then
		print("[gwarnn] register_spec_imgui при старте: " .. tostring(imgui_err))
		print("[gwarnn] Меню повторится при /vigmenu; проверьте mimgui")
	end

	welcome_gwarn_message()
	vig_delayed_update_hint_after_welcome()

	while true do
		wait(0)
	end
end

function onScriptTerminate()
	_G.VIGMENU_GWARNN_LOADED = nil
	pcall(function()
		local ok, hotkey = pcall(require, "mimgui_hotkeys")
		if ok and hotkey and hotkey.RemoveHotKey then
			hotkey.RemoveHotKey(GWARN_BINDER_HOTKEY_NAME)
			hotkey.RemoveHotKey("VigMenuBinderStop")
		end
	end)
	pcall(sampUnregisterChatCommand, GWARN_MENU_CMD)
	pcall(sampUnregisterChatCommand, GWARN_MENU_CMD_ALT)
	pcall(sampUnregisterChatCommand, GWARN_RELOAD_CMD)
end
