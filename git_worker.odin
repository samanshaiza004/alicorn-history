package main

import "core:sync/chan"
import "core:thread"

Git_Wake_Proc :: proc(data: rawptr)

Git_Waker :: struct {
	data: rawptr,
	wake: Git_Wake_Proc,
}

// Each request domain has its own one-slot latest-wins lane. Results mirror
// those lanes so a burst of detail requests cannot evict the only current
// history snapshot (or vice versa).
Git_Worker :: struct {
	work_signal:      chan.Chan(u8),
	history_requests: chan.Chan(^Git_Request),
	detail_requests:  chan.Chan(^Git_Request),
	patch_requests:   chan.Chan(^Git_Request),
	history_results:  chan.Chan(^History_Result),
	detail_results:   chan.Chan(^History_Result),
	patch_results:    chan.Chan(^History_Result),
	thread:           ^thread.Thread,
	waker:            Git_Waker,
	started:          bool,
}

git_worker_destroy_result :: proc(result: ^History_Result) {
	if result == nil { return }
	history_result_destroy(result)
	free(result)
}

git_worker_deliver :: proc(worker: ^Git_Worker, result: ^History_Result) -> bool {
	results := worker.history_results
	if result.kind == .Load_Commit_Detail { results = worker.detail_results }
	if result.kind == .Load_File_Patch { results = worker.patch_results }
	if chan.try_send(results, result) { return true }
	// A result already waiting in this same domain is obsolete. Never consume
	// the other domain's mailbox to make room.
	old, ok := chan.try_recv(results)
	if ok { git_worker_destroy_result(old) }
	return chan.try_send(results, result)
}

git_worker_proc :: proc(data: rawptr) {
	worker := cast(^Git_Worker)data
	for {
		signal, ok := chan.recv(worker.work_signal)
		if !ok || signal == 0 { break }
		for {
			// A single coalesced signal can represent work in both lanes. Drain
			// all pending lanes before blocking again so a detail request cannot
			// strand behind a history request (or vice versa).
			request, request_ready := chan.try_recv(worker.history_requests)
			if !request_ready { request, request_ready = chan.try_recv(worker.detail_requests) }
			if !request_ready { request, request_ready = chan.try_recv(worker.patch_requests) }
			if !request_ready { break }
			result := new(History_Result)
			result.kind = request.kind
			result.history_id = request.history_id
			result.detail_id = request.detail_id
			result.patch_id = request.patch_id
			result.repository = request.repository
			commit_id := request.commit_id
			file_path := request.file_path
			kind := request.kind
			request.repository = ""
			request.commit_id = ""
			request.file_path = ""
			git_request_destroy(request)
			if kind == .Load_History {
				stdout, stderr, exit_code, command_ok := git_run(result.repository, []string{
					"log", "--all", "--topo-order", "--date=unix", "-z",
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
			} else if kind == .Load_File_Patch {
				result.patch, result.error_text = git_load_file_patch(result.repository, commit_id, file_path)
			}
			// file_path was transferred out of request before request was
			// destroyed. The local copy is released here; never read the freed
			// request again after git_request_destroy.
			if len(file_path) > 0 { delete(file_path) }
			if len(commit_id) > 0 { delete(commit_id) }
			if !git_worker_deliver(worker, result) {
				git_worker_destroy_result(result)
				continue
			}
			if worker.waker.wake != nil {
				worker.waker.wake(worker.waker.data)
			}
		}
	}
}

git_worker_start :: proc(worker: ^Git_Worker) -> bool {
	worker.work_signal, _ = chan.create_buffered(chan.Chan(u8), 1, context.allocator)
	worker.history_requests, _ = chan.create_buffered(chan.Chan(^Git_Request), 1, context.allocator)
	worker.detail_requests, _ = chan.create_buffered(chan.Chan(^Git_Request), 1, context.allocator)
	worker.patch_requests, _ = chan.create_buffered(chan.Chan(^Git_Request), 1, context.allocator)
	worker.history_results, _ = chan.create_buffered(chan.Chan(^History_Result), 1, context.allocator)
	worker.detail_results, _ = chan.create_buffered(chan.Chan(^History_Result), 1, context.allocator)
	worker.patch_results, _ = chan.create_buffered(chan.Chan(^History_Result), 1, context.allocator)
	worker.thread = thread.create_and_start_with_data(rawptr(worker), git_worker_proc, name="alicorn-history-git")
	worker.started = worker.thread != nil
	return worker.thread != nil
}

git_worker_set_waker :: proc(worker: ^Git_Worker, waker: Git_Waker) {
	worker.waker = waker
}

git_worker_replace_request :: proc(queue: chan.Chan(^Git_Request), request: ^Git_Request) -> bool {
	old, ok := chan.try_recv(queue)
	if ok { git_request_destroy(old) }
	if chan.try_send(queue, request) { return true }
	old, ok = chan.try_recv(queue)
	if ok { git_request_destroy(old) }
	return chan.try_send(queue, request)
}

git_worker_request :: proc(worker: ^Git_Worker, request: ^Git_Request) -> bool {
	if worker == nil || !worker.started || request == nil { return false }
	switch request.kind {
	case .Load_History:
		queued := git_worker_replace_request(worker.history_requests, request)
		if queued { _ = chan.try_send(worker.work_signal, 1) }
		return queued
	case .Load_Commit_Detail:
		queued := git_worker_replace_request(worker.detail_requests, request)
		if queued { _ = chan.try_send(worker.work_signal, 1) }
		return queued
	case .Load_File_Patch:
		queued := git_worker_replace_request(worker.patch_requests, request)
		if queued { _ = chan.try_send(worker.work_signal, 1) }
		return queued
	}
	return false
}

git_worker_drain_requests :: proc(queue: chan.Chan(^Git_Request)) {
	for {
		request, ok := chan.try_recv(queue)
		if !ok { break }
		git_request_destroy(request)
	}
}

git_worker_drain_results :: proc(queue: chan.Chan(^History_Result)) {
	for {
		result, ok := chan.try_recv(queue)
		if !ok { break }
		git_worker_destroy_result(result)
	}
}

git_worker_destroy :: proc(worker: ^Git_Worker) {
	if !worker.started { worker^ = {}; return }
	if worker.thread != nil {
		// Drop all queued work in both domains before waking the worker to stop.
		// The currently running Git process is allowed to finish, but no stale
		// request can delay shutdown after that process returns.
		git_worker_drain_requests(worker.history_requests)
		git_worker_drain_requests(worker.detail_requests)
		git_worker_drain_requests(worker.patch_requests)
		// Replace any coalesced work token with a stop token. The worker is
		// either blocked in recv or finishing the one Git command already in
		// flight; no queued request remains after the drains above.
		_, _ = chan.try_recv(worker.work_signal)
		_ = chan.try_send(worker.work_signal, 0)
		thread.join(worker.thread)
		thread.destroy(worker.thread)
	}
	git_worker_drain_results(worker.history_results)
	git_worker_drain_results(worker.detail_results)
	git_worker_drain_results(worker.patch_results)
	_ = chan.destroy(worker.work_signal.impl)
	_ = chan.destroy(worker.history_requests.impl)
	_ = chan.destroy(worker.detail_requests.impl)
	_ = chan.destroy(worker.patch_requests.impl)
	_ = chan.destroy(worker.history_results.impl)
	_ = chan.destroy(worker.detail_results.impl)
	_ = chan.destroy(worker.patch_results.impl)
	worker^ = {}
}
