package main

import "core:os"
import "core:sync/chan"
import "core:thread"

Git_Worker :: struct {
	requests: chan.Chan(^Git_Request),
	results:  chan.Chan(^History_Result),
	thread:   ^thread.Thread,
}

git_worker_proc :: proc(data: rawptr) {
	worker := cast(^Git_Worker)data
	for {
		request, ok := chan.recv(worker.requests)
		if !ok || request == nil { break }
		result := new(History_Result)
		result.id = request.id
		result.repository = request.repository
		kind := request.kind
		request.repository = ""
		free(request)
		if kind == .Load_History {
			stdout, stderr, exit_code, command_ok := git_run(result.repository, []string{
				"log", "--all", "--topo-order", "--date=unix",
				"--pretty=format:%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00",
			})
			if !command_ok {
				result.error_text = git_error_text(stderr, exit_code)
				if len(stdout) > 0 { delete(stdout) }
				if len(stderr) > 0 { delete(stderr) }
			} else {
				result.commits, result.error_text = git_parse_log(stdout)
				if len(stdout) > 0 { delete(stdout) }
				if len(stderr) > 0 { delete(stderr) }
			}
			result.branch = git_repository_branch(result.repository)
		}
		if !chan.send(worker.results, result) {
			history_result_destroy(result)
			free(result)
			break
		}
	}
}

git_worker_start :: proc(worker: ^Git_Worker) -> bool {
	worker.requests, _ = chan.create_buffered(chan.Chan(^Git_Request), 4, context.allocator)
	worker.results, _ = chan.create_buffered(chan.Chan(^History_Result), 2, context.allocator)
	worker.thread = thread.create_and_start_with_data(rawptr(worker), git_worker_proc, name="alicorn-history-git")
	return worker.thread != nil
}

git_worker_request :: proc(worker: ^Git_Worker, request: ^Git_Request) -> bool {
	return chan.try_send(worker.requests, request)
}

git_worker_destroy :: proc(worker: ^Git_Worker) {
	if worker.thread != nil {
		_ = chan.send(worker.requests, nil)
		thread.join(worker.thread)
		thread.destroy(worker.thread)
	}
	for {
		result, ok := chan.try_recv(worker.results)
		if !ok || result == nil { break }
		history_result_destroy(result)
		free(result)
	}
	_ = chan.destroy(worker.requests.impl)
	_ = chan.destroy(worker.results.impl)
	worker^ = {}
}
