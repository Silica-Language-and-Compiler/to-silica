//// The command line of gleam-to-silica-poc.
////
////   gleam run -- [--port N] [--mode check|transpile] [--dump] file.gleam ...
////   gleam run -- [--port N] --release SESSION
////
//// It parses each file with glance, maps it to the frames of the to-silica
//// TCP transport contract (version 1) and sends them to the transpiler on
//// 127.0.0.1. `--dump` prints the frames as Erlang terms and sends nothing.
//// `--release SESSION` sends no session: it frees the storage of a finished
//// transpile session (contract 6.6) and prints the transpiler's answer.
//// SESSION is the id a transpile session printed, opaque text such as
//// `intake_1:42` (T6.5b). A finished transpile session holds one of the
//// transpiler's storage regions until it is released.
//// Exit status: 0 when the session's result is `ok` (or after a dump, or
//// when a release answers `freed` true), 2 for a usage error, 1 otherwise.

import argv
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_to_silica_poc/codex.{type Source, Source}
import gleam_to_silica_poc/frame.{type Mode}
import gleam_to_silica_poc/sender
import gleam_to_silica_poc/wire
import simplifile

const usage =
  "usage: gleam run -- [--port N] [--mode check|transpile] [--dump] file.gleam ...\n       gleam run -- [--port N] --release SESSION     (a session id, such as intake_1:42)"

type Options {
  Options(
    port: Int,
    mode: Mode,
    dump: Bool,
    release: Option(String),
    files: List(String),
  )
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "io", "format")
fn format(template: String, arguments: List(Dynamic)) -> Dynamic

pub fn main() -> Nil {
  let defaults =
    Options(
      port: 7411,
      mode: frame.Check,
      dump: False,
      release: None,
      files: [],
    )
  halt(case parse(argv.load().arguments, defaults) {
    Ok(Options(release: Some(session), files: [], port:, ..)) ->
      release(port, session)
    Error(Nil)
    | Ok(Options(files: [], ..))
    | Ok(Options(release: Some(_), ..)) -> {
      io.println(usage)
      2
    }
    Ok(options) -> run(options)
  })
}

fn parse(arguments: List(String), options: Options) -> Result(Options, Nil) {
  case arguments {
    [] -> Ok(Options(..options, files: list.reverse(options.files)))
    ["--port", port, ..rest] ->
      case int.parse(port) {
        Ok(port) -> parse(rest, Options(..options, port:))
        Error(Nil) -> Error(Nil)
      }
    ["--mode", "check", ..rest] ->
      parse(rest, Options(..options, mode: frame.Check))
    ["--mode", "transpile", ..rest] ->
      parse(rest, Options(..options, mode: frame.Transpile))
    ["--dump", ..rest] -> parse(rest, Options(..options, dump: True))
    ["--release", session, ..rest] ->
      parse(rest, Options(..options, release: Some(session)))
    ["--" <> _, ..] -> Error(Nil)
    [file, ..rest] ->
      parse(rest, Options(..options, files: [file, ..options.files]))
  }
}

/// M7: release a finished session and report the answer (R9).
fn release(port: Int, session: String) -> Int {
  case sender.release(port, session) {
    sender.ReleaseAnswered(session:, freed: True) -> {
      io.println("released: session " <> session <> ", freed true")
      0
    }
    sender.ReleaseAnswered(session:, freed: False) -> {
      io.println(
        "released: session "
        <> session
        <> ", freed false (the session is unknown or not finished)",
      )
      1
    }
    sender.ReleaseFailed(why:) -> {
      io.println("release failed: " <> why)
      1
    }
  }
}

fn run(options: Options) -> Int {
  let frames = case read(options.files) {
    Ok(sources) -> codex.session(sources, options.mode)
    Error(why) -> Error(why)
  }
  case frames {
    // The parser is the gate: nothing is sent unless every file parsed.
    Error(why) -> {
      io.println_error(why)
      1
    }
    Ok(frames) if options.dump -> {
      list.each(frames, fn(frame) { format("~tp.~n", [wire.to_term(frame)]) })
      0
    }
    Ok(frames) -> {
      let gaps = int.sum(list.map(frames, frame.gaps))
      report(sender.run(options.port, frames), list.length(frames), gaps)
    }
  }
}

fn read(files: List(String)) -> Result(List(Source), String) {
  list.try_map(files, fn(path) {
    case simplifile.read(path) {
      Ok(text) -> Ok(Source(path:, text:))
      Error(error) ->
        Error(path <> " cannot be read: " <> simplifile.describe_error(error))
    }
  })
}

fn report(outcome: sender.Outcome, sent: Int, gaps: Int) -> Int {
  let number = int.to_string
  case outcome {
    sender.Completed(
      session:,
      transpiler:,
      rejected:,
      diagnostics:,
      result:,
      ..,
    ) -> {
      io.println(
        string.concat([
          "session ",
          session,
          " (",
          transpiler,
          "): ",
          number(sent),
          " frames sent, ",
          number(gaps),
          " gaps among them",
        ]),
      )
      list.each(rejected, fn(reply) {
        case reply {
          sender.Rejected(seq:, reason:, where:) ->
            io.println(
              "rejected seq " <> number(seq) <> ": " <> reason <> " " <> where,
            )
          _ -> Nil
        }
      })
      list.each(diagnostics, fn(reply) {
        case reply {
          sender.Diagnostic(severity:, code:, message:, file:, line:, ..) ->
            io.println(
              string.concat([
                severity,
                " ",
                code,
                ": ",
                message,
                " (",
                file,
                ":",
                number(line),
                ")",
              ]),
            )
          _ -> Nil
        }
      })
      case result {
        Some(sender.Finished(status:, units:, gaps:, rejected:, files:, ..)) -> {
          io.println(
            string.concat([
              "result: ",
              status,
              " (units ",
              number(units),
              ", gaps ",
              number(gaps),
              ", rejected ",
              number(rejected),
              ", files ",
              number(files),
              ")",
            ]),
          )
          case status {
            "ok" -> 0
            _ -> 1
          }
        }
        _ -> {
          io.println("the transpiler closed the connection without a result")
          1
        }
      }
    }
    sender.NotAccepted(reason:, detail:) -> {
      io.println("refused: " <> reason <> " (" <> detail <> ")")
      1
    }
    sender.Failed(why:) -> {
      io.println("error: " <> why)
      1
    }
  }
}
