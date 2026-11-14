//// sender: the TCP sender of gleam-to-silica-poc. It speaks the to-silica TCP
//// transport contract, version 1: every frame is a 4-byte big-endian length
//// and one ETF term (T4.1, T4.2: gen_tcp's `{packet, 4}` and
//// `term_to_binary/1`); the hello goes first and nothing more until the
//// welcome (T6.1); M2 to M5 go only while credit is held (T6.2), and the
//// transpiler's replies are read while sending (T6.3); then everything it
//// answers is read until the result (T3.4).
////
//// Not done: resume (T6.5, T6.5a). The hello's `session` is always empty; a
//// session whose connection drops is started again from the beginning.
////
//// The socket is OTP's gen_tcp, reached through externals.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_to_silica_poc/frame.{type Frame}
import gleam_to_silica_poc/term.{atom}
import gleam_to_silica_poc/wire

/// A frame from the transpiler (R1 to R9). Atoms are given by name.
pub type Reply {
  Welcome(
    session: String,
    transpiler: String,
    resume_from: Int,
    credit: Int,
    max_frame: Int,
  )
  Refused(reason: String, detail: String)
  Credit(Int)
  Stored(next: Int)
  Rejected(seq: Int, reason: String, where: String)
  Progress(stage: String, unit_name: String)
  Diagnostic(
    seq: Int,
    severity: String,
    code: String,
    message: String,
    file: String,
    line: Int,
  )
  Finished(
    status: String,
    units: Int,
    gaps: Int,
    rejected: Int,
    session: String,
    files: Int,
  )
  Released(session: String, freed: Bool)
}

/// What a release came to (contract 6.6).
pub type Release {
  /// The transpiler answered (R9). `freed` is False when the session is
  /// unknown or not finished.
  ReleaseAnswered(session: String, freed: Bool)
  /// The connection, the protocol, or the transpiler failed: no answer.
  ReleaseFailed(why: String)
}

/// What a session came to.
pub type Outcome {
  /// The hello was accepted and the frames were sent. `result` is None when
  /// the transpiler closed the connection without sending one.
  Completed(
    session: String,
    transpiler: String,
    rejected: List(Reply),
    diagnostics: List(Reply),
    stored: Int,
    result: Option(Reply),
  )
  /// The hello was refused (R2).
  NotAccepted(reason: String, detail: String)
  /// The connection or the protocol failed.
  Failed(why: String)
}

type Socket

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: Dynamic,
  port: Int,
  options: List(Dynamic),
  timeout: Int,
) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "send")
fn tcp_send(socket: Socket, bytes: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "recv")
fn tcp_recv(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, Dynamic)

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Socket) -> Dynamic

/// Connects to the transpiler on 127.0.0.1 (T3.1) with 4-byte length framing
/// (T4.1).
fn connect(port: Int) -> Result(Socket, Dynamic) {
  let localhost =
    dynamic.array([
      dynamic.int(127),
      dynamic.int(0),
      dynamic.int(0),
      dynamic.int(1),
    ])
  let options = [
    atom("binary"),
    dynamic.array([atom("packet"), dynamic.int(4)]),
    dynamic.array([atom("active"), dynamic.bool(False)]),
  ]
  tcp_connect(localhost, port, options, 5000)
}

/// Releases a finished transpile session (M7, T6.13): a new connection whose
/// first and only frame is `(:release, { session })`, no hello and no credit.
/// The transpiler answers `(:released, { session, freed })` and closes.
/// Release a session only after its output has been exported (T6.14).
pub fn release(port: Int, session: String) -> Release {
  case connect(port) {
    Error(reason) -> ReleaseFailed("connect: " <> string.inspect(reason))
    Ok(socket) -> {
      let outcome = case send(socket, wire.release(session)) {
        Error(why) -> ReleaseFailed(why)
        Ok(Nil) ->
          case receive(socket) {
            Ok(Released(session:, freed:)) -> ReleaseAnswered(session:, freed:)
            Ok(other) ->
              ReleaseFailed("expected released, got " <> string.inspect(other))
            Error("closed") ->
              ReleaseFailed(
                "the transpiler closed the connection without answering the release",
              )
            Error(why) -> ReleaseFailed(why)
          }
      }
      tcp_close(socket)
      outcome
    }
  }
}

/// Runs one session against the transpiler on 127.0.0.1 (T3.1). `frames` is a
/// session as the codex writes it: the hello, then M2 to M5.
pub fn run(port: Int, frames: List(Frame)) -> Outcome {
  case frames, connect(port) {
    [], _ -> Failed("no frames to send")
    _, Error(reason) -> Failed("connect: " <> string.inspect(reason))
    [hello, ..rest], Ok(socket) -> {
      let outcome = case send(socket, wire.encode(hello)) {
        Error(why) -> Failed(why)
        Ok(Nil) -> opened(socket, rest)
      }
      tcp_close(socket)
      outcome
    }
  }
}

/// T6.1: after the hello, wait for the welcome.
fn opened(socket: Socket, frames: List(Frame)) -> Outcome {
  case receive(socket) {
    Ok(Welcome(session:, transpiler:, resume_from:, credit:, max_frame:)) -> {
      // T6.5: frames below resume_from are already stored. This sender never
      // resumes, and a new session starts at 0, so nothing is dropped.
      let frames = list.filter(frames, fn(f) { frame.seq(f) >= resume_from })
      let session = Completed(session, transpiler, [], [], 0, None)
      case list.find(frames, fn(f) { size(f) > max_frame }) {
        Ok(large) ->
          Failed(
            "frame seq "
            <> int.to_string(frame.seq(large))
            <> " is larger than the max_frame the transpiler granted (T4.3)",
          )
        Error(Nil) -> sending(socket, frames, credit, session)
      }
    }
    Ok(Refused(reason:, detail:)) -> NotAccepted(reason, detail)
    Ok(other) -> Failed("expected a welcome, got " <> string.inspect(other))
    Error(why) -> Failed(why)
  }
}

fn size(frame: Frame) -> Int {
  bit_array.byte_size(wire.encode(frame))
}

/// T6.2: each of M2 to M5 uses one credit, and nothing is sent without one.
///
/// T6.3, T6.11a: the transpiler answers while it receives. Each time half
/// of its window (64, as built) is used it sends `(:stored, next)` (not in
/// check mode) and then `(:credit, 32)`; rejections come at any time. So
/// the replies are read **while sending**: before every frame, whatever has
/// arrived is read without waiting, and credit that came is added to what is
/// held. Only with no credit left does the sender wait for a reply, and then
/// not for ever (T3.5).
fn sending(
  socket: Socket,
  frames: List(Frame),
  credit: Int,
  session: Outcome,
) -> Outcome {
  case frames {
    [] -> finishing(socket, session)
    [next, ..rest] -> {
      let wait = case credit > 0 {
        True -> 0
        False -> patience
      }
      case receive_within(socket, wait) {
        Ok(Some(Credit(more))) ->
          sending(socket, frames, credit + more, session)
        // A result before the end: the transpiler has finished the session.
        Ok(Some(Finished(..) as result)) -> done(note(session, result))
        Ok(Some(reply)) -> sending(socket, frames, credit, note(session, reply))
        Ok(None) if credit > 0 ->
          case send(socket, wire.encode(next)) {
            Ok(Nil) -> sending(socket, rest, credit - 1, session)
            Error(why) -> Failed(why)
          }
        Ok(None) ->
          Failed(
            "no credit came for "
            <> int.to_string(patience / 1000)
            <> " seconds (T3.5, T6.2); frame seq "
            <> int.to_string(frame.seq(next))
            <> " was not sent",
          )
        Error(why) -> Failed(why)
      }
    }
  }
}

/// T3.4: read until the result.
fn finishing(socket: Socket, session: Outcome) -> Outcome {
  case receive(socket) {
    Ok(Finished(..) as result) -> done(note(session, result))
    Ok(reply) -> finishing(socket, note(session, reply))
    Error("closed") -> done(session)
    Error(why) -> Failed(why)
  }
}

fn note(session: Outcome, reply: Reply) -> Outcome {
  case session, reply {
    Completed(rejected:, ..), Rejected(..) ->
      Completed(..session, rejected: [reply, ..rejected])
    Completed(diagnostics:, ..), Diagnostic(..) ->
      Completed(..session, diagnostics: [reply, ..diagnostics])
    Completed(..), Stored(next:) -> Completed(..session, stored: next)
    Completed(..), Finished(..) -> Completed(..session, result: Some(reply))
    // Credit while finishing, progress, and anything out of place.
    _, _ -> session
  }
}

fn done(session: Outcome) -> Outcome {
  case session {
    Completed(rejected:, diagnostics:, ..) ->
      Completed(
        ..session,
        rejected: list.reverse(rejected),
        diagnostics: list.reverse(diagnostics),
      )
    _ -> session
  }
}

fn send(socket: Socket, bytes: BitArray) -> Result(Nil, String) {
  let answer = tcp_send(socket, bytes)
  case answer == atom("ok") {
    True -> Ok(Nil)
    False -> Error("send: " <> string.inspect(answer))
  }
}

/// How long the sender waits for a reply it needs, in milliseconds (T3.5).
const patience = 30_000

fn receive(socket: Socket) -> Result(Reply, String) {
  case receive_within(socket, patience) {
    Ok(Some(reply)) -> Ok(reply)
    Ok(None) ->
      Error(
        "no reply for " <> int.to_string(patience / 1000) <> " seconds (T3.5)",
      )
    Error(why) -> Error(why)
  }
}

/// The next reply, waiting at most `wait` milliseconds for it; `Ok(None)`
/// when none came in that time. With `wait` 0 this only looks.
fn receive_within(socket: Socket, wait: Int) -> Result(Option(Reply), String) {
  case tcp_recv(socket, 0, wait) {
    Error(reason) ->
      case reason == atom("timeout"), reason == atom("closed") {
        True, _ -> Ok(None)
        _, True -> Error("closed")
        _, _ -> Error("receive: " <> string.inspect(reason))
      }
    Ok(bytes) -> {
      let reply = term.decode(bytes)
      case decode.run(reply, reply_decoder()) {
        Ok(reply) -> Ok(Some(reply))
        Error(_) ->
          Error("a reply the contract does not list: " <> string.inspect(reply))
      }
    }
  }
}

// ------------------------------------------------------------ replies

/// Decodes one reply term: a tuple, the atom tag first (contract 5.3).
pub fn reply_decoder() -> Decoder(Reply) {
  use tag <- decode.field(0, atom_name())
  case tag {
    "welcome" -> {
      use session <- decode.then(field(["session"], decode.string))
      use transpiler <- decode.then(field(["transpiler"], decode.string))
      use resume_from <- decode.then(field(["flow", "resume_from"], decode.int))
      use credit <- decode.then(field(["flow", "credit"], decode.int))
      use max_frame <- decode.then(field(["flow", "max_frame"], decode.int))
      decode.success(Welcome(
        session:,
        transpiler:,
        resume_from:,
        credit:,
        max_frame:,
      ))
    }
    "refused" -> {
      use reason <- decode.then(field(["reason"], atom_name()))
      use detail <- decode.then(field(["detail"], decode.string))
      decode.success(Refused(reason:, detail:))
    }
    "credit" -> decode.map(field([], decode.int), Credit)
    "stored" -> decode.map(field([], decode.int), Stored)
    "rejected" -> {
      use seq <- decode.then(field(["seq"], decode.int))
      use reason <- decode.then(field(["reason"], atom_name()))
      use where <- decode.then(field(["where"], decode.string))
      decode.success(Rejected(seq:, reason:, where:))
    }
    "progress" -> {
      use stage <- decode.then(field(["stage"], atom_name()))
      use unit_name <- decode.then(field(["unit_name"], decode.string))
      decode.success(Progress(stage:, unit_name:))
    }
    "diagnostic" -> {
      use seq <- decode.then(field(["seq"], decode.int))
      use severity <- decode.then(field(["finding", "severity"], atom_name()))
      use code <- decode.then(field(["finding", "code"], decode.string))
      use message <- decode.then(field(["finding", "message"], decode.string))
      use file <- decode.then(field(["place", "file"], decode.string))
      use line <- decode.then(field(["place", "line"], decode.int))
      decode.success(Diagnostic(seq:, severity:, code:, message:, file:, line:))
    }
    "result" -> {
      use status <- decode.then(field(["status"], atom_name()))
      use units <- decode.then(field(["counts", "units"], decode.int))
      use gaps <- decode.then(field(["counts", "gaps"], decode.int))
      use rejected <- decode.then(field(["counts", "rejected"], decode.int))
      use session <- decode.then(field(["session"], decode.string))
      use files <- decode.then(field(["files"], decode.int))
      decode.success(Finished(
        status:,
        units:,
        gaps:,
        rejected:,
        session:,
        files:,
      ))
    }
    "released" -> {
      use session <- decode.then(field(["session"], decode.string))
      use freed <- decode.then(field(["freed"], decode.bool))
      decode.success(Released(session:, freed:))
    }
    _ -> decode.failure(Credit(0), "a reply of the contract")
  }
}

/// A value inside a reply's second element, by the atom keys that lead to it.
fn field(keys: List(String), inner: Decoder(a)) -> Decoder(a) {
  decode.at([dynamic.int(1), ..list.map(keys, atom)], inner)
}

fn atom_name() -> Decoder(String) {
  decode.new_primitive_decoder("Atom", fn(value) {
    case term.is_atom(value) {
      True -> Ok(term.atom_name(value))
      False -> Error("")
    }
  })
}
