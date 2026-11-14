//! The projection's post-merge pipeline: the landing container every
//! merge path hands its built rows to, the DISTINCT first-seen pass, and
//! the finish tail that pages the merged table — split from `project.rs`
//! (the same move that produced `order.rs`): the classification and the
//! merge paths stay there, the container and the tail live here.

use std::collections::BTreeMap;

use relate_core::{Result, Value};
use relate_ir::Expr;

use crate::distinct_set::DistinctSet;
use crate::eval::{filter_rows_where, where_holds};
use crate::overlay::{ExecGraph, RetainedTotal};
use crate::row::{Row, RowNames};

use super::aggregate::WhereMode;
use super::order::{page, sort_rows_by_parked_keys, unpark_order_keys, TopKWindow};
use super::project::ProjectionClass;
use super::scope::{result_column, visible_keys, ProjectionFields};

/// The named columns of `row`, cloned in order — the row a multi-column
/// DISTINCT keys.
fn row_columns(row: &Row, names: &[String]) -> Vec<Value> {
    names
        .iter()
        .map(|n| result_column(row, n).clone())
        .collect()
}

/// The columns a non-`*` DISTINCT keys, borrowed when the projection is
/// one column wide (a one-element slice: no column clone, no row vector).
/// The arity-1 *keying* lives in [`DistinctSet::insert_row`] alone; this
/// is only the borrow.
fn distinct_columns<'r>(row: &'r Row, names: &[String]) -> std::borrow::Cow<'r, [Value]> {
    match names {
        [name] => std::borrow::Cow::Borrowed(std::slice::from_ref(result_column(row, name))),
        names => std::borrow::Cow::Owned(row_columns(row, names)),
    }
}

/// What a merged row's DISTINCT key is: a `*` row keys its visible keys, a
/// named projection its output columns — decided once, not re-checked per
/// row.
enum DistinctKeys<'a> {
    Visible,
    Columns(&'a [String]),
}

impl DistinctKeys<'_> {
    /// One row's key, borrowed when the projection is one column wide.
    fn key<'r>(&self, row: &'r Row) -> std::borrow::Cow<'r, [Value]> {
        match self {
            DistinctKeys::Visible => std::borrow::Cow::Owned(row_columns(row, &visible_keys(row))),
            DistinctKeys::Columns(names) => distinct_columns(row, names),
        }
    }
}

/// The post-merge DISTINCT stage: first-seen keep over the merged rows,
/// keyed by the output columns (a `*` row keys its visible keys). The
/// returned charge holds the kept row buffer; the caller resizes it as
/// the paging stage ([`page`]) and the result materialization shrink the
/// buffer. The set owns its workspace charge and drops (releasing it) at
/// the end of the pass.
fn retain_distinct(
    merged: Vec<Row>,
    keys: DistinctKeys<'_>,
) -> Result<(Vec<Row>, relate_core::tokens::WorkspaceCharge)> {
    let retained_rows = relate_core::tokens::WorkspaceCharge::retain_with(|| {
        crate::workspace::row_buffer_bytes(&merged)
    })?;
    let mut seen = DistinctSet::default();
    let mut kept = Vec::new();
    for row in merged {
        if seen.insert_row(&keys.key(&row))? {
            kept.push(row);
        }
    }
    drop(seen);
    Ok((kept, retained_rows))
}

/// The projection's output container — the one landing policy every merge
/// path reads, as one of the two containers the clause can have. They are
/// disjoint states, so they are variants rather than nullable fields: the
/// window shape carries a heap and no `Vec`, the collected shape a `Vec`
/// and no heap, and neither constructs the other's state.
pub(crate) enum Landing<'k, 'a> {
    /// ADR-0463's retaining `Vec`: each landed row grows a running charge
    /// and the buffer holds the projection's whole output.
    Collected {
        retained: RetainedTotal,
        out: Vec<Row>,
    },
    /// ADR-0555 §3's bounded top-k window: at most `skip + limit` entries,
    /// charged as entries enter and leave. The plain WHERE filters each row
    /// *here*, as it arrives, because the selection must see the filtered
    /// stream — the collected shape filters after the merge, in
    /// [`finish_projection`].
    Window {
        window: TopKWindow<'k>,
        graph: &'a ExecGraph<'a>,
        params: &'a BTreeMap<String, Value>,
        predicate: Option<&'a Expr>,
    },
}

impl<'k, 'a> Landing<'k, 'a> {
    /// The container for `keep`: the bounded window when the ordered shape
    /// holds, the retaining `Vec` otherwise. The parked-key plan and the
    /// plain WHERE are the classification's own — read from it, never
    /// handed back as loose parameters.
    pub(crate) fn open(
        graph: &'a ExecGraph<'a>,
        params: &'a BTreeMap<String, Value>,
        class: &'k ProjectionClass<'a>,
        keep: Option<usize>,
    ) -> Result<Self> {
        Ok(match keep {
            Some(keep) => Landing::Window {
                window: TopKWindow::new(&class.order_keys, keep),
                graph,
                params,
                predicate: class.where_mode.and_then(WhereMode::plain),
            },
            None => Landing::Collected {
                retained: graph.retain_bytes(0)?,
                out: Vec::new(),
            },
        })
    }

    /// One built output row lands in its container.
    pub(crate) fn land(&mut self, graph: &ExecGraph<'_>, row: Row) -> Result<()> {
        match self {
            Landing::Window {
                window,
                graph,
                params,
                predicate,
            } => {
                if let Some(predicate) = predicate {
                    if !where_holds(graph, params, &row, predicate)? {
                        return Ok(());
                    }
                }
                window.push(row)
            }
            Landing::Collected { retained, out } => {
                retained.add_row(graph, row.values())?;
                out.push(row);
                Ok(())
            }
        }
    }

    /// The container's rows: the window's best-first `skip + limit`, or the
    /// `Vec`'s whole output. Neither arm can fail — the window's charge is
    /// released with it, the `Vec` moves out.
    pub(crate) fn finish(self) -> Vec<Row> {
        match self {
            Landing::Window { window, .. } => window.finish(),
            Landing::Collected { out, .. } => out,
        }
    }
}

/// The projection's finish tail, shared by every merge path — the
/// pipeline's last stage: the plain WHERE filter over the merged rows (the
/// collected shape only; the window shape filtered as each row landed),
/// then the paging stages (the parked-key sort with its top-k selection
/// for the shapes that merge unordered rows, the DISTINCT first-seen pass
/// with its row-buffer charge re-measured at each shrink, the page
/// itself), then the result extraction. The eager stop already paged on
/// its own resolved bounds ([`materialize_feed`]), so the tail pages only
/// on the non-eager path.
pub(crate) fn finish_projection(
    graph: &ExecGraph<'_>,
    params: &BTreeMap<String, Value>,
    class: &ProjectionClass<'_>,
    merged: Vec<Row>,
    bounds: (usize, Option<usize>),
    windowed: bool,
) -> Result<Vec<Row>> {
    let ProjectionFields { distinct, .. } = class.fields;
    // The ordered-window shape filtered each row as it landed, before the
    // selection; filtering again here would evaluate the predicate twice
    // per surviving row (a nondeterministic predicate would flake).
    let mut merged = if windowed {
        merged
    } else if let Some(w) = class.where_mode.and_then(WhereMode::plain) {
        filter_rows_where(graph, params, w, merged)?
    } else {
        merged
    };
    let (skip_n, limit_n) = bounds;
    // The window shape's rows arrive already ordered and bounded by the
    // heap, so only the shapes that merge unordered rows sort here — on the
    // one cutoff the window decision reads too ([`ProjectionClass::sort_cut`]).
    if !windowed && !class.order_keys.is_empty() {
        sort_rows_by_parked_keys(&class.order_keys, &mut merged, class.sort_cut(bounds))?;
    }
    // The DISTINCT pass's row-buffer charge: Option-held from
    // [`retain_distinct`] — it exists only on the distinct shape, and
    // every later re-measure (the page, the output conversion) walks the
    // held charge instead of re-checking the mode beside an empty
    // sentinel.
    let mut retained_rows = if distinct {
        let keys = if class.shape.star() {
            DistinctKeys::Visible
        } else {
            DistinctKeys::Columns(&class.out_names)
        };
        let (kept, charge) = retain_distinct(merged, keys)?;
        merged = kept;
        Some(charge)
    } else {
        None
    };
    if let Some(charge) = retained_rows.as_mut() {
        charge.resize_with(|| crate::workspace::row_buffer_bytes(&merged))?;
    }
    merged = page(merged, skip_n, limit_n);
    if let Some(charge) = retained_rows.as_mut() {
        charge.resize_with(|| crate::workspace::row_buffer_bytes(&merged))?;
    }
    if class.shape.star() {
        // The parked keys were sort surface only; a `*` row keeps exactly
        // the incoming bindings and the explicit items.
        unpark_order_keys(&class.order_keys, &mut merged);
        drop(retained_rows);
        return Ok(merged);
    }
    let names = RowNames::new(&class.out_names);
    let mut out = Vec::with_capacity(merged.len());
    for mut row in merged {
        let values = class
            .out_names
            .iter()
            .map(|name| {
                row.take_value(name)
                    .expect("projection rows carry every result column")
            })
            .collect();
        out.push(Row::from_names(&names, values));
    }
    if let Some(charge) = retained_rows.as_mut() {
        charge.resize_with(|| crate::workspace::row_buffer_bytes(&out))?;
    }
    drop(retained_rows);
    Ok(out)
}
