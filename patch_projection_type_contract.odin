package main

// Compile-only negative contracts, enabled solely by check_folding_types.ps1.
when #config(HISTORY_COORDINATE_ERROR, 0) == 1 {
	wrong_coordinate :: proc(p: ^Patch_Projection) { _ = patch_projection_seek_old(p, Patch_New_Line(1)) }
}
when #config(HISTORY_COORDINATE_ERROR, 0) == 2 {
	wrong_coordinate :: proc(p: ^Patch_Projection) { _ = patch_projection_viewport(p, Patch_Pixel_Y(22), nil) }
}
when #config(HISTORY_COORDINATE_ERROR, 0) == 3 {
	wrong_coordinate :: proc(p: ^Patch_Projection) { _ = patch_projection_seek_old(p, Patch_Old_Count(1)) }
}
when #config(HISTORY_COORDINATE_ERROR, 0) == 4 {
	wrong_coordinate :: proc(p: ^Patch_Projection) { _, _ = patch_projection_seek_hunk(p, Patch_Line_Index(1)) }
}
