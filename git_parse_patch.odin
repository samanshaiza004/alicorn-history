package main

import "core:strconv"
import "core:strings"

git_patch_next_line :: proc(data: []byte, start: int) -> (line: string, next: int, ok: bool) {
	if start < 0 || start > len(data) { return }
	end := start
	for end < len(data) && data[end] != '\n' { end += 1 }
	line = string(data[start:end])
	if len(line) > 0 && line[len(line)-1] == '\r' { line = line[:len(line)-1] }
	next = end
	if next < len(data) { next += 1 }
	ok = true
	return
}

git_patch_parse_number :: proc(value: string, start: int) -> (number, next: int, ok: bool) {
	if start < 0 || start >= len(value) || value[start] < '0' || value[start] > '9' { return }
	end := start
	for end < len(value) && value[end] >= '0' && value[end] <= '9' { end += 1 }
	parsed, parsed_ok := strconv.parse_int(value[start:end])
	if !parsed_ok { return }
	return int(parsed), end, true
}

git_patch_parse_hunk_header :: proc(line: string) -> (old_start, old_count, new_start, new_count: int, ok: bool) {
	if len(line) < 4 || line[:2] != "@@" { return }
	position := 0
	minus := -1
	for i := 2; i < len(line); i += 1 {
		if line[i] == '-' { minus = i; break }
	}
	if minus < 0 { return }
	old_start, position, ok = git_patch_parse_number(line, minus+1)
	if !ok { return }
	old_count = 1
	if position < len(line) && line[position] == ',' {
		old_count, position, ok = git_patch_parse_number(line, position+1)
		if !ok { return }
	}
	plus := -1
	for i := position; i < len(line); i += 1 {
		if line[i] == '+' { plus = i; break }
	}
	if plus < 0 { return }
	new_start, position, ok = git_patch_parse_number(line, plus+1)
	if !ok { return }
	new_count = 1
	if position < len(line) && line[position] == ',' {
		new_count, position, ok = git_patch_parse_number(line, position+1)
		if !ok { return }
	}
	return old_start, old_count, new_start, new_count, true
}

git_patch_append_metadata :: proc(patch: ^File_Patch, line: string) -> bool {
	copy, err := strings.clone(line)
	if err != nil { return false }
	if patch.metadata == nil { patch.metadata = make([dynamic]string, 0, 4) }
	append(&patch.metadata, copy)
	return true
}

git_patch_append_line :: proc(hunk: ^Diff_Hunk, kind: Diff_Line_Kind, old_line, new_line: int, value: string) -> bool {
	copy, err := strings.clone(value)
	if err != nil { return false }
	if hunk.lines == nil { hunk.lines = make([dynamic]Diff_Line, 0, 32) }
	append(&hunk.lines, Diff_Line{kind=kind, old_line=old_line, new_line=new_line, text=copy})
	return true
}

git_parse_patch :: proc(data: []byte) -> (patch: File_Patch, error_text: string) {
	patch.hunks = make([dynamic]Diff_Hunk, 0, 8)
	patch.metadata = make([dynamic]string, 0, 4)
	position := 0
	current_hunk := -1
	old_line := 0
	new_line := 0
	for position < len(data) {
		line, next, line_ok := git_patch_next_line(data, position)
		if !line_ok { break }
		position = next
		if len(line) >= 2 && line[:2] == "@@" {
			old_start, old_count, new_start, new_count, header_ok := git_patch_parse_hunk_header(line)
			if !header_ok {
				file_patch_destroy(&patch)
				error_text = git_owned_error("git patch contained a malformed hunk header")
				return
			}
			header, clone_err := strings.clone(line)
			if clone_err != nil {
				file_patch_destroy(&patch)
				error_text = git_owned_error("out of memory copying patch hunk header")
				return
			}
			append(&patch.hunks, Diff_Hunk{
				old_start=old_start,
				old_count=old_count,
				new_start=new_start,
				new_count=new_count,
				header=header,
				lines=make([dynamic]Diff_Line, 0, 32),
			})
			current_hunk = len(patch.hunks)-1
			old_line = old_start
			new_line = new_start
			continue
		}
		if current_hunk < 0 {
			if strings.has_prefix(line, "Binary files ") || strings.has_prefix(line, "GIT binary patch") {
				patch.binary = true
				if !git_patch_append_metadata(&patch, line) {
					file_patch_destroy(&patch)
					error_text = git_owned_error("out of memory copying binary patch metadata")
					return
				}
			} else if strings.has_prefix(line, "old mode ") ||
				strings.has_prefix(line, "new mode ") ||
				strings.has_prefix(line, "new file mode ") ||
				strings.has_prefix(line, "deleted file mode ") ||
				strings.has_prefix(line, "rename from ") ||
				strings.has_prefix(line, "rename to ") {
				if !git_patch_append_metadata(&patch, line) {
					file_patch_destroy(&patch)
					error_text = git_owned_error("out of memory copying patch metadata")
					return
				}
			}
			continue
		}
		hunk := &patch.hunks[current_hunk]
		if len(line) == 0 {
			// A valid empty patch line still carries its leading kind byte. A
			// truly empty line is metadata from a malformed/foreign producer.
			continue
		}
		kind := Diff_Line_Kind.Meta
		text := line
		advance_old := false
		advance_new := false
		switch line[0] {
		case ' ':
			kind = .Context
			text = line[1:]
			advance_old = true
			advance_new = true
		case '+':
			kind = .Addition
			text = line[1:]
			advance_new = true
		case '-':
			kind = .Deletion
			text = line[1:]
			advance_old = true
		case '\\':
			kind = .Meta
		}
		if !git_patch_append_line(hunk, kind, old_line if advance_old else 0, new_line if advance_new else 0, text) {
			file_patch_destroy(&patch)
			error_text = git_owned_error("out of memory copying patch line")
			return
		}
		if advance_old { old_line += 1 }
		if advance_new { new_line += 1 }
	}
	history_patch_prepare_display(&patch)
	return
}

git_first_parent :: proc(repository, commit_id: string) -> (parent: string, ok: bool, error_text: string) {
	stdout, stderr, exit_code, command_ok := git_run(repository, []string{"show", "-s", "--format=%P", commit_id, "--"})
	defer {
		if len(stdout) > 0 { delete(stdout) }
		if len(stderr) > 0 { delete(stderr) }
	}
	if !command_ok {
		error_text = git_error_text(stderr, exit_code)
		return
	}
	end := 0
	for end < len(stdout) && stdout[end] != ' ' && stdout[end] != '\n' && stdout[end] != '\r' { end += 1 }
	if end == 0 { return "", true, "" }
	parent, _ = strings.clone(string(stdout[:end]))
	return parent, true, ""
}

git_load_file_patch :: proc(repository, commit_id, file_path: string) -> (patch: File_Patch, error_text: string) {
	patch.path, _ = strings.clone(file_path)
	parent, parent_ok, parent_error := git_first_parent(repository, commit_id)
	if len(parent_error) > 0 {
		error_text = parent_error
		return
	}
	args := []string{}
	if !parent_ok {
		file_patch_destroy(&patch)
		error_text = git_owned_error("could not resolve commit parent")
		return
	}
	if len(parent) == 0 {
		args = []string{
			"--literal-pathspecs", "diff-tree", "--root", "-p", "-r", "--no-commit-id",
			"--no-color", "--no-ext-diff", "--no-textconv", "--default-prefix",
			"--unified=3", "--no-renames", commit_id, "--", file_path,
		}
	} else {
		args = []string{
			"--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
			"--default-prefix", "--unified=3", "--no-renames", parent, commit_id,
			"--", file_path,
		}
	}
	stdout, stderr, exit_code, command_ok := git_run(repository, args)
	if !command_ok {
		error_text = git_error_text(stderr, exit_code)
		file_patch_destroy(&patch)
		if len(stdout) > 0 { delete(stdout) }
		if len(stderr) > 0 { delete(stderr) }
		if len(parent) > 0 { delete(parent) }
		return
	}
	parsed, parse_error := git_parse_patch(stdout)
	if len(stdout) > 0 { delete(stdout) }
	if len(stderr) > 0 { delete(stderr) }
	if len(parent) > 0 { delete(parent) }
	if len(parse_error) > 0 {
		file_patch_destroy(&patch)
		error_text = parse_error
		return
	}
	parsed.path = patch.path
	patch.path = ""
	patch = parsed
	return
}
