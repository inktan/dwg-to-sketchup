# encoding: UTF-8
# Build beams, columns, walls and a slab from floor.json, place them in the
# open SketchUp model, and write that component out as model.skp.

require 'json'

JOB_FILE = File.expand_path('job.txt', File.dirname(__FILE__))

def write_result(path, obj)
  File.write(path, JSON.generate(obj), encoding: 'UTF-8')
end

def tag_for(model, name)
  layer = model.layers[name] || model.layers.add(name)
  layer.visible = true
  layer
end

def material_for(model, name, rgb, alpha)
  mat = model.materials[name] || model.materials.add(name)
  mat.color = Sketchup::Color.new(*rgb)
  mat.alpha = alpha
  mat
end

def clean_ring(pts)
  out = []
  pts.each do |p|
    x = p[0].to_f
    y = p[1].to_f
    if out.empty? || (out.last[0] - x).abs > 0.5 || (out.last[1] - y).abs > 0.5
      out << [x, y]
    end
  end
  if out.length > 2 && (out[0][0] - out[-1][0]).abs <= 0.5 && (out[0][1] - out[-1][1]).abs <= 0.5
    out.pop
  end
  out
end

def beam_end_z(pt, fallback)
  return fallback if pt.nil? || pt.length < 3
  pt[2].to_f
end

def place_beam(group, x1, y1, z1, x2, y2, z2)
  dx = x2 - x1
  dy = y2 - y1
  dz = z2 - z1
  plan = Math.hypot(dx, dy)
  return nil if plan < 50.0
  axis = Math.hypot(plan, dz)
  return nil if axis < 50.0
  group.transform!(
    Geom::Transformation.translation([x1.mm, y1.mm, z1.mm]) *
    Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math.atan2(dy, dx)) *
    Geom::Transformation.rotation(ORIGIN, Y_AXIS, -Math.atan2(dz, plan))
  )
  axis
end

def extrude_ring(entities, pts, z0_mm, height_mm)
  ring = clean_ring(pts)
  return nil if ring.length < 3
  sp = ring.map { |p| Geom::Point3d.new(p[0].mm, p[1].mm, z0_mm.mm) }
  face = entities.add_face(sp)
  return nil if face.nil?
  face.reverse! if face.normal.z < 0
  face.pushpull(height_mm.mm)
  true
end

# 在 x = 0 平面上生成工字形钢梁截面（顶部在 z = 0，沿 -z 向下）。
def add_steel_face(entities, width, depth)
  return nil if width <= 1.0 || depth <= 1.0
  hw = width.mm / 2.0
  tw = [depth * 0.02, 5.0].max.mm / 2.0
  tf = [[depth * 0.04, 6.0].max, depth * 0.4].min.mm
  d = depth.mm
  entities.add_face(
    Geom::Point3d.new(0, -hw, 0),
    Geom::Point3d.new(0, -hw, -tf),
    Geom::Point3d.new(0, -tw, -tf),
    Geom::Point3d.new(0, -tw, -(d - tf)),
    Geom::Point3d.new(0, -hw, -(d - tf)),
    Geom::Point3d.new(0, -hw, -d),
    Geom::Point3d.new(0, hw, -d),
    Geom::Point3d.new(0, hw, -(d - tf)),
    Geom::Point3d.new(0, tw, -(d - tf)),
    Geom::Point3d.new(0, tw, -tf),
    Geom::Point3d.new(0, hw, -tf),
    Geom::Point3d.new(0, hw, 0)
  )
end

job = File.read(JOB_FILE, encoding: 'UTF-8').strip.tr('\\', '/')
data_path = File.join(job, 'floor.json')
result_path = File.join(job, 'build_result.json')
skp_path = File.join(job, 'model.skp')
model = Sketchup.active_model
started = false

begin
  data = JSON.parse(File.read(data_path, encoding: 'UTF-8'))
  story = data['story'].to_f
  slab_t = data['slab_thick'].to_f
  rect = data['slab_rect']

  model.start_operation('DWG生成结构模型', true)
  started = true

  model.entities.to_a.each do |ent|
    next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
    ent.erase! if ent.name == '8号楼_标准层' || ent.name == '结构模型'
  end
  model.definitions.purge_unused

  layer_beam = tag_for(model, '结构-梁')
  layer_slope = tag_for(model, '结构-斜梁')
  layer_col = tag_for(model, '结构-柱')
  layer_wall = tag_for(model, '结构-墙')
  layer_slab = tag_for(model, '结构-楼板')
  layer_steel = tag_for(model, '结构-钢梁')
  mat_beam = material_for(model, '梁-混凝土', [79, 109, 122], 1.0)
  mat_slope = material_for(model, '梁-坡屋面', [62, 122, 92], 1.0)
  mat_steel = material_for(model, '梁-钢', [146, 152, 160], 1.0)
  mat_col = material_for(model, '柱-混凝土', [90, 94, 99], 1.0)
  mat_wall = material_for(model, '墙-混凝土', [196, 184, 166], 1.0)
  mat_slab = material_for(model, '楼板-混凝土', [168, 196, 188], 0.55)

  defn_name = "结构模型_#{Time.now.strftime('%H%M%S')}"
  defn = model.definitions.add(defn_name)
  ents = defn.entities

  beams_g = ents.add_group
  beams_g.name = '梁'
  cols_g = ents.add_group
  cols_g.name = '柱'
  walls_g = ents.add_group
  walls_g.name = '墙'
  slab_g = ents.add_group
  slab_g.name = '楼板'

  beam_n = 0
  slope_n = 0
  data['beams'].each_with_index do |beam, i|
    pts = beam['pts']
    width = beam['w'].to_f
    depth = beam['h'].to_f
    rise = beam['rise'].to_f
    z_top = story + rise
    steel = beam['steel'] == true
    (0...(pts.length - 1)).each do |k|
      x1 = pts[k][0].to_f
      y1 = pts[k][1].to_f
      x2 = pts[k + 1][0].to_f
      y2 = pts[k + 1][1].to_f
      z1 = beam_end_z(pts[k], z_top)
      z2 = beam_end_z(pts[k + 1], z_top)
      g = beams_g.entities.add_group
      hw = width.mm / 2.0
      axis = Math.hypot(Math.hypot(x2 - x1, y2 - y1), z2 - z1)
      if steel
        face = add_steel_face(g.entities, width, depth)
      else
        face = g.entities.add_face(
          Geom::Point3d.new(0, -hw, -depth.mm),
          Geom::Point3d.new(axis.mm, -hw, -depth.mm),
          Geom::Point3d.new(axis.mm, hw, -depth.mm),
          Geom::Point3d.new(0, hw, -depth.mm)
        )
      end
      if face.nil?
        g.erase!
        next
      end
      if steel
        face.reverse! if face.normal.x < 0
        face.pushpull(axis.mm)
      else
        face.reverse! if face.normal.z < 0
        face.pushpull(depth.mm)
      end
      placed = place_beam(g, x1, y1, z1, x2, y2, z2)
      if placed.nil?
        g.erase!
        next
      end
      sloped = beam['slope'] == true && ((z1 - z2).abs > 50.0 || (z1 - z_top).abs > 50.0)
      if steel
        g.name = format('钢梁_%03d', i + 1)
        g.layer = layer_steel
        g.material = mat_steel
        slope_n += 1 if sloped
      elsif sloped
        g.name = format('斜梁_%03d', i + 1)
        g.layer = layer_slope
        g.material = mat_slope
        slope_n += 1
      else
        g.name = format('梁_%03d', i + 1)
        g.layer = layer_beam
        g.material = mat_beam
      end
      beam_n += 1
    end
  end

  col_n = 0
  data['columns'].each_with_index do |col, i|
    g = cols_g.entities.add_group
    ok = false
    if col['kind'] == 'circle'
      top = col['top'] ? col['top'].to_f : story
      top = story if top < 1.0
      center = Geom::Point3d.new(col['c'][0].to_f.mm, col['c'][1].to_f.mm, 0)
      edges = g.entities.add_circle(center, Z_AXIS, col['r'].to_f.mm, 24)
      face = g.entities.add_face(edges)
      if face
        face.reverse! if face.normal.z < 0
        face.pushpull(top.mm)
        ok = true
      end
    else
      top = col['top'] ? col['top'].to_f : story
      top = story if top < 1.0
      ok = extrude_ring(g.entities, col['pts'], 0, top)
    end
    if ok
      g.name = format('柱_%03d', i + 1)
      g.layer = layer_col
      g.material = mat_col
      col_n += 1
    else
      g.erase!
    end
  end

  wall_n = 0
  data['walls'].each_with_index do |wall, i|
    g = walls_g.entities.add_group
    if extrude_ring(g.entities, wall['pts'], 0, story)
      g.name = format('墙_%03d', i + 1)
      g.layer = layer_wall
      g.material = mat_wall
      wall_n += 1
    else
      g.erase!
    end
  end

  z_bot = story - slab_t
  slab_loops = data['slabs']
  drew_slab = false
  if slab_loops.is_a?(Array) && !slab_loops.empty?
    slab_loops.each_with_index do |item, i|
      pts = item.is_a?(Hash) ? item['pts'] : item
      g = slab_g.entities.add_group
      if extrude_ring(g.entities, pts, z_bot, slab_t)
        g.name = format('楼板_%03d', i + 1)
        g.layer = layer_slab
        g.material = mat_slab
        drew_slab = true
      else
        g.erase!
      end
    end
  end
  unless drew_slab
    slab = slab_g.entities.add_group
    face = slab.entities.add_face(
      Geom::Point3d.new(rect[0].to_f.mm, rect[1].to_f.mm, z_bot.mm),
      Geom::Point3d.new(rect[2].to_f.mm, rect[1].to_f.mm, z_bot.mm),
      Geom::Point3d.new(rect[2].to_f.mm, rect[3].to_f.mm, z_bot.mm),
      Geom::Point3d.new(rect[0].to_f.mm, rect[3].to_f.mm, z_bot.mm)
    )
    raise '楼板轮廓未能成面' if face.nil?
    face.reverse! if face.normal.z < 0
    face.pushpull(slab_t.mm)
    slab.name = '楼板_标准层'
    slab.layer = layer_slab
    slab.material = mat_slab
  end

  inst = model.entities.add_instance(defn, Geom::Transformation.new)
  inst.name = '结构模型'
  model.commit_operation
  started = false

  File.delete(skp_path) if File.exist?(skp_path)
  saved = defn.respond_to?(:save_as) && defn.save_as(skp_path)
  unless saved && File.exist?(skp_path)
    saved = model.save(skp_path)
  end
  raise 'SketchUp 没有写出 skp 文件' unless saved && File.exist?(skp_path)

  model.selection.clear
  model.selection.add(inst)
  model.active_view.zoom(inst)

  write_result(result_path, ok: true, beams: beam_n, slope: slope_n, columns: col_n, walls: wall_n, slab: 1, bytes: File.size(skp_path))
rescue StandardError => e
  model.abort_operation if started
  write_result(result_path, ok: false, error: "#{e.class}: #{e.message}")
  raise
end
