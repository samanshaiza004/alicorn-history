#+feature dynamic-literals

package main

import alicorn "vendor/alicorn/runtime"
import "core:fmt"
import "core:strings"

history_test_dag_geometry :: proc(failures: ^int) {
	commits := [dynamic]Commit{
		commit_dag_test_commit("C", []string{"B"}),
		commit_dag_test_commit("B", []string{"A"}),
		commit_dag_test_commit("A"),
	}
	defer {
		commit_dag_test_destroy_commits(commits[:])
		delete(commits)
	}
	layout := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&layout)
	visible := [3]int{0, 1, 2}
	segments := make([dynamic]alicorn.GPU_Surface_Line_Segment, 0, 16)
	circles := make([dynamic]alicorn.GPU_Surface_Filled_Circle, 0, 8)
	defer delete(segments)
	defer delete(circles)

	history_dag_build_geometry(layout, commits[:], visible[:], 1, 3, 44, 58, 2, false, &segments, &circles)
	history_test_expect(failures, len(circles) == 2, "DAG projects only markers in the virtualized commit range")
	history_test_expect(failures, len(segments) == 2, "DAG projects visible linear parent connections")
	if len(segments) == 2 {
		history_test_expect(failures, segments[1].start.y == 22 && segments[1].end.y == 66, "graph segment coordinates align with row centers in the same virtual viewport")
	}
	history_test_expect(failures, len(circles) == 2 && circles[1].radius > circles[0].radius, "selected commit receives a larger visible marker")

	history_dag_build_geometry(layout, commits[:], visible[:], 0, 3, 44, 58, -1, true, &segments, &circles)
	history_test_expect(failures, len(circles) == 3 && len(segments) == 0, "filtered compact rows retain markers but omit misleading parent connectors")
}

history_test_large_dag_virtual_projection :: proc(failures: ^int) {
	commit_count :: 10_000
	commits := make([dynamic]Commit, 0, commit_count)
	for i in 0..<commit_count {
		id, err := strings.clone(fmt.tprintf("commit-%08d", i))
		if err != nil {
			history_test_expect(failures, false, "large DAG fixture allocates stable commit IDs")
			for &commit in commits { commit_destroy(&commit) }
			delete(commits)
			return
		}
		append(&commits, Commit{id=id})
	}
	for i in 0..<commit_count-1 {
		parent, err := strings.clone(commits[i+1].id)
		if err != nil {
			history_test_expect(failures, false, "large DAG fixture allocates parent identities")
			for &commit in commits { commit_destroy(&commit) }
			delete(commits)
			return
		}
		commits[i].parents = make([dynamic]string, 0, 1)
		append(&commits[i].parents, parent)
	}
	layout := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&layout)
	history_test_expect(failures, len(layout.nodes) == commit_count && len(layout.edges) == commit_count-1 && layout.lane_count == 1, "ten thousand commits retain linear topology in one lane")

	visible := make([dynamic]int, 0, commit_count)
	for i in 0..<commit_count { append(&visible, i) }
	segments := make([dynamic]alicorn.GPU_Surface_Line_Segment, 0, 32)
	circles := make([dynamic]alicorn.GPU_Surface_Filled_Circle, 0, 24)
	history_dag_build_geometry(layout, commits[:], visible[:], 5_000, 5_020, 44, 58, -1, false, &segments, &circles)
	history_test_expect(failures, len(circles) == 20 && len(segments) == 21, "large snapshot projects only the visible rows plus crossing boundary edges")
	history_test_expect(failures, 6+len(segments)*6+len(circles)*alicorn.GPU_SURFACE_CIRCLE_SEGMENTS*3 <= alicorn.GPU_SURFACE_MAX_VERTICES, "large-history viewport geometry stays within the GPU surface budget")
	delete(segments)
	delete(circles)
	delete(visible)
	for &commit in commits { commit_destroy(&commit) }
	delete(commits)
}
