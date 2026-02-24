use janetrs::{
    client::JanetClient, env::CFunOptions, Janet, JanetArray, JanetKeyword, JanetString,
    JanetStruct, JanetTable,
};

fn struct_get_i32(st: &JanetStruct, key: &JanetKeyword) -> i32 {
    st.get(key)
        .and_then(|v| v.try_unwrap::<f64>().ok())
        .map(|f| f as i32)
        .unwrap_or(0)
}

/// Get the :_sgr Janet value from a cell's :style struct.
fn cell_sgr_janet(cell: &JanetTable, kw_style: &JanetKeyword, kw_sgr: &JanetKeyword) -> Janet {
    cell.get(kw_style)
        .and_then(|v| v.try_unwrap::<JanetStruct>().ok())
        .and_then(|st| st.get(kw_sgr).copied())
        .unwrap_or(Janet::nil())
}

/// Write a Janet string value to the output buffer.
fn emit_janet_str(out: &mut String, val: &Janet) {
    if let Ok(s) = val.try_unwrap::<JanetString>() {
        if let Ok(text) = std::str::from_utf8(s.as_bytes()) {
            out.push_str(text);
        }
    }
}

/// (buffer/diff old-buf new-buf rect)
/// Fast cell-by-cell diff between two buffers within a rect.
/// Compares :ch and :_sgr (from style interning) for each cell.
/// Updates old-buf cells in-place and returns an ANSI string of changes.
#[janetrs::janet_fn(arity(fix(3)))]
fn diff(args: &mut [Janet]) -> Janet {
    let old_buf: JanetTable = args[0]
        .try_unwrap()
        .expect("buffer/diff: old-buf must be a table");
    let new_buf: JanetTable = args[1]
        .try_unwrap()
        .expect("buffer/diff: new-buf must be a table");
    let r: JanetStruct = args[2]
        .try_unwrap()
        .expect("buffer/diff: rect must be a struct");

    let kw_x = JanetKeyword::new(b"x");
    let kw_y = JanetKeyword::new(b"y");
    let kw_width = JanetKeyword::new(b"width");
    let kw_height = JanetKeyword::new(b"height");
    let kw_area = JanetKeyword::new(b"area");
    let kw_cells = JanetKeyword::new(b"cells");
    let kw_ch = JanetKeyword::new(b"ch");
    let kw_style = JanetKeyword::new(b"style");
    let kw_sgr = JanetKeyword::new(b"_sgr");

    let rx = struct_get_i32(&r, &kw_x);
    let ry = struct_get_i32(&r, &kw_y);
    let rw = struct_get_i32(&r, &kw_width);
    let rh = struct_get_i32(&r, &kw_height);

    if rw <= 0 || rh <= 0 {
        return Janet::from(JanetString::new(b""));
    }

    let old_area: JanetStruct = old_buf
        .get(&kw_area)
        .and_then(|v| v.try_unwrap().ok())
        .expect("buffer/diff: old-buf must have :area");
    let old_ax = struct_get_i32(&old_area, &kw_x);
    let old_ay = struct_get_i32(&old_area, &kw_y);
    let old_aw = struct_get_i32(&old_area, &kw_width);

    let old_cells: JanetArray = old_buf
        .get(&kw_cells)
        .and_then(|v| v.try_unwrap().ok())
        .expect("buffer/diff: old-buf must have :cells");

    let new_area: JanetStruct = new_buf
        .get(&kw_area)
        .and_then(|v| v.try_unwrap().ok())
        .expect("buffer/diff: new-buf must have :area");
    let new_ax = struct_get_i32(&new_area, &kw_x);
    let new_ay = struct_get_i32(&new_area, &kw_y);
    let new_aw = struct_get_i32(&new_area, &kw_width);

    let new_cells: JanetArray = new_buf
        .get(&kw_cells)
        .and_then(|v| v.try_unwrap().ok())
        .expect("buffer/diff: new-buf must have :cells");

    let kw_dirty = JanetKeyword::new(b"dirty-rows");
    let dirty_rows: Option<JanetArray> = new_buf
        .get(&kw_dirty)
        .and_then(|v| v.try_unwrap().ok());

    let mut out = String::with_capacity((rw * rh * 4) as usize);
    // Track current SGR as a raw Janet value for fast comparison
    let mut cur_sgr_janet = Janet::nil();
    let mut cur_sgr_initialized = false;

    for row in 0..rh {
        let y = ry + row;

        if let Some(ref dr) = dirty_rows {
            let row_in_buf = y - new_ay;
            if row_in_buf >= 0 && (row_in_buf as usize) < dr.len() {
                let dirty_val = dr[row_in_buf as usize];
                if dirty_val.is_nil() || dirty_val.try_unwrap::<bool>().ok() == Some(false) {
                    continue;
                }
            }
        }

        let mut expected_col: Option<i32> = None;

        for col in 0..rw {
            let x = rx + col;

            let old_idx = ((y - old_ay) * old_aw + (x - old_ax)) as usize;
            let new_idx = ((y - new_ay) * new_aw + (x - new_ax)) as usize;

            if old_idx >= old_cells.len() || new_idx >= new_cells.len() {
                continue;
            }

            let old_cell: JanetTable = match old_cells[old_idx].try_unwrap() {
                Ok(t) => t,
                Err(_) => continue,
            };
            let new_cell: JanetTable = match new_cells[new_idx].try_unwrap() {
                Ok(t) => t,
                Err(_) => continue,
            };

            // Compare :ch Janet values directly (no allocation)
            let nil = Janet::nil();
            let old_ch = old_cell.get(&kw_ch).unwrap_or(&nil);
            let new_ch = new_cell.get(&kw_ch).unwrap_or(&nil);

            // Compare :_sgr Janet values from :style structs
            let old_sgr = cell_sgr_janet(&old_cell, &kw_style, &kw_sgr);
            let new_sgr = cell_sgr_janet(&new_cell, &kw_style, &kw_sgr);

            if old_ch == new_ch && old_sgr == new_sgr {
                continue;
            }

            // Cell changed — emit cursor move if needed
            if expected_col != Some(col) {
                use std::fmt::Write;
                write!(out, "\x1b[{};{}H", y + 1, x + 1).unwrap();
            }

            // Emit style change (only convert to string when actually changing)
            if !cur_sgr_initialized || new_sgr != cur_sgr_janet {
                out.push_str("\x1b[0m");
                emit_janet_str(&mut out, &new_sgr);
                cur_sgr_janet = new_sgr;
                cur_sgr_initialized = true;
            }

            // Emit character
            emit_janet_str(&mut out, new_ch);

            expected_col = Some(col + 1);

            // Update old-buf in place
            let new_ch_val = *new_cell.get(&kw_ch).unwrap_or(&nil);
            let new_style_val = *new_cell.get(&kw_style).unwrap_or(&nil);
            let mut old_cell_mut: JanetTable = old_cell;
            old_cell_mut.insert(JanetKeyword::new(b"ch"), new_ch_val);
            old_cell_mut.insert(JanetKeyword::new(b"style"), new_style_val);
        }
    }

    if !out.is_empty() {
        out.push_str("\x1b[0m");
    }

    if dirty_rows.is_some() {
        if let Some(mut dr_mut) = new_buf
            .get(&kw_dirty)
            .and_then(|v| v.try_unwrap::<JanetArray>().ok())
        {
            for i in 0..dr_mut.len() {
                let y_i = new_ay + i as i32;
                if y_i >= ry && y_i < ry + rh {
                    dr_mut[i] = Janet::boolean(false);
                }
            }
        }
    }

    Janet::from(JanetString::new(out.as_bytes()))
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"diff", diff_c).namespace(c"buffer"));
}
