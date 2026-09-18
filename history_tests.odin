package main

import "core:fmt"

history_test_expect :: proc(failures: ^int, condition: bool, message: string) {
	if !condition {
		failures^ += 1
		fmt.println("FAIL:", message)
	}
}

history_run_tests :: proc(repository: string) -> bool {
	failures := 0
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

	current := History_App{latest_request_id=Git_Request_ID(7)}
	history_test_expect(&failures, history_result_is_current(&current, Git_Request_ID(7)), "latest Git generation is accepted")
	history_test_expect(&failures, !history_result_is_current(&current, Git_Request_ID(6)), "stale Git generation is rejected")

	stdout, stderr, _, command_ok := git_run(repository, []string{
		"log", "--all", "--topo-order", "--date=unix",
		"--pretty=format:%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00",
	})
	history_test_expect(&failures, command_ok, "installed Git can read the target repository")
	if command_ok {
		real_commits, real_error := git_parse_log(stdout)
		history_test_expect(&failures, len(real_error) == 0, "real repository output parses completely")
		history_test_expect(&failures, len(real_commits) > 0, "real repository produces commits")
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
