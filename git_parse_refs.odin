package main

import "core:strings"

git_ref_name_parts :: proc(full_name: string) -> (kind: Git_Ref_Kind, short_name: string, ok: bool) {
	if strings.has_prefix(full_name, "refs/heads/") {
		return .Branch, full_name[len("refs/heads/"):], true
	}
	if strings.has_prefix(full_name, "refs/remotes/") {
		return .Remote, full_name[len("refs/remotes/"):], true
	}
	if strings.has_prefix(full_name, "refs/tags/") {
		return .Tag, full_name[len("refs/tags/"):], true
	}
	return
}

git_ref_oid_valid :: proc(value: string) -> bool {
	if len(value) != 40 && len(value) != 64 { return false }
	for byte in value {
		if (byte >= '0' && byte <= '9') ||
			(byte >= 'a' && byte <= 'f') ||
			(byte >= 'A' && byte <= 'F') {
			continue
		}
		return false
	}
	return true
}

git_parse_refs :: proc(data: []byte) -> (refs: [dynamic]Git_Ref, error_text: string) {
	refs = make([dynamic]Git_Ref, 0, 64)
	position := 0
	for position < len(data) {
		for position < len(data) && (data[position] == '\n' || data[position] == '\r') {
			position += 1
		}
		if position >= len(data) { break }

		fields: [7]string
		fields_ok := true
		for i := 0; i < len(fields); i += 1 {
			field, next, ok := git_field(data, position)
			if !ok {
				fields_ok = false
				break
			}
			fields[i] = field
			position = next
		}
		if !fields_ok {
			git_refs_destroy(refs)
			refs = {}
			error_text = git_owned_error("git for-each-ref output ended in the middle of a record")
			return
		}
		if position < len(data) && data[position] == '\r' { position += 1 }
		if position < len(data) && data[position] == '\n' { position += 1 }

		kind, short_name, recognized := git_ref_name_parts(fields[0])
		// Symbolic refs such as refs/remotes/origin/HEAD are aliases. Hiding
		// them avoids a duplicate row with an ambiguous short name.
		if !recognized || len(short_name) == 0 || len(fields[6]) > 0 { continue }
		if !git_ref_oid_valid(fields[1]) { continue }

		target_commit_id := ""
		if fields[2] == "commit" {
			target_commit_id = fields[1]
		} else if kind == .Tag && fields[4] == "commit" && git_ref_oid_valid(fields[3]) {
			// For annotated tags, object_id is the tag object. The starred
			// for-each-ref fields describe its peeled target.
			target_commit_id = fields[3]
		}

		ref := Git_Ref{kind=kind, is_head=fields[5] == "*"}
		ref.full_name, _ = strings.clone(fields[0])
		ref.short_name, _ = strings.clone(short_name)
		ref.object_id, _ = strings.clone(fields[1])
		if len(target_commit_id) > 0 {
			ref.target_commit_id, _ = strings.clone(target_commit_id)
		}
		if len(ref.full_name) == 0 || len(ref.short_name) == 0 || len(ref.object_id) == 0 ||
			(len(target_commit_id) > 0 && len(ref.target_commit_id) == 0) {
			git_ref_destroy(&ref)
			git_refs_destroy(refs)
			refs = {}
			error_text = git_owned_error("out of memory copying Git ref")
			return
		}
		append(&refs, ref)
	}
	return
}
