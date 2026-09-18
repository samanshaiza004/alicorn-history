package main

import "core:strconv"
import "core:strings"

git_parse_parent_ids :: proc(value: string, parents: ^[dynamic]string) -> bool {
	start := 0
	for start < len(value) {
		for start < len(value) && value[start] == ' ' { start += 1 }
		if start >= len(value) { break }
		end := start
		for end < len(value) && value[end] != ' ' { end += 1 }
		parent, err := strings.clone(value[start:end])
		if err != nil { return false }
		append(parents, parent)
		start = end
	}
	return true
}

git_parse_commit_detail :: proc(data: []byte) -> (detail: Commit_Detail, error_text: string) {
	position := 0
	fields: [7]string
	for i := 0; i < len(fields); i += 1 {
		value, next, ok := git_field(data, position)
		if !ok {
			error_text = git_owned_error("git show output ended in the middle of a record")
			return
		}
		fields[i] = value
		position = next
	}
	timestamp, parse_ok := strconv.parse_int(fields[4])
	if !parse_ok {
		error_text = git_owned_error("git show returned an invalid commit timestamp")
		return
	}
	detail.timestamp = i64(timestamp)
	detail.id, _ = strings.clone(fields[0])
	detail.subject, _ = strings.clone(fields[5])
	detail.body, _ = strings.clone(fields[6])
	detail.author_name, _ = strings.clone(fields[2])
	detail.author_email, _ = strings.clone(fields[3])
	detail.parents = make([dynamic]string, 0, 2)
	if !git_parse_parent_ids(fields[1], &detail.parents) {
		commit_detail_destroy(&detail)
		error_text = git_owned_error("out of memory copying commit parents")
	}
	return
}

git_tab_index :: proc(value: string, start: int = 0) -> int {
	for i := start; i < len(value); i += 1 {
		if value[i] == '\t' { return i }
	}
	return -1
}

git_parse_numstat_value :: proc(value: string) -> int {
	if value == "-" { return -1 }
	parsed, ok := strconv.parse_int(value)
	if !ok { return -1 }
	return int(parsed)
}

git_parse_numstat :: proc(data: []byte) -> (files: [dynamic]Changed_File, ok: bool) {
	files = make([dynamic]Changed_File, 0, 16)
	position := 0
	for position < len(data) {
		record, next, found := git_field(data, position)
		if !found { break }
		position = next
		if len(record) == 0 { continue }
		tab_one := git_tab_index(record)
		tab_two := git_tab_index(record, tab_one + 1)
		if tab_one <= 0 || tab_two <= tab_one {
			ok = false
			return
		}
		path, err := strings.clone(record[tab_two+1:])
		if err != nil {
			ok = false
			return
		}
		append(&files, Changed_File{
			path=path,
			additions=git_parse_numstat_value(record[:tab_one]),
			deletions=git_parse_numstat_value(record[tab_one+1:tab_two]),
		})
	}
	ok = true
	return
}

git_file_status :: proc(value: string) -> File_Status {
	if len(value) == 0 { return .Unknown }
	switch value[0] {
	case 'M': return .Modified
	case 'A': return .Added
	case 'D': return .Deleted
	case 'R': return .Renamed
	case 'C': return .Copied
	case 'T': return .Type_Changed
	case 'U': return .Unmerged
	}
	return .Unknown
}

git_parse_name_status :: proc(data: []byte) -> (files: [dynamic]Changed_File, ok: bool) {
	files = make([dynamic]Changed_File, 0, 16)
	position := 0
	for position < len(data) {
		record, next, found := git_field(data, position)
		if !found { break }
		position = next
		if len(record) == 0 { continue }
		tab := git_tab_index(record)
		status := record
		path_value := ""
		if tab > 0 {
			status = record[:tab]
			path_value = record[tab+1:]
		} else {
			path, path_next, path_ok := git_field(data, position)
			if !path_ok {
				ok = false
				return
			}
			path_value = path
			position = path_next
		}
		if len(status) == 0 || len(path_value) == 0 {
			ok = false
			return
		}
		path, err := strings.clone(path_value)
		if err != nil {
			ok = false
			return
		}
		append(&files, Changed_File{path=path, status=git_file_status(status)})
	}
	ok = true
	return
}

git_destroy_changed_files :: proc(files: ^[dynamic]Changed_File) {
	for file in files^ {
		if len(file.path) > 0 { delete(file.path) }
	}
	delete(files^)
	files^ = {}
}

git_load_commit_detail :: proc(repository, commit_id: string) -> (detail: Commit_Detail, error_text: string) {
	stdout, stderr, exit_code, ok := git_run(repository, []string{
		"show", "--no-patch", "--no-color", "--no-ext-diff",
		"--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%x00",
		commit_id,
	})
	if !ok {
		error_text = git_error_text(stderr, exit_code)
		if len(stdout) > 0 { delete(stdout) }
		if len(stderr) > 0 { delete(stderr) }
		return
	}
	detail, error_text = git_parse_commit_detail(stdout)
	if len(stdout) > 0 { delete(stdout) }
	if len(stderr) > 0 { delete(stderr) }
	if len(error_text) > 0 { return }

	// History presents every commit as a change from its first parent. This
	// keeps merge commits deterministic and consistent with the later patch
	// viewer; root commits compare the empty tree against the commit.
	diff_prefix := []string{"diff-tree", "--no-commit-id", "--numstat", "-r", "-z", "--no-renames"}
	diff_args := []string{}
	if len(detail.parents) == 0 {
		diff_args = []string{"diff-tree", "--root", "--no-commit-id", "--numstat", "-r", "-z", "--no-renames", commit_id}
	} else {
		diff_args = []string{diff_prefix[0], diff_prefix[1], diff_prefix[2], diff_prefix[3], diff_prefix[4], diff_prefix[5], detail.parents[0], commit_id}
	}
	numstat, numstat_stderr, numstat_exit, numstat_ok := git_run(repository, diff_args)
	if !numstat_ok {
		commit_detail_destroy(&detail)
		error_text = git_error_text(numstat_stderr, numstat_exit)
		if len(numstat) > 0 { delete(numstat) }
		if len(numstat_stderr) > 0 { delete(numstat_stderr) }
		return
	}
	files, files_ok := git_parse_numstat(numstat)
	if len(numstat) > 0 { delete(numstat) }
	if len(numstat_stderr) > 0 { delete(numstat_stderr) }
	if !files_ok {
		commit_detail_destroy(&detail)
		error_text = git_owned_error("git diff-tree returned malformed numstat output")
		return
	}

	status_args := []string{}
	if len(detail.parents) == 0 {
		status_args = []string{"diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--no-renames", commit_id}
	} else {
		status_args = []string{"diff-tree", "--no-commit-id", "--name-status", "-r", "-z", "--no-renames", detail.parents[0], commit_id}
	}
	status_data, status_stderr, status_exit, status_ok := git_run(repository, status_args)
	if !status_ok {
		git_destroy_changed_files(&files)
		commit_detail_destroy(&detail)
		error_text = git_error_text(status_stderr, status_exit)
		if len(status_data) > 0 { delete(status_data) }
		if len(status_stderr) > 0 { delete(status_stderr) }
		return
	}
	statuses, statuses_ok := git_parse_name_status(status_data)
	if len(status_data) > 0 { delete(status_data) }
	if len(status_stderr) > 0 { delete(status_stderr) }
	if !statuses_ok {
		git_destroy_changed_files(&files)
		commit_detail_destroy(&detail)
		error_text = git_owned_error("git diff-tree returned malformed name-status output")
		return
	}

	for status in statuses {
		matched := false
		for i := 0; i < len(files); i += 1 {
			if files[i].path == status.path {
				files[i].status = status.status
				matched = true
				break
			}
		}
		if !matched {
			copy, err := strings.clone(status.path)
			if err == nil { append(&files, Changed_File{path=copy, status=status.status}) }
		}
	}
	git_destroy_changed_files(&statuses)
	detail.files = files
	return
}
