package main

import "core:mem"

// Positions and extents have separate types. File lines are one-based;
// displayed rows, hunks, hunk-line indexes and byte offsets are zero-based.
Patch_Old_Line :: distinct i64
Patch_New_Line :: distinct i64
Patch_Display_Row :: distinct i64
Patch_Hunk_Ordinal :: distinct int
Patch_Line_Index :: distinct int
Patch_Byte_Offset :: distinct int
Patch_Pixel_Y :: distinct f64
Patch_Old_Count :: distinct i64
Patch_New_Count :: distinct i64
Patch_Display_Count :: distinct i64
Patch_Hunk_Count :: distinct i64

Patch_Measure :: struct {
	old_count: Patch_Old_Count,
	new_count: Patch_New_Count,
	rows: Patch_Display_Count,
	headers: Patch_Hunk_Count,
}
Patch_Target_Kind :: enum {Metadata, Header, Line, Binary}
Patch_Target :: struct {
	epoch: Patch_Request_ID,
	kind: Patch_Target_Kind,
	hunk: Patch_Hunk_Ordinal,
	line: Patch_Line_Index,
	byte: Patch_Byte_Offset,
	valid: bool,
}
Patch_Projection_Row :: struct {
	line: Patch_Display_Line,
	target: Patch_Target,
	folded: bool,
	hidden: Patch_Display_Count,
}
Patch_Source_Kind :: enum {Missing, Visible, Gap, Folded}
Patch_Source_Location :: struct {
	kind: Patch_Source_Kind,
	row: Patch_Display_Row,
	hunk: Patch_Hunk_Ordinal,
	line: Patch_Line_Index,
}
Patch_Span_Kind :: enum u32 {Metadata, Gap, Header, Lines, Binary}
Patch_Span :: struct {kind: Patch_Span_Kind, source, first, count: u32}
Patch_Hunk_Projection :: struct {first, end, first_body: int, collapsed: bool}
// The span topology is fixed for one parsed patch. Folding updates cached
// measures only; source edits or arbitrary splices require rebuilding and
// publishing a fresh projection rather than mutating this index in place.
Patch_Projection :: struct {
	// UI owner destroys this BEFORE its immutable parsed patch. Worker data
	// is adopted only after the request epoch has passed latest-wins checks.
	patch: ^File_Patch,
	epoch: Patch_Request_ID,
	spans: [dynamic]Patch_Span,
	hunks: []Patch_Hunk_Projection,
	directory: []Patch_Measure,
	base: int,
	revision: u64,
	allocator: mem.Allocator,
}
PATCH_BLOCK_CAPACITY :: 32
PATCH_COUNT_MAX :: i64(0x7fff_ffff_ffff_ffff)

@(private="file")
patch_append_span :: proc(p: ^Patch_Projection, span: Patch_Span) -> bool {
	written, err := append(&p.spans, span)
	return written == 1 && err == nil
}

patch_measure_combine :: proc(a, b: Patch_Measure) -> (Patch_Measure, bool) {
	if a.old_count < 0 || b.old_count < 0 || i64(a.old_count) > PATCH_COUNT_MAX-i64(b.old_count) ||
	   a.new_count < 0 || b.new_count < 0 || i64(a.new_count) > PATCH_COUNT_MAX-i64(b.new_count) ||
	   a.rows < 0 || b.rows < 0 || i64(a.rows) > PATCH_COUNT_MAX-i64(b.rows) ||
	   a.headers < 0 || b.headers < 0 || i64(a.headers) > PATCH_COUNT_MAX-i64(b.headers) { return {}, false }
	return {a.old_count+b.old_count, a.new_count+b.new_count, a.rows+b.rows, a.headers+b.headers}, true
}
@(private="file")
patch_origin :: proc(start, count: int) -> i64 { return i64(start)+1 if count == 0 else i64(start) }
@(private="file")
patch_gap :: proc(patch: ^File_Patch, hi: int) -> Patch_Measure {
	old_end, new_end: i64 = 1, 1
	if hi > 0 {
		h := patch.hunks[hi-1]
		old_end = patch_origin(h.old_start, h.old_count)+i64(h.old_count)
		new_end = patch_origin(h.new_start, h.new_count)+i64(h.new_count)
	}
	h := patch.hunks[hi]
	return {old_count=Patch_Old_Count(patch_origin(h.old_start, h.old_count)-old_end), new_count=Patch_New_Count(patch_origin(h.new_start, h.new_count)-new_end)}
}
@(private="file")
patch_span_measure :: proc(p: ^Patch_Projection, span: Patch_Span) -> Patch_Measure {
	switch span.kind {
	case .Metadata, .Binary: return {rows=1}
	case .Header: return {rows=1, headers=1}
	case .Gap: return patch_gap(p.patch, int(span.source))
	case .Lines:
		kind := p.patch.hunks[span.source].lines[span.first].kind
		rows := Patch_Display_Count(span.count)
		if p.hunks[span.source].collapsed { rows = 1 if span.first == 0 else 0 }
		return {
			old_count=Patch_Old_Count(span.count) if kind == .Context || kind == .Deletion else 0,
			new_count=Patch_New_Count(span.count) if kind == .Context || kind == .Addition else 0,
			rows=rows,
		}
	}
	return {}
}
patch_projection_destroy :: proc(p: ^Patch_Projection) {
	delete(p.spans); delete(p.hunks, p.allocator); delete(p.directory, p.allocator)
	p^ = {}
}
@(private="file")
patch_recompute_block :: proc(p: ^Patch_Projection, bi: int) -> bool {
	measure := Patch_Measure{}
	for span in p.spans[bi*PATCH_BLOCK_CAPACITY:min((bi+1)*PATCH_BLOCK_CAPACITY, len(p.spans))] {
		next, ok := patch_measure_combine(measure, patch_span_measure(p, span))
		if !ok { return false }
		measure = next
	}
	p.directory[p.base+bi] = measure
	return true
}
patch_projection_init :: proc(p: ^Patch_Projection, patch: ^File_Patch, epoch: Patch_Request_ID, allocator := context.allocator) -> bool {
	if p == nil || patch == nil || len(patch.hunks) > 0xffff_ffff || len(patch.metadata) > 0xffff_ffff { return false }
	trial := Patch_Projection{patch=patch, epoch=epoch, allocator=allocator}
	success := false
	defer { if !success { patch_projection_destroy(&trial) } }
	trial.spans = make([dynamic]Patch_Span, allocator=allocator)
	hunks, hunk_err := make([]Patch_Hunk_Projection, len(patch.hunks), allocator=allocator)
	if hunk_err != nil || len(hunks) != len(patch.hunks) { return false }
	trial.hunks = hunks
	for _, i in patch.metadata { if !patch_append_span(&trial, Patch_Span{kind=.Metadata, source=u32(i), count=1}) { return false } }
	for h, hi in patch.hunks {
		if h.old_start < 0 || h.new_start < 0 || h.old_count < 0 || h.new_count < 0 || len(h.lines) > 0xffff_ffff { return false }
		if i64(h.old_start) > PATCH_COUNT_MAX-max(i64(h.old_count), 1) || i64(h.new_start) > PATCH_COUNT_MAX-max(i64(h.new_count), 1) { return false }
		gap := patch_gap(patch, hi)
		if gap.old_count < 0 || gap.new_count < 0 { return false }
		if gap.old_count > 0 || gap.new_count > 0 { if !patch_append_span(&trial, Patch_Span{kind=.Gap, source=u32(hi), count=1}) { return false } }
		trial.hunks[hi].first = len(trial.spans)
		if !patch_append_span(&trial, Patch_Span{kind=.Header, source=u32(hi), count=1}) { return false }
		trial.hunks[hi].first_body = len(trial.spans)
		old, fresh := patch_origin(h.old_start, h.old_count), patch_origin(h.new_start, h.new_count)
		for line in h.lines {
			if line.kind == .Context || line.kind == .Deletion { if i64(line.old_line) != old { return false }; old += 1 }
			if line.kind == .Context || line.kind == .Addition { if i64(line.new_line) != fresh { return false }; fresh += 1 }
		}
		if old != patch_origin(h.old_start, h.old_count)+i64(h.old_count) || fresh != patch_origin(h.new_start, h.new_count)+i64(h.new_count) { return false }
		for first := 0; first < len(h.lines); {
			end := first+1
			for end < len(h.lines) && h.lines[end].kind == h.lines[first].kind { end += 1 }
			if !patch_append_span(&trial, Patch_Span{kind=.Lines, source=u32(hi), first=u32(first), count=u32(end-first)}) { return false }
			first = end
		}
		trial.hunks[hi].end = len(trial.spans)
	}
	if len(trial.spans) == 0 && patch.binary { if !patch_append_span(&trial, Patch_Span{kind=.Binary, count=1}) { return false } }
	trial.base = 1
	blocks := (len(trial.spans)+PATCH_BLOCK_CAPACITY-1)/PATCH_BLOCK_CAPACITY
	for trial.base < blocks { trial.base *= 2 }
	directory, directory_err := make([]Patch_Measure, trial.base*2, allocator=allocator)
	if directory_err != nil || len(directory) != trial.base*2 { return false }
	trial.directory = directory
	for bi in 0..<blocks { if !patch_recompute_block(&trial, bi) { return false } }
	for node := trial.base-1; node > 0; node -= 1 {
		measure, ok := patch_measure_combine(trial.directory[2*node], trial.directory[2*node+1])
		if !ok { return false }
		trial.directory[node] = measure
	}
	patch_projection_destroy(p)
	p^ = trial
	success = true
	return true
}
patch_projection_measure :: proc(p: ^Patch_Projection) -> Patch_Measure {
	if p == nil || len(p.directory) == 0 { return {} }
	return p.directory[1]
}
patch_projection_toggle_hunk :: proc(p: ^Patch_Projection, ordinal: Patch_Hunk_Ordinal) -> bool {
	hi := int(ordinal)
	if p == nil || hi < 0 || hi >= len(p.hunks) || len(p.patch.hunks[hi].lines) <= 1 { return false }
	h := &p.hunks[hi]
	h.collapsed = !h.collapsed
	first := h.first_body/PATCH_BLOCK_CAPACITY
	last := (h.end-1)/PATCH_BLOCK_CAPACITY
	for bi in first..=last { assert(patch_recompute_block(p, bi)) }
	// Recompute the union of affected ancestor paths, once per node/level.
	left, right := (p.base+first)/2, (p.base+last)/2
	for left > 0 {
		for node in left..=right {
			measure, ok := patch_measure_combine(p.directory[2*node], p.directory[2*node+1])
			assert(ok) // bounded by the validated all-expanded projection
			p.directory[node] = measure
		}
		left /= 2; right /= 2
	}
	p.revision += 1
	return true
}

@(private="file")
Patch_Axis :: enum {Old, New, Display, Hunk}
@(private="file")
Patch_Seek :: struct {span: int, within: i64, before: Patch_Measure, ok: bool}
@(private="file")
patch_extent :: proc(m: Patch_Measure, axis: Patch_Axis) -> i64 {
	switch axis { case .Old: return i64(m.old_count); case .New: return i64(m.new_count); case .Display: return i64(m.rows); case .Hunk: return i64(m.headers) }
	return 0
}
@(private="file")
patch_seek :: proc(p: ^Patch_Projection, axis: Patch_Axis, coordinate: i64) -> Patch_Seek {
	if p == nil || coordinate < 0 || coordinate >= patch_extent(patch_projection_measure(p), axis) { return {} }
	node := 1
	remaining := coordinate
	before := Patch_Measure{}
	for node < p.base {
		left := p.directory[2*node]
		if remaining < patch_extent(left, axis) { node *= 2 } else {
			remaining -= patch_extent(left, axis)
			before, _ = patch_measure_combine(before, left)
			node = node*2+1
		}
	}
	first := (node-p.base)*PATCH_BLOCK_CAPACITY
	for si in first..<min(first+PATCH_BLOCK_CAPACITY, len(p.spans)) {
		measure := patch_span_measure(p, p.spans[si])
		if remaining < patch_extent(measure, axis) { return {si, remaining, before, true} }
		remaining -= patch_extent(measure, axis)
		before, _ = patch_measure_combine(before, measure)
	}
	return {}
}
patch_projection_seek_hunk :: proc(p: ^Patch_Projection, ordinal: Patch_Hunk_Ordinal) -> (Patch_Display_Row, bool) {
	seek := patch_seek(p, .Hunk, i64(ordinal))
	return Patch_Display_Row(seek.before.rows), seek.ok
}
@(private="file")
patch_source :: proc(p: ^Patch_Projection, axis: Patch_Axis, coordinate: i64) -> Patch_Source_Location {
	if coordinate < 1 { return {} }
	seek := patch_seek(p, axis, coordinate-1)
	if !seek.ok { return {} }
	span := p.spans[seek.span]
	if span.kind == .Gap { return {kind=.Gap} }
	if span.kind != .Lines { return {} }
	if p.hunks[span.source].collapsed {
		row, ok := patch_projection_seek_hunk(p, Patch_Hunk_Ordinal(span.source))
		if !ok { return {} }
		return {kind=.Folded, row=row+1, hunk=Patch_Hunk_Ordinal(span.source)}
	}
	return {kind=.Visible, row=Patch_Display_Row(seek.before.rows)+Patch_Display_Row(seek.within), hunk=Patch_Hunk_Ordinal(span.source), line=Patch_Line_Index(span.first)+Patch_Line_Index(seek.within)}
}
patch_projection_seek_old :: proc(p: ^Patch_Projection, line: Patch_Old_Line) -> Patch_Source_Location { return patch_source(p, .Old, i64(line)) }
patch_projection_seek_new :: proc(p: ^Patch_Projection, line: Patch_New_Line) -> Patch_Source_Location { return patch_source(p, .New, i64(line)) }
@(private="file")
patch_materialize :: proc(p: ^Patch_Projection, span: Patch_Span, within: int) -> Patch_Projection_Row {
	target := Patch_Target{epoch=p.epoch, valid=true}
	switch span.kind {
	case .Metadata:
		target.kind = .Metadata; target.line = Patch_Line_Index(span.source)
		return {line={kind=.Meta, text=p.patch.metadata[span.source]}, target=target}
	case .Binary: target.kind = .Binary; return {line={kind=.Meta, text="Binary file changed"}, target=target}
	case .Header:
		target.kind = .Header; target.hunk = Patch_Hunk_Ordinal(span.source)
		return {line={kind=.Meta, text=p.patch.hunks[span.source].header, hunk=true, hunk_index=int(span.source)}, target=target}
	case .Lines:
		target.kind = .Line; target.hunk = Patch_Hunk_Ordinal(span.source); target.line = Patch_Line_Index(span.first)+Patch_Line_Index(within)
		if p.hunks[span.source].collapsed { return {line={kind=.Meta, hunk_index=int(span.source)}, target=target, folded=true, hidden=Patch_Display_Count(len(p.patch.hunks[span.source].lines))} }
		line := p.patch.hunks[span.source].lines[int(target.line)]
		return {line={kind=line.kind, text=line.text, old_line=line.old_line, new_line=line.new_line, hunk_index=int(span.source)}, target=target}
	case .Gap: return {}
	}
	return {}
}
patch_projection_viewport :: proc(p: ^Patch_Projection, first: Patch_Display_Row, output: []Patch_Projection_Row) -> int {
	seek := patch_seek(p, .Display, i64(first))
	if !seek.ok { return 0 }
	within := int(seek.within)
	written := 0
	for si in seek.span..<len(p.spans) {
		span := p.spans[si]
		rows := int(patch_span_measure(p, span).rows)
		for within < rows && written < len(output) { output[written] = patch_materialize(p, span, within); written += 1; within += 1 }
		if written == len(output) { break }
		within = 0
	}
	return written
}
patch_projection_resolve :: proc(p: ^Patch_Projection, target: Patch_Target) -> (Patch_Display_Row, bool) {
	if p == nil || !target.valid || target.epoch != p.epoch { return 0, false }
	if target.kind == .Metadata { return Patch_Display_Row(target.line), int(target.line) >= 0 && int(target.line) < len(p.patch.metadata) }
	if target.kind == .Binary { return 0, p.patch.binary }
	hi := int(target.hunk)
	if hi < 0 || hi >= len(p.hunks) { return 0, false }
	row, ok := patch_projection_seek_hunk(p, target.hunk)
	if !ok || target.kind == .Header { return row, ok }
	li := int(target.line)
	if li < 0 || li >= len(p.patch.hunks[hi].lines) { return 0, false }
	if p.hunks[hi].collapsed { return row+1, true }
	// Whole-hunk folding preserves all row order inside an expanded body.
	return row+1+Patch_Display_Row(li), true
}
