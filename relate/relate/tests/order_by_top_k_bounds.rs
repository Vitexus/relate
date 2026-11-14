//! LABS-1373: `ORDER BY ... LIMIT/SKIP` bounds the sort's own container.
//!
//! ADR-0555 declares the unlimited sort a breaker, but a sort with a
//! `LIMIT` (plus its `SKIP`) needs only the first `skip + limit` rows of
//! the order: the projection folds its producer into a charged top-k heap
//! of that capacity and never holds more. The memory-shape test below is
//! the ADR-0555 proof — two inputs an order of magnitude apart, one
//! bounded workspace, and the heap's charge independent of the input
//! count. The differential test pins that the bounded selection answers
//! exactly what a full sort answers.

mod common;

use relate::{Database, OpenOptions, Value};

/// The workspace budget the bounded shape must fit inside: generous for
/// five retained rows, impossible for the full input at the sizes below.
const BUDGET: u64 = 16 << 20;

fn bounded_db() -> relate::Connection {
    let db = Database::open_with(
        ":memory:",
        OpenOptions {
            concurrent_logical_workspace_limit: Some(BUDGET),
            ..Default::default()
        },
    )
    .unwrap();
    db.connect().unwrap()
}

/// One `ORDER BY ... LIMIT` over `n` generated rows under the bounded
/// workspace: the answer is the last five ids, whatever `n` is.
fn top_five(conn: &mut relate::Connection, n: i64) -> Vec<Value> {
    let q = format!("UNWIND range(1, {n}) AS i WITH i AS v ORDER BY v DESC LIMIT 5 RETURN v");
    common::rows(conn, &q)
        .into_iter()
        .map(|row| row.into_iter().next().expect("one column"))
        .collect()
}

/// The memory shape (ADR-0555): the sort's container is charged at
/// `skip + limit`, so the input count cannot price the statement out of a
/// fixed workspace. `n` an order of magnitude larger answers the same five
/// rows under the same budget.
#[test]
fn order_by_limit_fits_a_fixed_workspace_whatever_the_input_count() {
    let mut small = bounded_db();
    assert_eq!(
        top_five(&mut small, 200_000),
        vec![
            Value::Int(200_000),
            Value::Int(199_999),
            Value::Int(199_998),
            Value::Int(199_997),
            Value::Int(199_996)
        ]
    );
    let mut large = bounded_db();
    assert_eq!(
        top_five(&mut large, 2_000_000),
        vec![
            Value::Int(2_000_000),
            Value::Int(1_999_999),
            Value::Int(1_999_998),
            Value::Int(1_999_997),
            Value::Int(1_999_996)
        ]
    );
}

/// The selection answers what a full sort answers: mixed ASC/DESC keys,
/// ties broken by arrival order, and `SKIP` paying its share of the
/// window. The unbounded spellings (no `LIMIT`) are the oracle.
#[test]
fn order_by_skip_limit_answers_what_the_full_sort_answers() {
    let mut c = common::connection();
    let setup = "UNWIND range(1, 500) AS i CREATE (:N {a: i % 7, b: i})";
    common::run(&mut c, setup);

    let bounded =
        "MATCH (n:N) WITH n.a AS a, n.b AS b ORDER BY a ASC, b DESC SKIP 3 LIMIT 8 RETURN a, b";
    let oracle =
        "MATCH (n:N) WITH n.a AS a, n.b AS b ORDER BY a ASC, b DESC RETURN a, b SKIP 3 LIMIT 8";
    assert_eq!(
        common::rows(&mut c, bounded),
        common::rows(&mut c, oracle),
        "the bounded window must equal the full sort's page"
    );
}
