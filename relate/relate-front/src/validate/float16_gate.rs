//! The ADR-0371 `float16-coordinate-types` gate's detector (ADR-0464): does
//! a statement use a FLOAT16/BFLOAT16 vector coordinate type. A pure
//! detector — the floor form of the statement is unchanged, so the front's
//! detector loop fails it closed when the opt-in is off.

use relate_error::EngineError;
use relate_parser::{Clause, Expr, Statement};

use super::{statement_any_clause, statement_any_expr};

/// Whether the statement's AST uses one of the FLOAT16/BFLOAT16 vector
/// coordinate types (the ADR-0371 `float16-coordinate-types` gate of
/// ADR-0464, mirroring Neo4j's own toggle). Two
/// syntactic homes, both read here:
///
/// - a `VECTOR<…>` type expression — a type predicate (`x IS :: VECTOR<FLOAT16>(3)`),
///   a property-type constraint, or a graph-type element property type;
/// - the `vector(<list>, <dim>, <type>)` constructor, whose third argument
///   `parse_vector_call` normalizes into a coordinate-type name string.
///
/// The `VectorCoordKind` vocabulary is not re-spelled here: both arms test
/// against the model's one coordinate-type table.
pub(crate) fn statement_uses_float16_coordinate_types(
    stmt: &Statement,
) -> Result<bool, EngineError> {
    // The two syntactic homes are separate existence walks over the one
    // scaffold; either hit arms the gate.
    if statement_any_clause(stmt, clause_uses_float16_property_type)? {
        return Ok(true);
    }
    statement_any_expr(stmt, |expr| match expr {
        Expr::IsType(is_type) => type_uses_float16(&is_type.type_expr),
        Expr::FunctionCall(call) => is_float16_vector_constructor(call),
        _ => false,
    })
}

/// Whether a type expression names FLOAT16/BFLOAT16 as a vector coordinate
/// type, at any nesting depth (`VECTOR<LIST<FLOAT16>>` included).
fn type_uses_float16(type_expr: &relate_parser::TypeExpr) -> bool {
    use relate_parser::TypeExpr;
    match type_expr {
        TypeExpr::Vector { coord, .. } => coord.is_some_and(is_float16_family),
        TypeExpr::List { element, .. } => type_uses_float16(element),
        TypeExpr::Union(members) => members.iter().any(type_uses_float16),
        TypeExpr::Predefined { .. } | TypeExpr::PropertyValue { .. } => false,
    }
}

/// Whether the call is `vector(<list>, <dim>, FLOAT16|BFLOAT16)` — the
/// parser stores the coordinate-type keyword as its own argument, a
/// coordinate-name string resolved through the model's table.
fn is_float16_vector_constructor(call: &relate_parser::FunctionCallExpr) -> bool {
    if !call.name.with_str(|n| n.eq_ignore_ascii_case("vector")) || call.args.len() != 3 {
        return false;
    }
    matches!(
        &call.args[2],
        Expr::Literal(relate_parser::LiteralValue::String(name))
            if relate_parser::VectorCoordKind::from_alias(name).is_some_and(is_float16_family)
    )
}

/// The FLOAT16/BFLOAT16 coordinate-kind class the `float16-coordinate-types`
/// gate detects — the one spelling both syntactic homes consult.
fn is_float16_family(kind: relate_parser::VectorCoordKind) -> bool {
    matches!(
        kind,
        relate_parser::VectorCoordKind::Float16 | relate_parser::VectorCoordKind::BFloat16
    )
}

/// Whether a clause's own `<value type>` declarations name FLOAT16/BFLOAT16:
/// a CIP-85 property-type constraint, or a graph type's element property
/// types.
fn clause_uses_float16_property_type(clause: &Clause) -> bool {
    match clause {
        Clause::CreateConstraint(constraint) => constraint
            .property_type
            .as_ref()
            .is_some_and(type_uses_float16),
        other => super::graph_type_gate::clause_graph_type_body(other)
            .is_some_and(graph_type_body_uses_float16),
    }
}

/// Whether any element property type of a graph type body names
/// FLOAT16/BFLOAT16.
fn graph_type_body_uses_float16(body: &relate_parser::GraphTypeBody) -> bool {
    body.node_types
        .iter()
        .flat_map(|node| node.properties.iter())
        .chain(
            body.edge_types
                .iter()
                .flat_map(|edge| edge.properties.iter()),
        )
        .any(|property| type_uses_float16(&property.value_type))
}
