------------------------------------------------------------------
-- Luakit formfiller                                            --
-- © 2011 Fabian Streitel (karottenreibe) <luakit@rottenrei.be> --
-- © 2011 Mason Larobina  (mason-l) <mason.larobina@gmail.com>  --
------------------------------------------------------------------

local lousy = require("lousy")
local window = require("window")
local editor = require("editor")
local new_mode = require("modes").new_mode
local binds = require("binds")
local add_binds = binds.add_binds
local menu_binds = binds.menu_binds
local capi = { luakit = luakit }

--- Provides functionaliy to auto-fill forms based on a Lua DSL.
-- The configuration is stored in $XDG_DATA_DIR/luakit/forms.lua
--
-- The following is an example for a formfiller definition:
--
-- <pre>
-- <br>  on "luakit.org" {
-- <br>    form "profile1" {
-- <br>      method = "post",
-- <br>      action = "/login",
-- <br>      className = "someFormClass",
-- <br>      id = "form_id",
-- <br>      input {
-- <br>        name = "username",
-- <br>        type = "text",
-- <br>        className = "someClass",
-- <br>        id = "username_field",
-- <br>        value = "myUsername",
-- <br>      },
-- <br>      input {
-- <br>        name = "password",
-- <br>        value = "myPassword",
-- <br>      },
-- <br>      input {
-- <br>        name = "autologin",
-- <br>        type = "checkbox",
-- <br>        checked = true,
-- <br>      },
-- <br>      submit = true,
-- <br>    },
-- <br>  }
-- </pre>
--
-- <ul>
-- <li> The <code>form</code> function's string argument is optional.
--      It allows you to define multiple profiles for use with the
--      <code>zL</code> binding.
-- <li> All entries are matched top to bottom, until one fully matches
--      or calls <code>submit()</code>.
-- <li> The <code>submit</code> attribute of a form can also be a number, which
--      gives index of the submit button to click (starting with <code>1</code>).
--      If there is no such button ore the argument is <code>true</code>,
--      <code>form.submit()</code> will be called instead.
-- <li> Instead of <code>submit</code>, you can also use <code>focus = true</code>
--      inside an <code>input</code> to focus that element or <code>select = true</code>
--      to select the text inside it.
--      <code>focus</code> will trigger input mode.
-- <li> The string argument to the <code>on</code> function and all of
--      the attributes of the <code>form</code> and <code>input</code>
--      tables take JavaScript regular expressions.
--      BEWARE their escaping!
-- </ul>
--
-- There is a conversion script in the luakit repository that converts
-- from the old formfiller format to the new one. For more information,
-- see the converter script under <code>extras/convert_formfiller.rb</code>
--

local formfiller_wm = require_web_module("formfiller_wm")

-- The Lua DSL file containing the formfiller rules
local file = capi.luakit.data_dir .. "/forms.lua"

-- The function environment for the formfiller script
local DSL = {
    print = function (_, ...) print(...) end,

    -- DSL method to match a page by its URI
    on = function (s, pattern)
        return function (forms)
            table.insert(s.rules, {
                pattern = pattern,
                forms = forms,
            })
        end
    end,

    -- DSL method to match a form by its attributes
    form = function (_, data)
        local transform = function (inputs, profile)
            local form = {
                profile = profile,
                inputs = {},
            }
            for k, v in pairs(inputs) do
                if type(k) == "number" then
                    form.inputs[k] = v
                else
                    form[k] = v
                end
            end
            return form
        end
        if type(data) == "string" then
            local profile = data
            return function (inputs)
                return transform(inputs, profile)
            end
        else
            return transform(data)
        end
    end,

    -- DSL method to match an input element by its attributes
    input = function (_, attrs)
        return attrs
    end,
}

local function pattern_from_js_regex(re)
    -- TODO: This needs work
    local special = ".-+*?^$%"
    re = re:gsub("%%", "%%%%")
    for c in special:gmatch"." do
        re = re:gsub("\\%" .. c, "%%" .. c)
    end
    return re
end

--- Reads the rules from the formfiller DSL file
local function read_formfiller_rules_from_file()
    local state = {
        rules = {},
    }
    -- the environment of the DSL script
    -- load the script
    local f = io.open(file, "r")
    if not f then return end -- file doesn't exist
    local code = f:read("*all")
    f:close()
    local dsl, message = loadstring(code)
    if not dsl then
        msg.warn(string.format("loading formfiller data failed: %s", message))
        return
    end
    -- execute in sandbox
    local env = {}
    -- wrap the DSL functions so they can access the state
    for k in pairs(DSL) do
        env[k] = function (...) return DSL[k](state, ...) end
    end
    setfenv(dsl, env)
    local success, err = pcall(dsl)
    if not success then
        msg.warn("error in " .. file .. ": " .. err)
    end
    -- Convert JS regexes to Lua patterns
    for _, rule in ipairs(state.rules) do
        rule.pattern = pattern_from_js_regex(rule.pattern)
        for _, form in ipairs(rule.forms) do
            form.action = form.action:gsub("\\", "")
        end
    end
    return state.rules
end

local function form_specs_for_uri (all_rules, uri)
    -- Filter rules to the given uri
    local rules = lousy.util.table.filter_array(all_rules, function(_, rule)
        return string.find(uri, rule.pattern)
    end)

    -- Get list of all form specs that can be matched
    local form_specs = {}
    for _, rule in ipairs(rules) do
        for _, form in ipairs(rule.forms) do
            form_specs[#form_specs + 1] = form
        end
    end

    return form_specs
end

--- Edits the formfiller rules.
local function edit()
    editor.edit(file)
end

local function w_from_view_id(view_id)
    assert(type(view_id) == "number", type(view_id))
    for _, w in pairs(window.bywidget) do
        if w.view.id == view_id then return w end
    end
end

formfiller_wm:add_signal("failed", function (_, view_id, msg)
    local w = w_from_view_id(view_id)
    w:error(msg)
    w:set_mode()
end)
formfiller_wm:add_signal("add", function (_, view_id, str)
    local w = w_from_view_id(view_id)
    w:set_mode()
    local f = io.open(file, "a")
    f:write(str)
    f:close()
    edit()
end)

--- Fills the current page from the formfiller rules.
-- @param w The window on which to fill the forms
local function fill_form_fast(w)
    local rules = read_formfiller_rules_from_file(w)
    local form_specs = form_specs_for_uri(rules, w.view.uri)
    if #form_specs == 0 then
        w:error("no rules matched")
        return
    end
    formfiller_wm:emit_signal(w.view, "fill-fast", form_specs)
end

-- Support for choosing a form with a menu
local function fill_form_menu(w)
    local rules = read_formfiller_rules_from_file(w)
    local form_specs = form_specs_for_uri(rules, w.view.uri)
    if #form_specs == 0 then
        w:error("no rules matched")
        return
    end
    formfiller_wm:emit_signal(w.view, "filter", form_specs)
end

formfiller_wm:add_signal("filter", function (_, view_id, form_specs)
    local w = w_from_view_id(view_id)
    -- Build menu
    local menu = {}
    for _, form in ipairs(form_specs) do
        if form.profile then
            table.insert(menu, { form.profile, form = form })
        end
    end
    -- show menu if necessary
    if #menu == 0 then
        w:error("no forms with profile names found")
    else
        w:set_mode("formfiller-menu", menu)
    end
end)

-- Add formfiller menu mode
new_mode("formfiller-menu", {
    enter = function (w, menu)
        local rows = {{ "Profile", title = true }}
        for _, m in ipairs(menu) do
            table.insert(rows, m)
        end
        w.menu:build(rows)
    end,

    leave = function (w)
        w.menu:hide()
    end,
})

local key = lousy.bind.key
add_binds("formfiller-menu", lousy.util.table.join({
    -- use profile
    key({}, "Return", "Select formfiller profile.",
        function (w)
            local row = w.menu:get()
            local form = row.form
            w:set_mode()
            formfiller_wm:emit_signal(w.view, "apply_form", form)
        end),
}, menu_binds))

-- Visual form selection for adding a form
new_mode("formfiller-add", {
    enter = function (w)
        w:set_prompt("Add form:")
        w:set_input("")
        w:set_ibar_theme()

        formfiller_wm:emit_signal(w.view, "enter")
    end,

    changed = function (w, text)
        formfiller_wm:emit_signal(w.view, "changed", text)
    end,

    leave = function (w)
        w:set_ibar_theme()
        formfiller_wm:emit_signal(w.view, "leave")
    end,
})
add_binds("formfiller-add", {
    key({},          "Tab",    function (w) formfiller_wm:emit_signal(w.view, "focus",  1) end),
    key({"Shift"},   "Tab",    function (w) formfiller_wm:emit_signal(w.view, "focus", -1) end),
    key({},          "Return", function (w) formfiller_wm:emit_signal(w.view, "select") end),
})

-- Setup formfiller binds
local buf = lousy.bind.buf
add_binds("normal", {
    buf("^za$", "Add formfiller form.",
        function (w) w:set_mode("formfiller-add") end),

    buf("^ze$", "Edit formfiller forms for current domain.",
        function (_) edit() end),

    buf("^zl$", "Load formfiller form (use first profile).",
        fill_form_fast),

    buf("^zL$", "Load formfiller form.",
        fill_form_menu),
})
