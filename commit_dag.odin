package main

// Commit_DAG_Node is a commit's stable position in the supplied history
// snapshot. Rows always preserve the caller's input order; lanes are assigned
// deterministically from that order and the commit parent lists.
Commit_DAG_Node :: struct {
	row:                    int,
	lane:                   int,
	commit_index:           int,
	missing_parent_count:   int,
	unresolved_parent_count: int,
	is_root:                bool,
}

// Commit_DAG_Edge connects a child row/lane to a parent row/lane. A valid parent
// present in the snapshot produces an edge, including when the input order is
// not topological. Such backward edges are still represented exactly rather
// than silently changing the caller's row order. Invalid self-parent links are
// counted as unresolved and omitted because they have no useful row geometry.
Commit_DAG_Edge :: struct {
	child_row:     int,
	child_lane:    int,
	parent_row:    int,
	parent_lane:   int,
	parent_ordinal: int,
}

// Commit_DAG_Layout contains only backend-neutral row/lane coordinates.
// Missing parents (common for shallow or filtered snapshots) are counted on
// their child node and do not create fabricated connections.
Commit_DAG_Layout :: struct {
	nodes:               [dynamic]Commit_DAG_Node,
	edges:               [dynamic]Commit_DAG_Edge,
	lane_count:          int,
	missing_parent_count: int,
	duplicate_id_count:  int,
}

commit_dag_destroy :: proc(layout: ^Commit_DAG_Layout) {
	if layout == nil { return }
	delete(layout.nodes)
	delete(layout.edges)
	layout^ = {}
}

// commit_dag_layout assigns stable lanes in O(V+E) expected time.
//
// The first parent prefers the child's lane, keeping the primary history
// spine straight. Additional parents use lanes already reserved by earlier
// children or allocate a free lane. Freed lanes are reused LIFO; because the
// traversal and parent order are fixed, the resulting layout is deterministic
// without sorting or depending on map iteration order.
//
// The ID map keeps the first row for duplicate IDs. Duplicate IDs are counted
// and later references resolve to that first row. Parent IDs absent from the
// supplied snapshot are reported as missing instead of being treated as roots.
commit_dag_layout :: proc(commits: []Commit) -> Commit_DAG_Layout {
	layout := Commit_DAG_Layout{}
	layout.nodes = make([dynamic]Commit_DAG_Node, 0, len(commits))
	layout.edges = make([dynamic]Commit_DAG_Edge, 0)
	for row in 0..<len(commits) {
		append(&layout.nodes, Commit_DAG_Node{row=row, commit_index=row})
	}

	if len(commits) == 0 { return layout }

	row_by_id := make(map[string]int, len(commits))
	pending_lane_by_id := make(map[string]int, len(commits))
	seen_parent_row := make(map[string]int)
	lane_busy := make([dynamic]bool, 0, len(commits))
	free_lanes := make([dynamic]int, 0, len(commits))
	defer {
		delete(row_by_id)
		delete(pending_lane_by_id)
		delete(seen_parent_row)
		delete(lane_busy)
		delete(free_lanes)
	}

	// Insert only after the first occurrence so duplicate IDs still yield a
	// stable, unambiguous target row.
	for commit, row in commits {
		_, exists := row_by_id[commit.id]
		if exists {
			layout.duplicate_id_count += 1
		} else {
			row_by_id[commit.id] = row
		}
	}

	for commit, row in commits {
		current_lane: int
		if lane, pending := pending_lane_by_id[commit.id]; pending {
			current_lane = lane
			delete_key(&pending_lane_by_id, commit.id)
			lane_busy[current_lane] = false
		} else if len(free_lanes) > 0 {
			current_lane = pop(&free_lanes)
			lane_busy[current_lane] = true
		} else {
			current_lane = len(lane_busy)
			append(&lane_busy, true)
		}

		layout.nodes[row].lane = current_lane
		layout.nodes[row].is_root = len(commit.parents) == 0
		// The commit is now placed. Its lane can be continued by its primary
		// parent unless another still-pending path already owns that lane.
		lane_busy[current_lane] = false

		for parent_id, parent_ordinal in commit.parents {
			// Malformed duplicate parent entries should not draw duplicate edges
			// or reserve additional lanes.
			if previous_row, seen := seen_parent_row[parent_id]; seen && previous_row == row {
				continue
			}
			seen_parent_row[parent_id] = row

			parent_row, present := row_by_id[parent_id]
			if !present {
				layout.nodes[row].missing_parent_count += 1
				layout.nodes[row].unresolved_parent_count += 1
				layout.missing_parent_count += 1
				continue
			}

			if parent_row == row {
				// A self-parent is invalid topology. Keep the row and snapshot intact,
				// but don't emit a degenerate self-edge.
				layout.nodes[row].unresolved_parent_count += 1
				continue
			}

			parent_lane: int
			if parent_row < row {
				// The supplied order was not parent-after-child for this edge. Keep
				// the exact input order and connect to the already assigned lane.
				parent_lane = layout.nodes[parent_row].lane
			} else if lane, pending := pending_lane_by_id[parent_id]; pending {
				parent_lane = lane
			} else {
				if parent_ordinal == 0 && !lane_busy[current_lane] {
					parent_lane = current_lane
					lane_busy[parent_lane] = true
				} else if len(free_lanes) > 0 {
					parent_lane = pop(&free_lanes)
					lane_busy[parent_lane] = true
				} else {
					parent_lane = len(lane_busy)
					append(&lane_busy, true)
				}
				pending_lane_by_id[parent_id] = parent_lane
			}

			append(&layout.edges, Commit_DAG_Edge{
				child_row=row,
				child_lane=current_lane,
				parent_row=parent_row,
				parent_lane=parent_lane,
				parent_ordinal=parent_ordinal,
			})
		}

		// If no later parent continues through this lane, make it available to a
		// later disconnected component or branch. It is pushed exactly once.
		if !lane_busy[current_lane] {
			append(&free_lanes, current_lane)
		}
	}

	layout.lane_count = len(lane_busy)
	return layout
}
