package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import alicorn "vendor/alicorn/runtime"

HISTORY_FOLD_REAL_PATCH :: #load("research/fixtures/history-scroll.patch", string)

Patch_Projection_Fixture :: struct {
	name: string,
	data: string,
	path: string,
	minimum_rows: int,
	minimum_hunks: int,
}

history_fold_large_fixture :: proc() -> string {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "@@ -1,100 +1,100 @@\n")
	for i in 0..<100 { fmt.sbprintf(&b, "-old %d\n+new %d\n", i, i) }
	fmt.sbprintf(&b, "@@ -200,10 +200,10 @@\n")
	for i in 0..<10 { fmt.sbprintf(&b, " context %d\n", i) }
	copy, _ := strings.clone(strings.to_string(b))
	return copy
}
history_test_patch_projection :: proc(failures: ^int, repository: string) {
	large := history_fold_large_fixture()
	defer delete(large)
	fixtures := [?]Patch_Projection_Fixture{
		{"History scroll fixture", HISTORY_FOLD_REAL_PATCH, "", 0, 0},
		{"Alternating synthetic fixture", large, "", 0, 0},
		{"Alicorn large file replacement", "", "research/fixtures/alicorn-main-large-replacement.patch", 3000, 1},
		{"Alicorn caption rewrite", "", "research/fixtures/alicorn-caption-rewrite.patch", 300, 1},
		{"Alicorn many-hunk update", "", "research/fixtures/alicorn-theme-many-hunks.patch", 1, 8},
		{"Zero-count insertion and deletion", "@@ -0,0 +1,2 @@\n+a\n+b\n@@ -4,2 +5,0 @@\n-c\n-d\n", "", 0, 0},
		{"Binary patch", "Binary files a/p.png and b/p.png differ\n", "", 0, 0},
		{"Empty patch", "", "", 0, 0},
	}
	for fixture in fixtures {
		fixture_bytes: []byte
		if len(fixture.path) > 0 {
			fixture_path, path_error := filepath.join({repository, fixture.path}, context.allocator)
			history_test_expect(failures, path_error == nil, "large real patch fixture path resolves")
			if path_error != nil { continue }
			read_bytes, read_error := os.read_entire_file_from_path(fixture_path, context.allocator)
			delete(fixture_path)
			history_test_expect(failures, read_error == nil, "large real patch fixture is readable")
			if read_error != nil { continue }
			fixture_bytes = read_bytes
		} else {
			fixture_bytes = transmute([]byte)fixture.data
		}
		fixture_size := len(fixture_bytes)
		patch, err := git_parse_patch(fixture_bytes)
		if len(fixture.path) > 0 { delete(fixture_bytes) }
		defer file_patch_destroy(&patch)
		history_test_expect(failures, len(err) == 0, "folding fixture uses the actual History parser")
		if len(err) > 0 { delete(err); continue }
		history_test_expect(failures, len(patch.display_lines) >= fixture.minimum_rows && len(patch.hunks) >= fixture.minimum_hunks, "real patch corpus covers its recorded size and hunk shape")
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		p: Patch_Projection
		ok := patch_projection_init(&p, &patch, Patch_Request_ID(10), mem.tracking_allocator(&tracker))
		history_test_expect(failures, ok, "typed binary block projection builds")
		if !ok { mem.tracking_allocator_destroy(&tracker); continue }
		fmt.println("History patch corpus:", fixture.name, "bytes", fixture_size, "hunks", len(patch.hunks), "display rows", len(patch.display_lines), "spans", len(p.spans))
		original := patch_projection_measure(&p)
		viewport := make([]Patch_Projection_Row, len(patch.display_lines))
		written := patch_projection_viewport(&p, Patch_Display_Row(0), viewport)
		history_test_expect(failures, written == len(patch.display_lines), "unfolded count matches expanded display array")
		for row, ri in viewport[:written] {
			history_test_expect(failures, row.line == patch.display_lines[ri] && raw_data(row.line.text) == raw_data(patch.display_lines[ri].text), "actual row values and borrowed text match")
			resolved, valid := patch_projection_resolve(&p, row.target)
			history_test_expect(failures, valid && int(resolved) == ri, "source target maps to the same initial display row")
		}
		allocation_count := tracker.total_allocation_count
		for h, hi in patch.hunks {
			if len(h.lines) <= 1 { continue }
			history_test_expect(failures, patch_projection_toggle_hunk(&p, Patch_Hunk_Ordinal(hi)), "hunk fold crosses block boundaries")
			measure := patch_projection_measure(&p)
			history_test_expect(failures, measure.old_count == original.old_count && measure.new_count == original.new_count && measure.headers == original.headers, "collapse preserves independent source/header extents")
			for _, li in h.lines {
				target := Patch_Target{epoch=10, kind=.Line, hunk=Patch_Hunk_Ordinal(hi), line=Patch_Line_Index(li), byte=2, valid=true}
				row, found := patch_projection_resolve(&p, target)
				output: [1]Patch_Projection_Row
				history_test_expect(failures, found && patch_projection_viewport(&p, row, output[:]) == 1 && output[0].folded && int(output[0].target.hunk) == hi, "hidden selections resolve to their own placeholder")
			}
		}
		// All hunks coexist folded; expand in reverse order and compare the
		// final rows and both source-coordinate systems with the parsed model.
		for hi := len(p.hunks)-1; hi >= 0; hi -= 1 { if p.hunks[hi].collapsed { _ = patch_projection_toggle_hunk(&p, Patch_Hunk_Ordinal(hi)) } }
		history_test_expect(failures, patch_projection_measure(&p) == original, "non-LIFO unfolds recover exact measures")
		for row in viewport[:written] {
			if row.line.hunk || row.target.kind != .Line { continue }
			if row.line.old_line > 0 { found := patch_projection_seek_old(&p, Patch_Old_Line(row.line.old_line)); expected, _ := patch_projection_resolve(&p, row.target); history_test_expect(failures, found.kind == .Visible && found.row == expected && found.line == row.target.line, "typed old-file seeking") }
			if row.line.new_line > 0 { found := patch_projection_seek_new(&p, Patch_New_Line(row.line.new_line)); expected, _ := patch_projection_resolve(&p, row.target); history_test_expect(failures, found.kind == .Visible && found.row == expected && found.line == row.target.line, "typed new-file seeking") }
		}
		history_test_expect(failures, tracker.total_allocation_count == allocation_count, "folds and dimensional queries allocate nothing")
		history_test_expect(failures, patch_projection_seek_old(&p, Patch_Old_Line(0)).kind == .Missing && patch_projection_seek_new(&p, Patch_New_Line(-1)).kind == .Missing, "file source coordinates are explicitly one-based")
		_, stale := patch_projection_resolve(&p, Patch_Target{epoch=11, kind=.Header, valid=true})
		history_test_expect(failures, !stale, "another source epoch cannot bind")
		before_epoch, before_revision := p.epoch, p.revision
		history_test_expect(failures, !patch_projection_init(&p, &patch, 11, mem.nil_allocator()) && p.epoch == before_epoch && p.revision == before_revision && patch_projection_measure(&p) == original, "failed preparation preserves the old projection")
		delete(viewport)
		patch_projection_destroy(&p)
		history_test_expect(failures, tracker.current_memory_allocated == 0, "projection releases its owned allocation storage")
		mem.tracking_allocator_destroy(&tracker)
	}
	_, overflow := patch_measure_combine(Patch_Measure{rows=Patch_Display_Count(PATCH_COUNT_MAX)}, Patch_Measure{rows=1})
	history_test_expect(failures, !overflow, "aggregate counts reject overflow")
	history_test_fold_view(failures, large)
	history_test_fold_controls(failures)
}
history_test_fold_controls :: proc(failures: ^int) {
	app := history_app_new(".")
	defer { history_app_destroy(app); free(app) }
	history_profile_prepare(app, false)
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1200, 800})
	defer alicorn.destroy_runtime(&rt)
	_ = alicorn.text_engine_load_font(&rt.text_engine, HISTORY_TEST_FONT)
	build := proc(app: ^History_App, rt: ^alicorn.Runtime) {
		for _ in 0..<4 {
			_ = history_build(rawptr(app), rt, 1200, 800, 1)
			if !rt.invalidated { return }
		}
	}
	build(app, &rt)
	visible := Patch_Projection_Row{}
	found := false
	for row in app.patch_view_rows { if row.target.kind == .Line && !row.folded { visible = row; found = true; break } }
	history_test_expect(failures, found, "native-view description realizes a source selection control")
	if !found { return }
	history_test_expect(failures, alicorn.semantic_action_request(&rt, history_patch_row_semantic(app, visible), .Press), "gutter selection accepts accessible Press")
	build(app, &rt)
	history_test_expect(failures, app.patch_selection == visible.target, "real row control selects source identity")
	history_test_expect(failures, alicorn.semantic_action_request(&rt, history_patch_fold_semantic(app, visible.target.hunk), .Press), "real hunk control accepts accessible Press")
	build(app, &rt)
	history_test_expect(failures, app.patch_projection.hunks[int(visible.target.hunk)].collapsed && app.patch_selection == visible.target, "hunk control folds without discarding selection")
	placeholder := Patch_Projection_Row{}
	fold_visible := false
	for row in app.patch_view_rows { if row.folded && row.target.hunk == visible.target.hunk { placeholder = row; fold_visible = true; break } }
	history_test_expect(failures, fold_visible && history_patch_row_selected(app, placeholder), "selected source remains highlighted as a placeholder")
	if fold_visible {
		history_test_expect(failures, alicorn.semantic_action_request(&rt, history_patch_row_semantic(app, placeholder), .Press), "placeholder accepts accessible expand")
		build(app, &rt)
		history_test_expect(failures, !app.patch_projection.hunks[int(visible.target.hunk)].collapsed && app.patch_selection == visible.target, "placeholder expansion recovers the selected source row")
	}
}
history_test_fold_view :: proc(failures: ^int, fixture: string) {
	app := history_app_new(".")
	defer { history_app_destroy(app); free(app) }
	app.folding_enabled = true
	app.latest_patch_id = 5
	app.patch, _ = git_parse_patch(transmute([]byte)fixture)
	history_prepare_patch_projection(app)
	app.patch_selection = {epoch=5, kind=.Line, hunk=0, line=20, byte=3, valid=true}
	selection := app.patch_selection
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 700, 400})
	defer alicorn.destroy_runtime(&rt)
	font_ok := alicorn.text_engine_load_font(&rt.text_engine, HISTORY_TEST_FONT)
	history_test_expect(failures, font_ok, "fold viewport registers real font bytes")
	build := proc(app: ^History_App, rt: ^alicorn.Runtime) {
		ui, should_build := alicorn.begin_frame(rt)
		if !should_build { return }
		root := alicorn.container_begin(&ui, .Container, style=alicorn.layout_style(width=700, height=400))
		_ = root
		list := alicorn.virtual_list_begin(&ui, int(patch_projection_measure(&app.patch_projection).rows), HISTORY_PATCH_LINE_HEIGHT, key=alicorn.key_string("fold-scroll"), content_width=1000, axes=.Both, style=alicorn.layout_style(grow=1, clip=true))
		app.patch_scroll_node = list.scroll.id
		for position in list.first..<list.last { alicorn.text(&ui, "row", style=alicorn.layout_style(height=HISTORY_PATCH_LINE_HEIGHT)) }
		alicorn.virtual_list_end(&ui, list)
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
		history_restore_patch_anchor(app, rt)
	}
	build(app, &rt)
	_ = alicorn.scroll_region_set_offset(&rt, app.patch_scroll_node, 21*HISTORY_PATCH_LINE_HEIGHT+5, "fixture source scroll")
	_ = alicorn.scroll_region_set_offset_x(&rt, app.patch_scroll_node, 35, "fixture source x")
	build(app, &rt)
	history_test_expect(failures, history_toggle_patch_hunk(app, &rt, Patch_Hunk_Ordinal(0)), "fold visible native-layout source anchor")
	build(app, &rt); build(app, &rt)
	history_test_expect(failures, app.patch_selection == selection && app.patch_view_anchor.kind == .Line && int(app.patch_view_anchor.line) == 20, "selection and hidden scroll target retain source identity")
	_ = history_toggle_patch_hunk(app, &rt, Patch_Hunk_Ordinal(0))
	build(app, &rt); build(app, &rt)
	history_test_expect(failures, abs(alicorn.scroll_region_offset(&rt, app.patch_scroll_node)-(21*HISTORY_PATCH_LINE_HEIGHT+5)) < 0.25 && alicorn.scroll_region_offset_x(&rt, app.patch_scroll_node) == 35, "unfold restores source-relative vertical and horizontal scroll")
	history_test_expect(failures, app.patch_selection == selection, "source selection survives node removal and realization")
	app.patch_view_anchor = selection
	app.patch_anchor_pending = true
	app.patch_hunk_navigation_pending = true
	app.patch_pending_hunk = 1
	alicorn.invalidate_root(&rt, "newer hunk navigation")
	build(app, &rt); build(app, &rt)
	nav_row, _ := patch_projection_seek_hunk(&app.patch_projection, 1)
	current_scroll := alicorn.scroll_region_state(&rt, app.patch_scroll_node)
	nav_offset := clamp(f32(nav_row)*HISTORY_PATCH_LINE_HEIGHT-2*HISTORY_PATCH_LINE_HEIGHT, 0, current_scroll.max_scroll_y)
	history_test_expect(failures, !app.patch_anchor_pending && !app.patch_view_anchor.valid && abs(current_scroll.offset_y-nav_offset) < 0.25, "explicit navigation supersedes a pending fold anchor")
	// Stale results must not destroy the current UI-owned projection.
	result := new(History_Result)
	result.kind = .Load_File_Patch; result.patch_id = 4
	app.has_selection = true
	history_test_expect(failures, !history_adopt_result(app, result) && app.patch_projection_ready && app.patch_projection.epoch == 5, "stale worker publication cannot replace a live projection")
}
