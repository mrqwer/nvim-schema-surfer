use chrono::NaiveDateTime;
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Column, Row};
use std::collections::HashMap;
use std::env;
use std::error::Error;

#[derive(Serialize)]
struct ColumnDef {
    name: String,
    data_type: String,
    is_pk: bool,
    is_fk: bool,
}
#[derive(Serialize)]
struct Relation {
    relation_type: String,
    target_table: String,
    source_col: String,
    target_col: String,
}
#[derive(Serialize)]
struct TableData {
    columns: Vec<ColumnDef>,
    relations: Vec<Relation>,
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        let err_json = json!({ "error": e.to_string() });
        println!("{}", err_json.to_string());
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        return Err("Usage: engine <mode> <conn> [args...]".into());
    }

    let mode = &args[1];
    let conn_str = args.get(2).ok_or("Missing connection string")?;

    if mode == "exec" {
        let query = args.get(3).ok_or("Missing SQL query")?;
        let pool = PgPoolOptions::new().connect(conn_str).await?;
        let rows = sqlx::query(query).fetch_all(&pool).await?;

        let mut results: Vec<HashMap<String, Value>> = Vec::new();
        for row in rows {
            let mut map = HashMap::new();
            for col in row.columns() {
                map.insert(col.name().to_string(), get_json_value(&row, col.name()));
            }
            results.push(map);
        }
        println!("{}", serde_json::to_string_pretty(&results)?);
        return Ok(());
    }

    if mode == "preview" {
        let table = args.get(3).ok_or("Missing table name")?;
        if !table.chars().all(|c| c.is_alphanumeric() || c == '_') {
            return Err("Invalid table name".into());
        }

        let pool = PgPoolOptions::new().connect(conn_str).await?;
        let query = format!("SELECT * FROM \"{}\" LIMIT 5", table);
        let rows = sqlx::query(&query).fetch_all(&pool).await?;

        let mut results: Vec<HashMap<String, Value>> = Vec::new();
        for row in rows {
            let mut map = HashMap::new();
            for col in row.columns() {
                map.insert(col.name().to_string(), get_json_value(&row, col.name()));
            }
            results.push(map);
        }
        println!("{}", serde_json::to_string_pretty(&results)?);
        return Ok(());
    }

    let pool = PgPoolOptions::new().connect(conn_str).await?;
    let rows = sqlx::query(r#"
        SELECT table_name, column_name, udt_name as data_type,
        EXISTS(SELECT 1 FROM information_schema.key_column_usage kcu
            LEFT JOIN information_schema.table_constraints tc ON kcu.constraint_name = tc.constraint_name
            WHERE kcu.table_name = c.table_name AND kcu.column_name = c.column_name AND tc.constraint_type = 'PRIMARY KEY'
        ) as is_pk
        FROM information_schema.columns c WHERE table_schema = 'public' ORDER BY table_name, ordinal_position
    "#).fetch_all(&pool).await?;

    let mut schema: HashMap<String, TableData> = HashMap::new();
    for row in rows {
        let t: String = row.get("table_name");
        schema
            .entry(t.clone())
            .or_insert(TableData {
                columns: vec![],
                relations: vec![],
            })
            .columns
            .push(ColumnDef {
                name: row.get("column_name"),
                data_type: row.get("data_type"),
                is_pk: row.get("is_pk"),
                is_fk: false,
            });
    }

    let fk_rows = sqlx::query(r#"
        SELECT tc.table_name, kcu.column_name, ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name 
        FROM information_schema.table_constraints AS tc 
        JOIN information_schema.key_column_usage AS kcu ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage AS ccu ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public';
    "#).fetch_all(&pool).await?;

    for row in fk_rows {
        let table: String = row.get("table_name");
        let col: String = row.get("column_name");
        let target: String = row.get("foreign_table_name");
        let target_col: String = row.get("foreign_column_name");

        if let Some(data) = schema.get_mut(&table) {
            data.relations.push(Relation {
                relation_type: "Belongs To".to_string(),
                target_table: target.clone(),
                source_col: col.clone(),
                target_col: target_col.clone(),
            });
            for c in &mut data.columns {
                if c.name == col {
                    c.is_fk = true;
                }
            }
        }
        if let Some(data) = schema.get_mut(&target) {
            data.relations.push(Relation {
                relation_type: "Has Many".to_string(),
                target_table: table,
                source_col: target_col,
                target_col: col,
            });
        }
    }

    println!("{}", serde_json::to_string_pretty(&schema)?);
    Ok(())
}

fn get_json_value(row: &sqlx::postgres::PgRow, col_name: &str) -> Value {
    if let Ok(v) = row.try_get::<String, _>(col_name) {
        return json!(v);
    }
    if let Ok(v) = row.try_get::<i32, _>(col_name) {
        return json!(v);
    }
    if let Ok(v) = row.try_get::<i64, _>(col_name) {
        return json!(v);
    }
    if let Ok(v) = row.try_get::<bool, _>(col_name) {
        return json!(v);
    }
    if let Ok(v) = row.try_get::<NaiveDateTime, _>(col_name) {
        return json!(v.to_string());
    }
    json!(null)
}
