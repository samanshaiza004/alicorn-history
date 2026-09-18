package main

import "core:fmt"
import "core:os"
import "core:strings"

git_run :: proc(repository: string, args: []string) -> (stdout, stderr: []byte, exit_code: int, ok: bool) {
	command := make([dynamic]string, 0, len(args)+4)
	append(&command, "git")
	append(&command, "--no-pager")
	append(&command, "--no-optional-locks")
	append(&command, "-C")
	append(&command, repository)
	for arg in args { append(&command, arg) }
	state, output, errors, err := os.process_exec(os.Process_Desc{command=command[:]}, context.allocator)
	delete(command)
	if err != nil {
		if len(output) > 0 { delete(output) }
		if len(errors) > 0 { delete(errors) }
		return nil, nil, -1, false
	}
	exit_code = state.exit_code
	ok = state.success && state.exited && exit_code == 0
	stdout, stderr = output, errors
	return
}

git_repository_branch :: proc(repository: string) -> string {
	stdout, stderr, _, ok := git_run(repository, []string{"branch", "--show-current"})
	defer { if len(stderr) > 0 { delete(stderr) } }
	if !ok {
		if len(stdout) > 0 { delete(stdout) }
		result, _ := strings.clone("detached")
		return result
	}
	result, clone_err := strings.clone(string(stdout))
	if clone_err != nil {
		if len(stdout) > 0 { delete(stdout) }
		return "detached"
	}
	if len(stdout) > 0 { delete(stdout) }
	if len(result) > 0 && result[len(result)-1] == '\n' { result = result[:len(result)-1] }
	if len(result) == 0 {
		delete(result)
		result, _ = strings.clone("detached")
	}
	return result
}

git_error_text :: proc(stderr: []byte, exit_code: int) -> string {
	if len(stderr) == 0 { return fmt.tprintf("git exited with status %d", exit_code) }
	result, err := strings.clone(string(stderr))
	if err != nil { return fmt.tprintf("git exited with status %d", exit_code) }
	return result
}
