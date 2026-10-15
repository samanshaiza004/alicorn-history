package main

import "core:fmt"
import "core:sort"
import "core:strings"
import "core:time"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

// Explicit bounded native validation, never a production tick/polling path.
// It drives the real History build, text shaping, GPU submission and scrolling.
History_Fold_Profile :: struct {
	enabled, baseline, complete: bool,
	scheduler: host.Application_Scheduler,
	step, render_step, failures, target_hunk: int,
	target, original_selection: Patch_Target,
	original_offset: f32,
	expanded_index_bytes: int,
	ordinary_builds: [dynamic]i64,
	fold_builds: [dynamic]i64,
}
history_profile_prepare :: proc(app: ^History_App, baseline: bool) {
	app.fold_profile = History_Fold_Profile{enabled=true, baseline=baseline, target_hunk=6, render_step=-1}
	app.folding_enabled = !baseline
	app.latest_patch_id = 1
	app.has_selection = true
	app.selected_commit_index = 0
	app.selected_id, _ = strings.clone("3a22f387ef4003da82eea53aa27657471c71a899")
	commit := Commit{}
	commit.id, _ = strings.clone(app.selected_id)
	commit.subject, _ = strings.clone("History native folding projection profile")
	app.commits = make([dynamic]Commit, 0, 1); append(&app.commits, commit)
	append(&app.visible, 0)
	app.detail.id, _ = strings.clone(app.selected_id)
	app.selected_file_path, _ = strings.clone("history_view.odin")
	app.selected_file_index = 0
	app.detail.files = make([dynamic]Changed_File, 0, 1)
	file := Changed_File{status=.Modified}; file.path, _ = strings.clone(app.selected_file_path)
	append(&app.detail.files, file)
	app.patch, _ = git_parse_patch(transmute([]byte)HISTORY_FOLD_REAL_PATCH)
	app.patch.path, _ = strings.clone(app.selected_file_path)
	app.fold_profile.expanded_index_bytes = cap(app.patch.display_lines)*size_of(Patch_Display_Line)
	history_prepare_patch_projection(app)
	app.selected_patch_hunk = 6
	app.fold_profile.target = {epoch=1, kind=.Line, hunk=6, line=5, byte=2, valid=true}
	app.patch_selection = app.fold_profile.target
	app.fold_profile.original_selection = app.patch_selection
	app.fold_profile.ordinary_builds = make([dynamic]i64, 0, 80)
	app.fold_profile.fold_builds = make([dynamic]i64, 0, 32)
}
history_profile_expect :: proc(app: ^History_App, condition: bool, message: string) {
	if !condition { app.fold_profile.failures += 1; fmt.println("FAIL native folding:", message) }
}
history_profile_schedule :: proc(app: ^History_App) {
	_ = host.application_schedule_after(app.fold_profile.scheduler, .Frequent, 40_000_000)
}
history_profile_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, dpi: f32) -> alicorn.Node_ID {
	app := cast(^History_App)state
	start := time.now()
	root := history_build(state, rt, width, height, dpi)
	elapsed := time.duration_nanoseconds(time.since(start))
	if app.fold_profile.render_step >= 8 && app.fold_profile.render_step < 37 && !app.fold_profile.complete { append(&app.fold_profile.ordinary_builds, elapsed) }
	if app.fold_profile.render_step >= 1 && app.fold_profile.render_step < 8 { append(&app.fold_profile.fold_builds, elapsed) }
	return root
}
history_profile_check_anchor :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	row, valid := patch_projection_resolve(&app.patch_projection, app.patch_view_anchor)
	scroll := alicorn.scroll_region_state(rt, app.patch_scroll_node)
	desired := clamp(f32(row)*HISTORY_PATCH_LINE_HEIGHT+f32(app.patch_view_fraction), 0, scroll.max_scroll_y)
	history_profile_expect(app, valid && abs(scroll.offset_y-desired) < 0.25, "presented scroll resolves the original source anchor")
	history_profile_expect(app, app.patch_selection == app.fold_profile.original_selection, "selection survives native fold presentations")
	history_profile_expect(app, abs(scroll.offset_x-35) < 0.25, "horizontal scroll survives folds")
}
history_profile_on_scheduled :: proc(state: rawptr, rt: ^alicorn.Runtime, _: host.Scheduled_Wake_Class) {
	app := cast(^History_App)state
	p := &app.fold_profile
	if !p.enabled { return }
	if p.complete { alicorn.invalidate_root(rt, "bounded profile final capture"); return }
	p.render_step = p.step
	if p.step == 0 {
		row := Patch_Display_Row(history_patch_hunk_display_index(app.patch, p.target_hunk)+1+int(p.target.line))
		if app.patch_projection_ready { row, _ = patch_projection_resolve(&app.patch_projection, p.target) }
		_ = alicorn.scroll_region_set_offset(rt, app.patch_scroll_node, f32(row)*HISTORY_PATCH_LINE_HEIGHT+5, "native fixture source scroll")
		_ = alicorn.scroll_region_set_offset_x(rt, app.patch_scroll_node, 35, "native fixture horizontal scroll")
		p.original_offset = alicorn.scroll_region_offset(rt, app.patch_scroll_node)
		alicorn.invalidate_root(rt, "native fixture initial viewport")
	} else if p.step < 8 && !p.baseline {
		if p.step > 1 && p.step < 7 { history_profile_check_anchor(app, rt) }
		switch p.step {
		case 1: _ = history_toggle_patch_hunk(app, rt, 0)
		case 2: _ = history_toggle_patch_hunk(app, rt, Patch_Hunk_Ordinal(p.target_hunk))
		case 3: _ = history_toggle_patch_hunk(app, rt, 0)
		case 4: _ = history_toggle_patch_hunk(app, rt, Patch_Hunk_Ordinal(p.target_hunk))
		case 5:
			history_profile_expect(app, abs(alicorn.scroll_region_offset(rt, app.patch_scroll_node)-p.original_offset) < 0.25, "native unfold restores fractional original scroll")
			_ = history_toggle_patch_hunk(app, rt, Patch_Hunk_Ordinal(p.target_hunk))
		case 6:
			_ = alicorn.scroll_region_set_offset(rt, app.patch_scroll_node, alicorn.scroll_region_offset(rt, app.patch_scroll_node)+44, "native fixture newer scrolling")
		case 7:
			_ = history_toggle_patch_hunk(app, rt, Patch_Hunk_Ordinal(p.target_hunk))
			history_profile_expect(app, app.patch_view_anchor != p.target, "newer scrolling supersedes a hidden restore anchor")
		}
	} else if p.step >= 8 {
		if !p.baseline && p.step == 8 { history_profile_check_anchor(app, rt) }
		// Same warm ordinary-scroll trace for expanded and compact viewing.
		scroll := alicorn.scroll_region_state(rt, app.patch_scroll_node)
		fraction := f32((p.step*37)%101)/100
		_ = alicorn.scroll_region_set_offset(rt, app.patch_scroll_node, scroll.max_scroll_y*fraction, "native viewport profile scroll")
		alicorn.invalidate_root(rt, "native ordinary viewport profile")
	}
	p.step += 1
	if p.step >= 38 {
		p.complete = true
		if !p.baseline {
			row, ok := patch_projection_seek_hunk(&app.patch_projection, Patch_Hunk_Ordinal(p.target_hunk))
			if ok {
				_ = alicorn.scroll_region_set_offset(rt, app.patch_scroll_node, max(0, f32(row-2)*HISTORY_PATCH_LINE_HEIGHT), "profile final hunk view")
				app.patch_view_anchor = {}
				_ = history_toggle_patch_hunk(app, rt, Patch_Hunk_Ordinal(p.target_hunk))
			}
		}
		// One finite wake makes --capture-after=2 observable after the trace.
		_ = host.application_schedule_after(p.scheduler, .Frequent, 700_000_000)
		fmt.println("native_projection_script", "baseline", p.baseline, "steps", p.step, "failures", p.failures)
		return
	}
	history_profile_schedule(app)
}
history_profile_report :: proc(app: ^History_App) {
	p := &app.fold_profile
	if !p.enabled { return }
	fmt.println("native_projection_memory", "baseline", p.baseline, "expanded_display_index_bytes", p.expanded_index_bytes, "span_capacity_bytes", cap(app.patch_projection.spans)*size_of(Patch_Span), "hunk_state_bytes", len(app.patch_projection.hunks)*size_of(Patch_Hunk_Projection), "directory_bytes", len(app.patch_projection.directory)*size_of(Patch_Measure), "viewport_buffer_bytes", cap(app.patch_view_rows)*size_of(Patch_Projection_Row))
	history_profile_expect(app, p.complete, "bounded native script completed")
	if len(p.ordinary_builds) > 0 {
		sort.quick_sort(p.ordinary_builds[:])
		fmt.println("native_history_build", "baseline", p.baseline, "samples", len(p.ordinary_builds), "p50_ns", p.ordinary_builds[len(p.ordinary_builds)/2], "p95_ns", p.ordinary_builds[(len(p.ordinary_builds)*95)/100])
	}
	if len(p.fold_builds) > 0 {
		sort.quick_sort(p.fold_builds[:])
		fmt.println("native_history_fold_build", "samples", len(p.fold_builds), "p95_ns", p.fold_builds[(len(p.fold_builds)*95)/100])
	}
}
