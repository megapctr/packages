import birl/time.{DateTime}
import gleam/dynamic.{DecodeError, Dynamic} as dyn
import gleam/dynamic_extra as dyn_extra
import gleam/hexpm
import gleam/json
import gleam/list
import gleam/map.{Map}
import gleam/option.{None, Option, Some}
import gleam/pgo
import gleam/result.{try}
import packages/error.{Error}
import packages/generated/sql
import gleam/erlang/os

pub fn connect() -> pgo.Connection {
  let config = pgo.Config(..database_config_from_env(), pool_size: 10)
  let db = pgo.connect(config)
  let assert Ok(_) = sql.migrate_schema(db, [], Ok)
  db
}

pub fn database_config_from_env() -> pgo.Config {
  os.get_env("DATABASE_URL")
  |> result.then(pgo.url_config)
  // In production we use IPv6
  |> result.map(fn(config) { pgo.Config(..config, ip_version: pgo.Ipv6) })
  |> result.lazy_unwrap(fn() {
    let database_name =
      os.get_env("PGDATABASE")
      |> result.unwrap("gleam_packages")
    let user =
      os.get_env("PGUSER")
      |> result.unwrap("postgres")
    let password =
      os.get_env("PGPASSWORD")
      |> option.from_result

    pgo.Config(
      ..pgo.default_config(),
      host: "localhost",
      database: database_name,
      user: user,
      password: password,
    )
  })
}

/// Insert or replace the most recent Hex timestamp in the database.
pub fn upsert_most_recent_hex_timestamp(
  db: pgo.Connection,
  time: DateTime,
) -> Result(Nil, Error) {
  let unix = time.to_unix(time)
  sql.upsert_most_recent_hex_timestamp(db, [pgo.int(unix)], Ok)
  |> result.replace(Nil)
}

/// Get the most recent Hex timestamp from the database, returning the Unix
/// epoch if there is no previous timestamp in the database.
pub fn get_most_recent_hex_timestamp(
  db: pgo.Connection,
) -> Result(DateTime, Error) {
  let decoder = dyn.element(0, dyn.int)
  use returned <- result.map(sql.get_most_recent_hex_timestamp(db, [], decoder))
  case returned.rows {
    [unix] -> time.from_unix(unix)
    _ -> time.from_unix(0)
  }
}

// TODO: insert licences also
pub fn upsert_package(
  db: pgo.Connection,
  package: hexpm.Package,
) -> Result(Int, Error) {
  let links_json =
    package.meta.links
    |> map.to_list
    |> list.map(fn(pair) {
      let #(name, url) = pair
      #(name, json.string(url))
    })
    |> json.object
    |> json.to_string

  let parameters = [
    pgo.text(package.name),
    pgo.nullable(pgo.text, package.meta.description),
    pgo.nullable(pgo.text, package.docs_html_url),
    pgo.text(links_json),
    pgo.int(time.to_unix(package.inserted_at)),
    pgo.int(time.to_unix(package.updated_at)),
  ]
  let decoder = dyn.element(0, dyn.int)
  use returned <- result.then(sql.upsert_package(db, parameters, decoder))
  let assert [id] = returned.rows
  Ok(id)
}

pub type Package {
  Package(
    name: String,
    description: Option(String),
    docs_url: Option(String),
    links: Map(String, String),
    inserted_in_hex_at: DateTime,
    updated_in_hex_at: DateTime,
  )
}

pub fn decode_package(data: Dynamic) -> Result(Package, List(DecodeError)) {
  dyn.decode6(
    Package,
    dyn.element(0, dyn.string),
    dyn.element(1, dyn.optional(dyn.string)),
    dyn.element(2, dyn.optional(dyn.string)),
    dyn.element(3, decode_package_links),
    dyn.element(4, dyn_extra.unix_timestamp),
    dyn.element(5, dyn_extra.unix_timestamp),
  )(data)
}

pub fn get_package(
  db: pgo.Connection,
  id: Int,
) -> Result(Option(Package), Error) {
  let params = [pgo.int(id)]
  use returned <- result.then(sql.get_package(db, params, decode_package))
  case returned.rows {
    [package] -> Ok(Some(package))
    _ -> Ok(None)
  }
}

pub fn get_total_package_count(db: pgo.Connection) -> Result(Int, Error) {
  use returned <- result.then(sql.get_total_package_count(
    db,
    [],
    dyn.element(0, dyn.int),
  ))
  let assert [count] = returned.rows
  Ok(count)
}

pub fn upsert_release(
  db: pgo.Connection,
  package_id: Int,
  release: hexpm.Release,
) -> Result(Int, Error) {
  let #(retirement_reason, retirement_message) = case release.retirement {
    Some(retirement) -> #(
      Some(hexpm.retirement_reason_to_string(retirement.reason)),
      retirement.message,
    )
    None -> #(None, None)
  }
  let parameters = [
    pgo.int(package_id),
    pgo.text(release.version),
    pgo.nullable(pgo.text, retirement_reason),
    pgo.nullable(pgo.text, retirement_message),
    pgo.int(time.to_unix(release.inserted_at)),
    pgo.int(time.to_unix(release.updated_at)),
  ]
  let decoder = dyn.element(0, dyn.int)
  use returned <- result.then(sql.upsert_release(db, parameters, decoder))
  let assert [id] = returned.rows
  Ok(id)
}

pub type Release {
  Release(
    package_id: Int,
    version: String,
    retirement_reason: Option(hexpm.RetirementReason),
    retirement_message: Option(String),
    inserted_in_hex_at: DateTime,
    updated_in_hex_at: DateTime,
  )
}

pub fn decode_release(data: Dynamic) -> Result(Release, List(DecodeError)) {
  dyn.decode6(
    Release,
    dyn.element(0, dyn.int),
    dyn.element(1, dyn.string),
    dyn.element(2, dyn.optional(hexpm.decode_retirement_reason)),
    dyn.element(3, dyn.optional(dyn.string)),
    dyn.element(4, dyn_extra.unix_timestamp),
    dyn.element(5, dyn_extra.unix_timestamp),
  )(data)
}

pub fn get_release(
  db: pgo.Connection,
  id: Int,
) -> Result(Option(Release), Error) {
  let params = [pgo.int(id)]
  use returned <- result.then(sql.get_release(db, params, decode_release))
  case returned.rows {
    [package] -> Ok(Some(package))
    _ -> Ok(None)
  }
}

pub type PackageSummary {
  PackageSummary(
    name: String,
    description: String,
    docs_url: Option(String),
    links: Map(String, String),
    latest_versions: List(String),
    updated_in_hex_at: DateTime,
  )
}

fn decode_package_links(
  data: Dynamic,
) -> Result(Map(String, String), List(DecodeError)) {
  use json_data <- try(dyn.string(data))

  json.decode(json_data, using: dyn.map(of: dyn.string, to: dyn.string))
  |> result.map_error(fn(_) {
    [DecodeError(expected: "Map(String, String)", found: json_data, path: [])]
  })
}

fn decode_package_summary(
  data: Dynamic,
) -> Result(PackageSummary, List(DecodeError)) {
  dyn.decode6(
    PackageSummary,
    dyn.element(0, dyn.string),
    dyn.element(1, dyn.string),
    dyn.element(2, dyn.optional(dyn.string)),
    dyn.element(3, decode_package_links),
    dyn.element(4, dyn.list(dyn.string)),
    dyn.element(5, dyn_extra.unix_timestamp),
  )(data)
}

pub fn search_packages(
  db: pgo.Connection,
  search_term: String,
) -> Result(List(PackageSummary), Error) {
  let params = [pgo.text(search_term)]
  sql.search_packages(db, params, decode_package_summary)
  |> result.map(fn(r) { r.rows })
}
