package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "vendor/alicorn/runtime"
import host "vendor/alicorn/native/sdl_gpu"

main :: proc() {
	repository := "."
	fixture_root := "."
	repository_was_set := false
	argument_index := 1
	for argument_index < len(os.args) {
		argument := os.args[argument_index]
		if argument == "--fixture-root" {
			if argument_index+1 >= len(os.args) {
				fmt.println("alicorn-history: --fixture-root requires a directory")
				os.exit(1)
			}
			fixture_root = os.args[argument_index+1]
			argument_index += 2
			continue
		}
		fixture_root_prefix := "--fixture-root="
		if strings.has_prefix(argument, fixture_root_prefix) {
			fixture_root = argument[len(fixture_root_prefix):]
			argument_index += 1
			continue
		}
		if !repository_was_set && !strings.has_prefix(argument, "--") {
			repository = argument
			repository_was_set = true
		}
		argument_index += 1
	}
	if !path_exists(repository) {
		fmt.println("alicorn-history: repository does not exist:", repository)
		os.exit(1)
	}
	if has_argument("--self-test") {
		if !path_exists(fixture_root) {
			fmt.println("alicorn-history: test fixture root does not exist:", fixture_root)
			os.exit(1)
		}
		if !history_run_tests(repository, fixture_root) { os.exit(1) }
		return
	}
	if has_argument("--self-test-folding") {
		if !path_exists(fixture_root) {
			fmt.println("alicorn-history: test fixture root does not exist:", fixture_root)
			os.exit(1)
		}
		failures := 0
		history_test_patch_projection(&failures, fixture_root)
		if failures > 0 { os.exit(1) }
		fmt.println("History folding PASS")
		return
	}
	app := history_app_new(repository)
	defer {
		history_app_destroy(app)
		free(app)
	}
	if app == nil { os.exit(1) }
	app.select_first_on_load = has_argument("--select-first")
	app.folding_enabled = has_argument("--folding")
	if has_argument("--profile-folding") || has_argument("--profile-expanded") { history_profile_prepare(app, has_argument("--profile-expanded")) }
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
	if app.fold_profile.enabled { application.build = history_profile_build; application.on_scheduled_wake = history_profile_on_scheduled }
	host.Run(application, has_argument("--smoke"))
	history_profile_report(app)
	if app.fold_profile.failures > 0 { os.exit(1) }
	fmt.println("alicorn-history PASS", "commits", len(app.commits), "builds", app.build_count, "results", app.result_count)
}

has_argument :: proc(value: string) -> bool {
	for argument in os.args { if argument == value { return true } }
	return false
}

path_exists :: proc(path: string) -> bool {
	return os.is_dir(path)
}
