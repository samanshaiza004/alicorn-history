package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

main :: proc() {
	repository := "."
	for argument in os.args[1:] {
		if !strings.has_prefix(argument, "--") { repository = argument; break }
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
	if app == nil { os.exit(1) }
	app.select_first_on_load = has_argument("--select-first")
	application := host.Application{
		state=rawptr(app),
		title="Alicorn History",
		width=1200,
		height=800,
		on_start=history_on_start,
		on_services=history_on_services,
		on_dialog=history_on_dialog,
		build=history_build,
		on_text_change=history_on_text_change,
		on_key=history_on_key,
		on_scroll=nil,
		on_tick=nil,
		on_wake=history_on_wake,
		on_stop=history_on_stop,
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
