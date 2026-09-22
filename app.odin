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
	selected_commit_index: int,
	filter_node:         alicorn.Node_ID,
	history_scroll_node: alicorn.Node_ID,
	loading:             bool,
	error_text:          string,
	next_history_id:     History_Request_ID,
	latest_history_id:   History_Request_ID,
	next_detail_id:      Detail_Request_ID,
	latest_detail_id:    Detail_Request_ID,
	next_patch_id:       Patch_Request_ID,
	latest_patch_id:     Patch_Request_ID,
	detail:              Commit_Detail,
	detail_loading:      bool,
	detail_error:        string,
	selected_file_index: int,
	selected_file_path:  string,
	patch:               File_Patch,
	patch_loading:       bool,
	patch_error:         string,
	select_first_on_load: bool,
	result_count:        u64,
	build_count:         u64,
	worker:              Git_Worker,
	waker:               host.Application_Waker,
	dialogs:             host.Dialog_Service,
	pending_repository:  string,
	pending_repository_active: bool,
}

history_app_new :: proc(repository: string) -> ^History_App {
	app := new(History_App)
	copy, err := strings.clone(repository)
	if err != nil {
		free(app)
		return nil
	}
	app.repository = copy
	app.selected_commit_index = -1
	app.selected_file_index = -1
	app.visible = make([dynamic]int, 0, 1024)
	return app
}

history_app_destroy :: proc(app: ^History_App) {
	if app == nil { return }
	git_worker_destroy(&app.worker)
	history_destroy_commits(app)
	commit_detail_destroy(&app.detail)
	file_patch_destroy(&app.patch)
	delete(app.visible)
	if len(app.repository) > 0 { delete(app.repository) }
	if len(app.branch) > 0 { delete(app.branch) }
	if len(app.filter) > 0 { delete(app.filter) }
	if len(app.selected_id) > 0 { delete(app.selected_id) }
	if len(app.error_text) > 0 { delete(app.error_text) }
	if len(app.detail_error) > 0 { delete(app.detail_error) }
	if len(app.selected_file_path) > 0 { delete(app.selected_file_path) }
	if len(app.patch_error) > 0 { delete(app.patch_error) }
	if len(app.pending_repository) > 0 { delete(app.pending_repository) }
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

history_worker_submit_repository :: proc(app: ^History_App, repository: string) -> bool {
	app.next_history_id += 1
	request := new(Git_Request)
	request.history_id = app.next_history_id
	request.kind = .Load_History
	copy, err := strings.clone(repository)
	if err != nil {
		free(request)
		return false
	}
	request.repository = copy
	if !git_worker_request(&app.worker, request) {
		git_request_destroy(request)
		return false
	}
	app.latest_history_id = request.history_id
	app.loading = true
	if len(app.error_text) > 0 {
		delete(app.error_text)
		app.error_text = ""
	}
	return true
}

history_worker_submit :: proc(app: ^History_App) -> bool {
	return history_worker_submit_repository(app, app.repository)
}

history_begin_repository_load :: proc(app: ^History_App, repository: string, rt: ^alicorn.Runtime = nil) -> bool {
	copy, err := strings.clone(repository)
	if err != nil { return false }
	if len(app.pending_repository) > 0 { delete(app.pending_repository) }
	app.pending_repository = copy
	app.pending_repository_active = true
	if !history_worker_submit_repository(app, repository) {
		delete(app.pending_repository)
		app.pending_repository = ""
		app.pending_repository_active = false
		return false
	}
	app.loading = true
	if rt != nil { alicorn.invalidate_root(rt, "repository load requested") }
	return true
}

history_result_is_current :: proc(app: ^History_App, result_id: History_Request_ID) -> bool {
	return result_id == app.latest_history_id
}

detail_result_is_current :: proc(app: ^History_App, result_id: Detail_Request_ID) -> bool {
	return result_id == app.latest_detail_id
}

history_reset_detail_storage :: proc(app: ^History_App) {
	commit_detail_destroy(&app.detail)
	if len(app.detail_error) > 0 { delete(app.detail_error) }
	app.detail_error = ""
	app.detail_loading = false
	app.selected_file_index = -1
	if len(app.selected_file_path) > 0 { delete(app.selected_file_path) }
	app.selected_file_path = ""
	history_invalidate_patch(app)
}

history_reset_patch_storage :: proc(app: ^History_App) {
	file_patch_destroy(&app.patch)
	if len(app.patch_error) > 0 { delete(app.patch_error) }
	app.patch_error = ""
	app.patch_loading = false
}

history_invalidate_detail :: proc(app: ^History_App) {
	app.next_detail_id += 1
	app.latest_detail_id = app.next_detail_id
	history_reset_detail_storage(app)
}

history_invalidate_patch :: proc(app: ^History_App) {
	app.next_patch_id += 1
	app.latest_patch_id = app.next_patch_id
	history_reset_patch_storage(app)
}

history_worker_submit_detail :: proc(app: ^History_App) -> bool {
	if !app.has_selection { return false }
	selected := app.selected_commit_index
	if selected < 0 || selected >= len(app.commits) || app.commits[selected].id != app.selected_id {
		selected = -1
	}
	if selected < 0 { history_invalidate_detail(app); return false }

	app.next_detail_id += 1
	app.latest_detail_id = app.next_detail_id
	history_reset_detail_storage(app)
	app.detail_loading = true
	request := new(Git_Request)
	request.kind = .Load_Commit_Detail
	request.detail_id = app.next_detail_id
	request.repository, _ = strings.clone(app.repository)
	request.commit_id, _ = strings.clone(app.commits[selected].id)
	if len(request.repository) == 0 || len(request.commit_id) == 0 ||
		!git_worker_request(&app.worker, request) {
		git_request_destroy(request)
		app.detail_loading = false
		app.detail_error, _ = strings.clone("Commit detail request could not be queued")
		return false
	}
	return true
}

patch_result_is_current :: proc(app: ^History_App, result_id: Patch_Request_ID) -> bool {
	return result_id == app.latest_patch_id
}

history_worker_submit_patch :: proc(app: ^History_App) -> bool {
	if !app.has_selection || app.selected_file_index < 0 || app.selected_file_index >= len(app.detail.files) {
		history_invalidate_patch(app)
		return false
	}
	file := app.detail.files[app.selected_file_index]
	app.next_patch_id += 1
	app.latest_patch_id = app.next_patch_id
	file_patch_destroy(&app.patch)
	if len(app.patch_error) > 0 { delete(app.patch_error) }
	app.patch_error = ""
	app.patch_loading = true
	request := new(Git_Request)
	request.kind = .Load_File_Patch
	request.patch_id = app.next_patch_id
	request.repository, _ = strings.clone(app.repository)
	request.commit_id, _ = strings.clone(app.selected_id)
	request.file_path, _ = strings.clone(file.path)
	if len(request.repository) == 0 || len(request.commit_id) == 0 || len(request.file_path) == 0 ||
		!git_worker_request(&app.worker, request) {
		git_request_destroy(request)
		app.patch_loading = false
		app.patch_error, _ = strings.clone("File patch request could not be queued")
		return false
	}
	return true
}

history_select_file_index :: proc(app: ^History_App, index: int) -> bool {
	if index < 0 || index >= len(app.detail.files) { return false }
	file := app.detail.files[index]
	if app.selected_file_index == index && app.selected_file_path == file.path { return false }
	copy, err := strings.clone(file.path)
	if err != nil { return false }
	if len(app.selected_file_path) > 0 { delete(app.selected_file_path) }
	app.selected_file_path = copy
	app.selected_file_index = index
	return history_worker_submit_patch(app)
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

history_on_services :: proc(state: rawptr, services: host.Application_Services) {
	app := cast(^History_App)state
	app.dialogs = services.dialogs
}

history_open_repository :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	request := host.File_Dialog_Request{
		id=host.Dialog_ID(1),
		kind=.Open_Folder,
		title="Open Git Repository",
		initial_location=app.repository,
		allow_many=false,
		accept_label="Open",
		cancel_label="Cancel",
	}
	if !host.ShowFileDialog(app.dialogs, request) {
		if len(app.error_text) > 0 { delete(app.error_text) }
		app.error_text, _ = strings.clone("Open Repository is busy or unavailable")
		alicorn.invalidate_root(rt, "repository dialog unavailable")
	}
}

history_on_dialog :: proc(state: rawptr, rt: ^alicorn.Runtime, result: ^host.File_Dialog_Result) {
	app := cast(^History_App)state
	if result == nil || result.status != .Accepted || len(result.paths) == 0 { return }
	// The host-owned result is borrowed only for this callback. Copy the path
	// before returning; the dialog bridge releases its storage immediately after.
	if !history_begin_repository_load(app, result.paths[0], rt) {
		if len(app.error_text) > 0 { delete(app.error_text) }
		app.error_text, _ = strings.clone("Selected repository could not be queued")
	}
}

history_on_wake :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^History_App)state
	history_poll_results(app, rt)
}

history_on_stop :: proc(state: rawptr) {
	app := cast(^History_App)state
	git_worker_destroy(&app.worker)
}

history_adopt_result :: proc(app: ^History_App, result: ^History_Result) -> bool {
	if result.kind == .Load_File_Patch {
		if !patch_result_is_current(app, result.patch_id) || !app.has_selection ||
			(len(result.error_text) == 0 && result.patch.path != app.selected_file_path) {
			history_result_destroy(result)
			free(result)
			return false
		}
		history_reset_patch_storage(app)
		app.patch = result.patch
		result.patch = {}
		history_patch_prepare_display(&app.patch)
		app.patch_error = result.error_text
		result.error_text = ""
		app.patch_loading = false
		history_result_destroy(result)
		free(result)
		return true
	}
	if result.kind == .Load_Commit_Detail {
		if !detail_result_is_current(app, result.detail_id) || !app.has_selection ||
			(len(result.error_text) == 0 && result.detail.id != app.selected_id) {
			history_result_destroy(result)
			free(result)
			return false
		}
		history_reset_detail_storage(app)
		app.detail = result.detail
		result.detail = {}
		app.detail_error = result.error_text
		result.error_text = ""
		app.detail_loading = false
		if len(app.detail.files) > 0 {
			app.selected_file_index = -1
			_ = history_select_file_index(app, 0)
		}
		history_result_destroy(result)
		free(result)
		return true
	}
	if !history_result_is_current(app, result.history_id) {
		history_result_destroy(result)
		free(result)
		return false
	}
	if app.pending_repository_active && len(result.error_text) > 0 {
		// A candidate repository is validated asynchronously. Keep the current
		// repository and its visible history intact when Git rejects the candidate.
		if len(app.error_text) > 0 { delete(app.error_text) }
		app.error_text = result.error_text
		result.error_text = ""
		app.loading = false
		if len(app.pending_repository) > 0 { delete(app.pending_repository) }
		app.pending_repository = ""
		app.pending_repository_active = false
		history_result_destroy(result)
		free(result)
		return true
	}
	if app.pending_repository_active {
		if len(app.pending_repository) > 0 { delete(app.pending_repository) }
		app.pending_repository = ""
		app.pending_repository_active = false
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
	if app.select_first_on_load && !app.has_selection && len(app.visible) > 0 {
		history_select_visible_index(app, 0)
	}
	if !app.has_selection { history_invalidate_detail(app) }
	history_result_destroy(result)
	free(result)
	return true
}

history_poll_results :: proc(app: ^History_App, rt: ^alicorn.Runtime) {
	changed := false
	history_changed := false
	for {
		result, ok := chan.try_recv(app.worker.history_results)
		if !ok || result == nil { break }
		accepted := history_adopt_result(app, result)
		if accepted { changed = true; history_changed = true }
	}
	for {
		result, ok := chan.try_recv(app.worker.detail_results)
		if !ok || result == nil { break }
		accepted := history_adopt_result(app, result)
		if accepted { changed = true }
	}
	for {
		result, ok := chan.try_recv(app.worker.patch_results)
		if !ok || result == nil { break }
		accepted := history_adopt_result(app, result)
		if accepted { changed = true }
	}
	if history_changed && app.has_selection {
		// A refresh may replace the selected commit's metadata while keeping
		// its object ID. Re-request details in its independent generation
		// domain so the pane cannot silently display an old body/file list.
		_ = history_worker_submit_detail(app)
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
		app.selected_commit_index = -1
		for commit, index in app.commits {
			if commit.id == app.selected_id {
				app.selected_commit_index = index
				found = true
				break
			}
		}
		if !found {
			delete(app.selected_id)
			app.selected_id = ""
			app.has_selection = false
			app.selected_commit_index = -1
		}
	}
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
	app.selected_commit_index = app.visible[position]
}

history_move_selection :: proc(app: ^History_App, delta: int) -> (changed: bool, selected_position: int) {
	if len(app.visible) == 0 { return false, -1 }
	position := 0
	if app.has_selection {
		for i, index in app.visible {
			if index == app.selected_commit_index {
				position = i
				break
			}
		}
	}
	position += delta
	if position < 0 { position = 0 }
	if position >= len(app.visible) { position = len(app.visible)-1 }
	if app.has_selection && app.commits[app.visible[position]].id == app.selected_id { return false, position }
	history_select_visible_index(app, position)
	return true, position
}

history_on_text_change :: proc(state: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^History_App)state
	if change.node != app.filter_node || !change.changed { return }
	copy, err := strings.clone(change.text)
	if err != nil { return }
	if len(app.filter) > 0 { delete(app.filter) }
	app.filter = copy
	history_rebuild_visible(app)
	if !app.has_selection { history_invalidate_detail(app) }
	alicorn.invalidate_root(rt, "history filter changed")
}

history_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^History_App)state
	delta := 0
	list := alicorn.scroll_region_state(rt, app.history_scroll_node)
	#partial switch key {
	case .Up: delta = -1
	case .Down: delta = 1
	case .Page_Up: delta = -max(1, int(list.viewport_height/HISTORY_COMMIT_ROW_HEIGHT)-1)
	case .Page_Down: delta = max(1, int(list.viewport_height/HISTORY_COMMIT_ROW_HEIGHT)-1)
	case: return false
	}
	changed, position := history_move_selection(app, delta)
	if changed {
		_ = history_worker_submit_detail(app)
		_ = alicorn.virtual_list_ensure_visible(rt, app.history_scroll_node, position, "history selection visibility")
		alicorn.invalidate_root(rt, "history selection changed")
	}
	return changed
}
