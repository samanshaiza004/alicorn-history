package main

import "core:fmt"
import "core:strings"

History_Request_ID :: distinct u64
Detail_Request_ID  :: distinct u64
Patch_Request_ID   :: distinct u64

Git_Request_Kind :: enum {
	Load_History,
	Load_Commit_Detail,
	Load_File_Patch,
}

Git_Request :: struct {
	history_id: History_Request_ID,
	detail_id:  Detail_Request_ID,
	patch_id:   Patch_Request_ID,
	kind:       Git_Request_Kind,
	repository: string,
	commit_id:  string,
	file_path:  string,
}

git_request_destroy :: proc(request: ^Git_Request) {
	if request == nil { return }
	if len(request.repository) > 0 { delete(request.repository) }
	if len(request.commit_id) > 0 { delete(request.commit_id) }
	if len(request.file_path) > 0 { delete(request.file_path) }
	free(request)
}

File_Status :: enum {
	Modified,
	Added,
	Deleted,
	Renamed,
	Copied,
	Type_Changed,
	Unmerged,
	Unknown,
}

Changed_File :: struct {
	path:      string,
	status:    File_Status,
	additions: int,
	deletions: int,
}

Diff_Line_Kind :: enum {
	Context,
	Addition,
	Deletion,
	Meta,
}

Diff_Line :: struct {
	kind:     Diff_Line_Kind,
	old_line: int,
	new_line: int,
	text:     string,
}

Diff_Hunk :: struct {
	old_start: int,
	old_count: int,
	new_start: int,
	new_count: int,
	header:    string,
	lines:     [dynamic]Diff_Line,
}

File_Patch :: struct {
	path:     string,
	binary:   bool,
	metadata: [dynamic]string,
	hunks:    [dynamic]Diff_Hunk,
	// Display rows are an owned index into the patch's existing strings. The
	// text fields borrow metadata/hunk storage; only the index array itself is
	// owned here. This keeps visible-row lookup O(1) without duplicating text.
	display_lines: [dynamic]Patch_Display_Line,
	content_width: f32,
}

Patch_Display_Line :: struct {
	kind:     Diff_Line_Kind,
	old_line: int,
	new_line: int,
	text:     string,
	hunk:     bool,
}

history_patch_prepare_display :: proc(patch: ^File_Patch) {
	if patch == nil || patch.display_lines != nil { return }
	capacity := len(patch.metadata) + 1
	for hunk in patch.hunks { capacity += 1 + len(hunk.lines) }
	patch.display_lines = make([dynamic]Patch_Display_Line, 0, capacity)
	width: f32 = 720
	for metadata in patch.metadata {
		append(&patch.display_lines, Patch_Display_Line{kind=.Meta, text=metadata})
		width = max(width, f32(len(metadata))*8 + 24)
	}
	for hunk in patch.hunks {
		append(&patch.display_lines, Patch_Display_Line{kind=.Meta, text=hunk.header, hunk=true})
		width = max(width, f32(len(hunk.header))*8 + 24)
		for line in hunk.lines {
			append(&patch.display_lines, Patch_Display_Line{kind=line.kind, old_line=line.old_line, new_line=line.new_line, text=line.text})
			width = max(width, f32(len(line.text))*8 + 160)
		}
	}
	if len(patch.display_lines) == 0 && patch.binary {
		append(&patch.display_lines, Patch_Display_Line{kind=.Meta, text="Binary file changed"})
	}
	patch.content_width = min(width, 4096)
}

Commit_Detail :: struct {
	id:           string,
	subject:      string,
	body:         string,
	author_name:  string,
	author_email: string,
	timestamp:    i64,
	parents:      [dynamic]string,
	files:        [dynamic]Changed_File,
}

Commit :: struct {
	id:           string,
	parents:      [dynamic]string,
	author_name:  string,
	author_email: string,
	timestamp:    i64,
	subject:      string,
}

Git_Ref_Kind :: enum {
	Branch,
	Remote,
	Tag,
}

Git_Ref :: struct {
	full_name:        string,
	short_name:       string,
	object_id:        string,
	target_commit_id: string,
	kind:             Git_Ref_Kind,
	is_head:          bool,
}

Ref_List_Row :: struct {
	kind:      Git_Ref_Kind,
	ref_index: int,
	is_header: bool,
}

History_Result :: struct {
	kind:       Git_Request_Kind,
	history_id: History_Request_ID,
	detail_id:  Detail_Request_ID,
	patch_id:   Patch_Request_ID,
	repository: string,
	branch:     string,
	commits:    [dynamic]Commit,
	dag:        Commit_DAG_Layout,
	refs:       [dynamic]Git_Ref,
	detail:     Commit_Detail,
	patch:      File_Patch,
	error_text: string,
}

diff_line_destroy :: proc(line: ^Diff_Line) {
	if len(line.text) > 0 { delete(line.text) }
	line^ = {}
}

diff_hunk_destroy :: proc(hunk: ^Diff_Hunk) {
	if len(hunk.header) > 0 { delete(hunk.header) }
	for &line in hunk.lines { diff_line_destroy(&line) }
	delete(hunk.lines)
	hunk^ = {}
}

file_patch_destroy :: proc(patch: ^File_Patch) {
	if len(patch.path) > 0 { delete(patch.path) }
	for metadata in patch.metadata { if len(metadata) > 0 { delete(metadata) } }
	delete(patch.metadata)
	for &hunk in patch.hunks { diff_hunk_destroy(&hunk) }
	delete(patch.hunks)
	delete(patch.display_lines)
	patch^ = {}
}

commit_detail_destroy :: proc(detail: ^Commit_Detail) {
	if len(detail.id) > 0 { delete(detail.id) }
	if len(detail.subject) > 0 { delete(detail.subject) }
	if len(detail.body) > 0 { delete(detail.body) }
	if len(detail.author_name) > 0 { delete(detail.author_name) }
	if len(detail.author_email) > 0 { delete(detail.author_email) }
	for parent in detail.parents {
		if len(parent) > 0 { delete(parent) }
	}
	delete(detail.parents)
	for file in detail.files {
		if len(file.path) > 0 { delete(file.path) }
	}
	delete(detail.files)
	detail^ = {}
}

history_result_destroy :: proc(result: ^History_Result) {
	if len(result.repository) > 0 { delete(result.repository) }
	if len(result.branch) > 0 { delete(result.branch) }
	if len(result.error_text) > 0 { delete(result.error_text) }
	for commit in result.commits {
		if len(commit.id) > 0 { delete(commit.id) }
		if len(commit.author_name) > 0 { delete(commit.author_name) }
		if len(commit.author_email) > 0 { delete(commit.author_email) }
		if len(commit.subject) > 0 { delete(commit.subject) }
		for parent in commit.parents {
			if len(parent) > 0 { delete(parent) }
		}
		delete(commit.parents)
	}
	delete(result.commits)
	commit_dag_destroy(&result.dag)
	git_refs_destroy(result.refs)
	commit_detail_destroy(&result.detail)
	file_patch_destroy(&result.patch)
	result^ = {}
}

git_ref_destroy :: proc(ref: ^Git_Ref) {
	if len(ref.full_name) > 0 { delete(ref.full_name) }
	if len(ref.short_name) > 0 { delete(ref.short_name) }
	if len(ref.object_id) > 0 { delete(ref.object_id) }
	if len(ref.target_commit_id) > 0 { delete(ref.target_commit_id) }
	ref^ = {}
}

git_refs_destroy :: proc(refs: [dynamic]Git_Ref) {
	for &ref in refs { git_ref_destroy(&ref) }
	if refs != nil { delete(refs) }
}

commit_destroy :: proc(commit: ^Commit) {
	if len(commit.id) > 0 { delete(commit.id) }
	if len(commit.author_name) > 0 { delete(commit.author_name) }
	if len(commit.author_email) > 0 { delete(commit.author_email) }
	if len(commit.subject) > 0 { delete(commit.subject) }
	for parent in commit.parents {
		if len(parent) > 0 { delete(parent) }
	}
	delete(commit.parents)
	commit^ = {}
}

commit_clone :: proc(source: Commit) -> (Commit, bool) {
	result := Commit{timestamp=source.timestamp}
	copy, err := strings.clone(source.id)
	if err != nil { commit_destroy(&result); return {}, false }
	result.id = copy
	copy, err = strings.clone(source.author_name)
	if err != nil { commit_destroy(&result); return {}, false }
	result.author_name = copy
	copy, err = strings.clone(source.author_email)
	if err != nil { commit_destroy(&result); return {}, false }
	result.author_email = copy
	copy, err = strings.clone(source.subject)
	if err != nil { commit_destroy(&result); return {}, false }
	result.subject = copy
	result.parents = make([dynamic]string, 0, len(source.parents))
	for parent in source.parents {
		copy, copy_err := strings.clone(parent)
		if copy_err != nil { commit_destroy(&result); return {}, false }
		append(&result.parents, copy)
	}
	return result, true
}

commit_short_id :: proc(commit: Commit) -> string {
	if len(commit.id) <= 8 { return commit.id }
	return commit.id[:8]
}

commit_date_text :: proc(timestamp: i64) -> string {
	return fmt.tprintf("%d", timestamp)
}
