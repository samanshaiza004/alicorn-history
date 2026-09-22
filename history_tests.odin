package main

import "core:fmt"
import "core:mem"
import "core:strings"
import alicorn "vendor/alicorn/runtime"

history_test_expect :: proc(failures: ^int, condition: bool, message: string) {
	if !condition {
		failures^ += 1
		fmt.println("FAIL:", message)
	}
}

history_test_refresh_releases_commit_storage :: proc(failures: ^int) {
	base_allocator := context.allocator
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, base_allocator)
	context.allocator = mem.tracking_allocator(&tracking)
	app := History_App{latest_history_id=History_Request_ID(1)}
	app.visible = make([dynamic]int, 0, 4)
	for _ in 0..<100 {
		result := new(History_Result)
		result.kind = .Load_History
		result.history_id = History_Request_ID(1)
		result.commits = make([dynamic]Commit, 0, 1)
		id, _ := strings.clone("0123456789abcdef")
		subject, _ := strings.clone("refresh commit")
		append(&result.commits, Commit{id=id, subject=subject})
		history_test_expect(failures, history_adopt_result(&app, result), "current refresh result is adopted")
	}
	history_destroy_commits(&app)
	delete(app.visible)
	context.allocator = base_allocator
	history_test_expect(failures, len(tracking.allocation_map) == 0, "repeated refreshes release replaced commit backing storage")
	mem.tracking_allocator_destroy(&tracking)
}

history_test_worker_shutdown_stress :: proc(failures: ^int, repository: string) {
	for _ in 0..<5 {
		worker: Git_Worker
		if !git_worker_start(&worker) {
			history_test_expect(failures, false, "Git worker starts for shutdown stress")
			continue
		}
		request := new(Git_Request)
		request.history_id = History_Request_ID(1)
		request.kind = .Load_History
		request.repository, _ = strings.clone(repository)
		if !git_worker_request(&worker, request) {
			delete(request.repository)
			free(request)
		}
		// Destroy immediately. Result delivery is nonblocking, so a worker
		// cannot wedge shutdown behind a full result mailbox.
		git_worker_destroy(&worker)
	}
}

history_test_detail_generation_domains :: proc(failures: ^int) {
	app := History_App{has_selection=true, latest_detail_id=Detail_Request_ID(2)}
	app.selected_id, _ = strings.clone("selected")
	defer {
		if len(app.selected_id) > 0 { delete(app.selected_id) }
		commit_detail_destroy(&app.detail)
	}
	stale := new(History_Result)
	stale.kind = .Load_Commit_Detail
	stale.detail_id = Detail_Request_ID(1)
	stale.detail.id, _ = strings.clone("selected")
	history_test_expect(failures, !history_adopt_result(&app, stale), "stale detail generation is rejected")

	current := new(History_Result)
	current.kind = .Load_Commit_Detail
	current.detail_id = Detail_Request_ID(2)
	current.detail.id, _ = strings.clone("selected")
	current.detail.subject, _ = strings.clone("selected subject")
	history_test_expect(failures, history_adopt_result(&app, current), "current detail generation is adopted")
	history_test_expect(failures, app.detail.subject == "selected subject", "current detail payload reaches the selected pane")
}

history_test_file_stats :: proc(failures: ^int) {
	binary := Changed_File{additions=-1, deletions=-1}
	history_test_expect(failures, history_file_stats_text(binary) == "—  —", "binary numstat values render as unavailable counts")
	text := Changed_File{additions=23, deletions=7}
	history_test_expect(failures, history_file_stats_text(text) == "+23 -7", "numeric numstat values retain their readable form")
}

history_test_patch_parser :: proc(failures: ^int) {
	fixture := "diff --git a/main.odin b/main.odin\n" +
		"index 1111111..2222222 100644\n" +
		"--- a/main.odin\n" +
		"+++ b/main.odin\n" +
		"@@ -1,2 +1,3 @@ package main\n" +
		" package main\n" +
		"-old\n" +
		"+new\n" +
		"+tail\n" +
		"\\ No newline at end of file\n"
	fixture_data := make([dynamic]u8, 0, len(fixture))
	append(&fixture_data, fixture)
	patch, error_text := git_parse_patch(fixture_data[:])
	delete(fixture_data)
	history_test_expect(failures, len(error_text) == 0, "structured patch parser accepts a unified hunk")
	history_test_expect(failures, len(patch.hunks) == 1, "structured patch parser returns one hunk")
	if len(patch.hunks) == 1 {
		history_test_expect(failures, patch.hunks[0].old_start == 1 && patch.hunks[0].new_start == 1, "hunk header preserves line origins")
		history_test_expect(failures, len(patch.hunks[0].lines) == 5, "hunk parser retains context, additions, deletion, and metadata")
		if len(patch.hunks[0].lines) >= 4 {
			history_test_expect(failures, patch.hunks[0].lines[1].kind == .Deletion, "deletion line kind is structured")
			history_test_expect(failures, patch.hunks[0].lines[2].kind == .Addition, "addition line kind is structured")
			history_test_expect(failures, patch.hunks[0].lines[3].new_line == 3, "added line advances new source numbering")
		}
	}
	file_patch_destroy(&patch)
	if len(error_text) > 0 { delete(error_text) }

	binary_fixture := "diff --git a/image.bin b/image.bin\nBinary files a/image.bin and b/image.bin differ\n"
	binary_data := make([dynamic]u8, 0, len(binary_fixture))
	append(&binary_data, binary_fixture)
	binary, binary_error := git_parse_patch(binary_data[:])
	delete(binary_data)
	history_test_expect(failures, len(binary_error) == 0 && binary.binary, "binary patch is represented explicitly")
	history_test_expect(failures, len(binary.metadata) == 1, "binary patch keeps its diagnostic metadata")
	file_patch_destroy(&binary)
	if len(binary_error) > 0 { delete(binary_error) }
}

history_test_patch_generation :: proc(failures: ^int) {
	app := History_App{
		has_selection=true,
		latest_patch_id=Patch_Request_ID(2),
		selected_file_index=0,
	}
	app.selected_id, _ = strings.clone("commit")
	app.selected_file_path, _ = strings.clone("main.odin")
	defer {
		if len(app.selected_id) > 0 { delete(app.selected_id) }
		if len(app.selected_file_path) > 0 { delete(app.selected_file_path) }
		file_patch_destroy(&app.patch)
		if len(app.patch_error) > 0 { delete(app.patch_error) }
	}

	stale := new(History_Result)
	stale.kind = .Load_File_Patch
	stale.patch_id = Patch_Request_ID(1)
	stale.patch.path, _ = strings.clone("main.odin")
	history_test_expect(failures, !history_adopt_result(&app, stale), "stale patch generation is rejected")

	current := new(History_Result)
	current.kind = .Load_File_Patch
	current.patch_id = Patch_Request_ID(2)
	current.patch.path, _ = strings.clone("main.odin")
	current.patch.metadata = make([dynamic]string, 0, 1)
	metadata, _ := strings.clone("mode 100644")
	append(&current.patch.metadata, metadata)
	history_test_expect(failures, history_adopt_result(&app, current), "current patch generation is adopted")
	history_test_expect(failures, len(app.patch.metadata) == 1, "current patch payload reaches the diff pane")
}

history_test_large_patch :: proc(failures: ^int) {
	data := make([dynamic]u8, 0, 48*5000)
	append(&data, "diff --git a/large.odin b/large.odin\n")
	append(&data, "--- a/large.odin\n+++ b/large.odin\n")
	append(&data, "@@ -1,0 +1,5000 @@\n")
	for _ in 0..<5000 { append(&data, "+line\n") }
	patch, error_text := git_parse_patch(data[:])
	delete(data)
	history_test_expect(failures, len(error_text) == 0, "large unified patch parses without an error")
	history_test_expect(failures, len(patch.hunks) == 1, "large unified patch retains its hunk")
	if len(patch.hunks) == 1 {
		history_test_expect(failures, len(patch.hunks[0].lines) == 5000, "large unified patch retains every source line")
		history_test_expect(failures, patch.hunks[0].lines[4999].new_line == 5000, "large unified patch preserves final line numbering")
	}
	history_test_expect(failures, history_patch_display_count(patch) == 5001, "large patch display includes the hunk header")
	last_line, last_line_ok := history_patch_display_line(patch, 5000)
	history_test_expect(failures, last_line_ok && last_line.text == "line" && last_line.new_line == 5000, "large patch display index resolves the final visible row directly")
	file_patch_destroy(&patch)
	if len(error_text) > 0 { delete(error_text) }
}

history_test_view_layout_and_focus :: proc(failures: ^int) {
	app := history_app_new(".")
	if app == nil {
		history_test_expect(failures, false, "history view fixture allocates its application state")
		return
	}
	defer {
		history_app_destroy(app)
		free(app)
	}
	app.loading = false
	app.branch, _ = strings.clone("main")
	app.commits = make([dynamic]Commit, 0, 48)
	for i := 0; i < 48; i += 1 {
		id := fmt.tprintf("%040x", i+1)
		subject := fmt.tprintf("history fixture commit %d", i+1)
		commit := Commit{}
		commit.id, _ = strings.clone(id)
		commit.subject, _ = strings.clone(subject)
		append(&app.commits, commit)
	}
	history_rebuild_visible(app)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1200, 800})
	defer alicorn.destroy_runtime(&rt)
	_ = history_build(rawptr(app), &rt, 1200, 800, 2)
	if rt.invalidated { _ = history_build(rawptr(app), &rt, 1200, 800, 2) }

	history_test_expect(failures, app.filter_node != 0, "history view retains its filter node")
	history_test_expect(failures, rt.focused == app.filter_node, "history view starts with the filter focused")
	if filter, ok := rt.nodes[app.filter_node]; ok {
		history_test_expect(failures, filter.bounds.y >= 0 && filter.bounds.y+filter.bounds.h <= rt.viewport.h, "filter bounds remain inside the window")
	}
	if list, ok := rt.nodes[app.history_scroll_node]; ok {
		history_test_expect(failures, list.bounds.y >= 0 && list.bounds.y+list.bounds.h <= rt.viewport.h, "history list viewport remains inside the window")
		history_test_expect(failures, list.scroll_content_height > list.scroll_viewport_height, "history list exposes scrollable content")
		history_test_expect(failures, list.scroll_offset_y >= 0 && list.scroll_offset_y <= list.scroll_content_height-list.scroll_viewport_height, "history scroll offset is clamped to its viewport")
	} else {
		history_test_expect(failures, false, "history scroll region is retained")
	}
	detail_panel: ^alicorn.Node = nil
	for _, node in rt.nodes {
		if node.label == "history-detail-panel" { detail_panel = node; break }
	}
	if detail_panel != nil {
		history_test_expect(failures, detail_panel.parent != 0, "history detail panel is retained under the main row")
		history_test_expect(failures, detail_panel.bounds.x > 500, "history detail panel is a sibling beside the commit list")
		history_test_expect(failures, detail_panel.bounds.y >= 0 && detail_panel.bounds.y+detail_panel.bounds.h <= rt.viewport.h, "history detail panel remains inside the window")
	} else {
		history_test_expect(failures, false, "history detail panel is retained")
	}
	if next := alicorn.focus_traverse(&rt, .Next); next != 0 {
		history_test_expect(failures, next != app.filter_node, "focus traversal advances past the filter")
	} else {
		history_test_expect(failures, false, "history view exposes a next focus target")
	}
}

history_test_clean_object_id :: proc(value: string) -> bool {
	for byte in value {
		if byte == '\n' || byte == '\r' || byte == 0 { return false }
	}
	return len(value) > 0
}

history_run_tests :: proc(repository: string) -> bool {
	failures := 0
	data := make([dynamic]u8, 0, 160)
	append(&data, "abc\x00parent\x00Ada\x00ada@example.com\x001700000000\x00first commit\x00\x00")
	append(&data, "def\x00\x00Grace\x00grace@example.com\x001700000001\x00second commit\x00\x00")
	commits, error_text := git_parse_log(data[:])
	delete(data)
	history_test_expect(&failures, len(error_text) == 0, "machine-readable log parser accepts NUL records")
	history_test_expect(&failures, len(commits) == 2, "machine-readable log parser returns every commit")
	if len(commits) == 2 {
		history_test_expect(&failures, len(commits[0].parents) == 1, "parent list parses without formatting")
		history_test_expect(&failures, commits[1].timestamp == 1700000001, "timestamps parse as integers")
	}
	for i := 0; i < len(commits); i += 1 { commit_destroy(&commits[i]) }
	delete(commits)
	if len(error_text) > 0 { delete(error_text) }

	current := History_App{latest_history_id=History_Request_ID(7)}
	history_test_expect(&failures, history_result_is_current(&current, History_Request_ID(7)), "latest history generation is accepted")
	history_test_expect(&failures, !history_result_is_current(&current, History_Request_ID(6)), "stale history generation is rejected")
	history_test_refresh_releases_commit_storage(&failures)
	history_test_worker_shutdown_stress(&failures, repository)
	history_test_detail_generation_domains(&failures)
	history_test_file_stats(&failures)
	history_test_patch_parser(&failures)
	history_test_patch_generation(&failures)
	history_test_large_patch(&failures)
	history_test_view_layout_and_focus(&failures)

	stdout, stderr, _, command_ok := git_run(repository, []string{
		"log", "--all", "--topo-order", "--date=unix", "-z",
		"--pretty=format:%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00",
	})
	history_test_expect(&failures, command_ok, "installed Git can read the target repository")
	if command_ok {
		real_commits, real_error := git_parse_log(stdout)
		history_test_expect(&failures, len(real_error) == 0, "real repository output parses completely")
		history_test_expect(&failures, len(real_commits) > 0, "real repository produces commits")
		limit := min(len(real_commits), 3)
		patch_tested := false
		for i := 0; i < limit; i += 1 {
			history_test_expect(&failures, history_test_clean_object_id(real_commits[i].id), fmt.tprintf("parsed commit %d has no record-separator bytes", i))
			detail, detail_error := git_load_commit_detail(repository, real_commits[i].id)
			history_test_expect(&failures, len(detail_error) == 0, fmt.tprintf("commit detail query succeeds for parsed commit %d", i))
			history_test_expect(&failures, detail.id == real_commits[i].id, fmt.tprintf("commit detail preserves stable identity for parsed commit %d", i))
			if !patch_tested && len(detail.files) > 0 {
				patch, patch_error := git_load_file_patch(repository, real_commits[i].id, detail.files[0].path)
				history_test_expect(&failures, len(patch_error) == 0, "selected file patch query succeeds")
				history_test_expect(&failures, patch.path == detail.files[0].path, "selected file patch preserves its path")
				file_patch_destroy(&patch)
				if len(patch_error) > 0 { delete(patch_error) }
				patch_tested = true
			}
			// Empty commits are valid Git objects; a successful detail query does
			// not require at least one changed file.
			commit_detail_destroy(&detail)
			if len(detail_error) > 0 { delete(detail_error) }
		}
		for i := 0; i < len(real_commits); i += 1 { commit_destroy(&real_commits[i]) }
		delete(real_commits)
		if len(real_error) > 0 { delete(real_error) }
	}
	if len(stdout) > 0 { delete(stdout) }
	if len(stderr) > 0 { delete(stderr) }
	if failures == 0 { fmt.println("Alicorn history tests: PASS"); return true }
	fmt.println("Alicorn history tests: FAILURES", failures)
	return false
}
