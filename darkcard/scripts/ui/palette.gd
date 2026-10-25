class_name UiPalette
extends RefCounted

const BG_TOP := Color("#0B1020")
const BG_BOTTOM := Color("#141C2E")
const PANEL := Color("#182033")
const PANEL_SOFT := Color("#111828")
const LINE := Color("#2A3550")
const TEXT := Color("#E9EDF7")
const DIM := Color("#93A0B8")
const GOLD := Color("#E8C07A")
const GOLD_DEEP := Color("#B98B3E")
const RED := Color("#E4572E")
const TEAL := Color("#3FBF9F")
const BLUE := Color("#5B8DEF")
const PURPLE := Color("#8E7BE8")


static func category_color(d: SkillDef) -> Color:
    if d.tags.has("combo"):
        return PURPLE
    if d.tags.has("attack"):
        return RED
    if d.tags.has("defense"):
        return BLUE
    if d.tags.has("heal"):
        return TEAL
    return GOLD


static func category_glyph(d: SkillDef) -> String:
    if d.tags.has("combo"):
        return "★"
    if d.tags.has("attack"):
        return "▲"
    if d.tags.has("defense"):
        return "◆"
    if d.tags.has("heal"):
        return "✚"
    return "●"


static func gradient(c1: Color, c2: Color) -> GradientTexture2D:
    var g := Gradient.new()
    g.set_color(0, c1)
    g.set_color(1, c2)
    var t := GradientTexture2D.new()
    t.gradient = g
    t.width = 64
    t.height = 64
    t.fill_from = Vector2(0, 0)
    t.fill_to = Vector2(0, 1)
    return t


static func radial(c: Color, alpha: float) -> GradientTexture2D:
    var g := Gradient.new()
    g.set_color(0, Color(c.r, c.g, c.b, alpha))
    g.set_color(1, Color(c.r, c.g, c.b, 0.0))
    var t := GradientTexture2D.new()
    t.gradient = g
    t.width = 256
    t.height = 256
    t.fill = GradientTexture2D.FILL_RADIAL
    t.fill_from = Vector2(0.5, 0.5)
    t.fill_to = Vector2(1.0, 1.0)
    return t


static func panel_box(bg: Color = PANEL, radius: int = 16, border: Color = LINE) -> StyleBoxFlat:
    var sb := StyleBoxFlat.new()
    sb.bg_color = bg
    sb.border_color = border
    sb.set_border_width_all(1)
    sb.set_corner_radius_all(radius)
    sb.shadow_color = Color(0, 0, 0, 0.35)
    sb.shadow_size = 10
    sb.shadow_offset = Vector2(0, 4)
    sb.set_content_margin_all(12)
    return sb
