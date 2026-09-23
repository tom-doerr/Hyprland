-- A private portrait desktop for testing the native scrolling layout.
local root = assert(os.getenv("HYPRLAND_NESTED_ROOT"))
local terminal = string.format("%q/scripts/nested/terminal.sh", root)

hl.monitor({ output = "", mode = "900x1400@60", position = "auto", scale = 1 })
hl.config({
    general = { layout = "scrolling", gaps_in = 6, gaps_out = 12, border_size = 2 },
    scrolling = { direction = "down", column_width = 0.5, fullscreen_on_one_column = false },
    input = { follow_mouse = 0 },
    decoration = { rounding = 8, blur = { enabled = false } },
    animations = { enabled = true },
    cursor = { no_hardware_cursors = 1 },
    render = { direct_scanout = 0 },
    xwayland = { enabled = false },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
})

hl.bind("ALT + Return", hl.dsp.exec_cmd(terminal))
hl.bind("ALT + Q", hl.dsp.window.close())
hl.bind("ALT + SHIFT + Escape", hl.dsp.exit())
for _, direction in ipairs({ "up", "down", "left", "right" }) do
    hl.bind("ALT + " .. direction, hl.dsp.focus({ direction = direction }))
end
hl.bind("ALT + S", function() hl.config({ general = { layout = "scrolling" } }) end)
hl.bind("ALT + D", function() hl.config({ general = { layout = "dwindle" } }) end)
hl.bind("ALT + M", function() hl.config({ general = { layout = "master" } }) end)
