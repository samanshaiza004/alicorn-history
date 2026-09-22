package main

import alicorn "vendor/alicorn/runtime"

// Keep the graph gutter narrow for ordinary linear histories, but widen it as
// branch concurrency grows. The upper bound preserves useful commit-title
// space in the fixed-width History pane; very dense graphs compress lanes.
history_dag_gutter_width :: proc(lane_count: int) -> f32 {
	lanes := max(1, lane_count)
	return min(150, max(44, 16 + f32(lanes)*14))
}

history_dag_lane_color :: proc(lane: int) -> alicorn.Color {
	switch lane % 6 {
	case 0: return alicorn.Color{0.28, 0.78, 0.96, 1}
	case 1: return alicorn.Color{0.98, 0.66, 0.30, 1}
	case 2: return alicorn.Color{0.43, 0.84, 0.56, 1}
	case 3: return alicorn.Color{0.76, 0.58, 0.98, 1}
	case 4: return alicorn.Color{0.98, 0.47, 0.53, 1}
	case 5: return alicorn.Color{0.91, 0.82, 0.38, 1}
	}
	return alicorn.Color{0.65, 0.72, 0.82, 1}
}

history_dag_lane_x :: proc(lane: int, lane_count: int, surface_width: f32) -> f32 {
	lanes := max(1, lane_count)
	usable := max(1, surface_width-16)
	pitch := min(14, usable/f32(lanes))
	return 8 + f32(lane)*pitch + pitch*0.5
}

history_dag_geometry_can_append :: proc(
	segments: [dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: [dynamic]alicorn.GPU_Surface_Filled_Circle,
	add_segment, add_circle: bool,
) -> bool {
	segment_count := len(segments)
	circle_count := len(circles)
	if add_segment { segment_count += 1 }
	if add_circle { circle_count += 1 }
	return 6 + segment_count*6 + circle_count*alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3 <= alicorn.GPU_SURFACE_MAX_VERTICES
}

history_dag_append_segment :: proc(
	segments: ^[dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: [dynamic]alicorn.GPU_Surface_Filled_Circle,
	start, end: alicorn.GPU_Surface_Point,
	color: alicorn.Color,
) -> bool {
	if !history_dag_geometry_can_append(segments^, circles, true, false) { return false }
	append(segments, alicorn.GPU_Surface_Line_Segment{start=start, end=end, thickness=1.6, color=color})
	return true
}

// history_dag_build_geometry projects the full-snapshot lane model into one
// virtual viewport. On an active filter it emits markers only: compacting the
// commit list must never imply a parent edge that doesn't exist.
history_dag_build_geometry :: proc(
	layout: Commit_DAG_Layout,
	commits: []Commit,
	visible: []int,
	first, last: int,
	row_height, surface_width: f32,
	selected_commit_index: int,
	filtered: bool,
	segments: ^[dynamic]alicorn.GPU_Surface_Line_Segment,
	circles: ^[dynamic]alicorn.GPU_Surface_Filled_Circle,
) {
	clear(segments)
	clear(circles)
	if row_height <= 0 || surface_width <= 0 || first < 0 || last <= first { return }
	if first >= len(visible) { return }
	visible_last := min(last, len(visible))
	if visible_last <= first { return }

	lane_count := layout.lane_count
	if lane_count < 1 { lane_count = 1 }
	usable := max(1, surface_width-16)
	lane_pitch := min(14, usable/f32(lane_count))
	radius := max(0.75, min(4.25, lane_pitch*0.36))

	// Emit visible commit markers first so even a pathological octopus merge
	// cannot consume the geometry budget before the actual row anchors exist.
	for position := first; position < visible_last; position += 1 {
		commit_index := visible[position]
		if commit_index < 0 || commit_index >= len(commits) { continue }
		lane := 0
		if !filtered && commit_index < len(layout.nodes) { lane = layout.nodes[commit_index].lane }
		color := history_dag_lane_color(lane)
		marker_radius := radius
		if commit_index == selected_commit_index {
			color = alicorn.Color{0.96, 0.96, 1, 1}
			marker_radius = max(radius, 5)
		}
		if history_dag_geometry_can_append(segments^, circles^, false, true) {
			append(circles, alicorn.GPU_Surface_Filled_Circle{
				center=alicorn.GPU_Surface_Point{
					x=history_dag_lane_x(lane, lane_count, surface_width),
					y=f32(position-first)*row_height + row_height*0.5,
				},
				radius=marker_radius,
				color=color,
			})
		}
	}

	if filtered { return }

	for edge in layout.edges {
		if edge.child_row < 0 || edge.parent_row < 0 ||
		   edge.child_row >= len(layout.nodes) || edge.parent_row >= len(layout.nodes) {
			continue
		}
		low_row := min(edge.child_row, edge.parent_row)
		high_row := max(edge.child_row, edge.parent_row)
		if low_row >= visible_last || high_row < first { continue }

		child_x := history_dag_lane_x(edge.child_lane, lane_count, surface_width)
		parent_x := history_dag_lane_x(edge.parent_lane, lane_count, surface_width)
		child_y := f32(edge.child_row-first)*row_height + row_height*0.5
		parent_y := f32(edge.parent_row-first)*row_height + row_height*0.5
		color := history_dag_lane_color(edge.child_lane)
		if child_x == parent_x {
			_ = history_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, child_y},
				alicorn.GPU_Surface_Point{parent_x, parent_y}, color)
		} else {
			mid_y := (child_y + parent_y)*0.5
			_ = history_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, child_y},
				alicorn.GPU_Surface_Point{child_x, mid_y}, color)
			_ = history_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{child_x, mid_y},
				alicorn.GPU_Surface_Point{parent_x, mid_y}, color)
			_ = history_dag_append_segment(segments, circles^,
				alicorn.GPU_Surface_Point{parent_x, mid_y},
				alicorn.GPU_Surface_Point{parent_x, parent_y}, color)
		}
	}
}

History_DAG_Geometry_Key :: struct {
	snapshot_generation: u64,
	first:                int,
	last:                 int,
	visible_count:        int,
	width_milli:          int,
	height_milli:         int,
	selected_commit_index: int,
	filtered:              bool,
}

history_dag_geometry_key :: proc(
	app: ^History_App,
	first, last: int,
	logical_width, logical_height: f32,
) -> History_DAG_Geometry_Key {
	return History_DAG_Geometry_Key{
		snapshot_generation=app.dag_generation,
		first=first,
		last=last,
		visible_count=len(app.visible),
		width_milli=int(logical_width*1000),
		height_milli=int(logical_height*1000),
		selected_commit_index=app.selected_commit_index,
		filtered=len(app.filter) > 0,
	}
}
