package main

import "core:fmt"
import alicorn "vendor/alicorn/runtime"

HISTORY_BG :: alicorn.Color{0.035, 0.045, 0.065, 1}
PANEL_BG   :: alicorn.Color{0.055, 0.075, 0.115, 1}
HEADER_BG  :: alicorn.Color{0.08, 0.13, 0.22, 1}
ROW_BG     :: alicorn.Color{0.10, 0.17, 0.28, 1}
SELECT_BG  :: alicorn.Color{0.18, 0.35, 0.56, 1}

history_file_status_text :: proc(status: File_Status) -> string {
	#partial switch status {
	case .Modified: return "M"
	case .Added: return "A"
	case .Deleted: return "D"
	case .Renamed: return "R"
	case .Copied: return "C"
	case .Type_Changed: return "T"
	case .Unmerged: return "U"
	}
	return "?"
}

history_file_stats_text :: proc(file: Changed_File) -> string {
	if file.additions < 0 || file.deletions < 0 { return "—  —" }
	return fmt.tprintf("+%d -%d", file.additions, file.deletions)
}

history_patch_display_count :: proc(patch: File_Patch) -> int {
	count := len(patch.metadata)
	for hunk in patch.hunks { count += 1 + len(hunk.lines) }
	if count == 0 && patch.binary { return 1 }
	return count
}

history_patch_display_line :: proc(patch: File_Patch, index: int) -> (line: Patch_Display_Line, ok: bool) {
	if index < 0 { return }
	position := 0
	for metadata in patch.metadata {
		if position == index { return Patch_Display_Line{kind=.Meta, text=metadata}, true }
		position += 1
	}
	for hunk in patch.hunks {
		if position == index { return Patch_Display_Line{kind=.Meta, text=hunk.header, hunk=true}, true }
		position += 1
		for patch_line in hunk.lines {
			if position == index {
				return Patch_Display_Line{kind=patch_line.kind, old_line=patch_line.old_line, new_line=patch_line.new_line, text=patch_line.text}, true
			}
			position += 1
		}
	}
	if patch.binary && position == index {
		return Patch_Display_Line{kind=.Meta, text="Binary file changed"}, true
	}
	return
}

history_patch_content_width :: proc(patch: File_Patch) -> f32 {
	width: f32 = 720
	for metadata in patch.metadata {
		width = max(width, f32(len(metadata))*8 + 24)
	}
	for hunk in patch.hunks {
		width = max(width, f32(len(hunk.header))*8 + 24)
		for line in hunk.lines { width = max(width, f32(len(line.text))*8 + 160) }
	}
	return min(width, 4096)
}

history_diff_line_color :: proc(kind: Diff_Line_Kind) -> alicorn.Color {
	#partial switch kind {
	case .Addition: return alicorn.Color{0.08, 0.20, 0.14, 1}
	case .Deletion: return alicorn.Color{0.28, 0.10, 0.12, 1}
	case .Meta: return alicorn.Color{0.08, 0.14, 0.23, 1}
	}
	return alicorn.NO_BACKGROUND_COLOR
}

history_build :: proc(state: rawptr, rt: ^alicorn.Runtime, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID {
	app := cast(^History_App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	app.build_count += 1
	first_build := app.filter_node == 0
	selection_changed := false
	file_selection_changed := false

	root_style := alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 0, 12, 8, .Stretch, true}
	root := alicorn.container_begin(&ui, .Root, label="history-root", style=root_style, color=HISTORY_BG)
	alicorn.text(&ui, "Alicorn History", style=alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})

	status := "Loading history..."
	if !app.loading {
		if len(app.error_text) > 0 { status = fmt.tprintf("Git error: %s", app.error_text) }
		else { status = fmt.tprintf("%s  ·  %d commits", app.branch, len(app.commits)) }
	}
	alicorn.text(&ui, fmt.tprintf("%s\n%s", app.repository, status), style=alicorn.Layout_Style{.Row, -1, 40, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})

	alicorn.container_begin(&ui, .Container, label="history-actions", style=alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 0, 0, 8, .Stretch, false})
	filter_style := alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 1, 0, 0, .Stretch, false}
	filter_id := alicorn.text_field(&ui, app.filter, key=alicorn.key_string("history-filter"), style=filter_style)
	open_clicked := alicorn.button(&ui, "Open Repository...", key=alicorn.key_string("history-open-repository"), style=alicorn.Layout_Style{.Row, 190, 30, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	refresh_clicked := alicorn.button(&ui, "Refresh", key=alicorn.key_string("history-refresh"), style=alicorn.Layout_Style{.Row, 100, 30, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_end(&ui)
	if open_clicked {
		history_open_repository(app, rt)
	}
	if refresh_clicked {
		if history_worker_submit(app) { alicorn.invalidate_root(rt, "history refresh requested") }
	}

	alicorn.container_begin(&ui, .Container, label="history-main", style=alicorn.Layout_Style{.Row, -1, -1, 0, -1, 0, -1, 1, 0, 12, .Stretch, true})
	app.row_height = 44

	alicorn.container_begin(&ui, .Container, label="history-list-panel", style=alicorn.Layout_Style{.Column, 500, -1, 0, -1, 0, -1, 0, 8, 6, .Stretch, true}, color=PANEL_BG)
	alicorn.text(&ui, fmt.tprintf("Commits (%d matching)", len(app.visible)), style=alicorn.Layout_Style{.Row, -1, 26, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	history_scroll := alicorn.scroll_region_begin(
		&ui,
		key=alicorn.key_string("history-scroll"),
		content_height=f32(len(app.visible))*app.row_height,
		line_height=app.row_height,
		style=alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 1, 0, 0, .Stretch, true},
	)
	app.history_scroll_node = history_scroll.id
	app.list_viewport_height = history_scroll.viewport_height
	app.scroll_y = history_scroll.offset_y
	metrics := alicorn.virtual_list_metrics(len(app.visible), app.scroll_y, app.list_viewport_height, app.row_height)
	alicorn.container_begin(&ui, .Virtual_List, label="history-commit-list", style=alicorn.Layout_Style{.Column, -1, history_scroll.viewport_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true}, scroll_offset_y=metrics.offset_y, layout_scroll_offset_y=metrics.leading_offset_y)
	for position := metrics.first; position < metrics.last; position += 1 {
		commit := app.commits[app.visible[position]]
		if !alicorn.component_begin(&ui, alicorn.key_string(commit.id)) { continue }
		selected := app.has_selection && app.selected_id == commit.id
		label := fmt.tprintf("%s  %s", commit_short_id(commit), commit.subject)
		clicked := alicorn.button(&ui, label, key=alicorn.key_string("commit-row"), state=alicorn.Button_State{selected=selected}, style=alicorn.Layout_Style{.Row, -1, app.row_height, 0, -1, 0, -1, 0, 4, 0, .Stretch, false})
		if clicked {
			history_select_visible_index(app, position)
			selection_changed = true
		}
		alicorn.component_end(&ui)
	}
	if len(app.visible) == 0 && !app.loading {
		alicorn.text(&ui, "No matching commits", style=alicorn.Layout_Style{.Row, -1, 30, 0, -1, 0, -1, 0, 4, 0, .Stretch, false})
	}
	alicorn.container_end(&ui)
	alicorn.scroll_region_end(&ui)
	alicorn.container_end(&ui)

	alicorn.container_begin(&ui, .Container, label="history-detail-panel", style=alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 1, 8, 6, .Stretch, true}, color=PANEL_BG)
	if app.has_selection && app.selected_commit_index >= 0 && app.selected_commit_index < len(app.commits) {
		commit := app.commits[app.selected_commit_index]
		alicorn.text(&ui, commit.subject, style=alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		alicorn.text(&ui, fmt.tprintf("%s\n%s <%s>\n%s\nParents: %d", commit.id, commit.author_name, commit.author_email, commit_date_text(commit.timestamp), len(commit.parents)), style=alicorn.Layout_Style{.Column, -1, 82, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		if app.detail_loading {
			alicorn.text(&ui, "Loading commit details...", style=alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		} else if len(app.detail_error) > 0 {
			alicorn.text(&ui, fmt.tprintf("Detail error: %s", app.detail_error), style=alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
		} else if app.detail.id == app.selected_id {
			if len(app.detail.body) > 0 {
				alicorn.text(&ui, app.detail.body, style=alicorn.Layout_Style{.Column, -1, 66, 0, -1, 0, -1, 0, 0, 0, .Stretch, true})
			}
			alicorn.text(&ui, fmt.tprintf("Changed files (%d)", len(app.detail.files)), style=alicorn.Layout_Style{.Row, -1, 26, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
			detail_scroll := alicorn.scroll_region_begin(
				&ui,
				key=alicorn.key_string("history-detail-files-scroll"),
				viewport_height=132,
				content_height=f32(len(app.detail.files))*app.row_height,
				line_height=app.row_height,
				style=alicorn.Layout_Style{.Column, -1, 132, 0, -1, 0, -1, 0, 0, 0, .Stretch, true},
			)
			app.detail_scroll_node = detail_scroll.id
			app.detail_file_viewport_height = detail_scroll.viewport_height
			app.detail_files_scroll_y = detail_scroll.offset_y
			file_metrics := alicorn.virtual_list_metrics(len(app.detail.files), app.detail_files_scroll_y, app.detail_file_viewport_height, app.row_height)
			alicorn.container_begin(&ui, .Virtual_List, label="history-detail-files", style=alicorn.Layout_Style{.Column, -1, detail_scroll.viewport_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true}, scroll_offset_y=file_metrics.offset_y, layout_scroll_offset_y=file_metrics.leading_offset_y)
			for position := file_metrics.first; position < file_metrics.last; position += 1 {
				file := app.detail.files[position]
				stats := history_file_stats_text(file)
				selected_file := position == app.selected_file_index && file.path == app.selected_file_path
				label := fmt.tprintf("%s  %-8s %s", history_file_status_text(file.status), stats, file.path)
				clicked := alicorn.button(&ui, label, key=alicorn.key_u64(u64(position)), state=alicorn.Button_State{selected=selected_file}, style=alicorn.Layout_Style{.Row, -1, app.row_height, 0, -1, 0, -1, 0, 2, 0, .Stretch, false})
				if clicked {
					if history_select_file_index(app, position) { file_selection_changed = true }
				}
			}
			alicorn.container_end(&ui)
			alicorn.scroll_region_end(&ui)

			patch_title := "Select a changed file"
			if app.selected_file_index >= 0 && app.selected_file_index < len(app.detail.files) {
				patch_title = fmt.tprintf("Patch: %s", app.selected_file_path)
			}
			alicorn.text(&ui, patch_title, style=alicorn.Layout_Style{.Row, -1, 26, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
			if app.patch_loading {
				alicorn.text(&ui, "Loading patch...", style=alicorn.Layout_Style{.Row, -1, 26, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
			} else if len(app.patch_error) > 0 {
				alicorn.text(&ui, fmt.tprintf("Patch error: %s", app.patch_error), style=alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
			} else if app.patch.path == app.selected_file_path && (len(app.patch.hunks) > 0 || app.patch.binary || len(app.patch.metadata) > 0) {
				patch_content_width := history_patch_content_width(app.patch)
				patch_line_count := history_patch_display_count(app.patch)
				patch_scroll := alicorn.scroll_region_begin(
					&ui,
					key=alicorn.key_string("history-patch-scroll"),
					content_height=f32(patch_line_count)*app.row_height,
					line_height=app.row_height,
					content_width=patch_content_width,
					line_width=32,
					style=alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 1, 0, 0, .Stretch, true},
				)
				app.patch_scroll_node = patch_scroll.id
				app.patch_viewport_height = patch_scroll.viewport_height
				app.patch_viewport_width = patch_scroll.viewport_width
				app.patch_scroll_y = patch_scroll.offset_y
				app.patch_scroll_x = patch_scroll.offset_x
				patch_metrics := alicorn.virtual_list_metrics(patch_line_count, app.patch_scroll_y, app.patch_viewport_height, app.row_height)
				alicorn.container_begin(&ui, .Virtual_List, label="history-patch-lines", style=alicorn.Layout_Style{.Column, patch_content_width, patch_scroll.viewport_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true}, scroll_offset_y=patch_metrics.offset_y, layout_scroll_offset_y=patch_metrics.leading_offset_y, layout_scroll_offset_x=patch_scroll.offset_x)
				for position := patch_metrics.first; position < patch_metrics.last; position += 1 {
					line, line_ok := history_patch_display_line(app.patch, position)
					if !line_ok { continue }
					color := history_diff_line_color(line.kind)
					alicorn.container_begin(&ui, .Container, label="patch-line", key=alicorn.key_u64(u64(position)), style=alicorn.Layout_Style{.Row, patch_content_width, app.row_height, 0, -1, 0, -1, 0, 2, 0, .Stretch, false}, color=color)
					if line.hunk {
						alicorn.text(&ui, line.text, style=alicorn.Layout_Style{.Row, patch_content_width, app.row_height, 0, -1, 0, -1, 0, 6, 0, .Stretch, false})
					} else {
						old_text := ""
						new_text := ""
						if line.old_line > 0 { old_text = fmt.tprintf("%d", line.old_line) }
						if line.new_line > 0 { new_text = fmt.tprintf("%d", line.new_line) }
						marker := " "
						if line.kind == .Addition { marker = "+" }
						if line.kind == .Deletion { marker = "-" }
						alicorn.text(&ui, old_text, style=alicorn.Layout_Style{.Row, 58, app.row_height, 0, -1, 0, -1, 0, 4, 0, .End, false})
						alicorn.text(&ui, new_text, style=alicorn.Layout_Style{.Row, 58, app.row_height, 0, -1, 0, -1, 0, 4, 0, .End, false})
						alicorn.text(&ui, marker, style=alicorn.Layout_Style{.Row, 22, app.row_height, 0, -1, 0, -1, 0, 2, 0, .Center, false})
						alicorn.text(&ui, line.text, style=alicorn.Layout_Style{.Row, patch_content_width-138, app.row_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
					}
					alicorn.container_end(&ui)
				}
				alicorn.container_end(&ui)
				alicorn.scroll_region_end(&ui)
			} else if app.selected_file_index >= 0 {
				alicorn.text(&ui, "No textual patch for this file", style=alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
			}
		}
	} else {
		alicorn.text(&ui, "Select a commit", style=alicorn.Layout_Style{.Row, -1, 30, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	}
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)

	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	app.filter_node = filter_id
	if first_build && filter_id != 0 {
		// Start the application in a deterministic keyboard-ready state. The
		// native host can then use Tab/Shift-Tab and Enter/Space without
		// requiring a preliminary mouse click.
		_ = alicorn.focus(rt, filter_id)
	}
	if selection_changed {
		_ = history_worker_submit_detail(app)
		_ = alicorn.scroll_region_set_offset(rt, app.history_scroll_node, app.scroll_y, "history selection visibility")
		alicorn.invalidate_root(rt, "history selection changed")
	}
	if file_selection_changed {
		alicorn.invalidate_root(rt, "history file selection changed")
	}
	_ = dpi_scale
	_ = logical_width
	return root
}
