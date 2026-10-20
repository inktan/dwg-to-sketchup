# coding: utf-8
# Build the structure in the open Rhino document and write model.3dm.
# Runs inside Rhino via _-RunPythonScript (IronPython 2.7).

import json
import math
import os
import System
import scriptcontext as sc
import Rhino

JOB_FILE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ruby", "job.txt"))


def read_job():
    job = open(JOB_FILE, "r").read().strip().replace("\\", "/")
    raw = open(job + "/floor.json", "rb").read().decode("utf-8")
    return job, json.loads(raw)


def write_result(path, obj):
    handle = open(path, "wb")
    try:
        handle.write(json.dumps(obj).encode("utf-8"))
    finally:
        handle.close()


def clean_ring(pts):
    out = []
    for p in pts or []:
        x = float(p[0])
        y = float(p[1])
        if not out or abs(out[-1][0] - x) > 0.5 or abs(out[-1][1] - y) > 0.5:
            out.append([x, y])
    if len(out) > 2 and abs(out[0][0] - out[-1][0]) <= 0.5 and abs(out[0][1] - out[-1][1]) <= 0.5:
        out.pop()
    return out


def layer_index(doc, name, rgb):
    index = doc.Layers.Find(name, True)
    if index >= 0:
        return index
    layer = Rhino.DocObjects.Layer()
    layer.Name = name
    layer.Color = System.Drawing.Color.FromArgb(int(rgb[0]), int(rgb[1]), int(rgb[2]))
    return doc.Layers.Add(layer)


def delete_previous(doc):
    ids = []
    for obj in doc.Objects:
        name = obj.Attributes.Name
        if name and name.startswith("Stru"):
            ids.append(obj.Id)
    for oid in ids:
        doc.Objects.Delete(oid, True)


def add_solid(doc, file3dm, brep, name, rgb, layer_name, scale):
    attr = Rhino.DocObjects.ObjectAttributes()
    attr.Name = name
    attr.ColorSource = Rhino.DocObjects.ObjectColorSource.ColorFromObject
    attr.ObjectColor = System.Drawing.Color.FromArgb(int(rgb[0]), int(rgb[1]), int(rgb[2]))
    file3dm.Objects.AddBrep(brep, attr)
    doc_attr = attr.Duplicate()
    doc_attr.LayerIndex = layer_index(doc, layer_name, rgb)
    brep_doc = brep.DuplicateBrep()
    if abs(scale - 1.0) > 1e-9:
        brep_doc.Transform(Rhino.Geometry.Transform.Scale(Rhino.Geometry.Point3d.Origin, scale))
    doc.Objects.AddBrep(brep_doc, doc_attr)


def beam_brep(x1, y1, z1, x2, y2, z2, width, depth):
    dx = x2 - x1
    dy = y2 - y1
    dz = z2 - z1
    plan = math.sqrt(dx * dx + dy * dy)
    length = math.sqrt(plan * plan + dz * dz)
    if plan < 50.0 or length < 50.0 or width <= 1.0 or depth <= 1.0:
        return None
    side = Rhino.Geometry.Vector3d(-dy, dx, 0.0)
    axis = Rhino.Geometry.Vector3d(dx, dy, dz)
    if not side.Unitize() or not axis.Unitize():
        return None
    down = Rhino.Geometry.Vector3d.CrossProduct(side, axis)
    if down.Z > 0.0:
        down = -down
    if not down.Unitize():
        return None
    origin = Rhino.Geometry.Point3d(
        (x1 + x2) / 2.0 + down.X * depth / 2.0,
        (y1 + y2) / 2.0 + down.Y * depth / 2.0,
        (z1 + z2) / 2.0 + down.Z * depth / 2.0,
    )
    plane = Rhino.Geometry.Plane(origin, side, axis)
    box = Rhino.Geometry.Box(
        plane,
        Rhino.Geometry.Interval(-width / 2.0, width / 2.0),
        Rhino.Geometry.Interval(-length / 2.0, length / 2.0),
        Rhino.Geometry.Interval(-depth / 2.0, depth / 2.0),
    )
    return box.ToBrep()


def steel_beam_brep(x1, y1, z1, x2, y2, z2, width, depth):
    dx = x2 - x1
    dy = y2 - y1
    dz = z2 - z1
    plan = math.sqrt(dx * dx + dy * dy)
    length = math.sqrt(plan * plan + dz * dz)
    if plan < 50.0 or length < 50.0 or width <= 1.0 or depth <= 1.0:
        return None
    side = Rhino.Geometry.Vector3d(-dy, dx, 0.0)
    axis = Rhino.Geometry.Vector3d(dx, dy, dz)
    if not side.Unitize() or not axis.Unitize():
        return None
    down = Rhino.Geometry.Vector3d.CrossProduct(side, axis)
    if down.Z > 0.0:
        down = -down
    if not down.Unitize():
        return None
    up = -down
    # 截面在起点顶面。局部 x 为梁宽，局部 y 朝截面上方，法向即梁轴。
    plane = Rhino.Geometry.Plane(Rhino.Geometry.Point3d(x1, y1, z1), side, up)
    hw = width / 2.0
    tw = max(depth * 0.02, 5.0) / 2.0
    tf = min(max(depth * 0.04, 6.0), depth * 0.4)
    outline = [
        (-hw, 0.0),
        (-hw, -tf),
        (-tw, -tf),
        (-tw, -(depth - tf)),
        (-hw, -(depth - tf)),
        (-hw, -depth),
        (hw, -depth),
        (hw, -(depth - tf)),
        (tw, -(depth - tf)),
        (tw, -tf),
        (hw, -tf),
        (hw, 0.0),
    ]
    pline = Rhino.Geometry.Polyline()
    for u, v in outline:
        pline.Add(plane.PointAt(u, v))
    pline.Add(plane.PointAt(outline[0][0], outline[0][1]))
    curve = pline.ToPolylineCurve()
    if curve.ClosedCurveOrientation(plane.ZAxis) == Rhino.Geometry.CurveOrientation.Clockwise:
        curve.Reverse()
    extrusion = Rhino.Geometry.Extrusion.Create(curve, length, True)
    if extrusion is None:
        return None
    return extrusion.ToBrep()


def ring_brep(pts, z0, height):
    ring = clean_ring(pts)
    if len(ring) < 3 or height <= 1.0:
        return None
    pline = Rhino.Geometry.Polyline()
    for p in ring:
        pline.Add(float(p[0]), float(p[1]), float(z0))
    pline.Add(float(ring[0][0]), float(ring[0][1]), float(z0))
    curve = pline.ToPolylineCurve()
    orientation = curve.ClosedCurveOrientation(Rhino.Geometry.Vector3d.ZAxis)
    if orientation == Rhino.Geometry.CurveOrientation.Clockwise:
        curve.Reverse()
    extrusion = Rhino.Geometry.Extrusion.Create(curve, height, True)
    if extrusion is None:
        return None
    return extrusion.ToBrep()


def point_z(pt, fallback):
    if pt is not None and len(pt) >= 3:
        return float(pt[2])
    return fallback


def column_top(col, story):
    try:
        top = float(col.get("top"))
    except Exception:
        return story
    if top > 1.0:
        return top
    return story


def circle_brep(cx, cy, radius, height):
    if radius <= 1.0 or height <= 1.0:
        return None
    plane = Rhino.Geometry.Plane(Rhino.Geometry.Point3d(cx, cy, 0.0), Rhino.Geometry.Vector3d.ZAxis)
    circle = Rhino.Geometry.Circle(plane, radius)
    cylinder = Rhino.Geometry.Cylinder(circle, height)
    return cylinder.ToBrep(True, True)


def main():
    job, data = read_job()
    result_path = job + "/rhino_result.json"
    model_path = job + "/model.3dm"
    doc = sc.doc
    story = float(data.get("story") or 3000)
    slab_t = float(data.get("slab_thick") or 130)
    scale = Rhino.RhinoMath.UnitScale(Rhino.UnitSystem.Millimeters, doc.ModelUnitSystem)
    file3dm = Rhino.FileIO.File3dm()
    file3dm.Settings.ModelUnitSystem = Rhino.UnitSystem.Millimeters
    delete_previous(doc)

    beam_rgb = [79, 109, 122]
    slope_rgb = [62, 122, 92]
    steel_rgb = [146, 152, 160]
    col_rgb = [90, 94, 99]
    wall_rgb = [196, 184, 166]
    slab_rgb = [168, 196, 188]
    beam_n = 0
    slope_n = 0
    col_n = 0
    wall_n = 0

    for beam in data.get("beams") or []:
        pts = beam.get("pts") or []
        width = float(beam.get("w") or 200)
        depth = float(beam.get("h") or 500)
        rise = float(beam.get("rise") or 0)
        steel = beam.get("steel") is True
        z_top = story + rise
        for i in range(len(pts) - 1):
            z1 = point_z(pts[i], z_top)
            z2 = point_z(pts[i + 1], z_top)
            x1 = float(pts[i][0])
            y1 = float(pts[i][1])
            x2 = float(pts[i + 1][0])
            y2 = float(pts[i + 1][1])
            brep = steel_beam_brep(x1, y1, z1, x2, y2, z2, width, depth) if steel else beam_brep(x1, y1, z1, x2, y2, z2, width, depth)
            if brep is None:
                continue
            beam_n += 1
            sloped = beam.get("slope") is True and (abs(z1 - z2) > 50.0 or abs(z1 - z_top) > 50.0)
            if steel:
                if sloped:
                    slope_n += 1
                add_solid(doc, file3dm, brep, "StruSteelBeam_%03d" % beam_n, steel_rgb, u"结构-钢梁", scale)
            elif sloped:
                slope_n += 1
                add_solid(doc, file3dm, brep, "StruSlopeBeam_%03d" % slope_n, slope_rgb, u"结构-斜梁", scale)
            else:
                add_solid(doc, file3dm, brep, "StruBeam_%03d" % beam_n, beam_rgb, u"结构-梁", scale)

    for col in data.get("columns") or []:
        brep = None
        if col.get("kind") == "circle":
            center = col.get("c") or [0, 0]
            brep = circle_brep(float(center[0]), float(center[1]), float(col.get("r") or 0), column_top(col, story))
        else:
            brep = ring_brep(col.get("pts") or [], 0.0, column_top(col, story))
        if brep is None:
            continue
        col_n += 1
        add_solid(doc, file3dm, brep, "StruCol_%03d" % col_n, col_rgb, u"结构-柱", scale)

    for wall in data.get("walls") or []:
        brep = ring_brep(wall.get("pts") or [], 0.0, story)
        if brep is None:
            continue
        wall_n += 1
        add_solid(doc, file3dm, brep, "StruWall_%03d" % wall_n, wall_rgb, u"结构-墙", scale)

    slab_n = 0
    loops = data.get("slabs") or []
    if not loops and data.get("slab_rect"):
        rect = data.get("slab_rect")
        loops = [{"pts": [[rect[0], rect[1]], [rect[2], rect[1]], [rect[2], rect[3]], [rect[0], rect[3]]]}]
    z_bot = story - slab_t
    for item in loops:
        pts = item.get("pts") if isinstance(item, dict) else item
        brep = ring_brep(pts or [], z_bot, slab_t)
        if brep is None:
            continue
        slab_n += 1
        add_solid(doc, file3dm, brep, "StruSlab_%03d" % slab_n, slab_rgb, u"结构-楼板", scale)

    options = Rhino.FileIO.File3dmWriteOptions()
    options.Version = 7
    written = file3dm.Write(model_path, options)
    doc.Views.Redraw()
    if not written:
        raise Exception("Rhino did not write model.3dm")
    write_result(result_path, {
        "ok": True,
        "beams": beam_n,
        "slope": slope_n,
        "columns": col_n,
        "walls": wall_n,
        "slab": 1 if slab_n else 0,
    })


try:
    main()
except Exception as ex:
    try:
        job = open(JOB_FILE, "r").read().strip().replace("\\", "/")
        write_result(job + "/rhino_result.json", {"ok": False, "error": str(ex)})
    except Exception:
        pass
    raise
