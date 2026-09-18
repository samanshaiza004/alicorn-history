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

history_test_scroll_wakes_in_bounds :: proc(failures: ^int) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 640, 480})
	defer alicorn.destroy_runtime(&rt)
	app := History_App{
		visible=make([dynamic]int, 100),
		list_viewport_height=100,
		row_height=20,
	}
	defer delete(app.visible)
	history_on_scroll(rawptr(&app), &rt, alicorn.Scroll_Event{delta_y=-1, y=200})
	history_test_expect(failures, app.scroll_y == 20, "in-bounds scrolling advances by one row")
	history_test_expect(failures, rt.invalidated, "in-bounds scrolling invalidates the application")
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
	history_test_scroll_wakes_in_bounds(&failures)
	history_test_refresh_releases_commit_storage(&failures)
	history_test_worker_shutdown_stress(&failures, repository)
	history_test_detail_generation_domains(&failures)

	stdout, stderr, _, command_ok := git_run(repository, []string{
		"log", "--all", "--topo-order", "--date=unix",
		"--pretty=format:%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00",
	})
	history_test_expect(&failures, command_ok, "installed Git can read the target repository")
	if command_ok {
		real_commits, real_error := git_parse_log(stdout)
		history_test_expect(&failures, len(real_error) == 0, "real repository output parses completely")
		history_test_expect(&failures, len(real_commits) > 0, "real repository produces commits")
		if len(real_commits) > 0 {
			detail, detail_error := git_load_commit_detail(repository, real_commits[0].id)
			history_test_expect(&failures, len(detail_error) == 0, "selected commit detail query succeeds")
			history_test_expect(&failures, detail.id == real_commits[0].id, "commit detail preserves stable Git identity")
			history_test_expect(&failures, len(detail.files) > 0, "commit detail includes changed-file metadata")
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
