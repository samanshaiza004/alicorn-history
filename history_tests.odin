package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync/chan"
import "core:strings"
import "core:time"
import alicorn "vendor/alicorn/runtime"

history_test_expect :: proc(failures: ^int, condition: bool, message: string) {
	if !condition {
		failures^ += 1
		fmt.println("FAIL:", message)
	}
}

history_test_append_ref_record :: proc(data: ^[dynamic]u8, full_name, object_id, object_type, peeled_id, peeled_type, head, symref: string) {
	append(data, full_name)
	append(data, u8(0))
	append(data, object_id)
	append(data, u8(0))
	append(data, object_type)
	append(data, u8(0))
	append(data, peeled_id)
	append(data, u8(0))
	append(data, peeled_type)
	append(data, u8(0))
	append(data, head)
	append(data, u8(0))
	append(data, symref)
	append(data, u8(0))
	append(data, "\n")
}

history_test_find_ref :: proc(refs: [dynamic]Git_Ref, full_name: string) -> (index: int, found: bool) {
	index = -1
	for ref, i in refs {
		if ref.full_name == full_name { return i, true }
	}
	return
}

history_test_make_ref :: proc(full_name, short_name, object_id, target_commit_id: string, kind: Git_Ref_Kind, is_head: bool = false) -> Git_Ref {
	ref := Git_Ref{kind=kind, is_head=is_head}
	ref.full_name, _ = strings.clone(full_name)
	ref.short_name, _ = strings.clone(short_name)
	ref.object_id, _ = strings.clone(object_id)
	if len(target_commit_id) > 0 { ref.target_commit_id, _ = strings.clone(target_commit_id) }
	return ref
}

history_test_find_commit_row :: proc(rt: ^alicorn.Runtime, row_column: ^alicorn.Node) -> ^alicorn.Node {
	if rt == nil || row_column == nil { return nil }
	expected := alicorn.visual_part_identity_hash(
		alicorn.visual_part_extension_id("app.history", "commit-row"),
	)
	for id in row_column.children {
		node, found := rt.nodes[id]
		part, tagged := rt.visual_parts[id]
		if found && tagged && node.kind == .Button && alicorn.visual_part_identity_hash(part.identity) == expected {
			return node
		}
	}
	return nil
}

history_test_refs_parser :: proc(failures: ^int) {
	commit_oid := "1111111111111111111111111111111111111111"
	other_commit_oid := "2222222222222222222222222222222222222222"
	branch_oid := "3333333333333333333333333333333333333333"
	tag_object_oid := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	tree_oid := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	nested_tag_oid := "cccccccccccccccccccccccccccccccccccccccc"
	fixture := make([dynamic]u8, 0, 1024)
	history_test_append_ref_record(&fixture, "refs/heads/main", commit_oid, "commit", "", "", "*", "")
	history_test_append_ref_record(&fixture, "refs/heads/feature/foo", branch_oid, "commit", "", "", " ", "")
	history_test_append_ref_record(&fixture, "refs/remotes/origin/main", other_commit_oid, "commit", "", "", " ", "")
	history_test_append_ref_record(&fixture, "refs/remotes/origin/HEAD", other_commit_oid, "commit", "", "", " ", "refs/remotes/origin/main")
	history_test_append_ref_record(&fixture, "refs/tags/v0.1", other_commit_oid, "commit", "", "", " ", "")
	history_test_append_ref_record(&fixture, "refs/tags/release", tag_object_oid, "tag", commit_oid, "commit", " ", "")
	history_test_append_ref_record(&fixture, "refs/tags/tree-tag", tag_object_oid, "tag", tree_oid, "tree", " ", "")
	history_test_append_ref_record(&fixture, "refs/tags/nested-tag", tag_object_oid, "tag", nested_tag_oid, "tag", " ", "")
	refs, error_text := git_parse_refs(fixture[:])
	delete(fixture)
	history_test_expect(failures, len(error_text) == 0, "NUL-delimited for-each-ref records parse successfully")
	history_test_expect(failures, len(refs) == 7, "symbolic remote HEAD alias is omitted while real refs remain")

	main_index, main_found := history_test_find_ref(refs, "refs/heads/main")
	history_test_expect(failures, main_found, "full branch ref name is retained as identity")
	if main_found {
		history_test_expect(failures, refs[main_index].short_name == "main" && refs[main_index].kind == .Branch, "branch displays its short name and kind")
		history_test_expect(failures, refs[main_index].is_head, "HEAD marker survives the NUL parser")
		history_test_expect(failures, refs[main_index].target_commit_id == commit_oid, "branch target resolves to its commit")
	}
	feature_index, feature_found := history_test_find_ref(refs, "refs/heads/feature/foo")
	history_test_expect(failures, feature_found && refs[feature_index].short_name == "feature/foo", "nested branch names retain their slash suffix")
	remote_index, remote_found := history_test_find_ref(refs, "refs/remotes/origin/main")
	history_test_expect(failures, remote_found && refs[remote_index].short_name == "origin/main" && refs[remote_index].kind == .Remote, "remote refs display origin and branch name")
	light_tag_index, light_tag_found := history_test_find_ref(refs, "refs/tags/v0.1")
	history_test_expect(failures, light_tag_found && refs[light_tag_index].target_commit_id == other_commit_oid, "lightweight tag directly resolves to its commit")
	annotated_index, annotated_found := history_test_find_ref(refs, "refs/tags/release")
	history_test_expect(failures, annotated_found, "annotated tag remains visible")
	if annotated_found {
		history_test_expect(failures, refs[annotated_index].object_id == tag_object_oid, "annotated tag object identity is preserved")
		history_test_expect(failures, refs[annotated_index].target_commit_id == commit_oid, "annotated tag selects its peeled commit rather than the tag object")
	}
	tree_index, tree_found := history_test_find_ref(refs, "refs/tags/tree-tag")
	history_test_expect(failures, tree_found && len(refs[tree_index].target_commit_id) == 0, "tag to a tree is visible but cannot be selected as a commit")
	nested_index, nested_found := history_test_find_ref(refs, "refs/tags/nested-tag")
	history_test_expect(failures, nested_found && len(refs[nested_index].target_commit_id) == 0, "tag-to-tag ref is not mistaken for a commit")
	_, symbolic_found := history_test_find_ref(refs, "refs/remotes/origin/HEAD")
	history_test_expect(failures, !symbolic_found, "symbolic remote HEAD is not shown as a duplicate")
	git_refs_destroy(refs)
	if len(error_text) > 0 { delete(error_text) }

	truncated := make([dynamic]u8, 0, 32)
	append(&truncated, "refs/heads/main")
	append(&truncated, u8(0))
	partial, truncated_error := git_parse_refs(truncated[:])
	delete(truncated)
	history_test_expect(failures, len(truncated_error) > 0 && len(partial) == 0, "truncated ref records fail safely without returning partial refs")
	git_refs_destroy(partial)
	if len(truncated_error) > 0 { delete(truncated_error) }
	empty_refs, empty_error := git_parse_refs(nil)
	history_test_expect(failures, len(empty_error) == 0 && len(empty_refs) == 0, "repositories with no refs produce a valid empty snapshot")
	git_refs_destroy(empty_refs)
	if len(empty_error) > 0 { delete(empty_error) }
}

history_test_ref_snapshot_adoption :: proc(failures: ^int) {
	app := History_App{latest_history_id=History_Request_ID(3)}
	app.visible = make([dynamic]int, 0, 4)
	app.ref_rows = make([dynamic]Ref_List_Row, 0, 8)
	old_id := "4444444444444444444444444444444444444444"
	old_commit := Commit{}
	old_commit.id, _ = strings.clone(old_id)
	old_commit.subject, _ = strings.clone("old snapshot")
	app.commits = make([dynamic]Commit, 0, 1)
	append(&app.commits, old_commit)
	app.refs = make([dynamic]Git_Ref, 0, 1)
	append(&app.refs, history_test_make_ref("refs/heads/old", "old", old_id, old_id, .Branch))
	history_rebuild_ref_rows(&app)

	stale := new(History_Result)
	stale.kind = .Load_History
	stale.history_id = History_Request_ID(2)
	stale.refs = make([dynamic]Git_Ref, 0, 1)
	append(&stale.refs, history_test_make_ref("refs/heads/stale", "stale", old_id, old_id, .Branch))
	history_test_expect(failures, !history_adopt_result(&app, stale), "stale history result carrying refs is rejected")
	history_test_expect(failures, len(app.refs) == 1 && app.refs[0].full_name == "refs/heads/old", "stale snapshot leaves currently adopted refs intact")

	failed := new(History_Result)
	failed.kind = .Load_History
	failed.history_id = History_Request_ID(3)
	failed.error_text, _ = strings.clone("refs query failed")
	failed.refs = make([dynamic]Git_Ref, 0, 1)
	append(&failed.refs, history_test_make_ref("refs/heads/partial", "partial", old_id, old_id, .Branch))
	history_test_expect(failures, history_adopt_result(&app, failed), "current failed snapshot updates its error state")
	history_test_expect(failures, len(app.refs) == 1 && app.refs[0].full_name == "refs/heads/old", "failed ref query cannot publish a partial snapshot")

	current := new(History_Result)
	current.kind = .Load_History
	current.history_id = History_Request_ID(3)
	current.branch, _ = strings.clone("main")
	current.commits = make([dynamic]Commit, 0, 1)
	new_id := "5555555555555555555555555555555555555555"
	new_commit := Commit{}
	new_commit.id, _ = strings.clone(new_id)
	new_commit.subject, _ = strings.clone("new snapshot")
	append(&current.commits, new_commit)
	current.refs = make([dynamic]Git_Ref, 0, 1)
	append(&current.refs, history_test_make_ref("refs/heads/main", "main", new_id, new_id, .Branch, true))
	history_test_expect(failures, history_adopt_result(&app, current), "current history and refs snapshot is adopted")
	history_test_expect(failures, len(app.commits) == 1 && app.commits[0].id == new_id, "new commits are adopted from the snapshot")
	history_test_expect(failures, len(app.refs) == 1 && app.refs[0].full_name == "refs/heads/main" && app.refs[0].target_commit_id == new_id, "new refs are adopted with the same snapshot")
	history_app_destroy(&app)
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
	commit_dag_destroy(&app.dag)
	git_refs_destroy(app.refs)
	if app.ref_rows != nil { delete(app.ref_rows) }
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

history_test_worker_patch_selection :: proc(failures: ^int, repository: string, commit: Commit, path: string) {
	app := history_app_new(repository)
	if app == nil {
		history_test_expect(failures, false, "patch worker selection fixture allocates application state")
		return
	}
	defer {
		history_app_destroy(app)
		free(app)
	}
	app.commits = make([dynamic]Commit, 0, 1)
	copy, copy_ok := commit_clone(commit)
	if !copy_ok {
		history_test_expect(failures, false, "patch worker selection fixture clones its selected commit")
		return
	}
	append(&app.commits, copy)
	app.visible = make([dynamic]int, 0, 1)
	append(&app.visible, 0)
	app.selected_id, _ = strings.clone(commit.id)
	app.has_selection = true
	app.selected_commit_index = 0
	if !git_worker_start(&app.worker) {
		history_test_expect(failures, false, "patch worker selection fixture starts the Git worker")
		return
	}
	if !history_worker_submit_detail(app) {
		history_test_expect(failures, false, "selected commit detail request enters the worker lane")
		return
	}

	requested_source := false
	patch_completed := false
	for _ in 0..<5000 {
		progress := false
		for {
			result, ok := chan.try_recv(app.worker.detail_results)
			if !ok { break }
			progress = true
			accepted := history_adopt_result(app, result)
			if accepted {
				for file, index in app.detail.files {
					if file.path == path {
						app.selected_file_index = -1
						requested_source = history_select_file_index(app, index)
						break
					}
				}
			}
		}
		for {
			result, ok := chan.try_recv(app.worker.patch_results)
			if !ok { break }
			progress = true
			_ = history_adopt_result(app, result)
		}
		if requested_source && !app.patch_loading {
			patch_completed = app.patch.path == path && len(app.patch.hunks) > 0 && len(app.patch_error) == 0
			break
		}
		if !progress { time.sleep(time.Millisecond) }
	}
	history_test_expect(failures, requested_source, "loaded commit details let the UI submit the selected source file patch")
	history_test_expect(failures, patch_completed,
		"latest-wins worker selection delivers and adopts textual hunks for the selected source file")
}

history_test_ref_selection_visibility :: proc(failures: ^int) {
	app := history_app_new(".")
	if app == nil {
		history_test_expect(failures, false, "ref selection fixture allocates its application state")
		return
	}
	defer {
		history_app_destroy(app)
		free(app)
	}
	app.loading = false
	app.commits = make([dynamic]Commit, 0, 80)
	target_id := ""
	for i := 0; i < 80; i += 1 {
		id := fmt.tprintf("%040x", i+1)
		subject := "work commit"
		if i == 0 { subject = "head commit" }
		if i == 79 { subject = "target commit" }
		commit := Commit{}
		commit.id, _ = strings.clone(id)
		commit.subject, _ = strings.clone(subject)
		append(&app.commits, commit)
		if i == 79 { target_id = app.commits[i].id }
	}
	app.refs = make([dynamic]Git_Ref, 0, 1)
	append(&app.refs, history_test_make_ref("refs/heads/feature/target", "feature/target", target_id, target_id, .Branch))
	history_rebuild_ref_rows(app)
	app.filter, _ = strings.clone("head")
	history_rebuild_visible(app)
	history_test_expect(failures, len(app.visible) == 1, "filter initially hides the ref target commit")

	found, changed, filter_changed, visible_position := history_select_ref(app, 0)
	history_test_expect(failures, found && changed, "clicking a commit ref selects its target")
	history_test_expect(failures, filter_changed && len(app.filter) == 0, "ref navigation clears a filter that hides its target")
	history_test_expect(failures, visible_position == 79 && app.has_selection && app.selected_id == target_id, "selected target is exposed at its visible list position")

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1200, 800})
	defer alicorn.destroy_runtime(&rt)
	_ = history_build(rawptr(app), &rt, 1200, 800, 1)
	_ = alicorn.virtual_list_ensure_visible(&rt, app.history_scroll_node, visible_position, "ref target commit visibility test")
	scroll := alicorn.scroll_region_state(&rt, app.history_scroll_node)
	history_test_expect(failures, scroll.offset_y > 0 && scroll.offset_y <= scroll.max_scroll_y, "ref target commit is scrolled into the history viewport")
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
	history_test_expect(failures, history_repository_name(app.repository) != "." && len(history_repository_name(app.repository)) > 0,
		"repository heading resolves the launch directory to its directory name")
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
	app.refs = make([dynamic]Git_Ref, 0, 2)
	append(&app.refs, history_test_make_ref("refs/heads/main", "main", app.commits[0].id, app.commits[0].id, .Branch, true))
	append(&app.refs, history_test_make_ref("refs/remotes/origin/main", "origin/main", app.commits[1].id, app.commits[1].id, .Remote))
	long_ref_name := "feature/a-reference-name-longer-than-the-sidebar"
	append(&app.refs, history_test_make_ref(fmt.tprintf("refs/heads/%s", long_ref_name), long_ref_name, app.commits[2].id, app.commits[2].id, .Branch))
	history_rebuild_ref_rows(app)
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
	if graph, ok := rt.nodes[app.commit_graph_node]; ok && app.commit_graph_node != 0 {
		history_test_expect(failures, graph.surface_geometry_active && len(graph.surface_circles) > 0, "commit DAG is retained as copied typed GPU geometry")
		scroll_state := alicorn.scroll_region_state(&rt, app.history_scroll_node)
		row_column: ^alicorn.Node = nil
		for _, node in rt.nodes { if node.label == "history-commit-rows" { row_column = node } }
		if row_column != nil && len(graph.surface_circles) > 0 && len(app.visible) > 0 {
			first_row := history_test_find_commit_row(&rt, row_column)
			if first_row != nil {
				marker_y := graph.bounds.y + graph.surface_circles[0].center.y
				row_y := first_row.bounds.y + first_row.bounds.h*0.5
				delta := marker_y-row_y
				if delta < 0 { delta = -delta }
				history_test_expect(failures, graph.bounds.h == scroll_state.viewport_height && row_column.bounds.h == scroll_state.viewport_height, "DAG gutter and rows share the resolved scroll viewport height")
				history_test_expect(failures, delta < 0.1 && row_column.bounds.x >= graph.bounds.x+graph.bounds.w, "DAG markers align to virtualized commit row centers without overlapping text")
			} else {
				history_test_expect(failures, false, "first visible commit row remains addressable beside its DAG marker")
			}
		} else {
			history_test_expect(failures, false, "DAG gutter and commit rows are retained as adjacent siblings")
		}
	} else {
		history_test_expect(failures, false, "history view creates its commit DAG surface")
	}
	if alicorn.scroll_region_set_offset(&rt, app.history_scroll_node, 17, "DAG fractional alignment test") {
		_ = history_build(rawptr(app), &rt, 1200, 800, 2)
		if graph, ok := rt.nodes[app.commit_graph_node]; ok && len(graph.surface_circles) > 0 {
			row_column: ^alicorn.Node = nil
			for _, node in rt.nodes { if node.label == "history-commit-rows" { row_column = node } }
			first_row := history_test_find_commit_row(&rt, row_column)
			if first_row != nil {
				marker_y := graph.bounds.y + graph.surface_circles[0].center.y
				row_y := first_row.bounds.y + first_row.bounds.h*0.5
				delta := marker_y-row_y
				if delta < 0 { delta = -delta }
				history_test_expect(failures, alicorn.scroll_region_offset(&rt, app.history_scroll_node) == 17 && delta < 0.1, "DAG markers remain pixel-aligned with text rows at fractional scroll offsets")
			} else {
				history_test_expect(failures, false, "fractionally scrolled first commit row remains realized")
			}
		} else {
			history_test_expect(failures, false, "fractional scroll retains the DAG surface geometry")
		}
	}
	refs_panel: ^alicorn.Node = nil
	history_panel: ^alicorn.Node = nil
	detail_panel: ^alicorn.Node = nil
	for _, node in rt.nodes {
		if node.label == "history-refs-panel" { refs_panel = node }
		if node.label == "history-list-panel" { history_panel = node }
		if node.label == "history-detail-panel" { detail_panel = node }
	}
	if refs_panel != nil && history_panel != nil && detail_panel != nil {
		inner := rt.nodes[rt.nodes[refs_panel.parent].parent]
		outer := rt.nodes[rt.nodes[detail_panel.parent].parent]
		history_test_expect(failures, outer.kind == .Split && inner.kind == .Split && outer.id != inner.id && rt.nodes[history_panel.parent].parent == inner.id && rt.nodes[inner.parent].parent == outer.id, "refs/history group and detail use adjacent-neighbor nested retained splits")
		history_test_expect(failures, refs_panel.bounds.x < history_panel.bounds.x && history_panel.bounds.x < detail_panel.bounds.x, "three-pane order is refs, history, then detail")
		history_test_expect(failures, refs_panel.bounds.w == 220 && history_panel.bounds.x > refs_panel.bounds.x+refs_panel.bounds.w, "preferred refs pane width precedes the history pane")
		history_test_expect(failures, detail_panel.bounds.y >= 0 && detail_panel.bounds.y+detail_panel.bounds.h <= rt.viewport.h, "history detail panel remains inside the window")
	} else {
		history_test_expect(failures, false, "three-pane refs/history/detail layout is retained")
	}
	ref_marker_identity := alicorn.visual_part_identity_hash(alicorn.visual_part_extension_id("app.history", "ref-marker"))
	commit_row_identity := alicorn.visual_part_identity_hash(alicorn.visual_part_extension_id("app.history", "commit-row"))
	ref_marker_found, commit_row_found := false, false
	for id, part in rt.visual_parts {
		identity := alicorn.visual_part_identity_hash(part.identity)
		if identity == ref_marker_identity { ref_marker_found = true }
		if identity == commit_row_identity { commit_row_found = true }
	}
	history_test_expect(failures, ref_marker_found && commit_row_found,
		"History describes its ref marker and Commit_Row with app-defined visual-part identities")
	history_test_expect(failures, app.refs_scroll_node != 0, "refs sidebar uses a retained scroll region")
	if refs := alicorn.scroll_region_state(&rt, app.refs_scroll_node); app.refs_scroll_node != 0 {
		history_test_expect(failures, refs.viewport_height > 0, "refs sidebar has a visible viewport")
	}
	if next := alicorn.focus_traverse(&rt, .Next); next != 0 {
		history_test_expect(failures, next != app.filter_node, "focus traversal advances past the filter")
	} else {
		history_test_expect(failures, false, "history view exposes a next focus target")
	}
	widths := [3]int{1050, 1200, 1600}
	for width in widths {
		rt.viewport = alicorn.Rect{0, 0, f32(width), 800}
		rt.invalidated = true
		rt.layout_pending = true
		_ = history_build(rawptr(app), &rt, width, 800, 1)
		name_id := history_test_find_text_node(&rt, long_ref_name)
		name_ok := name_id != 0
		if name_ok {
			name := rt.nodes[name_id]
			content := rt.nodes[name.parent]
			marker_id := alicorn.Node_ID(0)
			for child_id in content.children {
				if child, ok := rt.nodes[child_id]; ok && child.label == "history-ref-marker" { marker_id = child_id; break }
			}
			if marker_id != 0 {
				marker := rt.nodes[marker_id]
				name_ok = marker.bounds.x+marker.bounds.w <= name.bounds.x &&
					name.bounds.w > 0 && name.bounds.x+name.bounds.w <= content.bounds.x+content.bounds.w+1
			} else {
				name_ok = false
			}
		}
		history_test_expect(failures, name_ok, fmt.tprintf("ref marker and ellipsized name stay in separate slots at %dpx window width", width))
	}
}

history_test_find_text_node :: proc(rt: ^alicorn.Runtime, value: string) -> alicorn.Node_ID {
	if rt == nil { return 0 }
	for id, node in rt.nodes {
		if node.kind == .Text && node.text == value { return id }
	}
	return 0
}

history_test_find_text_with_ancestor :: proc(rt: ^alicorn.Runtime, value: string, ancestor: alicorn.Node_ID) -> alicorn.Node_ID {
	if rt == nil || ancestor == 0 { return 0 }
	for id, node in rt.nodes {
		if node.kind != .Text || node.text != value { continue }
		current := node.parent
		for depth := 0; current != 0 && depth < len(rt.nodes); depth += 1 {
			if current == ancestor { return id }
			parent, found := rt.nodes[current]
			if !found { break }
			current = parent.parent
		}
	}
	return 0
}

history_test_semantic_press_actions_equal :: proc(a, b: alicorn.Semantic_Snapshot) -> bool {
	a_count, b_count := 0, 0
	for before in a.nodes {
		if !alicorn.semantic_actions_has(before.actions, .Press) { continue }
		a_count += 1
		matched := false
		for after in b.nodes {
			if after.id != before.id { continue }
			matched = after.role == before.role && after.actions == before.actions
			break
		}
		if !matched { return false }
	}
	for after in b.nodes {
		if alicorn.semantic_actions_has(after.actions, .Press) { b_count += 1 }
	}
	return a_count == b_count
}

history_test_detail_grid_resize :: proc(failures: ^int) {
	app := history_app_new(".")
	if app == nil {
		history_test_expect(failures, false, "detail grid resize fixture allocates its application state")
		return
	}
	defer {
		history_app_destroy(app)
		free(app)
	}
	app.branch, _ = strings.clone("feature/responsive-grid-layout")
	app.loading = false
	app.commits = make([dynamic]Commit, 0, 1)
	commit := Commit{}
	commit.id, _ = strings.clone("c6a9a55689abcdef0123456789abcdef01234567")
	commit.author_name, _ = strings.clone("Alexandra Example With A Deliberately Long Author Display Name")
	commit.author_email, _ = strings.clone("alexandra.example.with.a.long.address@example.invalid")
	commit.subject, _ = strings.clone("Dogfood the retained Grid layout with a long commit subject")
	append(&app.commits, commit)
	app.visible = make([dynamic]int, 0, 1)
	append(&app.visible, 0)
	app.has_selection = true
	app.selected_commit_index = 0
	app.selected_id, _ = strings.clone(commit.id)
	app.detail.id, _ = strings.clone(commit.id)
	app.detail.author_name, _ = strings.clone("Alexandra Example With A Deliberately Long Author Display Name")
	app.detail.author_email, _ = strings.clone("alexandra.example.with.a.long.address@example.invalid")
	app.detail.subject, _ = strings.clone("Exercise the Grid with a wrapped message while keeping its baselines and the diff pane visible")
	app.detail.files = make([dynamic]Changed_File, 0, 2)
	first_path := "history_view.odin"
	second_path := "tools/run.ps1"
	first_file_path, _ := strings.clone(first_path)
	second_file_path, _ := strings.clone(second_path)
	append(&app.detail.files, Changed_File{path=first_file_path, status=.Modified, additions=24, deletions=2})
	append(&app.detail.files, Changed_File{path=second_file_path, status=.Modified, additions=9, deletions=1})
	app.selected_file_index = 0
	app.selected_file_path, _ = strings.clone(first_path)
	app.patch.path, _ = strings.clone(first_path)
	app.patch.hunks = make([dynamic]Diff_Hunk, 0, 1)
	header, _ := strings.clone("@@ -318,2 +318,5 @@ history_build")
	lines := make([dynamic]Diff_Line, 0, 1)
	line_text, _ := strings.clone("alicorn.grid_begin(&ui, alicorn.key_string(\"history-commit-properties\"), ...) ")
	append(&lines, Diff_Line{kind=.Addition, new_line=318, text=line_text})
	append(&app.patch.hunks, Diff_Hunk{old_start=318, old_count=2, new_start=318, new_count=5, header=header, lines=lines})
	history_patch_prepare_display(&app.patch)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 1200, 800})
	defer alicorn.destroy_runtime(&rt)
	widths := [4]int{1200, 1200, 1050, 1200}
	metadata_owner := alicorn.Node_ID(0)
	focus_id := alicorn.Node_ID(0)
	wide_metadata_bounds := alicorn.Rect{}
	wide_grid_bounds := alicorn.Rect{}
	wide_author_bounds := alicorn.Rect{}
	wide_message_bounds := alicorn.Rect{}
	semantic_before := alicorn.Semantic_Snapshot{}
	semantic_before_valid := false
	for width, width_index in widths {
		incoming_width := history_detail_incoming_width(width, 722)
		presentation := history_commit_metadata_presentation(incoming_width)
		rt.viewport = alicorn.Rect{0, 0, f32(width), 800}
		rt.invalidated = true
		rt.layout_pending = true
		_ = history_build(rawptr(app), &rt, width, 800, 1)
		if width_index == 1 {
			focused := alicorn.focus(&rt, app.filter_node)
			focus_id = alicorn.focused_node(&rt)
			semantic_before = alicorn.semantic_snapshot(&rt)
			semantic_before_valid = focused && focus_id != 0
		}
		metadata_id := alicorn.Node_ID(0)
		grid_id := alicorn.Node_ID(0)
		compact_id := alicorn.Node_ID(0)
		for id, node in rt.nodes {
			if node.label == "history-commit-properties" { metadata_id = id }
			if node.label == "history-commit-properties-wide-grid" { grid_id = id }
			if node.label == "history-commit-properties-compact" { compact_id = id }
		}
		if metadata_owner == 0 { metadata_owner = metadata_id }
		owner_ok := metadata_id != 0 && metadata_id == metadata_owner
		grid_ok := presentation == .Wide && grid_id != 0
		if grid_ok {
			grid := rt.nodes[grid_id]
			max_bottom := grid.bounds.y
			for _, node in rt.nodes {
				if node.parent == grid_id && node.bounds.y+node.bounds.h > max_bottom {
					max_bottom = node.bounds.y+node.bounds.h
				}
			}
			grid_ok = grid.bounds.w > 0 && grid.bounds.h > 0 && max_bottom <= grid.bounds.y+grid.bounds.h+1
		}
		compact_ok := presentation == .Compact && compact_id != 0
		if compact_ok {
			compact := rt.nodes[compact_id]
			author_id := history_test_find_text_with_ancestor(&rt, "Alexandra Example With A Deliberately Long Author Display Name", compact_id)
			commit_id := history_test_find_text_with_ancestor(&rt, "c6a9a556", compact_id)
			message_id := history_test_find_text_with_ancestor(&rt, "Exercise the Grid with a wrapped message while keeping its baselines and the diff pane visible", compact_id)
			branch_id := history_test_find_text_with_ancestor(&rt, "feature/responsive-grid-layout", compact_id)
			compact_ok = author_id != 0 && commit_id != 0 && message_id != 0 && branch_id != 0
			if compact_ok {
				author, commit_text := rt.nodes[author_id], rt.nodes[commit_id]
				message, branch := rt.nodes[message_id], rt.nodes[branch_id]
				compact_ok = compact.bounds.w > 0 && compact.bounds.h > 0 &&
					author.bounds.x < commit_text.bounds.x && author.bounds.w > 0 && commit_text.bounds.w > 0 &&
					message.bounds.y >= compact.bounds.y && message.bounds.y+message.bounds.h <= compact.bounds.y+compact.bounds.h+1 &&
					branch.bounds.y >= compact.bounds.y && branch.bounds.y+branch.bounds.h <= compact.bounds.y+compact.bounds.h+1
			}
		}
		author_text := "Alexandra Example With A Deliberately Long Author Display Name <alexandra.example.with.a.long.address@example.invalid>"
		if presentation == .Compact { author_text = "Alexandra Example With A Deliberately Long Author Display Name" }
		author_id := history_test_find_text_node(&rt, author_text)
		stats_id := history_test_find_text_node(&rt, "+24 -2")
		file_name_id := history_test_find_text_node(&rt, first_path)
		rows_ok := author_id != 0 && stats_id != 0 && file_name_id != 0
		if rows_ok {
			author := rt.nodes[author_id]
			stats := rt.nodes[stats_id]
			file_name := rt.nodes[file_name_id]
			rows_ok = author.bounds.w > 0 && stats.bounds.x >= 0 && file_name.bounds.w > 0 &&
				stats.bounds.x+stats.bounds.w <= file_name.bounds.x+1
		}
		mode_ok := (presentation == .Wide && grid_ok) || (presentation == .Compact && compact_ok)
		history_test_expect(failures, owner_ok && mode_ok && rows_ok,
			fmt.tprintf("adaptive commit metadata and left-aligned file row remain bounded at %dpx window width", width))
		history_test_expect(failures, app.selected_id == commit.id && app.selected_file_path == first_path && app.selected_file_index == 0,
			"adaptive presentation preserves selected commit and changed-file identity")
		if width_index == 1 && presentation == .Wide && grid_ok && author_id != 0 {
			wide_metadata_bounds = rt.nodes[metadata_id].bounds
			wide_grid_bounds = rt.nodes[grid_id].bounds
			wide_author_bounds = rt.nodes[author_id].bounds
			message_id := history_test_find_text_node(&rt, "Exercise the Grid with a wrapped message while keeping its baselines and the diff pane visible")
			if message_id != 0 { wide_message_bounds = rt.nodes[message_id].bounds }
		}
		if presentation == .Compact {
			before_press_actions := 0
			for node in semantic_before.nodes {
				if alicorn.semantic_actions_has(node.actions, .Press) { before_press_actions += 1 }
			}
			semantic_before_valid = semantic_before_valid && before_press_actions > 0
			history_test_expect(failures, semantic_before_valid, "adaptive fixture captures existing semantic Press actions before switching")
			history_test_expect(failures, focus_id != 0 && alicorn.focused_node(&rt) == focus_id,
				"adaptive presentation preserves focus outside the metadata component")
			after := alicorn.semantic_snapshot(&rt)
			history_test_expect(failures, semantic_before_valid && history_test_semantic_press_actions_equal(semantic_before, after),
				"adaptive presentation preserves semantic action identities")
			alicorn.semantic_snapshot_destroy(&semantic_before)
			alicorn.semantic_snapshot_destroy(&after)
			semantic_before_valid = false
		}
		if width_index == 3 {
			message_id := history_test_find_text_node(&rt, "Exercise the Grid with a wrapped message while keeping its baselines and the diff pane visible")
			replay_ok := presentation == .Wide && metadata_id != 0 && grid_id != 0 && author_id != 0 && message_id != 0 &&
				rt.nodes[metadata_id].bounds == wide_metadata_bounds && rt.nodes[grid_id].bounds == wide_grid_bounds &&
				rt.nodes[author_id].bounds == wide_author_bounds && rt.nodes[message_id].bounds == wide_message_bounds
			history_test_expect(failures, replay_ok,
				"adaptive presentation deterministically replays the wide alternative when its incoming width returns")
		}
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
	subdirectory := fmt.tprintf("%s/out", repository)
	if os.is_dir(subdirectory) {
		subdirectory_root := history_absolute_repository(subdirectory)
		repository_root := history_absolute_repository(repository)
		history_test_expect(&failures, len(subdirectory_root) > 0 && subdirectory_root == repository_root,
			"launching from a repository subdirectory resolves Git's worktree root")
		if len(subdirectory_root) > 0 { delete(subdirectory_root) }
		if len(repository_root) > 0 { delete(repository_root) }
	}
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
	history_test_refs_parser(&failures)
	history_test_ref_snapshot_adoption(&failures)
	history_test_refresh_releases_commit_storage(&failures)
	history_test_worker_shutdown_stress(&failures, repository)
	history_test_detail_generation_domains(&failures)
	history_test_file_stats(&failures)
	history_test_patch_parser(&failures)
	history_test_patch_generation(&failures)
	history_test_large_patch(&failures)
	history_test_ref_selection_visibility(&failures)
	history_test_view_layout_and_focus(&failures)
	history_test_detail_grid_resize(&failures)
	history_test_dag_geometry(&failures)
	history_test_large_dag_virtual_projection(&failures)

	stdout, stderr, _, command_ok := git_run(repository, []string{
		"log", "--all", "--topo-order", "--date=unix", "-z",
		"--pretty=format:%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00",
	})
	history_test_expect(&failures, command_ok, "installed Git can read the target repository")
	if command_ok {
		real_commits, real_error := git_parse_log(stdout)
		history_test_expect(&failures, len(real_error) == 0, "real repository output parses completely")
		history_test_expect(&failures, len(real_commits) > 0, "real repository produces commits")
		refs_stdout, refs_stderr, refs_exit_code, refs_command_ok := git_run(repository, []string{
			"for-each-ref",
			"--sort=refname",
			"--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(HEAD)%00%(symref)%00",
			"refs/heads",
			"refs/remotes",
			"refs/tags",
		})
		history_test_expect(&failures, refs_command_ok, "installed Git can enumerate structured refs")
		if refs_command_ok {
			real_refs, refs_error := git_parse_refs(refs_stdout)
			history_test_expect(&failures, len(refs_error) == 0, "real for-each-ref output parses completely")
			if len(refs_error) == 0 {
				head_count := 0
				for ref in real_refs {
					if ref.is_head { head_count += 1 }
					if len(ref.target_commit_id) == 0 { continue }
					history_test_expect(&failures, git_ref_oid_valid(ref.target_commit_id), "selectable ref targets a full Git object id")
					if len(real_error) == 0 {
						target_found := false
						for commit in real_commits {
							if commit.id == ref.target_commit_id { target_found = true; break }
						}
						history_test_expect(&failures, target_found, fmt.tprintf("ref %s targets a commit in the history snapshot", ref.full_name))
					}
				}
				history_test_expect(&failures, head_count <= 1, "at most one enumerated ref is marked HEAD")
				branch := git_repository_branch(repository)
				if branch != "detached" {
					head_branch_found := false
					for ref in real_refs {
						if ref.kind == .Branch && ref.is_head && ref.short_name == branch {
							head_branch_found = true
							break
						}
					}
					history_test_expect(&failures, head_branch_found, "current local branch matches the structured HEAD ref")
				}
				if len(branch) > 0 { delete(branch) }
			}
			git_refs_destroy(real_refs)
			if len(refs_error) > 0 { delete(refs_error) }
		}
		if len(refs_stdout) > 0 { delete(refs_stdout) }
		if len(refs_stderr) > 0 { delete(refs_stderr) }
		_ = refs_exit_code
		limit := min(len(real_commits), 8)
		patch_tested := false
		source_patch_tested := false
		for i := 0; i < limit; i += 1 {
			history_test_expect(&failures, history_test_clean_object_id(real_commits[i].id), fmt.tprintf("parsed commit %d has no record-separator bytes", i))
			detail, detail_error := git_load_commit_detail(repository, real_commits[i].id)
			history_test_expect(&failures, len(detail_error) == 0, fmt.tprintf("commit detail query succeeds for parsed commit %d", i))
			history_test_expect(&failures, detail.id == real_commits[i].id, fmt.tprintf("commit detail preserves stable identity for parsed commit %d", i))
			for file in detail.files {
				if !patch_tested {
					patch, patch_error := git_load_file_patch(repository, real_commits[i].id, file.path)
					history_test_expect(&failures, len(patch_error) == 0, "selected file patch query succeeds")
					history_test_expect(&failures, patch.path == file.path, "selected file patch preserves its path")
					file_patch_destroy(&patch)
					if len(patch_error) > 0 { delete(patch_error) }
					patch_tested = true
				}
				is_odin_source := len(file.path) >= 5 && file.path[len(file.path)-5:] == ".odin"
				if !source_patch_tested && is_odin_source && (file.additions > 0 || file.deletions > 0) {
					patch, patch_error := git_load_file_patch(repository, real_commits[i].id, file.path)
					history_test_expect(&failures, len(patch_error) == 0, "changed Odin source patch query succeeds")
					history_test_expect(&failures, len(patch.hunks) > 0, "changed Odin source file produces parsed textual hunks")
					history_test_expect(&failures, patch.path == file.path, "changed Odin source patch retains the selected file identity")
					file_patch_destroy(&patch)
					if len(patch_error) > 0 { delete(patch_error) }
					history_test_worker_patch_selection(&failures, repository, real_commits[i], file.path)
					source_patch_tested = true
				}
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
