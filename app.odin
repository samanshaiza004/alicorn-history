package main

import "core:fmt"
import "core:strings"
import "core:sync/chan"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

History_App :: struct {
	repository:          string,
	branch:              string,
	commits:             [dynamic]Commit,
	visible:             [dynamic]int,
	filter:              string,
	selected_id:         string,
	has_selection:       bool,
	scroll_y:            f32,
	list_viewport_height: f32,
	row_height:          f32,
	filter_node:         alicorn.Node_ID,
	loading:             bool,
	error_text:          string,
	next_request_id:     Git_Request_ID,
	latest_request_id:   Git_Request_ID,
	result_count:        u64,
	build_count:         u64,
	worker:              Git_Worker,
	waker:               host.Application_Waker,
}

history_app_new :: proc(repository: string) -> ^History_App {
	app := new(History_App)
	copy, err := strings.clone(repository)
	if err != nil {
		free(app)
		return nil
	}
	app.repository = copy
	app.row_height = 44
	app.list_viewport_height = 560
	app.visible = make([dynamic]int, 0, 1024)
	return app
}

history_app_destroy :: proc(app: ^History_App) {
	if app == nil { return }
	git_worker_destroy(&app.worker)
	history_destroy_commits(app)
	delete(app.visible)
	if len(app.repository) > 0 { delete(app.repository) }
	if len(app.branch) > 0 { delete(app.branch) }
	if len(app.filter) > 0 { delete(app.filter) }
	if len(app.selected_id) > 0 { delete(app.selected_id) }
	if len(app.error_text) > 0 { delete(app.error_text) }
	app^ = {}
}

history_clear_commits :: proc(app: ^History_App) {
	for i := 0; i < len(app.commits); i += 1 {
		commit_destroy(&app.commits[i])
	}
	clear(&app.commits)
}

history_destroy_commits :: proc(app: ^History_App) {
	history_clear_commits(app)
	delete(app.commits)
	app.commits = {}
}

history_worker_submit :: proc(app: ^History_App) -> bool {
	app.next_request_id += 1
	request := new(Git_Request)
	request.id = app.next_request_id
	request.kind = .Load_History
	copy, err := strings.clone(app.repository)
	if err != nil {
		free(request)
		return false
	}
	request.repository = copy
	if !git_worker_request(&app.worker, request) {
		delete(request.repository)
		free(request)
		return false
	}
	app.latest_request_id = request.id
	app.loading = true
	if len(app.error_text) > 0 {
		delete(app.error_text)
		app.error_text = ""
	}
	return true
}

history_result_is_current :: proc(app: ^History_App, result_id: Git_Request_ID) -> bool {
	return result_id == app.latest_request_id
}

history_worker_wake :: proc(data: rawptr) {
	app := cast(^History_App)data
	host.application_wake(app.waker)
}

history_on_start :: proc(state: rawptr, waker: host.Application_Waker) {
	app := cast(^History_App)state
	app.waker = waker
	git_worker_set_waker(&app.worker, Git_Waker{data=rawptr(app), wake=history_worker_wake})
	if !git_worker_start(&app.worker) {
		app.error_text, _ = strings.clone("Git worker could not start")
		app.loading = false
		return
	}
	if !history_worker_submit(app) {
		app.error_text, _ = strings.clone("Git history request could not be queued")
		app.loading = false
	}
}

history_on_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^History_App)state
	history_poll_results(app, rt)
}

history_adopt_result :: proc(app: ^History_App, result: ^History_Result) -> bool {
	if !history_result_is_current(app, result.id) {
		history_result_destroy(result)
		free(result)
		return false
	}
	history_destroy_commits(app)
	if len(app.branch) > 0 { delete(app.branch) }
	if len(app.error_text) > 0 { delete(app.error_text) }
	app.commits = result.commits
	result.commits = {}
	app.branch = result.branch
	result.branch = ""
	app.error_text = result.error_text
	result.error_text = ""
	if len(result.repository) > 0 {
		delete(app.repository)
		app.repository = result.repository
		result.repository = ""
	}
	app.loading = false
	app.result_count += 1
	history_rebuild_visible(app)
	history_result_destroy(result)
	free(result)
	return true
}

history_poll_results :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	changed := false
	for {
		result, ok := chan.try_recv(app.worker.results)
		if !ok || result == nil { break }
		if history_adopt_result(app, result) { changed = true }
	}
	if changed { alicorn.invalidate_root(rt, "git history result adopted") }
}

history_rebuild_visible :: proc(app: ^History_App) {
	clear(&app.visible)
	for commit, index in app.commits {
		if len(app.filter) > 0 {
			if !history_contains_folded(commit.id, app.filter) &&
				!history_contains_folded(commit.subject, app.filter) &&
				!history_contains_folded(commit.author_name, app.filter) {
				continue
			}
		}
		append(&app.visible, index)
	}
	if app.has_selection {
		found := false
		for index in app.visible {
			if app.commits[index].id == app.selected_id {
				found = true
				break
			}
		}
		if !found {
			delete(app.selected_id)
			app.selected_id = ""
			app.has_selection = false
		}
	}
	metrics := alicorn.virtual_list_metrics(len(app.visible), app.scroll_y, app.list_viewport_height, app.row_height)
	app.scroll_y = metrics.offset_y
}

history_ascii_lower :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value + ('a' - 'A') }
	return value
}

history_contains_folded :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(needle) > len(haystack) { return false }
	for start := 0; start <= len(haystack)-len(needle); start += 1 {
		matches := true
		for i := 0; i < len(needle); i += 1 {
			if history_ascii_lower(haystack[start+i]) != history_ascii_lower(needle[i]) {
				matches = false
				break
			}
		}
		if matches { return true }
	}
	return false
}

history_select_visible_index :: proc(app: ^History_App, position: int) {
	if position < 0 || position >= len(app.visible) { return }
	commit := app.commits[app.visible[position]]
	copy, err := strings.clone(commit.id)
	if err != nil { return }
	if len(app.selected_id) > 0 { delete(app.selected_id) }
	app.selected_id = copy
	app.has_selection = true
	if position < int(app.scroll_y / app.row_height) {
		app.scroll_y = f32(position) * app.row_height
	} else if f32(position+1)*app.row_height > app.scroll_y+app.list_viewport_height {
		app.scroll_y = f32(position+1)*app.row_height - app.list_viewport_height
	}
	metrics := alicorn.virtual_list_metrics(len(app.visible), app.scroll_y, app.list_viewport_height, app.row_height)
	app.scroll_y = metrics.offset_y
}

history_move_selection :: proc(app: ^History_App, delta: int) -> bool {
	if len(app.visible) == 0 { return false }
	position := 0
	if app.has_selection {
		for i, index in app.visible {
			if app.commits[index].id == app.selected_id {
				position = i
				break
			}
		}
	}
	position += delta
	if position < 0 { position = 0 }
	if position >= len(app.visible) { position = len(app.visible)-1 }
	if app.has_selection && app.commits[app.visible[position]].id == app.selected_id { return false }
	history_select_visible_index(app, position)
	return true
}

history_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^History_App)state
	if change.node != app.filter_node || !change.changed { return }
	copy, err := strings.clone(change.text)
	if err != nil { return }
	if len(app.filter) > 0 { delete(app.filter) }
	app.filter = copy
	history_rebuild_visible(app)
	alicorn.invalidate_root(rt, "history filter changed")
}

history_on_scroll :: proc(state: rawptr, rt: ^alicorn.Runtime, event: alicorn.Scroll_Event) {
	app := cast(^History_App)state
	if event.y < 120 { return }
	delta := event.delta_y
	if event.ticks_y != 0 { delta = f32(event.ticks_y) * 3 }
	old_scroll := app.scroll_y
	requested := old_scroll - delta * app.row_height
	metrics := alicorn.virtual_list_metrics(len(app.visible), requested, app.list_viewport_height, app.row_height)
	if metrics.offset_y != old_scroll {
		app.scroll_y = metrics.offset_y
		alicorn.invalidate_root(rt, "history scroll")
	}
}

history_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^History_App)state
	delta := 0
	#partial switch key {
	case .Up: delta = -1
	case .Down: delta = 1
	case .Page_Up: delta = -max(1, int(app.list_viewport_height/app.row_height)-1)
	case .Page_Down: delta = max(1, int(app.list_viewport_height/app.row_height)-1)
	case: return false
	}
	changed := history_move_selection(app, delta)
	if changed { alicorn.invalidate_root(rt, "history selection changed") }
	return changed
}
