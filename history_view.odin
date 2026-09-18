package main

import "core:fmt"
import alicorn "vendor/alicorn/runtime"

HISTORY_BG :: alicorn.Color{0.035, 0.045, 0.065, 1}
PANEL_BG   :: alicorn.Color{0.055, 0.075, 0.115, 1}
HEADER_BG  :: alicorn.Color{0.08, 0.13, 0.22, 1}
ROW_BG     :: alicorn.Color{0.10, 0.17, 0.28, 1}
SELECT_BG  :: alicorn.Color{0.18, 0.35, 0.56, 1}

history_build :: proc(state: rawptr, rt: ^alicorn.Runtime, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID {
	app := cast(^History_App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	app.build_count += 1
	selection_changed := false

	root_style := alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 0, 12, 8, .Stretch, true}
	root := alicorn.container_begin(&ui, .Root, label="history-root", style=root_style, color=HISTORY_BG)
	alicorn.text(&ui, "Alicorn History", style=alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})

	status := "Loading history..."
	if !app.loading {
		if len(app.error_text) > 0 { status = fmt.tprintf("Git error: %s", app.error_text) }
		else { status = fmt.tprintf("%s  ·  %d commits", app.branch, len(app.commits)) }
	}
	alicorn.text(&ui, fmt.tprintf("%s\n%s", app.repository, status), style=alicorn.Layout_Style{.Row, -1, 40, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})

	filter_style := alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 1, 0, 8, .Stretch, false}
	filter_id := alicorn.text_field(&ui, app.filter, key=alicorn.key_string("history-filter"), style=filter_style)
	refresh_clicked := alicorn.button(&ui, "Refresh", key=alicorn.key_string("history-refresh"), style=alicorn.Layout_Style{.Row, 100, 30, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	if refresh_clicked {
		if history_worker_submit(app) { alicorn.invalidate_root(rt, "history refresh requested") }
	}

	alicorn.container_begin(&ui, .Container, label="history-main", style=alicorn.Layout_Style{.Row, -1, -1, 0, -1, 0, -1, 1, 0, 12, .Stretch, true})
	app.list_viewport_height = f32(logical_height) - 190
	if app.list_viewport_height < 180 { app.list_viewport_height = 180 }
	app.row_height = 44
	metrics := alicorn.virtual_list_metrics(len(app.visible), app.scroll_y, app.list_viewport_height, app.row_height)
	app.scroll_y = metrics.offset_y

	alicorn.container_begin(&ui, .Container, label="history-list-panel", style=alicorn.Layout_Style{.Column, 500, -1, 0, -1, 0, -1, 0, 8, 6, .Stretch, true}, color=PANEL_BG)
	alicorn.text(&ui, fmt.tprintf("Commits (%d matching)", len(app.visible)), style=alicorn.Layout_Style{.Row, -1, 26, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
	alicorn.container_begin(&ui, .Virtual_List, label="history-commit-list", style=alicorn.Layout_Style{.Column, -1, app.list_viewport_height, 0, -1, 0, -1, 0, 0, 0, .Stretch, true}, scroll_offset_y=metrics.offset_y, layout_scroll_offset_y=metrics.leading_offset_y)
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
	alicorn.container_end(&ui)

	alicorn.container_begin(&ui, .Container, label="history-detail-panel", style=alicorn.Layout_Style{.Column, -1, -1, 0, -1, 0, -1, 1, 8, 6, .Stretch, true}, color=PANEL_BG)
	if app.has_selection {
		for commit in app.commits {
			if commit.id == app.selected_id {
				alicorn.text(&ui, commit.subject, style=alicorn.Layout_Style{.Row, -1, 34, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
				alicorn.text(&ui, fmt.tprintf("%s\n%s <%s>\n%s", commit.id, commit.author_name, commit.author_email, commit_date_text(commit.timestamp)), style=alicorn.Layout_Style{.Column, -1, 72, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
				alicorn.text(&ui, fmt.tprintf("Parents: %d", len(commit.parents)), style=alicorn.Layout_Style{.Row, -1, 28, 0, -1, 0, -1, 0, 0, 0, .Stretch, false})
				break
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
	if selection_changed { alicorn.invalidate_root(rt, "history selection changed") }
	_ = dpi_scale
	_ = logical_width
	return root
}
