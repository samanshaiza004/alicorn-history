package main

import "core:fmt"
import alicorn "vendor/alicorn/runtime"

history_clear_patch :: proc(app: ^History_App) {
	patch_projection_destroy(&app.patch_projection)
	app.patch_projection_ready = false
	app.patch_selection = {}
	app.patch_view_anchor = {}
	app.patch_anchor_pending = false
	app.patch_hunk_navigation_pending = false
	clear(&app.patch_view_rows)
	file_patch_destroy(&app.patch)
}
history_prepare_patch_projection :: proc(app: ^History_App) {
	if !app.folding_enabled { return }
	if patch_projection_init(&app.patch_projection, &app.patch, app.latest_patch_id) {
		app.patch_projection_ready = true
		// Worker/parser built this as a fallback. The UI-owned compact view
		// now borrows the authoritative hunks and no longer needs the array.
		delete(app.patch.display_lines)
		app.patch.display_lines = nil
	}
}
history_toggle_patch_hunk :: proc(app: ^History_App, rt: ^alicorn.Runtime, ordinal: Patch_Hunk_Ordinal) -> bool {
	if !app.patch_projection_ready || int(ordinal) < 0 || int(ordinal) >= len(app.patch.hunks) || len(app.patch.hunks[int(ordinal)].lines) <= 1 { return false }
	if rt != nil && app.patch_scroll_node != 0 {
		offset := Patch_Pixel_Y(alicorn.scroll_region_offset(rt, app.patch_scroll_node))
		// Preserve a hidden logical anchor until the user changes scroll or
		// navigates explicitly. Unfold then recovers the original source row.
		if !app.patch_view_anchor.valid || app.patch_view_anchor.epoch != app.latest_patch_id || abs(offset-app.patch_anchor_offset) > 0.25 {
			first := Patch_Display_Row(f64(offset)/f64(HISTORY_PATCH_LINE_HEIGHT))
			visible: [1]Patch_Projection_Row
			if patch_projection_viewport(&app.patch_projection, first, visible[:]) == 1 {
				app.patch_view_anchor = visible[0].target
				app.patch_view_fraction = offset-Patch_Pixel_Y(first)*Patch_Pixel_Y(HISTORY_PATCH_LINE_HEIGHT)
			} else { app.patch_view_anchor = {} }
		}
		app.patch_anchor_pending = app.patch_view_anchor.valid
	}
	if !patch_projection_toggle_hunk(&app.patch_projection, ordinal) { return false }
	if rt != nil { alicorn.invalidate_root(rt, "patch hunk folding changed") }
	return true
}
history_restore_patch_anchor :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	if app.patch_hunk_navigation_pending && rt != nil && app.patch_scroll_node != 0 {
		scroll := alicorn.scroll_region_state(rt, app.patch_scroll_node)
		if scroll.id == 0 || scroll.viewport_height <= 0 { return }
		row, ok := patch_projection_seek_hunk(&app.patch_projection, app.patch_pending_hunk)
		app.patch_hunk_navigation_pending = false
		app.patch_anchor_pending = false
		app.patch_view_anchor = {}
		if ok { _ = history_scroll_patch_hunk_to_start(rt, scroll.id, int(row)) }
		return
	}
	if !app.patch_anchor_pending || rt == nil || app.patch_scroll_node == 0 { return }
	scroll := alicorn.scroll_region_state(rt, app.patch_scroll_node)
	if scroll.id == 0 || scroll.viewport_height <= 0 { return }
	row, ok := patch_projection_resolve(&app.patch_projection, app.patch_view_anchor)
	app.patch_anchor_pending = false
	if !ok { app.patch_view_anchor = {}; return }
	desired := Patch_Pixel_Y(row)*Patch_Pixel_Y(HISTORY_PATCH_LINE_HEIGHT)+app.patch_view_fraction
	_ = alicorn.scroll_region_set_offset(rt, scroll.id, f32(desired), "patch source anchor after folding")
	app.patch_anchor_offset = Patch_Pixel_Y(alicorn.scroll_region_offset(rt, scroll.id))
}
history_patch_fold_semantic :: proc(app: ^History_App, hunk: Patch_Hunk_Ordinal) -> alicorn.Semantic_ID {
	return {namespace=0x464F4C44 ~ u64(app.latest_patch_id), value=u64(hunk)+1}
}
history_patch_row_selected :: proc(app: ^History_App, row: Patch_Projection_Row) -> bool {
	selected := app.patch_selection
	if !selected.valid || selected.epoch != row.target.epoch { return false }
	if row.folded { return selected.kind == .Line && selected.hunk == row.target.hunk }
	return selected.kind == row.target.kind && selected.hunk == row.target.hunk && selected.line == row.target.line
}
history_patch_row_semantic :: proc(app: ^History_App, row: Patch_Projection_Row) -> alicorn.Semantic_ID {
	namespace := u64(0x50415443) ~ u64(app.latest_patch_id) ~ (u64(row.target.kind)<<48)
	if row.folded { namespace ~= 0x464F4C4400000000 }
	return {namespace=namespace, value=(u64(row.target.hunk)<<32) | (u64(row.target.line)+1)}
}
history_build_patch_row :: proc(ui: ^alicorn.UI, app: ^History_App, row: Patch_Projection_Row, width: f32, position: int, fold_request: ^int) {
	line := row.line
	interactive := app.patch_projection_ready
	color := history_diff_line_color(line.kind)
	if (line.hunk && line.hunk_index == app.selected_patch_hunk) || (interactive && history_patch_row_selected(app, row)) { color = SELECT_BG }
	key := alicorn.key_u64(u64(position))
	if interactive { key = alicorn.key_string(fmt.tprintf("patch:%d:%d:%d:%d:%t", row.target.epoch, row.target.kind, row.target.hunk, row.target.line, row.folded)) }
	alicorn.container_begin(ui, .Container, key=key, style=alicorn.layout_style(.Row, width=width, height=HISTORY_PATCH_LINE_HEIGHT), color=color, label="patch-line")
	// Keep hunk controls usable while code remains horizontally scrolled.
	control_offset := f32(0)
	if interactive && (line.hunk || row.folded) {
		control_offset = alicorn.scroll_region_offset_x(ui.runtime, app.patch_scroll_node)
		if control_offset > 0 { alicorn.container_begin(ui, .Container, style=alicorn.layout_style(width=control_offset, height=HISTORY_PATCH_LINE_HEIGHT)); alicorn.container_end(ui) }
	}
	if line.hunk {
		button_width := f32(0)
		if interactive {
			button_width = 76
			collapsed := app.patch_projection.hunks[line.hunk_index].collapsed
			_, clicked := alicorn.button_begin(ui, "Expand" if collapsed else "Collapse", key=alicorn.key_string("patch-fold"), state=alicorn.Button_State{disabled=len(app.patch.hunks[line.hunk_index].lines)<=1}, style=alicorn.layout_style(.Row, width=button_width, height=HISTORY_PATCH_LINE_HEIGHT), content_style=alicorn.button_content_style(padding_x=4, padding_y=0))
			_ = alicorn.semantic_describe_as(ui, history_patch_fold_semantic(app, Patch_Hunk_Ordinal(line.hunk_index)), .Button, "Expand hunk" if collapsed else "Collapse hunk", actions=alicorn.semantic_actions_add({}, .Press))
			alicorn.button_end(ui)
			if clicked { fold_request^ = line.hunk_index }
		}
		alicorn.text(ui, line.text, style=alicorn.layout_style(.Row, width=max(0, width-button_width-control_offset), height=HISTORY_PATCH_LINE_HEIGHT, padding=6), font=.Monospace, text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Clip})
	} else if row.folded {
		_, clicked := alicorn.button_begin(ui, fmt.tprintf("… %d hidden lines — expand", row.hidden), key=alicorn.key_string("expand-fold"), state=alicorn.Button_State{selected=history_patch_row_selected(app, row)}, style=alicorn.layout_style(.Row, width=max(0, width-control_offset), height=HISTORY_PATCH_LINE_HEIGHT), content_style=alicorn.button_content_style(.Start, padding_x=4, padding_y=0))
		_ = alicorn.semantic_describe_as(ui, history_patch_row_semantic(app, row), .Button, "Expand hidden hunk", actions=alicorn.semantic_actions_add({}, .Press))
		alicorn.button_end(ui)
		if clicked { fold_request^ = line.hunk_index }
	} else {
		old_text, new_text := "", ""
		if line.old_line > 0 { old_text = fmt.tprintf("%d", line.old_line) }
		if line.new_line > 0 { new_text = fmt.tprintf("%d", line.new_line) }
		marker := " "
		if line.kind == .Addition { marker = "+" }
		if line.kind == .Deletion { marker = "-" }
		alicorn.container_begin(ui, .Container, label="patch-line-number-gutter", style=alicorn.layout_style(.Row, width=HISTORY_PATCH_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT), color=HISTORY_PATCH_GUTTER_BG)
		gutter_style := alicorn.Text_Style{overflow=.Clip}
		old_id := alicorn.text(ui, old_text, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_OLD_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=4, align=.End), font=.Monospace, text_style=gutter_style)
		if len(old_text) > 0 { span := [1]alicorn.Text_Paint_Span{{start=0, end=len(old_text), color=history_diff_gutter_color(line.kind), color_set=true}}; _ = alicorn.text_paint_spans(ui, old_id, span[:]) }
		new_id := alicorn.text(ui, new_text, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_NEW_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=4, align=.End), font=.Monospace, text_style=gutter_style)
		if len(new_text) > 0 { span := [1]alicorn.Text_Paint_Span{{start=0, end=len(new_text), color=history_diff_gutter_color(line.kind), color_set=true}}; _ = alicorn.text_paint_spans(ui, new_id, span[:]) }
		if interactive {
			_, clicked := alicorn.button_begin(ui, marker, key=alicorn.key_string("select-source-row"), state=alicorn.Button_State{selected=history_patch_row_selected(app, row)}, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_MARKER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT), content_style=alicorn.button_content_style(padding_x=0, padding_y=0))
			_ = alicorn.semantic_describe_as(ui, history_patch_row_semantic(app, row), .Button, line.text, actions=alicorn.semantic_actions_add({}, .Press))
			alicorn.button_end(ui)
			if clicked && app.patch_selection != row.target {
				app.patch_selection = row.target
				if row.target.kind == .Line { app.selected_patch_hunk = line.hunk_index }
				alicorn.invalidate_root(ui.runtime, "patch source row selected")
			}
		} else {
			marker_id := alicorn.text(ui, marker, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_MARKER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=2, align=.Center), font=.Monospace, text_style=gutter_style)
			marker_span := [1]alicorn.Text_Paint_Span{{start=0, end=len(marker), color=history_diff_gutter_color(line.kind), color_set=true}}
			_ = alicorn.text_paint_spans(ui, marker_id, marker_span[:])
		}
		alicorn.container_end(ui)
		alicorn.text(ui, line.text, style=alicorn.layout_style(.Row, width=max(0, width-HISTORY_PATCH_GUTTER_WIDTH), height=HISTORY_PATCH_LINE_HEIGHT, padding=4), font=.Monospace, text_style=alicorn.Text_Style{overflow=.Clip})
	}
	alicorn.container_end(ui)
}
