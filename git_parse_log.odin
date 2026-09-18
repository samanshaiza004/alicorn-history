package main

import "core:strconv"
import "core:strings"

git_owned_error :: proc(message: string) -> string {
	result, _ := strings.clone(message)
	return result
}

git_field :: proc(data: []byte, start: int) -> (field: string, next: int, ok: bool) {
	if start < 0 || start > len(data) { return }
	end := start
	for end < len(data) && data[end] != 0 { end += 1 }
	if end >= len(data) { return }
	field = string(data[start:end])
	next = end + 1
	ok = true
	return
}

git_parse_log :: proc(data: []byte) -> (commits: [dynamic]Commit, error_text: string) {
	commits = make([dynamic]Commit, 0, 256)
	position := 0
	for position < len(data) {
		if data[position] == 0 {
			position += 1
			continue
		}
		fields: [6]string
		for i := 0; i < len(fields); i += 1 {
			value, next, ok := git_field(data, position)
			if !ok {
				error_text = git_owned_error("git log output ended in the middle of a record")
				return
			}
			fields[i] = value
			position = next
		}
		timestamp, parse_ok := strconv.parse_int(fields[4])
		if !parse_ok {
			error_text = git_owned_error("git log returned an invalid commit timestamp")
			return
		}
		commit := Commit{timestamp=i64(timestamp)}
		copy, clone_err := strings.clone(fields[0])
		if clone_err != nil { error_text = git_owned_error("out of memory copying commit id"); return }
		commit.id = copy
		copy, clone_err = strings.clone(fields[2])
		if clone_err != nil { commit_destroy(&commit); error_text = git_owned_error("out of memory copying author"); return }
		commit.author_name = copy
		copy, clone_err = strings.clone(fields[3])
		if clone_err != nil { commit_destroy(&commit); error_text = git_owned_error("out of memory copying email"); return }
		commit.author_email = copy
		copy, clone_err = strings.clone(fields[5])
		if clone_err != nil { commit_destroy(&commit); error_text = git_owned_error("out of memory copying subject"); return }
		commit.subject = copy
		commit.parents = make([dynamic]string, 0, 2)
		parent_start := 0
		for parent_start < len(fields[1]) {
			for parent_start < len(fields[1]) && fields[1][parent_start] == ' ' { parent_start += 1 }
			if parent_start >= len(fields[1]) { break }
			parent_end := parent_start
			for parent_end < len(fields[1]) && fields[1][parent_end] != ' ' { parent_end += 1 }
			parent, parent_err := strings.clone(fields[1][parent_start:parent_end])
			if parent_err != nil { commit_destroy(&commit); error_text = git_owned_error("out of memory copying parent"); return }
			append(&commit.parents, parent)
			parent_start = parent_end
		}
		append(&commits, commit)
	}
	return
}
