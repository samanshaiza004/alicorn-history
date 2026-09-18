package main

import "core:fmt"
import "core:strings"

History_Request_ID :: distinct u64
Detail_Request_ID  :: distinct u64

Git_Request_Kind :: enum {
	Load_History,
	Load_Commit_Detail,
}

Git_Request :: struct {
	history_id: History_Request_ID,
	detail_id:  Detail_Request_ID,
	kind:       Git_Request_Kind,
	repository: string,
	commit_id:  string,
}

git_request_destroy :: proc(request: ^Git_Request) {
	if request == nil { return }
	if len(request.repository) > 0 { delete(request.repository) }
	if len(request.commit_id) > 0 { delete(request.commit_id) }
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

History_Result :: struct {
	kind:       Git_Request_Kind,
	history_id: History_Request_ID,
	detail_id:  Detail_Request_ID,
	repository: string,
	branch:     string,
	commits:    [dynamic]Commit,
	detail:     Commit_Detail,
	error_text: string,
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
	commit_detail_destroy(&result.detail)
	result^ = {}
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
