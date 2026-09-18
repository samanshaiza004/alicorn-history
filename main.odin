package main

import "core:fmt"
import "core:os"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

main :: proc() {
	repository := "."
	for argument in os.args[1:] {
		if argument != "--smoke" && argument != "--self-test" { repository = argument; break }
	}
	if !path_exists(repository) {
		fmt.println("alicorn-history: repository does not exist:", repository)
		os.exit(1)
	}
	if has_argument("--self-test") {
		if !history_run_tests(repository) { os.exit(1) }
		return
	}
	app := history_app_new(repository)
	defer {
		history_app_destroy(app)
		free(app)
	}
	if app == nil || !history_worker_submit(app) { os.exit(1) }
	application := host.Application{
		state=rawptr(app),
		title="Alicorn History",
		width=1200,
		height=800,
		build=history_build,
		on_text_change=history_on_text_change,
		on_key=history_on_key,
		on_scroll=history_on_scroll,
		on_tick=history_on_tick,
	}
	host.Run(application, has_argument("--smoke"))
	fmt.println("alicorn-history PASS", "commits", len(app.commits), "builds", app.build_count, "results", app.result_count)
}

has_argument :: proc(value: string) -> bool {
	for argument in os.args { if argument == value { return true } }
	return false
}

path_exists :: proc(path: string) -> bool {
	return os.is_dir(path)
}
