package main

import "core:fmt"
import "core:path/filepath"
import alicorn "vendor/alicorn/runtime"

HISTORY_BG :: alicorn.Color{0.035, 0.045, 0.065, 1}
PANEL_BG   :: alicorn.Color{0.055, 0.075, 0.115, 1}
HEADER_BG  :: alicorn.Color{0.08, 0.13, 0.22, 1}
ROW_BG     :: alicorn.Color{0.10, 0.17, 0.28, 1}
SELECT_BG  :: alicorn.Color{0.18, 0.35, 0.56, 1}
HISTORY_PATCH_GUTTER_BG :: alicorn.Color{0.035, 0.05, 0.075, 1}

HISTORY_COMMIT_ROW_HEIGHT :: f32(44)
HISTORY_FILE_ROW_HEIGHT   :: f32(32)
HISTORY_PATCH_LINE_HEIGHT :: f32(22)
HISTORY_REF_ROW_HEIGHT    :: f32(24)
HISTORY_FILE_LIST_HEIGHT  :: f32(104)
HISTORY_PATCH_OLD_GUTTER_WIDTH :: f32(56)
HISTORY_PATCH_NEW_GUTTER_WIDTH :: f32(56)
HISTORY_PATCH_MARKER_WIDTH :: f32(24)
HISTORY_PATCH_GUTTER_WIDTH :: HISTORY_PATCH_OLD_GUTTER_WIDTH + HISTORY_PATCH_NEW_GUTTER_WIDTH + HISTORY_PATCH_MARKER_WIDTH
HISTORY_ROOT_PADDING :: f32(12)
HISTORY_WORKSPACE_DIVIDER_WIDTH :: f32(2)
HISTORY_DETAIL_MIN_WIDTH :: f32(280)
HISTORY_METADATA_WIDE_MIN_WIDTH :: f32(380)
HISTORY_METADATA_ROW_HEIGHT :: f32(26)
HISTORY_METADATA_ROW_GAP :: f32(4)
HISTORY_METADATA_GRID_HEIGHT :: f32(4*HISTORY_METADATA_ROW_HEIGHT + 3*HISTORY_METADATA_ROW_GAP)

history_build_commit_metadata :: proc(ui_value: alicorn.UI, app: ^History_App, commit: Commit) {
	ui := ui_value
	alicorn.adaptive_begin(&ui,
		alicorn.key_string("history-commit-properties"),
		style=alicorn.layout_style(.Column, height=HISTORY_METADATA_GRID_HEIGHT),
		label="history-commit-properties",
	)

	message := commit.subject
	if app.detail.id == app.selected_id && len(app.detail.subject) > 0 { message = app.detail.subject }
	alicorn.adaptive_alternative_begin(&ui,
		alicorn.key_string("history-commit-properties-wide-grid"),
		"Wide",
		minimum_width=HISTORY_METADATA_WIDE_MIN_WIDTH,
		style=alicorn.layout_style(.Column),
	)
	property_columns := [2]alicorn.Grid_Track{alicorn.grid_fixed(76), alicorn.grid_fraction(1)}
	property_rows := [4]alicorn.Grid_Track{
		alicorn.grid_fixed(HISTORY_METADATA_ROW_HEIGHT),
		alicorn.grid_fixed(HISTORY_METADATA_ROW_HEIGHT),
		alicorn.grid_fixed(HISTORY_METADATA_ROW_HEIGHT),
		alicorn.grid_fixed(HISTORY_METADATA_ROW_HEIGHT),
	}
	alicorn.grid_begin(&ui, alicorn.key_string("history-commit-properties-wide-grid-content"), property_columns[:], property_rows[:],
		style=alicorn.layout_style(width=-1, height=HISTORY_METADATA_GRID_HEIGHT), gap_x=8, gap_y=HISTORY_METADATA_ROW_GAP,
		label="history-commit-properties-wide-grid")
	metadata_text_style := alicorn.Text_Style{overflow=.Ellipsis}
	author_label := alicorn.text(&ui, "Author", key=alicorn.key_string("history-property-author-label"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, author_label, 0, 0, align_y=.Baseline)
	author_value := alicorn.text(&ui, fmt.tprintf("%s <%s>", commit.author_name, commit.author_email), key=alicorn.key_string("history-property-author-value"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, author_value, 0, 1, align_y=.Baseline)
	commit_label := alicorn.text(&ui, "Commit", key=alicorn.key_string("history-property-commit-label"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, commit_label, 1, 0, align_y=.Baseline)
	commit_value := alicorn.text(&ui, commit_short_id(commit), key=alicorn.key_string("history-property-commit-value"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, commit_value, 1, 1, align_y=.Baseline)
	branch_label := alicorn.text(&ui, "Branch", key=alicorn.key_string("history-property-branch-label"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, branch_label, 2, 0, align_y=.Baseline)
	branch_value := alicorn.text(&ui, app.branch, key=alicorn.key_string("history-property-branch-value"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, branch_value, 2, 1, align_y=.Baseline)
	message_label := alicorn.text(&ui, "Message", key=alicorn.key_string("history-property-message-label"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, message_label, 3, 0, align_y=.Baseline)
	message_value := alicorn.text(&ui, message, key=alicorn.key_string("history-property-message-value"), text_style=metadata_text_style)
	_ = alicorn.grid_cell(&ui, message_value, 3, 1, align_y=.Baseline)
	alicorn.grid_end(&ui)
	alicorn.adaptive_alternative_end(&ui)

	alicorn.adaptive_alternative_begin(&ui,
		alicorn.key_string("history-commit-properties-compact"),
		"Compact",
		minimum_width=0,
		style=alicorn.layout_style(.Column),
	)
		alicorn.container_begin(&ui, .Container,
			label="history-commit-properties-compact",
			key=alicorn.key_string("history-commit-properties-compact"),
			style=alicorn.layout_style(.Column, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, gap=2))
		alicorn.container_begin(&ui, .Container,
			label="history-commit-properties-identity",
			key=alicorn.key_string("history-commit-properties-identity"),
			style=alicorn.layout_style(.Row, height=26, align=.Center, gap=8))
		alicorn.text(&ui, commit.author_name,
			key=alicorn.key_string("history-property-author-value"),
			style=alicorn.layout_style(.Row, height=24, grow=1),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD, overflow=.Ellipsis})
		alicorn.text(&ui, commit_short_id(commit),
			key=alicorn.key_string("history-property-commit-value"),
			style=alicorn.layout_style(.Row, width=76, height=24, align=.End),
			text_style=alicorn.Text_Style{overflow=.Ellipsis})
		alicorn.container_end(&ui)
		alicorn.text(&ui, message,
			key=alicorn.key_string("history-property-message-value"),
			style=alicorn.layout_style(.Row, height=24),
			text_style=alicorn.Text_Style{overflow=.Ellipsis})
		alicorn.container_begin(&ui, .Container,
			label="history-commit-properties-branch-chip",
			key=alicorn.key_string("history-commit-properties-branch-chip"),
			style=alicorn.layout_style(.Row, width=-1, height=28, padding=3, align=.Center),
			color=HEADER_BG)
		alicorn.text(&ui, app.branch,
			key=alicorn.key_string("history-property-branch-value"),
			style=alicorn.layout_style(.Row, height=22, grow=1),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
		alicorn.container_end(&ui)
		alicorn.container_end(&ui)
	alicorn.adaptive_alternative_end(&ui)
	alicorn.adaptive_end(&ui)
}

history_ref_heading :: proc(kind: Git_Ref_Kind) -> (label, key: string) {
	#partial switch kind {
	case .Branch: return "Branches", "history-refs-heading-branches"
	case .Remote: return "Remotes", "history-refs-heading-remotes"
	case .Tag:    return "Tags", "history-refs-heading-tags"
	}
	return "", "history-refs-heading-unknown"
}

history_ref_marker_color :: proc(kind: Git_Ref_Kind) -> alicorn.Color {
	#partial switch kind {
	case .Branch: return alicorn.Color{0.30, 0.72, 0.52, 1}
	case .Remote: return alicorn.Color{0.32, 0.66, 0.84, 1}
	case .Tag:    return alicorn.Color{0.84, 0.66, 0.34, 1}
	}
	return alicorn.Color{0.55, 0.58, 0.64, 1}
}

history_repository_name :: proc(repository: string) -> string {
	name := filepath.base(repository)
	if len(name) == 0 || name == "." || name == "\\" || name == "/" { return repository }
	return name
}

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
	if len(patch.display_lines) > 0 { return len(patch.display_lines) }
	count := len(patch.metadata)
	for hunk in patch.hunks { count += 1 + len(hunk.lines) }
	if count == 0 && patch.binary { return 1 }
	return count
}

history_patch_display_line :: proc(patch: File_Patch, index: int) -> (line: Patch_Display_Line, ok: bool) {
	if index < 0 { return }
	if index < len(patch.display_lines) { return patch.display_lines[index], true }
	position := 0
	for metadata in patch.metadata {
		if position == index { return Patch_Display_Line{kind=.Meta, text=metadata}, true }
		position += 1
	}
	for hunk, hunk_index in patch.hunks {
		if position == index { return Patch_Display_Line{kind=.Meta, text=hunk.header, hunk=true, hunk_index=hunk_index}, true }
		position += 1
		for patch_line in hunk.lines {
			if position == index {
				return Patch_Display_Line{kind=patch_line.kind, old_line=patch_line.old_line, new_line=patch_line.new_line, text=patch_line.text, hunk_index=hunk_index}, true
			}
			position += 1
		}
	}
	if patch.binary && position == index {
		return Patch_Display_Line{kind=.Meta, text="Binary file changed"}, true
	}
	return
}

history_patch_hunk_display_index :: proc(patch: File_Patch, hunk_index: int) -> int {
	if hunk_index < 0 || hunk_index >= len(patch.hunks) { return -1 }
	display_index := len(patch.metadata)
	for hunk, index in patch.hunks {
		if index == hunk_index { return display_index }
		display_index += 1 + len(hunk.lines)
	}
	return -1
}

history_patch_hunk_step :: proc(hunk_count, current_index, direction: int) -> (next_index: int, changed: bool) {
	if hunk_count <= 0 { return 0, false }
	next_index = current_index
	if next_index < 0 { next_index = 0 }
	if next_index >= hunk_count { next_index = hunk_count-1 }
	if direction > 0 && next_index+1 < hunk_count { next_index += 1 }
	if direction < 0 && next_index > 0 { next_index -= 1 }
	changed = next_index != current_index
	return
}

history_scroll_patch_hunk_to_start :: proc(rt: ^alicorn.Runtime, scroll_node: alicorn.Node_ID, display_index: int) -> bool {
	if rt == nil || scroll_node == 0 || display_index < 0 { return false }
	scroll := alicorn.scroll_region_state(rt, scroll_node)
	if scroll.id == 0 { return false }
	desired_offset := f32(display_index)*HISTORY_PATCH_LINE_HEIGHT - 2*HISTORY_PATCH_LINE_HEIGHT
	if desired_offset < 0 { desired_offset = 0 }
	if desired_offset > scroll.max_scroll_y { desired_offset = scroll.max_scroll_y }
	return alicorn.scroll_region_set_offset(rt, scroll_node, desired_offset, "history hunk navigation")
}

history_reset_patch_scroll :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.patch_scroll_reset_pending { return }
	if app.patch_scroll_node != 0 {
		_ = alicorn.scroll_region_set_offset(rt, app.patch_scroll_node, 0, "history patch selection changed")
	}
	app.patch_scroll_reset_pending = false
}

history_patch_content_width :: proc(patch: File_Patch) -> f32 {
	if patch.content_width > 0 { return patch.content_width }
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

history_diff_gutter_color :: proc(kind: Diff_Line_Kind) -> alicorn.Color {
	#partial switch kind {
	case .Addition: return alicorn.Color{0.50, 0.82, 0.64, 1}
	case .Deletion: return alicorn.Color{0.90, 0.58, 0.60, 1}
	}
	return alicorn.Color{0.58, 0.64, 0.73, 1}
}

history_build :: proc(state: rawptr, rt: ^alicorn.Runtime, logical_width, logical_height: int, dpi_scale: f32) -> alicorn.Node_ID {
	app := cast(^History_App)state
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	app.build_count += 1
	first_build := app.filter_node == 0
	selection_changed := false
	file_selection_changed := false
	refs_filter_changed := false
	refs_selection_position := -1
	commit_graph_first := 0
	commit_graph_last := 0
	patch_hunk_scroll_node := alicorn.Node_ID(0)
	patch_hunk_scroll_target := -1
	patch_hunk_changed := false

	root_style := alicorn.layout_style(padding=HISTORY_ROOT_PADDING, gap=8, clip=true)
	root := alicorn.container_begin(&ui, .Root, label="history-root", style=root_style, color=HISTORY_BG)

	status := "Loading history..."
	if !app.loading {
		if len(app.error_text) > 0 { status = fmt.tprintf("Git error: %s", app.error_text) }
		else { status = fmt.tprintf("%d commits", len(app.commits)) }
	}
	alicorn.container_begin(&ui, .Container, label="history-repository-heading", style=alicorn.layout_style(.Row, height=32, gap=10, align=.Center))
	alicorn.text(&ui, history_repository_name(app.repository), style=alicorn.layout_style(.Row, height=28, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	if len(app.branch) > 0 {
		alicorn.container_begin(&ui, .Container, label="history-current-branch", style=alicorn.layout_style(.Row, height=22, max_width=260, padding=6, align=.Center, clip=true), color=HEADER_BG)
		alicorn.text(&ui, app.branch, style=alicorn.layout_style(.Row, height=18), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
		alicorn.container_end(&ui)
	}
	alicorn.text(&ui, status, style=alicorn.layout_style(.Row, height=22))
	alicorn.container_end(&ui)
	path_node := alicorn.text(&ui, app.repository, style=alicorn.layout_style(.Row, height=18), text_style=alicorn.Text_Style{overflow=.Ellipsis})
	path_span := [1]alicorn.Text_Paint_Span{{start=0, end=len(app.repository), color=alicorn.Color{0.56, 0.60, 0.68, 1}, color_set=true}}
	_ = alicorn.text_paint_spans(&ui, path_node, path_span[:])

	alicorn.container_begin(&ui, .Container, label="history-actions", style=alicorn.layout_style(.Row, height=34, gap=8))
	filter_style := alicorn.layout_style(.Row, height=34, grow=1)
	filter_id := alicorn.text_field(&ui, app.filter, key=alicorn.key_string("history-filter"), style=filter_style)
	open_clicked := alicorn.button(&ui, "Open Repository...", key=alicorn.key_string("history-open-repository"), style=alicorn.layout_style(.Row, width=190, height=30), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
	refresh_clicked := alicorn.button(&ui, "Refresh", key=alicorn.key_string("history-refresh"), style=alicorn.layout_style(.Row, width=100, height=30), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
	alicorn.container_end(&ui)
	if open_clicked {
		history_open_repository(app, rt)
	}
	if refresh_clicked {
		if history_worker_submit(app) { alicorn.invalidate_root(rt, "history refresh requested") }
	}

	outer_split := alicorn.split_begin(
		&ui,
		key=alicorn.key_string("history-workspace-detail-split"),
		axis=.Horizontal,
		initial=722,
		min_first=452,
		min_second=HISTORY_DETAIL_MIN_WIDTH,
		style=alicorn.layout_style(.Row, grow=1, gap=12, clip=true),
		label="history-workspace-detail-split",
	)
	alicorn.split_first_begin(&ui, outer_split)
	inner_split := alicorn.split_begin(
		&ui,
		key=alicorn.key_string("history-refs-commits-split"),
		axis=.Horizontal,
		initial=220,
		min_first=150,
		min_second=300,
		style=alicorn.layout_style(.Row, grow=1, gap=12, clip=true),
		label="history-refs-commits-split",
	)
	alicorn.split_first_begin(&ui, inner_split)
	alicorn.container_begin(&ui, .Container, label="history-refs-panel", style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true), color=PANEL_BG)
	alicorn.text(&ui, fmt.tprintf("Refs (%d)", len(app.refs)), style=alicorn.layout_style(.Row, height=26), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	ref_list := alicorn.virtual_list_begin(
		&ui,
		len(app.ref_rows),
		HISTORY_REF_ROW_HEIGHT,
		key=alicorn.key_string("history-refs-scroll"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="history-ref-list",
		axes=.Vertical,
	)
	app.refs_scroll_node = ref_list.scroll.id
	for position := ref_list.first; position < ref_list.last; position += 1 {
		row := app.ref_rows[position]
		if row.is_header {
			heading, heading_key := history_ref_heading(row.kind)
			if !alicorn.component_begin(&ui, alicorn.key_string(heading_key)) { continue }
			alicorn.text(&ui, heading, style=alicorn.layout_style(.Row, height=HISTORY_REF_ROW_HEIGHT, padding=4), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
			alicorn.component_end(&ui)
			continue
		}
		if row.ref_index < 0 || row.ref_index >= len(app.refs) { continue }
		ref := app.refs[row.ref_index]
		if !alicorn.component_begin(&ui, alicorn.key_string(ref.full_name)) { continue }
		label := ref.short_name
		if ref.is_head { label = fmt.tprintf("%s  (HEAD)", ref.short_name) }
		selected := app.has_selection && len(ref.target_commit_id) > 0 && app.selected_id == ref.target_commit_id
		ref_button, clicked := alicorn.button_begin(
			&ui,
			"",
			key=alicorn.key_string("ref-row-button"),
			state=alicorn.Button_State{selected=selected, disabled=len(ref.target_commit_id) == 0},
			style=alicorn.layout_style(.Row, height=HISTORY_REF_ROW_HEIGHT, padding=0),
			content_style=alicorn.button_content_style(.Start, padding_x=4, padding_y=2),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis},
		)
		_ = alicorn.visual_part_attach(&ui, ref_button, ref_button,
			alicorn.visual_part_extension_id("app.history", "ref-row"))
		alicorn.container_begin(&ui, .Container, label="history-ref-content",
			key=alicorn.key_string("ref-content"),
			style=alicorn.layout_style(.Row, height=HISTORY_REF_ROW_HEIGHT-4, grow=1, gap=8, align=.Center, clip=true))
		marker := alicorn.container_begin(&ui, .Container, label="history-ref-marker",
			key=alicorn.key_string("ref-marker"),
			style=alicorn.layout_style(.Row, width=8, height=8, align=.Center),
			color=history_ref_marker_color(ref.kind))
		_ = alicorn.visual_part_attach(&ui, marker, ref_button,
			alicorn.visual_part_extension_id("app.history", "ref-marker"))
		alicorn.container_end(&ui)
		alicorn.text(&ui, label,
			key=alicorn.key_string("ref-name-label"),
			style=alicorn.layout_style(.Row, grow=1, height=HISTORY_REF_ROW_HEIGHT-4),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
		alicorn.container_end(&ui)
		alicorn.button_end(&ui)
		if clicked {
			found, changed, filter_changed, visible_position := history_select_ref(app, row.ref_index)
			if found {
				if changed { selection_changed = true }
				if filter_changed { refs_filter_changed = true }
				refs_selection_position = visible_position
			}
		}
		alicorn.component_end(&ui)
	}
	alicorn.virtual_list_end(&ui, ref_list)
	alicorn.container_end(&ui)
	alicorn.split_first_end(&ui, inner_split)
	alicorn.split_divider(&ui, inner_split)
	alicorn.split_second_begin(&ui, inner_split)
	alicorn.container_begin(&ui, .Container, label="history-list-panel", style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true), color=PANEL_BG)
	dag_gutter_width := history_dag_gutter_width(app.dag.lane_count)
	alicorn.container_begin(&ui, .Container, label="history-commit-heading", style=alicorn.layout_style(.Row, height=26))
	alicorn.container_begin(&ui, .Container, label="history-commit-heading-graph-spacer", style=alicorn.layout_style(.Row, width=dag_gutter_width, height=26))
	alicorn.container_end(&ui)
	alicorn.text(&ui, fmt.tprintf("Commits (%d matching)", len(app.visible)), style=alicorn.layout_style(.Row, height=26, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
	alicorn.container_end(&ui)
	commit_list := alicorn.virtual_list_begin(
		&ui,
		len(app.visible),
		HISTORY_COMMIT_ROW_HEIGHT,
		key=alicorn.key_string("history-scroll"),
		style=alicorn.layout_style(grow=1, clip=true),
		label="history-commit-list",
		axes=.Vertical,
	)
	app.history_scroll_node = commit_list.scroll.id
	commit_graph_first = commit_list.first
	commit_graph_last = commit_list.last
	app.commit_graph_node = 0
	if len(app.visible) > 0 {
		viewport_height := commit_list.scroll.viewport_height
		alicorn.container_begin(&ui, .Container, label="history-commit-graph-rows", style=alicorn.layout_style(.Row, height=viewport_height, clip=true))
		app.commit_graph_node = alicorn.gpu_geometry_surface(
			&ui,
			"history-commit-dag",
			alicorn.layout_style(.Row, width=dag_gutter_width, height=viewport_height, clip=true),
			dpi_scale,
		)
		alicorn.container_begin(&ui, .Container, label="history-commit-rows", style=alicorn.layout_style(.Column, grow=1, height=viewport_height, clip=true))
	}
	for position := commit_list.first; position < commit_list.last; position += 1 {
		commit := app.commits[app.visible[position]]
		if !alicorn.component_begin(&ui, alicorn.key_string(commit.id)) { continue }
		selected := app.has_selection && app.selected_id == commit.id
		label := fmt.tprintf("%s  %s", commit_short_id(commit), commit.subject)
		row_weight := alicorn.FONT_WEIGHT_REGULAR
		if selected { row_weight = alicorn.FONT_WEIGHT_MEDIUM }
		commit_row, clicked := alicorn.button_begin(
			&ui,
			"",
			key=alicorn.key_string("commit-row-button"),
			state=alicorn.Button_State{selected=selected},
			style=alicorn.layout_style(.Row, height=HISTORY_COMMIT_ROW_HEIGHT, padding=0),
			content_style=alicorn.button_content_style(.Start, padding_x=4, padding_y=4),
		)
		_ = alicorn.visual_part_attach(&ui, commit_row, commit_row,
			alicorn.visual_part_extension_id("app.history", "commit-row"))
		alicorn.container_begin(&ui, .Container, label="history-commit-row-content",
			key=alicorn.key_string("commit-row-content"),
			style=alicorn.layout_style(.Row, height=HISTORY_COMMIT_ROW_HEIGHT-8, grow=1, gap=10, align=.Center, clip=true))
		alicorn.text(&ui, commit_short_id(commit),
			key=alicorn.key_string("commit-short-id"),
			style=alicorn.layout_style(.Row, width=68, height=HISTORY_COMMIT_ROW_HEIGHT-8),
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis})
		alicorn.text(&ui, commit.subject,
			key=alicorn.key_string("commit-subject"),
			style=alicorn.layout_style(.Row, grow=1, height=HISTORY_COMMIT_ROW_HEIGHT-8),
			text_style=alicorn.Text_Style{font_weight=row_weight, overflow=.Ellipsis})
		alicorn.container_end(&ui)
		alicorn.button_end(&ui)
		if clicked {
			history_select_visible_index(app, position)
			selection_changed = true
		}
		alicorn.component_end(&ui)
	}
	if len(app.visible) == 0 && !app.loading {
		alicorn.text(&ui, "No matching commits", style=alicorn.layout_style(.Row, height=30, padding=4))
	}
	if len(app.visible) > 0 { alicorn.container_end(&ui) }
	if len(app.visible) > 0 { alicorn.container_end(&ui) }
	alicorn.virtual_list_end(&ui, commit_list)
	alicorn.container_end(&ui)
	alicorn.split_second_end(&ui, inner_split)
	alicorn.split_end(&ui, inner_split)
	alicorn.split_first_end(&ui, outer_split)
	alicorn.split_divider(&ui, outer_split, thickness=HISTORY_WORKSPACE_DIVIDER_WIDTH)
	alicorn.split_second_begin(&ui, outer_split)
	alicorn.container_begin(&ui, .Container, label="history-detail-panel", style=alicorn.layout_style(grow=1, padding=8, gap=6, clip=true), color=PANEL_BG)
	if app.has_selection && app.selected_commit_index >= 0 && app.selected_commit_index < len(app.commits) {
		commit := app.commits[app.selected_commit_index]
		history_build_commit_metadata(ui, app, commit)
		if app.detail_loading {
			alicorn.text(&ui, "Loading commit details...", style=alicorn.layout_style(.Row, height=28))
		} else if len(app.detail_error) > 0 {
			alicorn.text(&ui, fmt.tprintf("Detail error: %s", app.detail_error), style=alicorn.layout_style(.Row, height=34))
		} else if app.detail.id == app.selected_id {
			if len(app.detail.body) > 0 {
				alicorn.text(&ui, app.detail.body, style=alicorn.layout_style(height=66, clip=true))
			}
			alicorn.text(&ui, fmt.tprintf("Changed files (%d)", len(app.detail.files)), style=alicorn.layout_style(.Row, height=26), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
				file_list := alicorn.virtual_list_begin(
					&ui,
					len(app.detail.files),
					HISTORY_FILE_ROW_HEIGHT,
					key=alicorn.key_string("history-detail-files-scroll"),
					style=alicorn.layout_style(height=HISTORY_FILE_LIST_HEIGHT, clip=true),
					label="history-detail-files",
					axes=.Vertical,
				)
				for position := file_list.first; position < file_list.last; position += 1 {
					file := app.detail.files[position]
					if !alicorn.component_begin(&ui, alicorn.key_string(file.path)) { continue }
					stats := history_file_stats_text(file)
					selected_file := position == app.selected_file_index && file.path == app.selected_file_path
					row_weight := alicorn.FONT_WEIGHT_REGULAR
					if selected_file { row_weight = alicorn.FONT_WEIGHT_MEDIUM }
					file_row, clicked := alicorn.button_begin(
						&ui,
						"",
						key=alicorn.key_string("history-file-row-button"),
						state=alicorn.Button_State{selected=selected_file},
						style=alicorn.layout_style(.Row, height=HISTORY_FILE_ROW_HEIGHT, padding=0),
						content_style=alicorn.button_content_style(.Start, padding_x=8, padding_y=2),
					)
					file_row_states := alicorn.Semantic_States{}
					if selected_file { file_row_states = alicorn.semantic_states_add(file_row_states, .Selected) }
					_ = alicorn.semantic_description(&ui, .Button,
						fmt.tprintf("%s, %s, %s", history_file_status_text(file.status), stats, file.path),
						states=file_row_states,
						actions=alicorn.semantic_actions_add({}, .Press))
					alicorn.container_begin(&ui, .Container, label="history-file-row-content",
						key=alicorn.key_string("history-file-row-content"),
						style=alicorn.layout_style(.Row, height=HISTORY_FILE_ROW_HEIGHT-4, grow=1, gap=10, align=.Center, clip=true))
					alicorn.text(&ui, history_file_status_text(file.status),
						key=alicorn.key_string("history-file-status"),
						style=alicorn.layout_style(.Row, width=18, height=HISTORY_FILE_ROW_HEIGHT-4),
						text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
					alicorn.text(&ui, stats,
						key=alicorn.key_string("history-file-stats"),
						style=alicorn.layout_style(.Row, width=82, height=HISTORY_FILE_ROW_HEIGHT-4),
						text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
					alicorn.text(&ui, file.path,
						key=alicorn.key_string("history-file-name"),
						style=alicorn.layout_style(.Row, grow=1, height=HISTORY_FILE_ROW_HEIGHT-4),
						text_style=alicorn.Text_Style{font_weight=row_weight, overflow=.Ellipsis})
					alicorn.container_end(&ui)
					alicorn.button_end(&ui)
					if clicked {
						if history_select_file_index(app, position) { file_selection_changed = true }
					}
					alicorn.component_end(&ui)
				}
				alicorn.virtual_list_end(&ui, file_list)

			patch_title := "Select a changed file"
			if app.selected_file_index >= 0 && app.selected_file_index < len(app.detail.files) {
				patch_title = fmt.tprintf("Patch: %s", app.selected_file_path)
			}
			alicorn.text(&ui, patch_title, style=alicorn.layout_style(.Row, height=30), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
			if app.patch_loading {
				alicorn.text(&ui, "Loading patch...", style=alicorn.layout_style(.Row, height=26))
			} else if len(app.patch_error) > 0 {
				alicorn.text(&ui, fmt.tprintf("Patch error: %s", app.patch_error), style=alicorn.layout_style(.Row, height=34))
			} else if app.patch.path == app.selected_file_path && (len(app.patch.hunks) > 0 || app.patch.binary || len(app.patch.metadata) > 0) {
				patch_content_width := history_patch_content_width(app.patch)
				patch_line_count := history_patch_display_count(app.patch)
				hunk_count := len(app.patch.hunks)
				if hunk_count > 0 {
					if app.selected_patch_hunk >= hunk_count { app.selected_patch_hunk = hunk_count-1 }
					alicorn.container_begin(&ui, .Container, label="history-patch-hunk-navigation", style=alicorn.layout_style(.Row, height=30, gap=8, align=.Center))
					_, previous_hunk_clicked := alicorn.button_begin(
						&ui,
						"‹ Previous",
						key=alicorn.key_string("history-patch-previous-hunk"),
						state=alicorn.Button_State{disabled=app.selected_patch_hunk <= 0},
						style=alicorn.layout_style(.Row, width=84, height=28),
					)
					alicorn.button_end(&ui)
					if previous_hunk_clicked {
						app.selected_patch_hunk, patch_hunk_changed = history_patch_hunk_step(hunk_count, app.selected_patch_hunk, -1)
					}
					alicorn.text(&ui, fmt.tprintf("Hunk %d / %d", app.selected_patch_hunk+1, hunk_count), style=alicorn.layout_style(.Row, height=26, grow=1), text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM})
					_, next_hunk_clicked := alicorn.button_begin(
						&ui,
						"Next ›",
						key=alicorn.key_string("history-patch-next-hunk"),
						state=alicorn.Button_State{disabled=app.selected_patch_hunk+1 >= hunk_count},
						style=alicorn.layout_style(.Row, width=84, height=28),
					)
					alicorn.button_end(&ui)
					if next_hunk_clicked {
						app.selected_patch_hunk, patch_hunk_changed = history_patch_hunk_step(hunk_count, app.selected_patch_hunk, 1)
					}
					alicorn.container_end(&ui)
					if patch_hunk_changed {
						patch_hunk_scroll_target = history_patch_hunk_display_index(app.patch, app.selected_patch_hunk)
					}
				}
				patch_list := alicorn.virtual_list_begin(
					&ui,
					patch_line_count,
					HISTORY_PATCH_LINE_HEIGHT,
					key=alicorn.key_string("history-patch-scroll"),
					content_width=patch_content_width,
					line_width=32,
					style=alicorn.layout_style(grow=1, clip=true),
					label="history-patch-lines",
					axes=.Both,
					axis_behavior=.Auto_Lock,
				)
				patch_hunk_scroll_node = patch_list.scroll.id
				app.patch_scroll_node = patch_list.scroll.id
				for position := patch_list.first; position < patch_list.last; position += 1 {
					line, line_ok := history_patch_display_line(app.patch, position)
					if !line_ok { continue }
					color := history_diff_line_color(line.kind)
					if line.hunk && line.hunk_index == app.selected_patch_hunk { color = SELECT_BG }
					alicorn.container_begin(&ui, .Container, label="patch-line", key=alicorn.key_u64(u64(position)), style=alicorn.layout_style(.Row, width=patch_content_width, height=HISTORY_PATCH_LINE_HEIGHT), color=color)
					if line.hunk {
						alicorn.text(&ui, line.text, style=alicorn.layout_style(.Row, width=patch_content_width, height=HISTORY_PATCH_LINE_HEIGHT, padding=6), font=alicorn.Font_Role.Monospace, text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Clip})
					} else {
						old_text := ""
						new_text := ""
						if line.old_line > 0 { old_text = fmt.tprintf("%d", line.old_line) }
						if line.new_line > 0 { new_text = fmt.tprintf("%d", line.new_line) }
						marker := " "
						if line.kind == .Addition { marker = "+" }
						if line.kind == .Deletion { marker = "-" }
						alicorn.container_begin(&ui, .Container, label="patch-line-number-gutter", style=alicorn.layout_style(.Row, width=HISTORY_PATCH_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT), color=HISTORY_PATCH_GUTTER_BG)
						gutter_text_style := alicorn.Text_Style{overflow=.Clip}
						old_number_id := alicorn.text(&ui, old_text, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_OLD_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=4, align=.End), font=alicorn.Font_Role.Monospace, text_style=gutter_text_style)
						if len(old_text) > 0 {
							span := [1]alicorn.Text_Paint_Span{{start=0, end=len(old_text), color=history_diff_gutter_color(line.kind), color_set=true}}
							_ = alicorn.text_paint_spans(&ui, old_number_id, span[:])
						}
						new_number_id := alicorn.text(&ui, new_text, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_NEW_GUTTER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=4, align=.End), font=alicorn.Font_Role.Monospace, text_style=gutter_text_style)
						if len(new_text) > 0 {
							span := [1]alicorn.Text_Paint_Span{{start=0, end=len(new_text), color=history_diff_gutter_color(line.kind), color_set=true}}
							_ = alicorn.text_paint_spans(&ui, new_number_id, span[:])
						}
					marker_id := alicorn.text(&ui, marker, style=alicorn.layout_style(.Row, width=HISTORY_PATCH_MARKER_WIDTH, height=HISTORY_PATCH_LINE_HEIGHT, padding=2, align=.Center), font=alicorn.Font_Role.Monospace, text_style=gutter_text_style)
					marker_span := [1]alicorn.Text_Paint_Span{{start=0, end=len(marker), color=history_diff_gutter_color(line.kind), color_set=true}}
					_ = alicorn.text_paint_spans(&ui, marker_id, marker_span[:])
						alicorn.container_end(&ui)
						code_width := max(0, patch_content_width-HISTORY_PATCH_GUTTER_WIDTH)
						alicorn.text(&ui, line.text, style=alicorn.layout_style(.Row, width=code_width, height=HISTORY_PATCH_LINE_HEIGHT, padding=4), font=alicorn.Font_Role.Monospace, text_style=alicorn.Text_Style{overflow=.Clip})
					}
					alicorn.container_end(&ui)
				}
				alicorn.virtual_list_end(&ui, patch_list)
			} else if app.selected_file_index >= 0 {
				file := app.detail.files[app.selected_file_index]
				if file.additions > 0 || file.deletions > 0 {
					alicorn.text(&ui, fmt.tprintf("Patch mismatch: Git reports %s lines, but the selected patch contains no hunks (commit %s).", history_file_stats_text(file), commit_short_id(commit)), style=alicorn.layout_style(.Row, height=28))
				} else {
					alicorn.text(&ui, "No textual patch for this file", style=alicorn.layout_style(.Row, height=28))
				}
			}
		}
	} else {
		alicorn.text(&ui, "Select a commit", style=alicorn.layout_style(.Row, height=30))
	}
	alicorn.container_end(&ui)
	alicorn.split_second_end(&ui, outer_split)
	alicorn.split_end(&ui, outer_split)
	history_reset_patch_scroll(app, rt)
	alicorn.end_frame(&ui)
	if app.commit_graph_node == 0 {
		app.graph_geometry_node = 0
		app.graph_geometry_key = {}
	} else if ctx, ok := alicorn.gpu_surface_context(rt, app.commit_graph_node); ok {
		if app.graph_geometry_node != app.commit_graph_node {
			app.graph_geometry_node = app.commit_graph_node
			app.graph_geometry_key = {}
		}
		key := history_dag_geometry_key(app, commit_graph_first, commit_graph_last, ctx.logical_bounds.w, ctx.logical_bounds.h)
		if key != app.graph_geometry_key {
			if app.graph_segments == nil { app.graph_segments = make([dynamic]alicorn.GPU_Surface_Line_Segment, 0, 128) }
			if app.graph_circles == nil { app.graph_circles = make([dynamic]alicorn.GPU_Surface_Filled_Circle, 0, 64) }
			history_dag_build_geometry(
				app.dag,
				app.commits[:],
				app.visible[:],
				commit_graph_first,
				commit_graph_last,
				HISTORY_COMMIT_ROW_HEIGHT,
				ctx.logical_bounds.w,
				app.selected_commit_index,
				len(app.filter) > 0,
				&app.graph_segments,
				&app.graph_circles,
			)
			app.graph_geometry_revision += 1
			if app.graph_geometry_revision == 0 { app.graph_geometry_revision = 1 }
			if alicorn.gpu_surface_update_geometry_versioned(
				rt,
				app.commit_graph_node,
				alicorn.GPU_Surface_Update_Revision(app.graph_geometry_revision),
				app.graph_segments[:],
				app.graph_circles[:],
			) {
				app.graph_geometry_key = key
			}
		}
	}
	app.filter_node = filter_id
	if first_build && filter_id != 0 {
		// Start the application in a deterministic keyboard-ready state. The
		// native host can then use Tab/Shift-Tab and Enter/Space without
		// requiring a preliminary mouse click.
		_ = alicorn.focus(rt, filter_id)
	}
	if selection_changed {
		_ = history_worker_submit_detail(app)
		alicorn.invalidate_root(rt, "history selection changed")
	}
	if file_selection_changed {
		alicorn.invalidate_root(rt, "history file selection changed")
	}
	if refs_filter_changed && !selection_changed {
		alicorn.invalidate_root(rt, "filter cleared to reveal selected ref")
	}
	if refs_selection_position >= 0 {
		_ = alicorn.virtual_list_ensure_visible(rt, app.history_scroll_node, refs_selection_position, "ref target commit visibility")
	}
	if patch_hunk_changed {
		alicorn.invalidate_root(rt, "history patch hunk changed")
		if patch_hunk_scroll_node != 0 && patch_hunk_scroll_target >= 0 {
			_ = history_scroll_patch_hunk_to_start(rt, patch_hunk_scroll_node, patch_hunk_scroll_target)
		}
	}
	_ = dpi_scale
	_ = logical_width
	return root
}
