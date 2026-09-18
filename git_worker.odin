package main

import "core:os"
import "core:sync/chan"
import "core:thread"

Git_Wake_Proc :: proc(data: rawptr)

Git_Waker :: struct {
	data: rawptr,
	wake: Git_Wake_Proc,
}

Git_Worker :: struct {
	requests: chan.Chan(^Git_Request),
	results:  chan.Chan(^History_Result),
	thread:   ^thread.Thread,
	waker:    Git_Waker,
	started:  bool,
}

git_worker_proc :: proc(data: rawptr) {
	worker := cast(^Git_Worker)data
	for {
		request, ok := chan.recv(worker.requests)
		if !ok || request == nil { break }
		result := new(History_Result)
		result.kind = request.kind
		result.history_id = request.history_id
		result.detail_id = request.detail_id
		result.repository = request.repository
		commit_id := request.commit_id
		kind := request.kind
		request.repository = ""
		request.commit_id = ""
		git_request_destroy(request)
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
		} else if kind == .Load_Commit_Detail {
			result.detail, result.error_text = git_load_commit_detail(result.repository, commit_id)
		}
		if len(commit_id) > 0 { delete(commit_id) }
		delivered := chan.try_send(worker.results, result)
		if !delivered {
			// Keep the mailbox bounded without blocking shutdown. A newer
			// snapshot supersedes an older one, so discard one queued result
			// and retry delivery before giving up.
			old_result, dropped := chan.try_recv(worker.results)
			if dropped && old_result != nil {
				history_result_destroy(old_result)
				free(old_result)
			}
			delivered = chan.try_send(worker.results, result)
		}
		if !delivered {
			history_result_destroy(result)
			free(result)
			continue
		}
		if worker.waker.wake != nil {
			worker.waker.wake(worker.waker.data)
		}
	}
}

git_worker_start :: proc(worker: ^Git_Worker) -> bool {
	worker.requests, _ = chan.create_buffered(chan.Chan(^Git_Request), 1, context.allocator)
	worker.results, _ = chan.create_buffered(chan.Chan(^History_Result), 2, context.allocator)
	worker.thread = thread.create_and_start_with_data(rawptr(worker), git_worker_proc, name="alicorn-history-git")
	worker.started = worker.thread != nil
	return worker.thread != nil
}

git_worker_set_waker :: proc(worker: ^Git_Worker, waker: Git_Waker) {
	worker.waker = waker
}

git_worker_request :: proc(worker: ^Git_Worker, request: ^Git_Request) -> bool {
	if worker == nil || !worker.started || request == nil { return false }
	// Latest work wins. A request still being executed cannot be canceled
	// safely, but anything waiting in the one-slot mailbox is obsolete once
	// this request arrives.
	for {
		queued, ok := chan.try_recv(worker.requests)
		if !ok { break }
		git_request_destroy(queued)
	}
	if chan.try_send(worker.requests, request) { return true }
	queued, ok := chan.try_recv(worker.requests)
	if ok { git_request_destroy(queued) }
	if chan.try_send(worker.requests, request) { return true }
	return false
}

git_worker_destroy :: proc(worker: ^Git_Worker) {
	if !worker.started { worker^ = {}; return }
	if worker.thread != nil {
		// Clear queued work before inserting the shutdown sentinel. The worker
		// may still be inside one Git process, but it will observe nil next
		// instead of replaying obsolete refresh/detail requests.
		for {
			if chan.try_send(worker.requests, nil) { break }
			queued, ok := chan.try_recv(worker.requests)
			if !ok { continue }
			git_request_destroy(queued)
		}
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
