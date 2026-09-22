#+feature dynamic-literals

package main

import "core:testing"

commit_dag_test_commit :: proc(id: string, parents: []string = nil) -> Commit {
	commit := Commit{id=id}
	commit.parents = make([dynamic]string, 0, len(parents))
	for parent in parents { append(&commit.parents, parent) }
	return commit
}

commit_dag_test_destroy_commits :: proc(commits: []Commit) {
	for &commit in commits { delete(commit.parents) }
}

commit_dag_test_edge_exists :: proc(layout: Commit_DAG_Layout, child_row, parent_row, parent_ordinal: int) -> bool {
	for edge in layout.edges {
		if edge.child_row == child_row && edge.parent_row == parent_row && edge.parent_ordinal == parent_ordinal {
			return true
		}
	}
	return false
}

@(test)
test_commit_dag_linear_history :: proc(t: ^testing.T) {
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

	testing.expect(t, len(layout.nodes) == 3 && len(layout.edges) == 2, "linear history retains all rows and parent edges")
	testing.expect(t, layout.lane_count == 1, "linear history uses one lane")
	testing.expect(t, layout.nodes[0].row == 0 && layout.nodes[1].row == 1 && layout.nodes[2].row == 2, "DAG rows preserve input order")
	testing.expect(t, layout.nodes[0].lane == 0 && layout.nodes[1].lane == 0 && layout.nodes[2].lane == 0, "primary-parent chain stays in one lane")
	testing.expect(t, layout.nodes[2].is_root && !layout.nodes[0].is_root, "root is distinguished from ordinary commits")
	testing.expect(t, commit_dag_test_edge_exists(layout, 0, 1, 0) && commit_dag_test_edge_exists(layout, 1, 2, 0), "linear edges connect each child to its parent row")
}

@(test)
test_commit_dag_branch_merge_and_lane_reuse :: proc(t: ^testing.T) {
	commits := [dynamic]Commit{
		commit_dag_test_commit("M", []string{"A", "B"}),
		commit_dag_test_commit("A", []string{"R"}),
		commit_dag_test_commit("B", []string{"R"}),
		commit_dag_test_commit("Z"),
		commit_dag_test_commit("R"),
	}
	defer {
		commit_dag_test_destroy_commits(commits[:])
		delete(commits)
	}
	layout := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&layout)

	testing.expect(t, layout.nodes[0].lane == 0 && layout.nodes[1].lane == 0 && layout.nodes[2].lane == 1, "branch reserves a deterministic side lane")
	testing.expect(t, layout.nodes[3].lane == 1, "released branch lane is reused by a disconnected root")
	testing.expect(t, layout.nodes[4].lane == 0, "primary history lane remains reserved through the merge base")
	testing.expect(t, layout.lane_count == 2, "branch merge uses only the necessary two lanes")
	testing.expect(t, commit_dag_test_edge_exists(layout, 0, 1, 0) && commit_dag_test_edge_exists(layout, 0, 2, 1), "merge emits both parent edges in parent-list order")
	testing.expect(t, commit_dag_test_edge_exists(layout, 1, 4, 0) && commit_dag_test_edge_exists(layout, 2, 4, 0), "converging branches meet at their shared parent")
}

@(test)
test_commit_dag_octopus_merge :: proc(t: ^testing.T) {
	commits := [dynamic]Commit{
		commit_dag_test_commit("O", []string{"A", "B", "C"}),
		commit_dag_test_commit("A", []string{"R"}),
		commit_dag_test_commit("B", []string{"R"}),
		commit_dag_test_commit("C", []string{"R"}),
		commit_dag_test_commit("R"),
	}
	defer {
		commit_dag_test_destroy_commits(commits[:])
		delete(commits)
	}
	layout := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&layout)

	testing.expect(t, len(layout.edges) == 6, "octopus history emits every distinct parent relationship")
	testing.expect(t, layout.lane_count == 3, "octopus merge reserves one lane for each concurrent parent path")
	testing.expect(t, layout.nodes[0].lane == 0 && layout.nodes[1].lane == 0 && layout.nodes[2].lane == 1 && layout.nodes[3].lane == 2 && layout.nodes[4].lane == 0, "octopus lane assignment is stable across parent paths")
	testing.expect(t, commit_dag_test_edge_exists(layout, 0, 3, 2), "third octopus parent retains its original parent ordinal")
}

@(test)
test_commit_dag_missing_and_disconnected_parents :: proc(t: ^testing.T) {
	commits := [dynamic]Commit{
		commit_dag_test_commit("shallow", []string{"outside-snapshot"}),
		commit_dag_test_commit("root"),
		commit_dag_test_commit("child", []string{"root"}),
	}
	defer {
		commit_dag_test_destroy_commits(commits[:])
		delete(commits)
	}
	layout := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&layout)

	testing.expect(t, layout.nodes[0].missing_parent_count == 1 && layout.nodes[0].unresolved_parent_count == 1, "missing shallow parent is reported on its child")
	testing.expect(t, layout.missing_parent_count == 1, "layout aggregates unresolved parents")
	testing.expect(t, !layout.nodes[0].is_root && layout.nodes[1].is_root, "a missing parent does not turn a shallow commit into a root")
	testing.expect(t, len(layout.edges) == 1 && commit_dag_test_edge_exists(layout, 2, 1, 0), "known disconnected component still produces its edge")
	testing.expect(t, layout.nodes[0].lane == 0 && layout.nodes[1].lane == 0, "lane released by a shallow boundary is safely reused")
}

@(test)
test_commit_dag_deterministic_for_fixed_input :: proc(t: ^testing.T) {
	commits := [dynamic]Commit{
		commit_dag_test_commit("M", []string{"A", "B", "C"}),
		commit_dag_test_commit("A", []string{"R"}),
		commit_dag_test_commit("B", []string{"R"}),
		commit_dag_test_commit("C", []string{"R"}),
		commit_dag_test_commit("R"),
	}
	defer {
		commit_dag_test_destroy_commits(commits[:])
		delete(commits)
	}
	first := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&first)
	second := commit_dag_layout(commits[:])
	defer commit_dag_destroy(&second)

	equal := first.lane_count == second.lane_count &&
		first.missing_parent_count == second.missing_parent_count &&
		first.duplicate_id_count == second.duplicate_id_count &&
		len(first.nodes) == len(second.nodes) &&
		len(first.edges) == len(second.edges)
	if equal {
		for i in 0..<len(first.nodes) {
			if first.nodes[i] != second.nodes[i] { equal = false; break }
		}
	}
	if equal {
		for i in 0..<len(first.edges) {
			if first.edges[i] != second.edges[i] { equal = false; break }
		}
	}
	testing.expect(t, equal, "fixed commit input produces field-for-field stable lane and edge records")
}
