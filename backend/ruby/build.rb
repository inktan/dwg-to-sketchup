# encoding: UTF-8
# Build beams, columns, walls and a slab from floor.json, place them in the
# open SketchUp model, and write that component out as model.skp.

require 'json'

JOB_FILE = 'C:/set/dwg-to-sketchup/backend/ruby/job.txt'

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
  layer_col = tag_for(model, '结构-柱')
  layer_wall = tag_for(model, '结构-墙')
  layer_slab = tag_for(model, '结构-楼板')
  mat_beam = material_for(model, '梁-混凝土', [79, 109, 122], 1.0)
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
  data['beams'].each_with_index do |beam, i|
    pts = beam['pts']
    width = beam['w'].to_f
    depth = beam['h'].to_f
    rise = beam['rise'].to_f
    z_top = story + rise
    (0...(pts.length - 1)).each do |k|
      x1 = pts[k][0].to_f
      y1 = pts[k][1].to_f
      x2 = pts[k + 1][0].to_f
      y2 = pts[k + 1][1].to_f
      len = Math.hypot(x2 - x1, y2 - y1)
      next if len < 50.0
      g = beams_g.entities.add_group
      hw = width.mm / 2.0
      face = g.entities.add_face(
        Geom::Point3d.new(0, -hw, -depth.mm),
        Geom::Point3d.new(len.mm, -hw, -depth.mm),
        Geom::Point3d.new(len.mm, hw, -depth.mm),
        Geom::Point3d.new(0, hw, -depth.mm)
      )
      if face.nil?
        g.erase!
        next
      end
      face.reverse! if face.normal.z < 0
      face.pushpull(depth.mm)
      g.transform!(
        Geom::Transformation.translation([x1.mm, y1.mm, z_top.mm]) *
        Geom::Transformation.rotation(ORIGIN, Z_AXIS, Math.atan2(y2 - y1, x2 - x1))
      )
      g.name = format('梁_%03d', i + 1)
      g.layer = layer_beam
      g.material = mat_beam
      beam_n += 1
    end
  end

  col_n = 0
  data['columns'].each_with_index do |col, i|
    g = cols_g.entities.add_group
    ok = false
    if col['kind'] == 'circle'
      center = Geom::Point3d.new(col['c'][0].to_f.mm, col['c'][1].to_f.mm, 0)
      edges = g.entities.add_circle(center, Z_AXIS, col['r'].to_f.mm, 24)
      face = g.entities.add_face(edges)
      if face
        face.reverse! if face.normal.z < 0
        face.pushpull(story.mm)
        ok = true
      end
    else
      ok = extrude_ring(g.entities, col['pts'], 0, story)
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

  write_result(result_path, ok: true, beams: beam_n, columns: col_n, walls: wall_n, slab: 1, bytes: File.size(skp_path))
rescue StandardError => e
  model.abort_operation if started
  write_result(result_path, ok: false, error: "#{e.class}: #{e.message}")
  raise
end
