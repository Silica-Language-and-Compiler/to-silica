//// codex: the inbound codex of gleam-to-silica-poc. Gleam source -> the frames
//// of the to-silica TCP transport contract, version 1
//// (../contract/tcp-transport-v1.md; rule ids such as T9.2 and node ids such
//// as H21 are cited).
////
//// Parsing is the Gleam ecosystem's own parser, `glance`. The parser is the
//// gate: nothing is produced unless it succeeded. glance gives syntax only,
//// with no type information, so every decision here is made from the syntax
//// of one module.
////
//// Types (contract 8.6): the language side decides every type, and the
//// transpiler infers none. So this codex has a typing pass of its own. It
//// runs while the nodes are written: every function that writes an
//// expression also records the expression's type (`typed`), and a hint for
//// it (T8.5). The sources of a type are the annotations of the source, the
//// literals, the spelling of the operators (`+` is Int, `+.` is Float), the
//// annotated signatures of the module's functions, its custom types, and
//// the few functions of other modules listed in `types.library_signature`.
//// Where the contract requires a type (T8.10) and the codex has none, the
//// construct is sent as a gap whose note says what is missing; nothing is
//// sent untyped. README, "Types", has the rules.
////
//// Scope of the proof of concept (everything else is sent as a gap, T9.10, so
//// a session always completes):
////   in:  Int, Float and String literals, Bool, Nil and other constructors,
////        tuples, custom types (the record idiom and tagged variants),
////        variables, let, functions, case with patterns and guards, blocks,
////        local and qualified calls, anonymous functions, captures, function
////        names as values, operators, the pipe, panic, let assert, alias
////        patterns, calls to this module's externals to erlang:self, spawn,
////        spawn_link, send, link and exit, seven calls of gleam/erlang/process
////        (functions are split at their receives first: split.gleam),
////        the plain gleam_otp actor, a gleam_otp static supervisor of named
////        actors (read first: sup.gleam; sent as static children, T9.14b)
////        and sends to their names (T9.14c), function literals that capture
////        nothing (made functions first: lift.gleam), io.println and
////        io.print (as Silica's print builtins, L1), lists, constants with a
////        literal value, type aliases without parameters.
////   out: dicts, bit arrays, use, assert, todo, echo, tuple indexing, string
////        prefix patterns, every other external (a receive through one
////        included), the rest of gleam_otp (initialisers, selectors, a
////        named actor outside a static supervisor, a supervisor that cannot
////        be read), and everything that reaches another node.
////
//// Where to add a mapping: the sections below follow the contract's order
//// (forms 9.3, node tables and types 8, statements, patterns, expressions
//// H1..H37, calls, processes H20..H26, gleam_otp, operators Appendix B).
//// Every name written into a frame goes through `names` (rules N1..N5).
//// README, "Extending this sender", has the steps.

import glance as g
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_to_silica_poc/frame.{
  type Form, type Frame, type Mode, type Node, type Strength, Inferred, Proven,
}
import gleam_to_silica_poc/lift
import gleam_to_silica_poc/names
import gleam_to_silica_poc/split
import gleam_to_silica_poc/sup
import gleam_to_silica_poc/types.{
  type Ty, TyAtoms, TyBool, TyFloat, TyFn, TyInt, TyList, TyName, TyNamed,
  TyNamedSubject, TyNever, TyNext, TyNil, TyPid, TyResult, TyStartError,
  TyStarted, TyString, TySubject, TyTagged, TyTuple, TyUnknown, TyVar,
}
import gleam_to_silica_poc/wire
import glexer

const out_of_scope = "outside the proof of concept"

const inter_node = "inter-node communication is outside the proof of concept"

const registered_names =
  "registered names (H38, H39) are left out of the proof of concept"

const foreign_code =
  "a binding to foreign code: the contract has no node for a foreign call (T9.9)"

/// The type expected of an expression when its place says nothing.
const any = TyUnknown("its type is not known to this codex")

/// The Gleam name under which the one library constructor with known labels
/// is kept (`library_constructor`).
const started_type = "gleam/otp/actor.Started"

/// One source file: its path, and its text.
pub type Source {
  Source(path: String, text: String)
}

/// The frames of a whole session for these sources: the hello, then for each
/// source its unit_begin, forms and unit_end, then the end. An error names the
/// source that does not parse; then there are no frames at all.
pub fn session(
  sources: List(Source),
  mode: Mode,
) -> Result(List(Frame), String) {
  use #(seq, units) <- result.try(
    list.try_fold(sources, #(0, []), fn(acc, source) {
      let #(seq, units) = acc
      use frames <- result.map(unit(source, seq))
      #(seq + list.length(frames), [frames, ..units])
    }),
  )
  Ok(
    list.flatten([
      [frame.Hello(mode)],
      list.flatten(list.reverse(units)),
      [frame.End(seq, list.length(sources))],
    ]),
  )
}

/// The frames of one unit (M2, M3..., M4), numbered from `seq` (T5.1).
pub fn unit(source: Source, seq: Int) -> Result(List(Frame), String) {
  case g.module(source.text) {
    Error(error) ->
      Error(source.path <> " does not parse: " <> string.inspect(error))
    Ok(module) -> {
      let file = basename(source.path)
      let name = case string.ends_with(file, ".gleam") {
        True -> string.drop_end(file, 6)
        False -> file
      }
      // Gleam's process semantics first (split.gleam): every receive in
      // tail position, the code after it in functions of its own.
      let #(module, constant_functions) = constants_as_functions(module)
      // The registered names the unit makes, read where they are made.
      let named = name_statements(module)
      let #(module, made, unexported) = split_module(module)
      let env =
        settle_made(
          module,
          environment(
            module,
            name,
            file,
            source.text,
            made,
            constant_functions,
            named,
            unexported,
          ),
          40,
        )
      let forms = forms(module, env)
      let frames =
        list.index_map(forms, fn(form, index) {
          frame.FormFrame(seq + 1 + index, name, form)
        })
      let count = list.length(forms)
      Ok(
        list.flatten([
          // N1 (names.gleam): the Silica unit asked for (T5.2).
          [
            frame.UnitBegin(
              seq,
              name,
              names.silica_unit(wire.prefix, name),
              file,
            ),
          ],
          frames,
          // T5.3b: `forms` is the number of form frames sent for the unit.
          [frame.UnitEnd(seq + 1 + count, name, count)],
        ]),
      )
    }
  }
}

/// A constant whose value is a literal (an Int, a Float, a String) is sent
/// as a function of no parameters that gives the literal, and a use of the
/// constant as a call of it (`variable`): the contract has no form for a
/// constant. Any other constant stays a gap form.
fn constants_as_functions(module: g.Module) -> #(g.Module, List(String)) {
  let named = fn(at, name) { Some(g.NamedType(at, name, None, [])) }
  let #(literal, other) =
    list.partition(module.constants, fn(definition) {
      case definition.definition.value {
        g.Int(..) | g.Float(..) | g.String(..) -> True
        _ -> False
      }
    })
  let functions =
    list.map(literal, fn(definition) {
      let constant = definition.definition
      let at = constant.location
      let return = case constant.value {
        g.Int(..) -> named(at, "Int")
        g.Float(..) -> named(at, "Float")
        _ -> named(at, "String")
      }
      g.Definition(
        [],
        g.Function(
          location: at,
          name: constant.name,
          publicity: constant.publicity,
          parameters: [],
          return:,
          body: [g.Expression(constant.value)],
        ),
      )
    })
  #(
    g.Module(
      ..module,
      constants: other,
      functions: list.append(module.functions, functions),
    ),
    list.map(literal, fn(definition) { definition.definition.name }),
  )
}

/// Import alias -> module name, and unqualified imported value -> module
/// name.
fn imports_of(
  module: g.Module,
) -> #(List(#(String, String)), List(#(String, String))) {
  let imports =
    list.filter_map(module.imports, fn(definition) {
      let import_ = definition.definition
      case import_.alias {
        Some(g.Named(alias)) -> Ok(#(alias, import_.module))
        Some(g.Discarded(_)) -> Error(Nil)
        None -> Ok(#(basename(import_.module), import_.module))
      }
    })
  let imported =
    list.flat_map(module.imports, fn(definition) {
      let import_ = definition.definition
      list.map(import_.unqualified_values, fn(value) {
        #(option.unwrap(value.alias, value.name), import_.module)
      })
    })
  #(imports, imported)
}

/// Every `let name: Name(Message) = process.new_name("literal")` that is a
/// statement of a function body: the annotation's message type and the
/// literal. This is the one place a registered name is read from: the
/// contract's static child and its send take a literal name (T9.14b,
/// T9.14c), and gleam_erlang makes a name when the program runs.
fn name_statements(module: g.Module) -> List(#(g.Type, String)) {
  let #(imports, imported) = imports_of(module)
  let imported_types =
    list.flat_map(module.imports, fn(definition) {
      let import_ = definition.definition
      list.map(import_.unqualified_types, fn(type_) {
        #(option.unwrap(type_.alias, type_.name), import_.module)
      })
    })
  let process_module = "gleam/erlang/process"
  let is_name = fn(annotation: g.Type) {
    case annotation {
      g.NamedType(name: "Name", module: Some(alias), parameters: [message], ..) ->
        case list.key_find(imports, alias) == Ok(process_module) {
          True -> Ok(message)
          False -> Error(Nil)
        }
      g.NamedType(name:, module: None, parameters: [message], ..) ->
        case list.key_find(imported_types, name) == Ok(process_module) {
          True if name == "Name" -> Ok(message)
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  }
  let is_new_name = fn(function: g.Expression) {
    case function {
      g.FieldAccess(
        container: g.Variable(name: alias, ..),
        label: "new_name",
        ..,
      ) -> list.key_find(imports, alias) == Ok(process_module)
      g.Variable(name: "new_name", ..) ->
        list.key_find(imported, "new_name") == Ok(process_module)
      _ -> False
    }
  }
  list.flat_map(module.functions, fn(definition) {
    list.filter_map(definition.definition.body, fn(statement) {
      case statement {
        g.Assignment(
          kind: g.Let,
          pattern: g.PatternVariable(..),
          annotation: Some(annotation),
          value: g.Call(function:, arguments: [argument], ..),
          ..,
        ) ->
          case is_new_name(function), split.field_item(argument) {
            True, g.String(value: literal, ..) ->
              result.map(is_name(annotation), fn(message) {
                #(message, literal)
              })
            _, _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  })
}

/// The module as it is typed and sent, after this sender's own lowerings of
/// what is Gleam's (glance syntax in, glance syntax out), in this order:
/// gleam_otp's static supervisors read into static children (sup.gleam),
/// function literals that capture nothing made functions (lift.gleam), and
/// the functions split at their receives (split.gleam). Also what each
/// function the lift and the split made is made from.
fn split_module(
  module: g.Module,
) -> #(g.Module, Dict(String, split.Made), List(String)) {
  let #(imports, imported) = imports_of(module)
  let #(plain, other) =
    list.partition(module.functions, fn(definition) {
      kind(definition) == Plain
    })
  let read =
    sup.functions(
      list.map(plain, fn(definition) { definition.definition }),
      dict.from_list(imports),
      dict.from_list(imported),
    )
  let lifted = lift.functions(read)
  let result =
    split.functions(
      lifted.functions,
      dict.from_list(imports),
      dict.from_list(imported),
    )
  let result = split.Split(..result, made: dict.merge(lifted.made, result.made))
  let attributes =
    dict.from_list(
      list.map(plain, fn(definition) {
        #(definition.definition.name, definition.attributes)
      }),
    )
  let functions =
    list.map(result.functions, fn(function) {
      g.Definition(
        result.unwrap(dict.get(attributes, function.name), []),
        function,
      )
    })
  #(
    g.Module(..module, functions: list.append(other, functions)),
    result.made,
    result.unexported,
  )
}

/// The parameter types of the functions the split made (continuations,
/// copies: the parameters it adds have no annotation). A made function is
/// called only by the pieces of the function it was cut from, so such a
/// parameter has the type of the argument of those calls: the functions are
/// typed (and the forms thrown away) until the types the calls give no
/// longer change. `named_call` notes every call of a made function.
fn settle_made(module: g.Module, env: Env, tries: Int) -> Env {
  case dict.is_empty(env.made) || tries == 0 {
    True -> env
    False -> {
      let calls =
        list.flat_map(module.functions, fn(definition) {
          case kind(definition) {
            Plain -> function_written(definition.definition, env).2
            _ -> []
          }
        })
      let signatures =
        dict.map_values(env.signatures, fn(name, signature) {
          case dict.has_key(env.made, name) {
            False -> signature
            True -> {
              let given =
                list.filter_map(calls, fn(call) {
                  case call.0 == name {
                    True -> Ok(call.1)
                    False -> Error(Nil)
                  }
                })
              let params =
                list.index_map(signature.params, fn(ty, index) {
                  let found =
                    list.find_map(given, fn(arguments) {
                      case list.drop(arguments, index) {
                        [argument, ..] ->
                          case types.closed(argument) {
                            True -> Ok(argument)
                            False -> Error(Nil)
                          }
                        [] -> Error(Nil)
                      }
                    })
                  case types.stateable(ty), found {
                    False, Ok(found) -> found
                    _, _ -> ty
                  }
                })
              Signature(..signature, params:)
            }
          }
        })
      case signatures == env.signatures {
        True -> env
        False -> settle_made(module, Env(..env, signatures:), tries - 1)
      }
    }
  }
}

/// N4 for a function of the module. N6: a function the split made is sent as
/// the sent name of the function it was made from and its suffix: `main__k1`
/// (the first continuation of main), `ask__c1` (a copy of ask),
/// `ask__c1__k1`. `ident` never writes `__k` or `__c`, so these names are no
/// source function's.
fn fname(env: Env, name: String) -> String {
  case dict.get(env.made, name) {
    Ok(split.Made(base:, suffix:, ..)) -> fname(env, base) <> suffix
    Error(Nil) -> names.ident(name)
  }
}

fn basename(path: String) -> String {
  path |> string.split("/") |> list.last |> result.unwrap(path)
}

// ------------------------------------------------------------ the module

/// What the codex knows about the module while it maps one form.
type Env {
  Env(
    /// The module's name as the user writes it (N2).
    module: String,
    file: String,
    /// The byte offset at which each line starts, in order.
    lines: List(Int),
    /// The module's functions that are called by name: their parameter labels.
    functions: Dict(String, List(Option(String))),
    /// The types of every function of the module, externals included, as
    /// far as its annotations give them.
    signatures: Dict(String, Signature),
    /// The module's externals to Erlang's process functions.
    primitives: Dict(String, Primitive),
    constants: List(String),
    /// The constructors of the module's custom types.
    constructors: Dict(String, Constructor),
    /// How an annotation is read as a type; `resolver.declared` holds the
    /// custom types sent as type forms.
    resolver: types.Resolver,
    /// Import alias -> module name.
    imports: Dict(String, String),
    /// Unqualified imported value -> module name.
    imported: Dict(String, String),
    /// The functions split.gleam made, and what each is made from.
    made: Dict(String, split.Made),
    /// The module's constants that are sent as functions of no parameters.
    constant_functions: List(String),
    /// The public functions that are sent as not exported: they wait only
    /// in a function they call (`split.Split`).
    unexported: List(String),
  )
}

/// A function's types, from its annotations. A parameter or a result that
/// is not annotated, or names a type the codex does not know, is a
/// `TyUnknown` that says so. `annotated` is true when every parameter and
/// the result have an annotation.
type Signature {
  Signature(params: List(Ty), result: Ty, annotated: Bool)
}

/// A constructor with its fields' labels and types. `record` is true for
/// the record idiom: the only variant of its type, with every field labelled.
type Constructor {
  Constructor(
    labels: List(Option(String)),
    record: Bool,
    /// The N3 name of the constructor's type: what a record node is named.
    type_name: String,
    /// The Gleam name of the constructor's type, and its type parameters.
    type_: String,
    params: List(String),
    /// The fields' types, by position; they may hold the type's parameters.
    fields: List(Ty),
  )
}

type Primitive {
  SelfPrimitive
  SpawnPrimitive(link: Bool)
  SendPrimitive
  LinkPrimitive
  ExitSignalPrimitive
  FailPrimitive
}

/// How a function declaration is treated.
type Kind {
  /// A function with a body: a function form.
  Plain
  /// An external to one of Erlang's process functions: no form; its calls
  /// become process nodes.
  Process(Primitive)
  /// Any other function without a Gleam body to translate: a gap form.
  Foreign(construct: String, note: String)
}

fn environment(
  module: g.Module,
  name: String,
  file: String,
  text: String,
  made: Dict(String, split.Made),
  constant_functions: List(String),
  named: List(#(g.Type, String)),
  unexported: List(String),
) -> Env {
  let kinds =
    list.map(module.functions, fn(definition) {
      #(definition.definition, kind(definition))
    })
  let functions =
    list.filter_map(kinds, fn(pair) {
      let #(function, kind) = pair
      case kind {
        Process(_) -> Error(Nil)
        Plain | Foreign(..) ->
          Ok(#(
            function.name,
            list.map(function.parameters, fn(parameter) { parameter.label }),
          ))
      }
    })
  let primitives =
    list.filter_map(kinds, fn(pair) {
      let #(function, kind) = pair
      case kind {
        Process(primitive) -> Ok(#(function.name, primitive))
        Plain | Foreign(..) -> Error(Nil)
      }
    })
  let imports =
    list.filter_map(module.imports, fn(definition) {
      let import_ = definition.definition
      case import_.alias {
        Some(g.Named(alias)) -> Ok(#(alias, import_.module))
        Some(g.Discarded(_)) -> Error(Nil)
        None -> Ok(#(basename(import_.module), import_.module))
      }
    })
  let imported =
    list.flat_map(module.imports, fn(definition) {
      let import_ = definition.definition
      list.map(import_.unqualified_values, fn(value) {
        #(option.unwrap(value.alias, value.name), import_.module)
      })
    })
  let imported_types =
    list.flat_map(module.imports, fn(definition) {
      let import_ = definition.definition
      list.map(import_.unqualified_types, fn(type_) {
        #(option.unwrap(type_.alias, type_.name), import_.module)
      })
    })
  let customs =
    list.map(module.custom_types, fn(d) { d.definition })
    |> list.sort(fn(a, b) { int.compare(a.location.start, b.location.start) })
  let with_variants = fn(custom_type: g.CustomType) {
    custom_type.variants != []
  }
  let resolver =
    settle(
      customs,
      types.Resolver(
        declared: customs
          |> list.filter(with_variants)
          |> list.map(fn(t) { t.name }),
        external: customs
          |> list.filter(fn(t) { !with_variants(t) })
          |> list.map(fn(t) { t.name }),
        unsendable: dict.new(),
        aliases: list.map(module.type_aliases, fn(d) { d.definition.name }),
        alias_types: dict.from_list(
          list.filter_map(module.type_aliases, fn(d) {
            case d.definition.parameters {
              [] -> Ok(#(d.definition.name, d.definition.aliased))
              _ -> Error(Nil)
            }
          }),
        ),
        // An external type that erlang:self/0 or erlang:spawn/1 gives, as
        // this module declares them, is a process.
        processes: list.filter_map(kinds, fn(pair) {
          case pair.1, { pair.0 }.return {
            Process(SelfPrimitive), Some(g.NamedType(name:, module: None, ..))
            | Process(SpawnPrimitive(..)),
              Some(g.NamedType(name:, module: None, ..))
            -> Ok(name)
            _, _ -> Error(Nil)
          }
        }),
        imports: dict.from_list(imports),
        imported_types: dict.from_list(imported_types),
        names: [],
      ),
    )
  // A name is known by its message type (`types.TyName`), so a message type
  // has one name in a unit, and a literal one message type; the literal is
  // an identifier (contract T9.11, T9.14b). Anything else is not read, and
  // the type `Name` of that message is then not known.
  let names =
    list.map(named, fn(pair) { #(types.resolve(pair.0, resolver), pair.1) })
  let names =
    list.filter(names, fn(pair) {
      types.closed(pair.0)
      && is_identifier(pair.1)
      && list.count(names, fn(other) { other.0 == pair.0 }) == 1
      && list.count(names, fn(other) { other.1 == pair.1 }) == 1
    })
  let resolver = types.Resolver(..resolver, names:)
  let constructors =
    list.flat_map(customs, fn(custom_type) {
      let record = is_record(custom_type)
      let type_name = names.type_name(name, custom_type.name)
      list.map(custom_type.variants, fn(variant) {
        #(
          variant.name,
          Constructor(
            labels: list.map(variant.fields, label),
            record:,
            type_name:,
            type_: custom_type.name,
            params: custom_type.parameters,
            fields: list.map(variant.fields, fn(field) {
              types.resolve(field_annotation(field), resolver)
            }),
          ),
        )
      })
    })
  let signatures =
    list.map(module.functions, fn(definition) {
      let function = definition.definition
      let params =
        list.map(function.parameters, fn(parameter) {
          case parameter.type_ {
            Some(annotation) -> types.resolve(annotation, resolver)
            None ->
              case dict.has_key(made, function.name) {
                True ->
                  TyUnknown(
                    "no call of "
                    <> split.shown(function.name)
                    <> " could be typed (the code before it is a gap, or a value it is given has no type)",
                  )
                False ->
                  TyUnknown(
                    "a parameter of "
                    <> function.name
                    <> " has no type annotation, and this codex does not infer parameter types",
                  )
              }
          }
        })
      let result = case function.return {
        Some(annotation) -> types.resolve(annotation, resolver)
        None ->
          TyUnknown(
            "the function "
            <> function.name
            <> " has no return annotation, so its result type is not known where it is called",
          )
      }
      let annotated =
        function.return != None
        && list.all(function.parameters, fn(p) { p.type_ != None })
      #(function.name, Signature(params:, result:, annotated:))
    })
  Env(
    module: name,
    file:,
    lines: line_starts(text),
    functions: dict.from_list(functions),
    signatures: dict.from_list(signatures),
    primitives: dict.from_list(primitives),
    constants: list.map(module.constants, fn(c) { c.definition.name }),
    constructors: dict.from_list(constructors),
    resolver:,
    imports: dict.from_list(imports),
    imported: dict.from_list(imported),
    made:,
    constant_functions:,
    unexported:,
  )
}

/// Takes out of `declared` every custom type that has a field whose type is
/// not known (a type of another module the codex has no entry for): such a
/// type cannot be written as a type form, and neither can a type that names
/// it. Repeats until nothing changes.
fn settle(
  customs: List(g.CustomType),
  resolver: types.Resolver,
) -> types.Resolver {
  let unsendable =
    list.filter_map(customs, fn(custom_type) {
      case list.contains(resolver.declared, custom_type.name) {
        False -> Error(Nil)
        True ->
          custom_type.variants
          |> list.flat_map(fn(variant) { variant.fields })
          |> list.find_map(fn(field) {
            types.why(types.resolve(field_annotation(field), resolver))
          })
          |> result.map(fn(why) {
            #(
              custom_type.name,
              "the type "
                <> custom_type.name
                <> " is not sent, because a field of it has no known type: "
                <> why,
            )
          })
      }
    })
  case unsendable {
    [] -> resolver
    _ ->
      settle(
        customs,
        types.Resolver(
          ..resolver,
          declared: list.filter(resolver.declared, fn(name) {
            list.key_find(unsendable, name) == Error(Nil)
          }),
          unsendable: list.fold(unsendable, resolver.unsendable, fn(acc, pair) {
            dict.insert(acc, pair.0, pair.1)
          }),
        ),
      )
  }
}

/// A registered name the output can have: a lowercase letter, then
/// lowercase letters, digits and single underscores.
fn is_identifier(text: String) -> Bool {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  case string.to_graphemes(text) {
    [] -> False
    [first, ..] as all ->
      string.contains(letters, first)
      && list.all(all, fn(c) { string.contains(letters <> "0123456789_", c) })
      && !string.contains(text, "__")
  }
}

fn field_annotation(field: g.VariantField) -> g.Type {
  case field {
    g.LabelledVariantField(item:, ..) -> item
    g.UnlabelledVariantField(item:) -> item
  }
}

fn label(field: g.VariantField) -> Option(String) {
  case field {
    g.LabelledVariantField(label:, ..) -> Some(label)
    g.UnlabelledVariantField(..) -> None
  }
}

/// The record idiom: one variant, at least one field, every field labelled.
fn is_record(custom_type: g.CustomType) -> Bool {
  case custom_type.variants {
    [g.Variant(fields: [_, ..] as fields, ..)] ->
      list.all(fields, fn(field) { label(field) != None })
    _ -> False
  }
}

fn kind(definition: g.Definition(g.Function)) -> Kind {
  let function = definition.definition
  let arity = list.length(function.parameters)
  case erlang_external(definition.attributes), function.body {
    Some(#("erlang", "self")), _ if arity == 0 -> Process(SelfPrimitive)
    Some(#("erlang", "spawn")), _ if arity == 1 ->
      Process(SpawnPrimitive(link: False))
    Some(#("erlang", "spawn_link")), _ if arity == 1 ->
      Process(SpawnPrimitive(link: True))
    Some(#("erlang", "send")), _ if arity == 2 -> Process(SendPrimitive)
    Some(#("erlang", "link")), _ if arity == 1 -> Process(LinkPrimitive)
    Some(#("erlang", "exit")), _ if arity == 2 -> Process(ExitSignalPrimitive)
    Some(#("erlang", "exit")), _ if arity == 1 -> Process(FailPrimitive)
    Some(#(module, name)), _ ->
      Foreign(
        "@external(erlang, \"" <> module <> "\", \"" <> name <> "\")",
        external_note(module, name),
      )
    None, [] -> Foreign("function without a body", out_of_scope)
    None, _ -> Plain
  }
}

/// The target of a function's `@external(erlang, "module", "function")`.
fn erlang_external(attributes: List(g.Attribute)) -> Option(#(String, String)) {
  case attributes {
    [] -> None
    [
      g.Attribute(
        "external",
        [
          g.Variable(name: "erlang", ..),
          g.String(value: module, ..),
          g.String(value: name, ..),
        ],
      ),
      ..
    ] -> Some(#(module, name))
    [_, ..rest] -> erlang_external(rest)
  }
}

fn external_note(module: String, name: String) -> String {
  let distribution_modules = [
    "rpc", "erpc", "global", "global_group", "pg", "pg2", "net_kernel",
    "net_adm", "slave", "peer", "dist_util",
  ]
  let distribution_functions = [
    "node", "nodes", "monitor_node", "disconnect_node", "is_alive", "set_cookie",
    "get_cookie", "spawn", "spawn_link", "spawn_monitor", "spawn_opt",
    "spawn_request",
  ]
  let name_functions = ["register", "unregister", "whereis", "registered"]
  case module {
    "erlang" ->
      case
        list.contains(distribution_functions, name),
        list.contains(name_functions, name)
      {
        // spawn and spawn_link reach here only with an arity that names a
        // node, a module or options: not the one-argument form.
        True, _ -> inter_node
        _, True -> registered_names
        _, _ -> foreign_code
      }
    _ ->
      case list.contains(distribution_modules, module) {
        True -> inter_node
        False -> foreign_code
      }
  }
}

// ------------------------------------------------------------ top-level forms

/// The module's forms (contract 9.3): the type forms first (T5.3, T8.14: a
/// type form comes before every form that names it), then everything else
/// in source order, then the helper functions this codex writes, then the
/// entry if the module has a public `main` with no parameters (T9.6).
fn forms(module: g.Module, env: Env) -> List(Form) {
  let line = fn(span: g.Span) { locate(env.lines, span.start).0 }
  let customs =
    list.map(module.custom_types, fn(d) { d.definition })
    |> list.sort(fn(a, b) { int.compare(a.location.start, b.location.start) })
  let type_forms =
    list.map(type_order(customs, env), fn(custom_type) {
      type_form(custom_type, line(custom_type.location), env)
    })
  // A custom type with a field of an unknown type: a gap form in its place.
  // A type with no constructors is a name for a platform type (Pid): nothing
  // to send; signatures that use it claim {t_basic, dynamic}.
  let unsendable =
    list.filter_map(customs, fn(custom_type) {
      use why <- result.map(dict.get(env.resolver.unsendable, custom_type.name))
      #(
        custom_type.location.start,
        #(
          frame.Gap(
            custom_type.name,
            env.file,
            line(custom_type.location),
            "type " <> custom_type.name,
            why <> " (T8.14)",
          ),
          [],
        ),
      )
    })
  let aliases =
    list.filter(module.type_aliases, fn(definition) {
      definition.definition.parameters != []
    })
    |> list.map(fn(definition) {
      let alias = definition.definition
      #(
        alias.location.start,
        #(
          frame.Gap(
            alias.name,
            env.file,
            line(alias.location),
            "type alias with parameters",
            out_of_scope,
          ),
          [],
        ),
      )
    })
  let constants =
    list.map(module.constants, fn(definition) {
      let constant = definition.definition
      #(
        constant.location.start,
        #(
          frame.Gap(
            constant.name,
            env.file,
            line(constant.location),
            "constant",
            out_of_scope,
          ),
          [],
        ),
      )
    })
  let functions =
    list.filter_map(module.functions, fn(definition) {
      let function = definition.definition
      let start = function.location.start
      case kind(definition) {
        Plain -> Ok(#(start, function_form(function, env)))
        Process(_) -> Error(Nil)
        Foreign(construct:, note:) ->
          Ok(#(
            start,
            #(
              frame.Gap(
                fname(env, function.name),
                env.file,
                line(function.location),
                construct,
                note,
              ),
              [],
            ),
          ))
      }
    })
  let entry =
    list.filter_map(module.functions, fn(definition) {
      case definition.definition, kind(definition) {
        g.Function(name: "main", publicity: g.Public, parameters: [], ..), Plain
        -> Ok(frame.Entry("main", 0))
        _, _ -> Error(Nil)
      }
    })
  let written =
    list.flatten([unsendable, aliases, constants, functions])
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.1 })
  // Each kind of gleam_otp actor the unit starts (a state type and a message
  // type) gets the loop function it runs, under a name of its own.
  let loops =
    written
    |> list.flat_map(fn(pair) { pair.1 })
    |> list.unique
    |> list.index_map(fn(actor, index) {
      #(
        actor,
        "gleam_otp_actor_loop" <> names.generated <> int.to_string(index + 1),
      )
    })
  let written =
    list.map(written, fn(pair) {
      case pair.0 {
        frame.Function(nodes:, ..) as form ->
          frame.Function(
            ..form,
            nodes: list.map(nodes, fn(node) {
              case node {
                frame.FunRef(name:, ..) ->
                  case
                    list.find(loops, fn(loop) { actor_key(loop.0) == name })
                  {
                    Ok(#(_, loop)) -> frame.FunRef(..node, name: loop)
                    Error(Nil) -> node
                  }
                _ -> node
              }
            }),
          )
        form -> form
      }
    })
  let helpers =
    list.map(loops, fn(loop) {
      let #(actor, name) = loop
      actor_loop_form(env, name, actor)
    })
  list.flatten([type_forms, written, helpers, entry])
}

/// The custom types that are sent, each after the types its fields name
/// (T8.14), and otherwise in source order. A type that names itself, directly
/// or through another, is still sent, truthfully: the contract says the
/// transpiler reports it (T4002).
fn type_order(customs: List(g.CustomType), env: Env) -> List(g.CustomType) {
  let sent =
    list.filter(customs, fn(t) { list.contains(env.resolver.declared, t.name) })
  let uses = fn(custom_type: g.CustomType) {
    custom_type.variants
    |> list.flat_map(fn(variant) { variant.fields })
    |> list.flat_map(fn(field) {
      named_in(types.resolve(field_annotation(field), env.resolver))
    })
  }
  let order =
    list.fold(sent, [], fn(done, custom_type) {
      type_visit(custom_type.name, sent, uses, [], done)
    })
  list.filter_map(order, fn(name) { list.find(sent, fn(t) { t.name == name }) })
}

fn type_visit(
  name: String,
  sent: List(g.CustomType),
  uses: fn(g.CustomType) -> List(String),
  visiting: List(String),
  done: List(String),
) -> List(String) {
  case
    list.contains(done, name) || list.contains(visiting, name),
    list.find(sent, fn(t) { t.name == name })
  {
    False, Ok(custom_type) -> {
      let done =
        list.fold(uses(custom_type), done, fn(done, used) {
          type_visit(used, sent, uses, [name, ..visiting], done)
        })
      list.append(done, [name])
    }
    _, _ -> done
  }
}

/// The custom types of the module a type names.
fn named_in(ty: Ty) -> List(String) {
  let inner = list.flat_map(types.parts(ty), named_in)
  case ty {
    TyNamed(name:, ..) -> [name, ..inner]
    _ -> inner
  }
}

/// A custom type as a type form (contract 8.5).
///
/// The record idiom (one variant, every field labelled) is a `t_record`.
/// Otherwise each variant with fields is a `t_tagged` named after its
/// constructor, with its fields by position, and the variants without fields
/// are one `t_symbols`; several entries are joined by a `t_union`. This
/// matches how the codex writes the values: a record node, a tuple whose first
/// element is the constructor's symbol, or a symbol. A type parameter is a
/// `t_var`, and a type of the module a `t_named` with its arguments (T8.14).
fn type_form(custom_type: g.CustomType, line: Int, env: Env) -> Form {
  let fields_of = fn(variant: g.Variant) {
    case dict.get(env.constructors, variant.name) {
      Ok(constructor) -> constructor.fields
      Error(Nil) -> []
    }
  }
  let interned = fn(all: List(Ty), table) {
    let #(indices, table) =
      list.fold(all, #([], table), fn(acc, ty) {
        let #(index, table) = types.intern(ty, acc.1, env.module)
        #([index, ..acc.0], table)
      })
    #(list.reverse(indices), table)
  }
  let #(root, table) = case is_record(custom_type), custom_type.variants {
    True, [variant] -> {
      let #(indices, table) = interned(fields_of(variant), types.new_table())
      let labels =
        list.map(variant.fields, fn(field) {
          names.ident(option.unwrap(label(field), ""))
        })
      types.add(table, frame.TRecord(list.zip(labels, indices)))
    }
    _, variants -> {
      let symbols =
        list.filter_map(variants, fn(variant) {
          case variant.fields {
            [] -> Ok(names.symbol(variant.name))
            _ -> Error(Nil)
          }
        })
      let #(alternatives, table) = case symbols {
        [] -> #([], types.new_table())
        _ -> {
          let #(index, table) =
            types.add(types.new_table(), frame.TSymbols(symbols))
          #([index], table)
        }
      }
      let #(alternatives, table) =
        list.fold(variants, #(alternatives, table), fn(acc, variant) {
          case variant.fields {
            [] -> acc
            _ -> {
              let #(elems, table) = interned(fields_of(variant), acc.1)
              let #(index, table) =
                types.add(
                  table,
                  frame.TTagged(names.symbol(variant.name), elems),
                )
              #([index, ..acc.0], table)
            }
          }
        })
      case alternatives {
        [only] -> #(only, table)
        _ -> types.add(table, frame.TUnion(list.reverse(alternatives)))
      }
    }
  }
  frame.Type(
    // N3: a type's name is qualified by its module.
    name: names.type_name(env.module, custom_type.name),
    params: custom_type.parameters,
    exported: custom_type.publicity == g.Public,
    file: env.file,
    at_line: line,
    types: types.entries(table),
    root:,
  )
}

/// A function as a function form, with the kinds of actor it starts.
///
/// T8.10 (a): the form needs a signature hint (node -1, a `t_fun`). The
/// parameters' types are their annotations; the result's is its annotation,
/// or, without one, the type the codex works out for the body. The hint is
/// `proven` only when all of it is annotation. A function whose parameters
/// are not annotated, or whose types the codex does not know, is sent whole
/// as a gap form that says which type is missing.
fn function_form(function: g.Function, env: Env) -> #(Form, List(Actor)) {
  let #(form, actors, _) = function_written(function, env)
  #(form, actors)
}

/// The form, the kinds of actor it starts, and its calls of the functions
/// the split made, each with the types of its arguments (`settle_made`).
fn function_written(
  function: g.Function,
  env: Env,
) -> #(Form, List(Actor), List(#(String, List(Ty)))) {
  let at = function.location
  let arity = list.length(function.parameters)
  let signature =
    result.unwrap(
      dict.get(env.signatures, function.name),
      Signature([], any, False),
    )
  // What split.gleam made is this sender's own: nothing of it is `proven`.
  let is_made = dict.has_key(env.made, function.name)
  let written_as = case is_made {
    True -> Inferred
    False -> Proven
  }
  let construct = case dict.get(env.made, function.name) {
    Ok(made) -> made.what
    Error(Nil) -> "function " <> function.name <> "/" <> int.to_string(arity)
  }
  let no_signature = fn(why: String) {
    #(
      frame.Gap(
        fname(env, function.name),
        env.file,
        locate(env.lines, at.start).0,
        construct,
        why <> ", so the function has no signature (T8.10 a)",
      ),
      [],
      [],
    )
  }
  case list.find(signature.params, fn(ty) { !types.stateable(ty) }) {
    Ok(missing) -> no_signature(types.reason(missing))
    Error(Nil) -> {
      let builder = new_builder(env)
      // Gleam has one clause for each function: its patterns are the
      // parameters.
      let typed_parameters = list.zip(function.parameters, signature.params)
      let #(parameters, builder) =
        each(typed_parameters, builder, fn(pair, builder) {
          parameter_node({ pair.0 }.name, at, pair.1, written_as, builder)
        })
      let scope =
        list.filter_map(typed_parameters, fn(pair) {
          result.map(assigned_name({ pair.0 }.name), fn(name) {
            #(name, pair.1)
          })
        })
      let #(body, builder) =
        body(at, function.body, scope, signature.result, builder)
      let result_type = case types.stateable(signature.result) {
        True -> signature.result
        False -> ty_of(builder, body)
      }
      case types.stateable(result_type) {
        False ->
          no_signature(
            "the result of "
            <> function.name
            <> " has no usable annotation and this codex cannot work its type out: "
            <> types.reason(result_type),
          )
        True -> {
          let #(clause, builder) =
            emit(builder, at, frame.Clause(_, parameters, -1, body))
          let strength = case signature.annotated && !is_made {
            True -> Proven
            False -> Inferred
          }
          let #(table, hints) =
            hint_table(builder, TyFn(signature.params, result_type), strength)
          #(
            frame.Function(
              name: fname(env, function.name),
              arity:,
              exported: function.publicity == g.Public
                && !list.contains(env.unexported, function.name),
              file: env.file,
              locations: list.reverse(builder.locations),
              nodes: list.reverse(builder.nodes),
              clauses: [clause],
              types: table,
              hints:,
              overrides: list.reverse(builder.overrides),
            ),
            list.reverse(builder.actors),
            builder.calls,
          )
        }
      }
    }
  }
}

// ------------------------------------------------------------ node tables, and their types

/// The local variables in sight, newest first, with their types.
type Scope =
  List(#(String, Ty))

fn local(scope: Scope, name: String) -> Bool {
  list.key_find(scope, name) != Error(Nil)
}

/// A kind of gleam_otp actor a unit starts: its state and message types and
/// the function of the module that handles its messages ("": none given).
type Actor {
  Actor(state: Ty, message: Ty, handler: String)
}

/// A node table being written (contract 9.1), with what the typing pass
/// knows about it. Nodes and locations are kept newest first.
type Builder {
  Builder(
    env: Env,
    nodes: List(Node),
    locations: List(#(Int, Int)),
    next: Int,
    /// The type of each expression node, as far as the codex knows it.
    tys: Dict(Int, Ty),
    /// The hints of the form (T8.5): node -> its stated type.
    hints: Dict(Int, #(Ty, Strength)),
    /// The variables bound by the pattern being written, newest first.
    bound: Scope,
    /// The last pattern that could not be sent or typed: the construct and
    /// the note of the gap its `let` or `case` becomes.
    trouble: Option(#(String, String)),
    /// The kinds of gleam_otp actor the form starts.
    actors: List(Actor),
    /// The form's overrides of the session's choices (T7.6), newest first.
    overrides: List(frame.Override),
    /// The calls of functions the split made, with their arguments' types.
    calls: List(#(String, List(Ty))),
    /// Inside a receive: what the variable `_received` of split.gleam stands
    /// for ("message", "ok" or "error"), the type of that value, and how
    /// the message that was taken is written.
    received: Option(#(String, Ty, fn(Builder) -> #(Int, Builder))),
  )
}

fn new_builder(env: Env) -> Builder {
  Builder(
    env:,
    nodes: [],
    locations: [],
    next: 0,
    tys: dict.new(),
    hints: dict.new(),
    bound: [],
    trouble: None,
    actors: [],
    overrides: [],
    calls: [],
    received: None,
  )
}

/// Appends one node. Every node gets its own location entry, so a node's `at`
/// equals its index (T9.3). A node is appended after its children (T9.2).
fn emit(
  builder: Builder,
  span: g.Span,
  node: fn(Int) -> Node,
) -> #(Int, Builder) {
  let index = builder.next
  #(
    index,
    Builder(
      ..builder,
      nodes: [node(index), ..builder.nodes],
      locations: [locate(builder.env.lines, span.start), ..builder.locations],
      next: index + 1,
    ),
  )
}

/// H40: a construct this codex does not translate (T9.10). Its type is not
/// known, for the gap's own reason.
fn gap(
  builder: Builder,
  span: g.Span,
  construct: String,
  note: String,
) -> #(Int, Builder) {
  let #(index, builder) = emit(builder, span, frame.GapNode(_, construct, note))
  #(
    index,
    Builder(
      ..builder,
      tys: dict.insert(
        builder.tys,
        index,
        TyUnknown(construct <> " is a gap (" <> note <> ")"),
      ),
    ),
  )
}

/// The type the codex has worked out for a node.
fn ty_of(builder: Builder, index: Int) -> Ty {
  result.unwrap(dict.get(builder.tys, index), any)
}

fn node_at(builder: Builder, index: Int) -> Result(Node, Nil) {
  list.first(list.drop(builder.nodes, builder.next - 1 - index))
}

/// Records the type of the node just written, and states it with an
/// `inferred` hint (T8.5) when it can be stated. This is how a new mapping
/// states a type: `typed(emit(builder, at, frame.Call(…)), the_type)`.
fn typed(written: #(Int, Builder), ty: Ty) -> #(Int, Builder) {
  #(written.0, set(written.1, written.0, ty, Inferred))
}

/// `typed` for a type that is literally an annotation of the source.
fn typed_as(
  written: #(Int, Builder),
  ty: Ty,
  strength: Strength,
) -> #(Int, Builder) {
  #(written.0, set(written.1, written.0, ty, strength))
}

/// Sets a node's type, and its hint if the node is of a kind that needs one.
/// The kinds T8.9 fixes by themselves get none: literals, a variable used as
/// a value (its binding is hinted), operators, and clauses; `fail` has no
/// value.
fn set(builder: Builder, index: Int, ty: Ty, strength: Strength) -> Builder {
  let builder = Builder(..builder, tys: dict.insert(builder.tys, index, ty))
  let fixed = case node_at(builder, index) {
    Ok(frame.Int(..))
    | Ok(frame.Float(..))
    | Ok(frame.Text(..))
    | Ok(frame.Boolean(..))
    | Ok(frame.Var(..))
    | Ok(frame.Wild(..))
    | Ok(frame.Clause(..))
    | Ok(frame.Op(..))
    | Ok(frame.SlCall(..))
    | Ok(frame.Fail(..))
    | Error(Nil) -> True
    Ok(_) -> False
  }
  case fixed {
    True -> builder
    False -> hint(builder, index, ty, strength)
  }
}

/// States the type of a node, whatever its kind, if the type can be stated.
fn hint(builder: Builder, index: Int, ty: Ty, strength: Strength) -> Builder {
  case types.stateable(ty) {
    True ->
      Builder(
        ..builder,
        hints: dict.insert(builder.hints, index, #(ty, strength)),
      )
    False -> builder
  }
}

/// A node whose own type is not known takes the type its place gives it:
/// an annotation, the parameter it is passed for, the operator it is an
/// operand of. That is a statement of the language side, not a guess: in
/// source the Gleam compiler has checked, the place's type is the value's.
fn adopt(written: #(Int, Builder), expected: Ty) -> #(Int, Builder) {
  let #(index, builder) = written
  let own = ty_of(builder, index)
  case types.stateable(own) || own == TyNever, types.stateable(expected) {
    False, True -> #(index, set(builder, index, expected, Inferred))
    _, _ -> written
  }
}

/// The form's type table and hints (contract 8.4, 8.5): the signature
/// first (node -1), then the hints in node order. Each type is written once.
fn hint_table(
  builder: Builder,
  signature: Ty,
  strength: Strength,
) -> #(List(frame.TypeNode), List(frame.Hint)) {
  let module = builder.env.module
  let #(index, table) = types.intern(signature, types.new_table(), module)
  let #(hints, table) =
    dict.to_list(builder.hints)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.fold(#([], table), fn(acc, entry) {
      let #(node, #(ty, strength)) = entry
      let #(index, table) = types.intern(ty, acc.1, module)
      #([frame.Hint(node:, type_: index, strength:), ..acc.0], table)
    })
  #(types.entries(table), [
    frame.Hint(node: -1, type_: index, strength:),
    ..list.reverse(hints)
  ])
}

/// Maps each item to a node, in order.
fn each(
  items: List(a),
  builder: Builder,
  one: fn(a, Builder) -> #(Int, Builder),
) -> #(List(Int), Builder) {
  let #(indices, builder) =
    list.fold(items, #([], builder), fn(acc, item) {
      let #(index, builder) = one(item, acc.1)
      #([index, ..acc.0], builder)
    })
  #(list.reverse(indices), builder)
}

/// A parameter of a function or a closure: a variable with its type stated
/// (T8.10 b), or a wildcard.
fn parameter_node(
  name: g.AssignmentName,
  at: g.Span,
  ty: Ty,
  strength: Strength,
  builder: Builder,
) -> #(Int, Builder) {
  case name {
    g.Named(name) -> {
      let #(index, builder) = emit(builder, at, frame.Var(_, names.ident(name)))
      #(index, hint(builder, index, ty, strength))
    }
    g.Discarded(_) -> emit(builder, at, frame.Wild)
  }
}

fn assigned_name(name: g.AssignmentName) -> Result(String, Nil) {
  case name {
    g.Named(name) -> Ok(name)
    g.Discarded(_) -> Error(Nil)
  }
}

/// What a gap that stands for an expression is called.
fn describe(e: g.Expression) -> String {
  let arity = fn(arguments) { "/" <> int.to_string(list.length(arguments)) }
  case e {
    g.Call(function: g.Variable(name:, ..), arguments:, ..) ->
      name <> arity(arguments)
    g.Call(
      function: g.FieldAccess(container: g.Variable(name:, ..), label:, ..),
      arguments:,
      ..,
    ) -> name <> "." <> label <> arity(arguments)
    g.Call(..) -> "call"
    g.Variable(name:, ..) -> name
    g.Case(..) -> "case"
    g.Block(..) -> "block"
    g.Fn(..) | g.FnCapture(..) -> "anonymous function"
    g.BinaryOperator(name: g.Pipe, right:, ..) ->
      "pipe into " <> describe(right)
    g.BinaryOperator(..) -> "operator"
    g.Tuple(..) -> "tuple"
    g.FieldAccess(label:, ..) -> "." <> label
    _ -> "expression"
  }
}

// ------------------------------------------------------------ statements

/// A function body or a block. One expression is itself; anything else is a
/// block node (H19). `scope` holds the local variables in sight; `expected`
/// is the type the place gives the value (the function's result).
fn body(
  at: g.Span,
  statements: List(g.Statement),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  case statements {
    [] -> gap(builder, at, "empty body", out_of_scope)
    [g.Expression(expression)] -> expr(expression, scope, expected, builder)
    _ -> {
      let #(indices, builder) =
        sequence(statements, scope, expected, builder, [])
      let last = case list.last(indices) {
        Ok(last) -> ty_of(builder, last)
        Error(Nil) -> any
      }
      adopt(typed(emit(builder, at, frame.Block(_, indices)), last), expected)
    }
  }
}

/// The statements of a block, in order.
///
/// T8.10 (e) wants a type for every expression of a block but the last, and
/// (b) one for every variable a `let` binds. A statement that has none is a
/// gap, and a gap **ends its block**: the program never gets past it, so the
/// statements after it are not sent (they could only name variables that
/// have no binding). The same holds for a statement that is a gap for any
/// other reason, and for one that always fails (`panic`).
fn sequence(
  statements: List(g.Statement),
  scope: Scope,
  expected: Ty,
  builder: Builder,
  done: List(Int),
) -> #(List(Int), Builder) {
  let last = fn(written: #(Int, Builder)) {
    #(list.reverse([written.0, ..done]), written.1)
  }
  case statements {
    [] -> #(list.reverse(done), builder)
    // `use` turns the rest of its block into a callback: one gap for all of it.
    [g.Use(location:, ..), ..] ->
      last(gap(
        builder,
        location,
        "use, with the rest of its block",
        out_of_scope,
      ))
    [g.Expression(expression)] ->
      last(expr(expression, scope, expected, builder))
    [g.Expression(expression), ..rest] -> {
      let #(index, written) =
        send_statement(expr(expression, scope, any, builder))
      let ty = ty_of(written, index)
      case types.stateable(ty), node_at(written, index) {
        True, _ -> sequence(rest, scope, expected, written, [index, ..done])
        False, Ok(frame.GapNode(..)) | False, Ok(frame.Fail(..)) ->
          last(#(index, written))
        False, _ ->
          last(gap(
            builder,
            expression.location,
            describe(expression),
            types.reason(ty)
              <> ", so this statement, whose value is dropped, has no type (T8.10 d, e)",
          ))
      }
    }
    // `let assert pattern = value` is H18 exactly: "a mismatch fails the
    // actor". With `as message` the failure carries the programmer's reason,
    // which a match node cannot hold: a gap.
    [g.Assignment(location:, kind: g.LetAssert(Some(_)), ..), ..] ->
      last(gap(
        builder,
        location,
        "let assert ... as message",
        "a match node (H18) has no failure reason",
      ))
    [g.Assignment(location:, pattern: p, annotation:, value:, ..), ..rest] ->
      case let_(location, p, annotation, value, scope, builder) {
        Ok(#(index, builder, bound)) ->
          sequence(rest, list.append(bound, scope), expected, builder, [
            index,
            ..done
          ])
        Error(written) -> last(written)
      }
    [g.Assert(location:, ..), ..] ->
      last(gap(builder, location, "assert", out_of_scope))
  }
}

/// A send whose value is dropped. `send` writes Gleam's send as the block
/// `{ send, nil }` (contract H22: the value of the node is the message, the
/// value of Gleam's call is Nil). As a statement of a block that is not its
/// last, the send stands there itself: the two nodes written after it (the
/// `nil` and the block) are taken off the table again.
fn send_statement(written: #(Int, Builder)) -> #(Int, Builder) {
  let #(index, builder) = written
  let is_last = index == builder.next - 1
  case
    is_last,
    node_at(builder, index),
    node_at(builder, index - 1),
    node_at(builder, index - 2)
  {
    True,
      Ok(frame.Block(_, [sent, nil])),
      Ok(frame.Symbol(_, "nil")),
      Ok(frame.Send(..))
    | True,
      Ok(frame.Block(_, [sent, nil])),
      Ok(frame.Symbol(_, "nil")),
      Ok(frame.SendNamed(..))
      if sent == index - 2 && nil == index - 1
    -> #(
      sent,
      Builder(
        ..builder,
        nodes: list.drop(builder.nodes, 2),
        locations: list.drop(builder.locations, 2),
        next: builder.next - 2,
        tys: dict.drop(builder.tys, [index, nil]),
        hints: dict.drop(builder.hints, [index, nil]),
      ),
    )
    _, _, _, _ -> written
  }
}

/// H18: `let pattern = value`. The value is written first, in the scope
/// before the binding, then the pattern, whose variables take their types
/// from the value's type, position by position (T8.10 b).
///
/// The value's type is the let's annotation (`proven`), or else the type the
/// codex works out for the value. `Error` is the gap the statement becomes
/// when there is no type, or when the pattern cannot be sent.
fn let_(
  at: g.Span,
  p: g.Pattern,
  annotation: Option(g.Type),
  value: g.Expression,
  scope: Scope,
  builder: Builder,
) -> Result(#(Int, Builder, Scope), #(Int, Builder)) {
  let start = builder
  let #(declared, strength) = case annotation {
    Some(annotation) -> #(
      types.resolve(annotation, builder.env.resolver),
      Proven,
    )
    None -> #(any, Inferred)
  }
  // `let s: Subject(M) = process.named_subject(name)` binds a named
  // subject: the annotation is Gleam's type for it, and the binding keeps
  // what this codex knows (`types.TyNamedSubject`).
  let wanted = case declared {
    TySubject(..) -> any
    _ -> declared
  }
  let #(right, builder) = expr(value, scope, wanted, builder)
  let #(ty, builder) = case types.stateable(declared), ty_of(builder, right) {
    _, TyNamedSubject(..) as named -> #(named, builder)
    True, _ -> #(declared, set(builder, right, declared, Proven))
    False, own -> #(own, builder)
  }
  case types.stateable(ty) {
    False -> {
      let consequence = case pattern_names(p) {
        [] -> "the value of this let has no type (T8.10 e)"
        [name] -> "the binding " <> name <> " has no type (T8.10 b)"
        bound ->
          "the bindings "
          <> string.join(bound, ", ")
          <> " have no type (T8.10 b)"
      }
      Error(gap(
        start,
        at,
        describe(value),
        types.reason(ty) <> ", so " <> consequence,
      ))
    }
    True -> {
      let #(left, builder) =
        pattern(p, ty, strength, Builder(..builder, bound: []))
      case builder.trouble == start.trouble, builder.trouble {
        False, Some(#(construct, note)) ->
          Error(gap(start, at, construct, note))
        _, _ -> {
          let bound = builder.bound
          let #(index, builder) =
            typed_as(
              emit(builder, at, frame.Match(_, left, right)),
              ty,
              strength,
            )
          Ok(#(index, builder, bound))
        }
      }
    }
  }
}

// ------------------------------------------------------------ patterns

/// Patterns use the same nodes as expressions (contract 9.4). `ty` is the
/// type of the value the pattern is matched with; every variable the pattern
/// binds gets its part of that type as a hint (T8.10 b) and is added to
/// `builder.bound`. A pattern that cannot be sent, or a variable with no
/// type, is noted in `builder.trouble`: the `let` or `case` it belongs to
/// then becomes one gap.
fn pattern(
  p: g.Pattern,
  ty: Ty,
  strength: Strength,
  builder: Builder,
) -> #(Int, Builder) {
  case p {
    g.PatternInt(location:, value:) -> int_literal(location, value, builder)
    g.PatternFloat(location:, value:) ->
      emit(builder, location, frame.Float(_, float_text(value)))
    g.PatternString(location:, value:) -> text_literal(location, value, builder)
    g.PatternDiscard(location:, ..) -> emit(builder, location, frame.Wild)
    g.PatternVariable(location:, name:) ->
      binding(builder, location, name, ty, strength)
    g.PatternTuple(location:, elements:) -> {
      let element_types = case ty {
        TyTuple(elems:) -> elems
        _ -> []
      }
      let element_types = case
        list.length(element_types) == list.length(elements)
      {
        True -> element_types
        False -> list.repeat(not_taken_apart(ty), list.length(elements))
      }
      let #(elements, builder) =
        each(list.zip(elements, element_types), builder, fn(pair, builder) {
          pattern(pair.0, pair.1, Inferred, builder)
        })
      emit(builder, location, frame.Tuple(_, elements))
    }
    g.PatternVariant(location:, module:, constructor:, arguments:, with_spread:) ->
      variant_pattern(
        location,
        module,
        constructor,
        list.map(arguments, pattern_field),
        with_spread,
        ty,
        builder,
      )
    // H7, H10: `[]`, `[a, b]`, `[first, ..rest]`, `[first, ..]`.
    g.PatternList(location:, elements:, tail:) ->
      case ty, elements, tail {
        TyList(..), [], None -> emit(builder, location, frame.EmptyList)
        TyList(elem:), _, _ -> {
          let #(elements, builder) =
            each(elements, builder, fn(element, builder) {
              pattern(element, elem, Inferred, builder)
            })
          let #(tail, builder) = case tail {
            Some(tail) -> pattern(tail, ty, Inferred, builder)
            None -> #(-1, builder)
          }
          let #(index, builder) =
            emit(builder, location, frame.ListOf(_, elements, tail))
          #(index, hint(builder, index, ty, Inferred))
        }
        _, _, _ ->
          trouble(
            builder,
            location,
            "list pattern",
            types.reason(not_taken_apart(ty))
              <> ", so the list this pattern takes apart has no type (T8.10 b)",
          )
      }
    // `pattern as name`: a match node in a pattern position, both sides
    // read as patterns (contract 9.4: a node is a pattern or an expression
    // by where it is referenced; H18). The contract does not say this in so
    // many words: it is this sender's reading, shared with the Erlang and
    // Elixir senders.
    g.PatternAssignment(location:, pattern: inner, name:) -> {
      let #(alias, builder) = binding(builder, location, name, ty, strength)
      let #(inner, builder) = pattern(inner, ty, Inferred, builder)
      emit(builder, location, frame.Match(_, alias, inner))
    }
    g.PatternConcatenate(location:, ..) ->
      trouble(builder, location, "string prefix pattern", out_of_scope)
    g.PatternBitString(location:, ..) ->
      trouble(builder, location, "bit array pattern", out_of_scope)
  }
}

/// The type of a part of a value whose type the codex cannot take apart.
fn not_taken_apart(ty: Ty) -> Ty {
  case types.stateable(ty) {
    False -> ty
    True ->
      TyUnknown(
        "this codex cannot take the type of the matched value apart at this pattern",
      )
  }
}

/// A variable in a pattern: a binding, with its type stated (T8.10 b).
fn binding(
  builder: Builder,
  at: g.Span,
  name: String,
  ty: Ty,
  strength: Strength,
) -> #(Int, Builder) {
  let #(index, builder) = emit(builder, at, frame.Var(_, names.ident(name)))
  let builder = Builder(..builder, bound: [#(name, ty), ..builder.bound])
  case types.stateable(ty) {
    True -> #(index, hint(builder, index, ty, strength))
    False -> #(
      index,
      Builder(
        ..builder,
        trouble: Some(#(
          "variable " <> name,
          types.reason(ty)
            <> ", so the binding "
            <> name
            <> " has no type (T8.10 b)",
        )),
      ),
    )
  }
}

/// A pattern that is not sent. The gap node written here is thrown away
/// with the rest of its `let` or `case`, which becomes the gap.
fn trouble(
  builder: Builder,
  at: g.Span,
  construct: String,
  note: String,
) -> #(Int, Builder) {
  let #(index, builder) = gap(builder, at, construct, note)
  #(index, Builder(..builder, trouble: Some(#(construct, note))))
}

fn variant_pattern(
  at: g.Span,
  module: Option(String),
  name: String,
  arguments: List(#(Option(String), g.Pattern)),
  with_spread: Bool,
  ty: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let known = case module {
    None -> dict.get(builder.env.constructors, name)
    Some(alias) -> library_constructor(alias, name, builder.env)
  }
  let inner = fn(pair: #(g.Pattern, Ty), builder) {
    pattern(pair.0, pair.1, Inferred, builder)
  }
  case name, arguments, known {
    "True", [], _ -> emit(builder, at, frame.Boolean(_, True))
    "False", [], _ -> emit(builder, at, frame.Boolean(_, False))
    // The record idiom: the fields the pattern names (H12).
    _, _, Ok(Constructor(labels:, record: True, type_name:, ..) as constructor)
    ->
      case named(labels, arguments) {
        Ok(fields) -> {
          let by_label = list.zip(labels, field_types(constructor, ty))
          let #(indices, builder) =
            each(fields, builder, fn(field, builder) {
              let field_type =
                result.unwrap(list.key_find(by_label, Some(field.0)), any)
              pattern(field.1, field_type, Inferred, builder)
            })
          let fields =
            list.map2(fields, indices, fn(field, index) {
              #(names.ident(field.0), index)
            })
          emit(builder, at, frame.Record(_, type_name, fields, -1))
        }
        Error(Nil) ->
          trouble(builder, at, "pattern " <> name, "its fields cannot be named")
      }
    // A constructor without fields is its symbol (H5).
    _, [], Ok(Constructor(labels: [], ..)) | _, [], Error(Nil) ->
      emit(builder, at, frame.Symbol(_, names.symbol(name)))
    // A variant with fields: a tuple, the constructor's symbol first. Fields
    // the pattern leaves to `..` are wildcards.
    _, _, Ok(Constructor(labels:, record: False, ..) as constructor) -> {
      let #(tag, builder) =
        emit(builder, at, frame.Symbol(_, names.symbol(name)))
      let positions =
        list.zip(by_position(labels, arguments), field_types(constructor, ty))
      let #(elements, builder) =
        each(positions, builder, fn(position, builder) {
          case position {
            #(Some(p), field_type) -> inner(#(p, field_type), builder)
            #(None, _) -> emit(builder, at, frame.Wild)
          }
        })
      emit(builder, at, frame.Tuple(_, [tag, ..elements]))
    }
    // A constructor of another module: its fields are known only by
    // position, and their types only for the prelude's Ok and Error.
    _, _, Error(Nil) ->
      case with_spread, positional(arguments) {
        False, Ok(patterns) -> {
          let field_types = case name, module, ty {
            "Ok", None, TyResult(ok:, ..) -> [ok]
            "Error", None, TyResult(error:, ..) -> [error]
            _, _, _ ->
              list.repeat(
                case types.stateable(ty) {
                  False -> ty
                  True ->
                    TyUnknown(
                      "the types of the fields of "
                      <> name
                      <> ", a constructor of another module, are not known to this codex",
                    )
                },
                list.length(patterns),
              )
          }
          let #(tag, builder) =
            emit(builder, at, frame.Symbol(_, names.symbol(name)))
          let #(elements, builder) =
            each(list.zip(patterns, field_types), builder, inner)
          emit(builder, at, frame.Tuple(_, [tag, ..elements]))
        }
        _, _ ->
          trouble(
            builder,
            at,
            "pattern " <> name,
            "a constructor of another module with labels or a spread",
          )
      }
  }
}

/// The types of a constructor's fields, by position, in a value of type
/// `value`: the declared field types, with the type's parameters replaced by
/// the arguments `value` gives them.
fn field_types(constructor: Constructor, value: Ty) -> List(Ty) {
  let bound = case value {
    TyNamed(name:, args:) if name == constructor.type_ ->
      list.zip(constructor.params, args)
    TyStarted(data:) if constructor.type_ == started_type -> [#("data", data)]
    _ -> []
  }
  let bound = dict.from_list(bound)
  list.map(constructor.fields, fn(field) {
    types.fill(field, bound, fn(variable) {
      "the type parameter "
      <> variable
      <> " of "
      <> constructor.type_
      <> " is not known here"
    })
  })
}

/// The type of a value built with a constructor of the module: its type,
/// with each type parameter taken from the arguments' types, or else from
/// the type the place expects.
fn constructed(
  constructor: Constructor,
  arguments: List(Ty),
  expected: Ty,
  env: Env,
) -> Ty {
  case
    list.contains(env.resolver.declared, constructor.type_),
    dict.get(env.resolver.unsendable, constructor.type_)
  {
    False, Ok(why) -> TyUnknown(why)
    False, Error(Nil) ->
      TyUnknown("the type " <> constructor.type_ <> " is not sent")
    True, _ -> {
      let bound =
        list.zip(constructor.fields, arguments)
        |> list.fold(dict.new(), fn(bound, pair) {
          types.bind(pair.0, pair.1, bound)
        })
      let bound = case expected {
        TyNamed(name:, args:) if name == constructor.type_ ->
          list.zip(constructor.params, args)
          |> list.fold(bound, fn(bound, pair) {
            types.bind(TyVar(pair.0), pair.1, bound)
          })
        _ -> bound
      }
      TyNamed(
        constructor.type_,
        list.map(constructor.params, fn(parameter) {
          types.fill(TyVar(parameter), bound, fn(variable) {
            "the type parameter "
            <> variable
            <> " of "
            <> constructor.type_
            <> " is not fixed by this constructor's arguments"
          })
        }),
      )
    }
  }
}

/// The variables a pattern binds, gaps included.
fn pattern_names(p: g.Pattern) -> List(String) {
  case p {
    g.PatternVariable(name:, ..) -> [name]
    g.PatternTuple(elements:, ..) -> list.flat_map(elements, pattern_names)
    g.PatternAssignment(pattern: inner, name:, ..) -> [
      name,
      ..pattern_names(inner)
    ]
    g.PatternList(elements:, tail:, ..) ->
      list.flat_map(list.append(elements, option.values([tail])), pattern_names)
    g.PatternConcatenate(prefix_name:, rest_name:, ..) ->
      option.values([prefix_name, Some(rest_name)])
      |> list.filter_map(assigned_name)
    g.PatternBitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) { pattern_names(segment.0) })
    g.PatternVariant(arguments:, ..) ->
      list.flat_map(arguments, fn(argument) {
        pattern_names(pattern_field(argument).1)
      })
    g.PatternInt(..)
    | g.PatternFloat(..)
    | g.PatternString(..)
    | g.PatternDiscard(..) -> []
  }
}

// ------------------------------------------------------------ expressions

/// An expression as nodes. `expected` is the type its place gives it (`any`
/// when the place says nothing); the node's own type wins when the codex
/// can work it out, and the place's type is taken otherwise (`adopt`).
fn expr(
  e: g.Expression,
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let written = adopt(expression(e, scope, expected, builder), expected)
  // A named subject is no process (`types.TyNamedSubject`): it cannot stand
  // where a subject is passed on as a value.
  case expected, ty_of(written.1, written.0) {
    TySubject(..), TyNamedSubject(..) ->
      adopt(
        gap(
          builder,
          e.location,
          "a named subject as a value",
          "the value of process.named_subject is used where a Subject is expected (an argument, a result, a field), and no node gives the process that is registered under a name: a send to a name is written where the send stands (contract T9.14c). Pass the Name, and write process.send(process.named_subject(name), message) where the message is sent",
        ),
        expected,
      )
    _, _ -> written
  }
}

fn expression(
  e: g.Expression,
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  case e {
    // --- literals and data (H1..H13). A literal's type is fixed (T8.9).
    g.Int(location:, value:) ->
      typed(int_literal(location, value, builder), TyInt)
    g.Float(location:, value:) ->
      typed(emit(builder, location, frame.Float(_, float_text(value))), TyFloat)
    g.String(location:, value:) ->
      typed(text_literal(location, value, builder), TyString)
    g.Tuple(location:, elements:) -> {
      let wanted = case expected {
        TyTuple(elems:) -> elems
        _ -> []
      }
      let #(elements, builder) = exprs(elements, scope, wanted, builder)
      let element_types = list.map(elements, ty_of(builder, _))
      typed(
        emit(builder, location, frame.Tuple(_, elements)),
        TyTuple(element_types),
      )
    }
    g.RecordUpdate(location:, module:, constructor:, record:, fields:) ->
      record_update(
        location,
        module,
        constructor,
        record,
        fields,
        scope,
        expected,
        builder,
      )
    g.FieldAccess(location:, container:, label:) ->
      field_access(location, container, label, scope, builder)
    // --- names, matching and control (H16..H19, H28..H36)
    g.Variable(location:, name:) ->
      variable(location, name, scope, expected, builder)
    g.Block(location:, statements:) ->
      body(location, statements, scope, expected, builder)
    g.Case(location:, subjects:, clauses:) ->
      case_(location, subjects, clauses, scope, expected, builder)
    g.Fn(location:, arguments:, return_annotation:, body: statements) ->
      lambda(
        location,
        arguments,
        return_annotation,
        statements,
        scope,
        expected,
        builder,
      )
    // `f(1, _)` is `fn(x) { f(1, x) }`; the name cannot clash with a Gleam
    // variable, which never starts with an underscore. The parameter's type
    // is the type the function declares at the hole.
    g.FnCapture(
      location:,
      label:,
      function:,
      arguments_before:,
      arguments_after:,
    ) -> {
      let hole = argument(label, location, g.Variable(location, "_capture"))
      let call =
        g.Call(
          location,
          function,
          list.flatten([arguments_before, [hole], arguments_after]),
        )
      let declared = case function {
        g.Variable(name:, ..) ->
          case local(scope, name), dict.get(builder.env.signatures, name) {
            False, Ok(Signature(params:, result:, ..)) ->
              case list.drop(params, list.length(arguments_before)) {
                [parameter, ..] -> TyFn([parameter], result)
                [] -> any
              }
            _, _ -> any
          }
        _ -> any
      }
      let expected = case types.closed(declared) {
        True -> declared
        False -> expected
      }
      let parameter = g.FnParameter(g.Named("_capture"), None)
      lambda(
        location,
        [parameter],
        None,
        [g.Expression(call)],
        scope,
        expected,
        builder,
      )
    }
    g.Call(location:, function:, arguments:) ->
      call(
        location,
        function,
        list.map(arguments, expr_field),
        scope,
        expected,
        builder,
      )
    // --- operators (Appendix B). Gleam's unary minus is Int's.
    g.NegateInt(location:, value:) -> {
      let #(value, builder) = expr(value, scope, TyInt, builder)
      typed(emit(builder, location, frame.Op(_, "neg", [value])), TyInt)
    }
    g.NegateBool(location:, value:) -> {
      let #(value, builder) = expr(value, scope, TyBool, builder)
      typed(emit(builder, location, frame.Op(_, "not", [value])), TyBool)
    }
    // `a |> f(b)` is `f(a, b)`.
    g.BinaryOperator(location:, name: g.Pipe, left:, right:) ->
      expression(pipe(location, left, right), scope, expected, builder)
    g.BinaryOperator(location:, name:, left:, right:) ->
      binary(location, name, left, right, scope, builder)
    // --- failure (H26)
    g.Panic(location:, message:) -> {
      let #(reason, builder) = case message {
        Some(message) -> expr(message, scope, TyString, builder)
        None -> emit(builder, location, frame.Text(_, "panic"))
      }
      typed(emit(builder, location, frame.Fail(_, reason)), TyNever)
    }
    // --- everything else is outside the proof of concept
    // H7, H10: a list. Its type is the list of its first element's type,
    // or the one its place gives.
    g.List(location:, elements:, rest:) -> {
      let wanted = case expected {
        TyList(elem:) -> elem
        _ -> any
      }
      let #(elements, builder) =
        exprs(elements, scope, list.map(elements, fn(_) { wanted }), builder)
      let element_type = case types.stateable(wanted), elements {
        True, _ -> wanted
        False, [first, ..] -> ty_of(builder, first)
        False, [] -> wanted
      }
      let #(tail, builder) = case rest {
        Some(rest) -> expr(rest, scope, TyList(element_type), builder)
        None -> #(-1, builder)
      }
      let ty = case types.stateable(element_type), rest {
        False, Some(_) -> ty_of(builder, tail)
        _, _ -> TyList(element_type)
      }
      case elements, rest {
        [], None -> typed(emit(builder, location, frame.EmptyList), ty)
        _, _ ->
          typed(emit(builder, location, frame.ListOf(_, elements, tail)), ty)
      }
    }
    g.BitString(location:, ..) ->
      gap(builder, location, "bit array", out_of_scope)
    g.TupleIndex(location:, ..) ->
      gap(builder, location, "tuple index", out_of_scope)
    g.Todo(location:, ..) -> gap(builder, location, "todo", out_of_scope)
    g.Echo(location:, ..) -> gap(builder, location, "echo", out_of_scope)
  }
}

/// Several expressions in order; `expectations` gives the type each one's
/// place states, as far as it goes.
fn exprs(
  all: List(g.Expression),
  scope: Scope,
  expectations: List(Ty),
  builder: Builder,
) -> #(List(Int), Builder) {
  let expectations =
    list.append(expectations, list.repeat(any, list.length(all)))
  each(list.zip(all, expectations), builder, fn(pair, builder) {
    expr(pair.0, scope, pair.1, builder)
  })
}

/// What the parameters of a called function say about its arguments: a
/// parameter type with a type variable in it says nothing by itself.
fn expectations(params: List(Ty)) -> List(Ty) {
  list.map(params, fn(param) {
    case types.closed(param) {
      True -> param
      False -> any
    }
  })
}

/// The result type of a call: the declared result, with the type variables
/// of the declaration taken from the arguments' types.
fn result_type(
  params: List(Ty),
  result: Ty,
  arguments: List(Ty),
  callee: String,
) -> Ty {
  let bound =
    list.zip(params, arguments)
    |> list.fold(dict.new(), fn(bound, pair) {
      types.bind(pair.0, pair.1, bound)
    })
  types.fill(result, bound, fn(variable) {
    "the type variable "
    <> variable
    <> " in the result of "
    <> callee
    <> " is not fixed by its arguments: it is decided by how the value is used later, which this codex does not follow"
  })
}

/// H16, H35, H5, H6: a name used as a value.
fn variable(
  at: g.Span,
  name: String,
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let env = builder.env
  let function = dict.get(env.functions, name)
  let constructor = dict.get(env.constructors, name)
  use <- received_value(at, name, builder)
  let is_constant = list.contains(env.constant_functions, name)
  case name, list.key_find(scope, name) {
    // Its type is the stated type of its binding (T8.9).
    _, Ok(ty) -> typed(emit(builder, at, frame.Var(_, names.ident(name))), ty)
    "True", _ -> typed(emit(builder, at, frame.Boolean(_, True)), TyBool)
    "False", _ -> typed(emit(builder, at, frame.Boolean(_, False)), TyBool)
    _, _ ->
      case is_constructor(name), constructor, function {
        True, Ok(Constructor(labels: [_, ..], ..)), _ ->
          gap(builder, at, "constructor as a function", out_of_scope)
        // A variant without fields: its symbol, with its type.
        True, Ok(constructor), _ ->
          typed(
            emit(builder, at, frame.Symbol(_, names.symbol(name))),
            constructed(constructor, [], expected, env),
          )
        // Nil, or a constructor of another module.
        True, Error(Nil), _ ->
          typed(
            emit(builder, at, frame.Symbol(_, names.symbol(name))),
            case name {
              "Nil" -> TyNil
              _ ->
                TyUnknown(
                  "the type of "
                  <> name
                  <> ", a constructor of another module, is not known to this codex",
                )
            },
          )
        False, _, Ok([]) if is_constant -> {
          let #(_, result) = signature_of(env, name)
          typed(
            emit(builder, at, frame.Call(_, "", fname(env, name), [])),
            result,
          )
        }
        False, _, Ok(labels) -> {
          let ty = case dict.get(env.signatures, name) {
            Ok(Signature(params:, result:, ..)) -> {
              let ty = TyFn(params, result)
              case types.closed(ty) {
                True -> ty
                False ->
                  TyUnknown(
                    "the function "
                    <> name
                    <> " is not fully annotated or has type variables, so its type as a value is not known to this codex",
                  )
              }
            }
            Error(Nil) -> any
          }
          typed(
            emit(builder, at, frame.FunRef(
              _,
              "",
              fname(env, name),
              list.length(labels),
            )),
            ty,
          )
        }
        False, _, Error(Nil) ->
          case
            dict.has_key(env.primitives, name),
            list.contains(env.constants, name),
            dict.has_key(env.imported, name)
          {
            True, _, _ ->
              gap(builder, at, "process primitive as a value", out_of_scope)
            _, True, _ -> gap(builder, at, "constant", out_of_scope)
            _, _, True ->
              gap(
                builder,
                at,
                "imported function as a value",
                "its arity is not known from the syntax of this module",
              )
            _, _, _ -> emit(builder, at, frame.Var(_, names.ident(name)))
          }
      }
  }
}

/// `_received`, the value of the receive a continuation call stands in
/// (split.gleam): written where it is used, as `_message`, `#(ok, _message)`
/// or `#(error, nil)`.
fn received_value(
  at: g.Span,
  name: String,
  builder: Builder,
  otherwise: fn() -> #(Int, Builder),
) -> #(Int, Builder) {
  case name == split.received, builder.received {
    True, Some(#("message", _, taken)) -> taken(builder)
    True, Some(#("ok", ty, taken)) -> {
      let #(ok, builder) = emit(builder, at, frame.Symbol(_, "ok"))
      let #(taken, builder) = taken(builder)
      typed(emit(builder, at, frame.Tuple(_, [ok, taken])), ty)
    }
    True, Some(#(_, ty, _)) -> {
      let #(error, builder) = emit(builder, at, frame.Symbol(_, "error"))
      let #(nil, builder) = emit(builder, at, frame.Symbol(_, "nil"))
      typed(emit(builder, at, frame.Tuple(_, [error, nil])), ty)
    }
    _, _ -> otherwise()
  }
}

fn is_constructor(name: String) -> Bool {
  let first = string.slice(name, 0, 1)
  string.uppercase(first) == first && string.lowercase(first) != first
}

/// H13, or a name of another module used as a value. A field node's type is
/// the type of that field in the record's type (T8.9), so the value before
/// the dot must have a type of the module that is sent as a record.
fn field_access(
  at: g.Span,
  container: g.Expression,
  label: String,
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let env = builder.env
  case imported_module(container, scope, env) {
    Some(_) ->
      case is_constructor(label) {
        True ->
          typed(
            emit(builder, at, frame.Symbol(_, names.symbol(label))),
            TyUnknown(
              "the type of "
              <> label
              <> ", a constructor of another module, is not known to this codex",
            ),
          )
        False ->
          gap(
            builder,
            at,
            "function of another module as a value",
            "its arity is not known from the syntax of this module",
          )
      }
    None -> {
      let start = builder
      let #(record, builder) = expr(container, scope, any, builder)
      let ty = ty_of(builder, record)
      let field_type = {
        use constructor <- result.try(
          list.find(dict.values(env.constructors), fn(constructor) {
            case ty {
              TyNamed(name:, ..) ->
                constructor.record && constructor.type_ == name
              _ -> False
            }
          }),
        )
        list.key_find(
          list.zip(constructor.labels, field_types(constructor, ty)),
          Some(label),
        )
      }
      case field_type, types.stateable(ty) {
        Ok(field_type), _ ->
          typed(
            emit(builder, at, frame.Field(_, record, names.ident(label))),
            field_type,
          )
        Error(Nil), False ->
          gap(
            start,
            at,
            "." <> label,
            types.reason(ty)
              <> ", so the value before ."
              <> label
              <> " has no record type and the field has no type (T8.9)",
          )
        Error(Nil), True ->
          gap(
            start,
            at,
            "." <> label,
            "the value before ."
              <> label
              <> " is not of a type this codex sends as a record (one constructor, every field labelled), so a field node would not describe it",
          )
      }
    }
  }
}

/// The module an expression names, when it is an import's name and no local
/// variable hides it.
fn imported_module(e: g.Expression, scope: Scope, env: Env) -> Option(String) {
  case e {
    g.Variable(name:, ..) ->
      case local(scope, name) {
        True -> None
        False -> option.from_result(dict.get(env.imports, name))
      }
    _ -> None
  }
}

/// H12 with a base: `Point(..p, x: 1)`.
fn record_update(
  at: g.Span,
  module: Option(String),
  name: String,
  record: g.Expression,
  fields: List(g.RecordUpdateField(g.Expression)),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  case module, dict.get(builder.env.constructors, name) {
    None, Ok(Constructor(record: True, type_name:, labels:, ..) as constructor)
    -> {
      let #(base, builder) = expr(record, scope, expected, builder)
      let ty = case types.stateable(ty_of(builder, base)) {
        True -> ty_of(builder, base)
        False -> constructed(constructor, [], expected, builder.env)
      }
      let by_label = list.zip(labels, field_types(constructor, ty))
      let fields =
        list.map(fields, fn(field) {
          #(field.label, option.unwrap(field.item, g.Variable(at, field.label)))
        })
      let #(indices, builder) =
        each(fields, builder, fn(field, builder) {
          let wanted =
            result.unwrap(list.key_find(by_label, Some(field.0)), any)
          expr(field.1, scope, wanted, builder)
        })
      let fields =
        list.map2(fields, indices, fn(field, index) {
          #(names.ident(field.0), index)
        })
      case types.stateable(ty) {
        True ->
          typed(emit(builder, at, frame.Record(_, type_name, fields, base)), ty)
        False ->
          gap(
            start,
            at,
            "record update of " <> name,
            types.reason(ty) <> ", so the record has no type (T8.10 e)",
          )
      }
    }
    _, _ ->
      gap(
        builder,
        at,
        "record update of " <> name,
        "not the only, fully labelled constructor of a type of this module",
      )
  }
}

/// H28, H29. Several subjects are one tuple, and so are their patterns.
/// Alternative patterns (`a | b -> body`) are one clause each, with the same
/// guard and body.
///
/// T8.10 (e): the subject needs a type, and (b) every variable a pattern
/// binds takes its type from it. Without a subject type, or with a pattern
/// that cannot be sent, the whole case is one gap: a case sent without one
/// of its clauses would be another program.
fn case_(
  at: g.Span,
  subjects: List(g.Expression),
  clauses: List(g.Clause),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let #(subject, builder) = case subjects {
    [one] -> expr(one, scope, any, builder)
    _ -> {
      let #(elements, builder) = exprs(subjects, scope, [], builder)
      let element_types = list.map(elements, ty_of(builder, _))
      typed(emit(builder, at, frame.Tuple(_, elements)), TyTuple(element_types))
    }
  }
  let subject_type = ty_of(builder, subject)
  let subject_types = case subjects, subject_type {
    [_], _ -> [subject_type]
    _, TyTuple(elems:) -> elems
    _, _ -> []
  }
  let alternatives =
    list.flat_map(clauses, fn(clause) {
      list.map(clause.patterns, fn(patterns) { #(patterns, clause) })
    })
  let #(clauses, builder) =
    each(alternatives, builder, fn(alternative, builder) {
      let #(patterns, clause) = alternative
      let at = case patterns {
        [first, ..] -> first.location
        [] -> at
      }
      let builder = Builder(..builder, bound: [])
      let #(matched, builder) = case patterns {
        [one] -> pattern(one, subject_type, Inferred, builder)
        _ -> {
          let pattern_types =
            list.append(subject_types, list.repeat(any, list.length(patterns)))
          let #(elements, builder) =
            each(list.zip(patterns, pattern_types), builder, fn(pair, builder) {
              pattern(pair.0, pair.1, Inferred, builder)
            })
          emit(builder, at, frame.Tuple(_, elements))
        }
      }
      let scope = list.append(builder.bound, scope)
      let #(guard, builder) = case clause.guard {
        Some(guard) -> expr(guard, scope, TyBool, builder)
        None -> #(-1, builder)
      }
      let #(result, builder) = expr(clause.body, scope, expected, builder)
      emit(builder, at, frame.Clause(_, [matched], guard, result))
    })
  case
    types.stateable(subject_type),
    builder.trouble == start.trouble,
    builder.trouble
  {
    False, _, _ ->
      gap(
        start,
        at,
        "case",
        types.reason(subject_type)
          <> ", so the subject of this case has no type (T8.10 e)",
      )
    True, False, Some(#(construct, note)) ->
      gap(
        start,
        at,
        construct,
        note
          <> "; in a clause of a case, and a case cannot be sent without one of its clauses, so the whole case is this gap",
      )
    True, _, _ -> {
      // The type of the case: the place's, or else the first clause body's
      // that has one.
      let bodies =
        list.filter_map(clauses, fn(clause) {
          case node_at(builder, clause) {
            Ok(frame.Clause(body:, ..)) -> Ok(ty_of(builder, body))
            _ -> Error(Nil)
          }
        })
      let ty = case
        types.stateable(expected),
        list.find(bodies, types.stateable),
        list.all(bodies, fn(body) { body == TyNever }),
        bodies
      {
        True, _, _, _ -> expected
        False, Ok(ty), _, _ -> ty
        False, _, True, _ -> TyNever
        False, _, _, [first, ..] -> first
        False, _, _, [] -> any
      }
      typed(emit(builder, at, frame.Case(_, subject, clauses)), ty)
    }
  }
}

/// H36: a closure. T8.10 (a): it needs a `t_fun` hint on its node. A
/// parameter's type is its annotation, or else the type the place gives the
/// closure (the parameter it is passed for); the result's is its annotation,
/// the body's type, or the place's. The hint is `proven` only when all of it
/// is annotation. With a type missing the closure is a gap.
fn lambda(
  at: g.Span,
  arguments: List(g.FnParameter),
  return: Option(g.Type),
  statements: List(g.Statement),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let resolver = builder.env.resolver
  let count = list.length(arguments)
  let #(wanted_params, wanted_result) = case expected {
    TyFn(params:, result:) ->
      case list.length(params) == count {
        True -> #(params, result)
        False -> #(list.repeat(any, count), any)
      }
    _ -> #(list.repeat(any, count), any)
  }
  let params =
    list.map2(arguments, wanted_params, fn(argument, wanted) {
      case argument.type_ {
        Some(annotation) -> types.resolve(annotation, resolver)
        None -> wanted
      }
    })
  case list.find(params, fn(ty) { !types.stateable(ty) }) {
    Ok(_) ->
      gap(
        start,
        at,
        "anonymous function",
        "a parameter of this anonymous function has no type annotation, and none can be taken from where the function is used, so the function has no type (T8.10 a)",
      )
    Error(Nil) -> {
      let typed_arguments = list.zip(arguments, params)
      let #(parameters, builder) =
        each(typed_arguments, builder, fn(pair, builder) {
          let strength = case { pair.0 }.type_ {
            Some(_) -> Proven
            None -> Inferred
          }
          parameter_node({ pair.0 }.name, at, pair.1, strength, builder)
        })
      let bound =
        list.filter_map(typed_arguments, fn(pair) {
          result.map(assigned_name({ pair.0 }.name), fn(name) {
            #(name, pair.1)
          })
        })
      let declared = case return {
        Some(annotation) -> types.resolve(annotation, resolver)
        None -> wanted_result
      }
      let #(result, builder) =
        body(at, statements, list.append(bound, scope), declared, builder)
      let result_type = case types.stateable(declared) {
        True -> declared
        False -> ty_of(builder, result)
      }
      case types.stateable(result_type) {
        False ->
          gap(
            start,
            at,
            "anonymous function",
            types.reason(result_type)
              <> ", so the result of this anonymous function has no type (T8.10 a)",
          )
        True -> {
          let #(clause, builder) =
            emit(builder, at, frame.Clause(_, parameters, -1, result))
          let strength = case
            return != None && list.all(arguments, fn(a) { a.type_ != None })
          {
            True -> Proven
            False -> Inferred
          }
          typed_as(
            emit(builder, at, frame.Lambda(_, [clause])),
            TyFn(params, result_type),
            strength,
          )
        }
      }
    }
  }
}

// ------------------------------------------------------------ calls

/// An argument: its label, if it has one, and its value.
type Argument(a) =
  #(Option(String), a)

fn call(
  at: g.Span,
  function: g.Expression,
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let env = builder.env
  case function {
    g.Variable(name:, ..) ->
      case local(scope, name), is_constructor(name) {
        True, _ -> apply(at, function, arguments, scope, builder)
        False, True ->
          construct(at, name, None, arguments, scope, expected, builder)
        False, False ->
          named_call(at, name, arguments, scope, expected, builder)
      }
    g.FieldAccess(container:, label:, ..) ->
      case imported_module(container, scope, env), is_constructor(label) {
        Some(module), True ->
          construct(
            at,
            label,
            Some(module),
            arguments,
            scope,
            expected,
            builder,
          )
        Some(module), False ->
          remote_call(at, module, label, arguments, scope, expected, builder)
        None, _ -> apply(at, function, arguments, scope, builder)
      }
    _ -> apply(at, function, arguments, scope, builder)
  }
}

/// H33: a call through a function value. Its result type is the result of
/// the value's function type (T8.10 d).
fn apply(
  at: g.Span,
  function: g.Expression,
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  case positional(arguments) {
    Ok(arguments) -> {
      let #(function, builder) = expr(function, scope, any, builder)
      let function_type = ty_of(builder, function)
      let params = case function_type {
        TyFn(params:, ..) -> params
        _ -> []
      }
      let #(arguments, builder) =
        exprs(arguments, scope, expectations(params), builder)
      let ty = case function_type {
        TyFn(result:, ..) ->
          result_type(
            params,
            result,
            list.map(arguments, ty_of(builder, _)),
            "the called function",
          )
        _ ->
          TyUnknown(
            "the value that is called has no function type known to this codex ("
            <> types.reason(function_type)
            <> ")",
          )
      }
      typed(emit(builder, at, frame.Apply(_, function, arguments)), ty)
    }
    Error(Nil) ->
      gap(
        builder,
        at,
        "labelled arguments to a function value",
        "the labels are not known from the syntax of this module",
      )
  }
}

/// A call to a name that is not a local variable: one of the module's process
/// externals, one of its functions (H32), or an unqualified import. The
/// result type of a call to a function of the module is the one its
/// signature declares (T8.10 d): the codex sees the whole module.
fn named_call(
  at: g.Span,
  name: String,
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let env = builder.env
  let marked = case
    name == split.receive_marker
    || name == split.forever_marker
    || name == split.gap_marker
    || name == sup.child_marker
  {
    True -> positional(arguments)
    False -> Error(Nil)
  }
  case
    marked,
    dict.get(env.primitives, name),
    dict.get(env.functions, name),
    dict.get(env.imported, name)
  {
    // What split.gleam writes that is not Gleam source.
    Ok([g.String(value: construct, ..), g.String(value: note, ..)]), _, _, _ ->
      gap(builder, at, construct, note)
    // What sup.gleam writes for a child of a static supervisor it read.
    Ok([
      g.String(value: restart, ..),
      g.String(value: strategy, ..),
      state,
      handler,
    ]),
      _,
      _,
      _
    -> static_child(at, restart, strategy, state, handler, scope, builder)
    Ok([subject, within, then]), _, _, _ ->
      receive_(at, subject, Some(within), then, scope, expected, builder)
    Ok([subject, then]), _, _, _ ->
      receive_(at, subject, None, then, scope, expected, builder)
    _, Ok(primitive), _, _ ->
      process(at, primitive, name, arguments, scope, builder)
    _, _, Ok(labels), _ ->
      case in_order(labels, arguments) {
        Ok(arguments) -> {
          let #(params, result) = signature_of(env, name)
          let #(arguments, builder) =
            exprs(arguments, scope, expectations(params), builder)
          let argument_types = list.map(arguments, ty_of(builder, _))
          let builder = case dict.has_key(env.made, name) {
            True ->
              Builder(..builder, calls: [
                #(name, argument_types),
                ..builder.calls
              ])
            False -> builder
          }
          let ty = result_type(params, result, argument_types, name)
          typed(
            emit(builder, at, frame.Call(_, "", fname(env, name), arguments)),
            ty,
          )
        }
        Error(Nil) -> out_of_order(at, name, arguments, builder)
      }
    _, _, _, Ok(module) ->
      remote_call(at, module, name, arguments, scope, expected, builder)
    _, _, _, _ -> remote_call(at, "", name, arguments, scope, expected, builder)
  }
}

fn signature_of(env: Env, name: String) -> #(List(Ty), Ty) {
  case dict.get(env.signatures, name) {
    Ok(Signature(params:, result:, ..)) -> #(params, result)
    Error(Nil) -> #([], any)
  }
}

/// H20..H26: a call to one of the module's externals to Erlang's process
/// functions is the contract's process node. Its type is the one the
/// external's declaration gives the call.
fn process(
  at: g.Span,
  primitive: Primitive,
  name: String,
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  case positional(arguments) {
    Error(Nil) -> out_of_order(at, name, arguments, builder)
    Ok(arguments) -> {
      let #(params, result) = signature_of(builder.env, name)
      let #(arguments, builder) =
        exprs(arguments, scope, expectations(params), builder)
      let ty =
        result_type(
          params,
          result,
          list.map(arguments, ty_of(builder, _)),
          name,
        )
      case primitive, arguments {
        SelfPrimitive, [] -> typed(emit(builder, at, frame.Self), ty)
        SpawnPrimitive(link:), [function] ->
          typed(emit(builder, at, frame.Spawn(_, function, [], link)), ty)
        SendPrimitive, [to, message] ->
          send(
            start,
            at,
            name <> "/2",
            frame.Send(_, to, message),
            message,
            ty,
            builder,
          )
        LinkPrimitive, [to] -> typed(emit(builder, at, frame.Link(_, to)), ty)
        ExitSignalPrimitive, [to, reason] ->
          typed(emit(builder, at, frame.ExitSignal(_, to, reason)), ty)
        FailPrimitive, [reason] ->
          typed(emit(builder, at, frame.Fail(_, reason)), TyNever)
        // The wrong number of arguments: not Gleam that type-checks.
        _, _ ->
          typed(
            emit(builder, at, frame.Call(_, "", names.ident(name), arguments)),
            ty,
          )
      }
    }
  }
}

/// H22. T8.10 (e): the message of a send needs a type; without one the send
/// is a gap. `start` is the builder before the send's operands were written.
fn send(
  start: Builder,
  at: g.Span,
  construct: String,
  node: fn(Int) -> Node,
  message: Int,
  ty: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let message_type = ty_of(builder, message)
  let free = !types.stateable(ty)
  case types.stateable(message_type) {
    // Contract H22: the value of a `(:send)` is the message. Gleam's
    // `process.send` gives Nil, so the send is a statement of a block that
    // ends with `nil`. (`sequence` takes the block away again where the
    // send is itself a statement whose value is dropped.) An external whose
    // declared result is the message's type is the send alone.
    True if ty == TyNil && message_type != TyNil -> {
      let #(sent, builder) = typed(emit(builder, at, node), message_type)
      let #(nil, builder) =
        typed(emit(builder, at, frame.Symbol(_, "nil")), TyNil)
      typed(emit(builder, at, frame.Block(_, [sent, nil])), TyNil)
    }
    True if ty == message_type || free ->
      typed(emit(builder, at, node), message_type)
    True ->
      gap(
        start,
        at,
        construct,
        "the value of a send is the message (contract H22), and this one is declared with another type that is not Nil, which this codex cannot make a value of",
      )
    False ->
      gap(
        start,
        at,
        construct,
        types.reason(message_type)
          <> ", so the message that is sent has no type (T8.10 e)",
      )
  }
}

/// H32 with a module: `module.function(...)`. The module travels under the
/// name it is imported by (`gleam/int`), not its alias in this file.
///
/// T8.12: Gleam's numeric conversions are functions of its standard library;
/// the three the contract has an operator for are sent as that operator.
/// T8.10 (d): the result type of any other call is known only for the
/// functions in `types.library_signature`.
fn remote_call(
  at: g.Span,
  module: String,
  name: String,
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let arity = list.length(arguments)
  let construct = module <> "." <> name <> "/" <> int.to_string(arity)
  let conversion = fn(op, value, from, to) {
    let #(value, builder) = expr(value, scope, from, builder)
    Ok(typed(emit(builder, at, frame.Op(_, op, [value])), to))
  }
  // The library calls this codex lowers itself. To map another library
  // function, add it to `library_process` or `otp_actor`, or add a line here
  // for a new module.
  let library = case module, name, positional(arguments) {
    "gleam/int", "to_float", Ok([value]) ->
      conversion("to_float", value, TyInt, TyFloat)
    "gleam/float", "truncate", Ok([value]) ->
      conversion("trunc", value, TyFloat, TyInt)
    "gleam/float", "round", Ok([value]) ->
      conversion("round", value, TyFloat, TyInt)
    "gleam/io", "println", Ok([value]) ->
      Ok(io_print(at, True, value, scope, builder))
    "gleam/io", "print", Ok([value]) ->
      Ok(io_print(at, False, value, scope, builder))
    "gleam/erlang/process", _, Ok(arguments) ->
      library_process(at, name, arguments, scope, expected, builder)
    "gleam/otp/actor", _, Ok(arguments) ->
      otp_actor(at, name, arguments, scope, expected, builder)
    _, _, _ -> Error(Nil)
  }
  case library, module_note(module), positional(arguments) {
    Ok(mapped), _, _ -> mapped
    _, Some(note), _ -> gap(builder, at, construct, note)
    _, None, Ok(arguments) -> {
      let #(params, ty) = case types.library_signature(module, name, arity) {
        Ok(#(params, result)) -> #(params, Ok(result))
        Error(Nil) -> #([], Error(Nil))
      }
      let #(arguments, builder) =
        exprs(arguments, scope, expectations(params), builder)
      let ty = case ty {
        Ok(result) ->
          result_type(
            params,
            result,
            list.map(arguments, ty_of(builder, _)),
            construct,
          )
        Error(Nil) ->
          TyUnknown(
            "the result type of "
            <> construct
            <> " is not known to this codex (it has the signatures of this module's functions and of a few functions of the standard library)",
          )
      }
      typed(emit(builder, at, frame.Call(_, module, name, arguments)), ty)
    }
    _, None, Error(Nil) ->
      gap(
        builder,
        at,
        construct,
        "labelled arguments to a function of another module: the labels are not known from the syntax of this module",
      )
  }
}

/// `io.println(text)` and `io.print(text)`: Gleam's own output is this
/// sender's business, so the call is sent as what it does: one L1 call of a
/// Silica print builtin (contract T9.16) for each piece of the text, then
/// `nil`. The pieces are the operands of `<>`:
///
///   "a literal"            print(text)
///   int.to_string(n)       print_int64(n)
///   float.to_string(f)     print_float64(f)
///   any other String       print(value)
///
/// and `println` for the last piece of an `io.println` (after a number:
/// `println("")`). Gleam builds the whole text before it prints, so every
/// piece that is not a literal or a variable is evaluated and bound first,
/// in Gleam's order, and only then is anything printed.
/// NOT GLEAM'S OUTPUT: a float is printed by Silica's print_float64 (at most
/// 15 decimal places, cut and not rounded, where float.to_string writes the
/// shortest text that reads back; contract T9.16).
fn io_print(
  at: g.Span,
  line: Bool,
  value: g.Expression,
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let construct = case line {
    True -> "gleam/io.println/1"
    False -> "gleam/io.print/1"
  }
  let kind_type = fn(kind) {
    case kind {
      "int" -> TyInt
      "float" -> TyFloat
      _ -> TyString
    }
  }
  // Evaluate what must be evaluated, in order: #(kind, expression, bound name).
  let #(pieces, bindings, problem, builder) =
    list.fold(
      print_pieces(value, scope, builder.env),
      #([], [], None, builder),
      fn(acc, piece) {
        let #(pieces, bindings, problem, builder) = acc
        let #(kind, e) = piece
        let written_later = case e {
          g.String(..) -> kind == "text"
          g.Variable(name:, ..) -> local(scope, name)
          _ -> False
        }
        case written_later {
          True -> #([#(kind, e, None), ..pieces], bindings, problem, builder)
          False -> {
            let #(value, builder) = expr(e, scope, kind_type(kind), builder)
            let ty = ty_of(builder, value)
            let name = "_print_" <> int.to_string(builder.next)
            let #(bound, builder) = emit(builder, at, frame.Var(_, name))
            let builder = hint(builder, bound, ty, Inferred)
            let #(binding, builder) =
              typed(emit(builder, at, frame.Match(_, bound, value)), ty)
            let problem = case problem, types.stateable(ty) {
              None, False -> Some(types.reason(ty))
              _, _ -> problem
            }
            #(
              [#(kind, e, Some(name)), ..pieces],
              [binding, ..bindings],
              problem,
              builder,
            )
          }
        }
      },
    )
  case problem {
    Some(why) ->
      gap(
        start,
        at,
        construct,
        why <> ", so a piece of the text that is printed has no type (T8.10 e)",
      )
    None -> {
      let pieces = list.reverse(pieces)
      let count = list.length(pieces)
      let #(prints, builder) =
        list.index_fold(pieces, #([], builder), fn(acc, piece, index) {
          let #(prints, builder) = acc
          let #(kind, e, bound) = piece
          let #(value, builder) = case bound, e {
            Some(name), _ -> emit(builder, at, frame.Var(_, name))
            None, g.String(location:, value:) ->
              text_literal(location, value, builder)
            None, _ -> expr(e, scope, kind_type(kind), builder)
          }
          let last = line && index == count - 1
          let builtin = case kind, last {
            "int", _ -> "print_int64"
            "float", _ -> "print_float64"
            _, True -> "println"
            _, False -> "print"
          }
          let #(print, builder) =
            emit(builder, at, frame.SlCall(_, "", builtin, [value]))
          case last && builtin != "println" {
            False -> #([print, ..prints], builder)
            True -> {
              let #(empty, builder) = emit(builder, at, frame.Text(_, ""))
              let #(end, builder) =
                emit(builder, at, frame.SlCall(_, "", "println", [empty]))
              #([end, print, ..prints], builder)
            }
          }
        })
      let #(nil, builder) =
        typed(emit(builder, at, frame.Symbol(_, "nil")), TyNil)
      typed(
        emit(builder, at, frame.Block(
          _,
          list.flatten([list.reverse(bindings), list.reverse(prints), [nil]]),
        )),
        TyNil,
      )
    }
  }
}

/// The operands of `<>` in a text that is printed, in order, each with how
/// it is printed: "text" (a literal), "int", "float" (the argument of
/// `int.to_string`, `float.to_string`), "string" (anything else).
fn print_pieces(
  e: g.Expression,
  scope: Scope,
  env: Env,
) -> List(#(String, g.Expression)) {
  case e {
    g.BinaryOperator(name: g.Concatenate, left:, right:, ..) ->
      list.append(
        print_pieces(left, scope, env),
        print_pieces(right, scope, env),
      )
    g.String(..) -> [#("text", e)]
    g.Call(function:, arguments: [g.UnlabelledField(argument)], ..) ->
      case library_function(function, scope, env) {
        Some(#("gleam/int", "to_string")) -> [#("int", argument)]
        Some(#("gleam/float", "to_string")) -> [#("float", argument)]
        _ -> [#("string", e)]
      }
    _ -> [#("string", e)]
  }
}

/// H20..H23 for the calls of `gleam/erlang/process` that have a node in the
/// contract. This is a lowering decision of this codex (contract 1, "what you
/// own"): **a subject is lowered to the process that owns it.**
///
///   process.self()              -> self
///   process.new_subject()       -> self       (the subject's tag is dropped)
///   process.spawn(f)            -> spawn, linked;  spawn_unlinked(f) -> spawn
///   process.send(subject, m)    -> send of the message as T9.12 asks
///                                  (`message_shape`); where its value (Nil)
///                                  is used, the block { send, nil }
///   process.receive(s, within)  -> receive, one clause for each way a message
///   process.receive_forever(s)     of the subject's type arrives (`receive_`),
///                                  in tail position: split.gleam put it there
///
/// What is lost: a receive on one subject takes every message of the
/// subject's type that reaches its process, not only the ones sent to that
/// subject (on the BEAM the subject's reference selects them). The contract
/// has no node that makes a unique value, so a subject cannot carry a tag of
/// its own (README, "Processes").
/// The subject expression of a receive is still evaluated, for its effects,
/// unless it is a plain variable. Every other function of the module stays
/// a gap.
///
/// Types: `self()` is a Pid, a subject is `Subject(message)` (`t_actor`),
/// the `send` node has the message's type and Gleam's call is Nil (see
/// `send`), a receive is `Result(message, Nil)` or the
/// message. The message type of `new_subject()` is not in its arguments:
/// Gleam decides it from how the subject is used later, which this codex
/// does not follow, so it comes from the place (`let s: Subject(M) = …`), or
/// the binding is a gap. The message of a send and of a receive clause needs
/// a type (T8.10 e): without it the call is a gap.
fn library_process(
  at: g.Span,
  name: String,
  arguments: List(g.Expression),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> Result(#(Int, Builder), Nil) {
  let start = builder
  let construct =
    "gleam/erlang/process."
    <> name
    <> "/"
    <> int.to_string(list.length(arguments))
  case name, arguments {
    "self", [] -> Ok(typed(emit(builder, at, frame.Self), TyPid))
    "new_subject", [] ->
      Ok(typed(
        emit(builder, at, frame.Self),
        TySubject(TyUnknown(
          "the message type of process.new_subject() is not in the call: Gleam decides it from how the subject is used later, which this codex does not follow (annotate the let: `let s: Subject(Message) = process.new_subject()`)",
        )),
      ))
    "spawn", [function] | "spawn_unlinked", [function] -> {
      let #(function, builder) = expr(function, scope, any, builder)
      Ok(typed(
        emit(builder, at, frame.Spawn(_, function, [], name == "spawn")),
        TyPid,
      ))
    }
    // A name the unit makes (`environment`): the symbol of its literal.
    "new_name", [prefix] ->
      Ok(case prefix, expected {
        g.String(value: literal, ..), TyName(name:, ..) if name == literal ->
          typed(emit(builder, at, frame.Symbol(_, name)), expected)
        _, _ -> gap(builder, at, construct, types.no_name)
      })
    // The subject of a name: the same symbol. Only a send takes it.
    "named_subject", [name] -> {
      let #(index, written) = expr(name, scope, any, builder)
      Ok(case ty_of(written, index) {
        TyName(message:, name:) ->
          typed(#(index, written), TyNamedSubject(message, name))
        _ -> gap(builder, at, construct, types.no_name)
      })
    }
    "send", [to, message] -> {
      let #(to, builder) = expr(to, scope, any, builder)
      let to_type = ty_of(builder, to)
      // A send to a named subject is a send to the name (contract T9.14c):
      // the subject is not a node of it. It is a variable or
      // `process.named_subject(variable)`, which have no effect to keep.
      let #(node, builder) = case to_type {
        TyNamedSubject(name:, ..) -> #(
          fn(message) { frame.SendNamed(_, name, message) },
          start,
        )
        _ -> #(fn(message) { frame.Send(_, to, message) }, builder)
      }
      let wanted = case to_type {
        TySubject(message:) | TyNamedSubject(message:, ..) -> message
        _ -> any
      }
      let #(message, builder) = expr(message, scope, wanted, builder)
      let message_type = case types.stateable(wanted) {
        True -> wanted
        False -> ty_of(builder, message)
      }
      case
        types.stateable(message_type),
        message_shape(message_type, builder.env)
      {
        // Contract T9.12: a message is a symbol or a tagged tuple. A value
        // of a custom type with variants is one already; any other value is
        // sent under the tag of its type.
        True, Wrapped(tag:) -> {
          let #(tag_node, builder) = emit(builder, at, frame.Symbol(_, tag))
          let #(tagged, builder) =
            typed(
              emit(builder, at, frame.Tuple(_, [tag_node, message])),
              TyTagged(tag, [message_type]),
            )
          Ok(send(start, at, construct, node(tagged), tagged, TyNil, builder))
        }
        _, _ ->
          Ok(send(start, at, construct, node(message), message, TyNil, builder))
      }
    }
    // A receive the split left where it is (it stands in tail position, or
    // in a closure): its value is the value of its place.
    "receive", [subject, within] ->
      Ok(receive_(
        at,
        subject,
        Some(within),
        g.Variable(at, split.received),
        scope,
        expected,
        builder,
      ))
    "receive_forever", [subject] ->
      Ok(receive_(
        at,
        subject,
        None,
        g.Variable(at, split.received),
        scope,
        expected,
        builder,
      ))
    _, _ -> Error(Nil)
  }
}

/// H23: `process.receive(subject, within)` (`within` None:
/// `process.receive_forever(subject)`), whose value, bound to `_received`,
/// is used by the expression `then`: the call of a continuation the split
/// made, or `_received` itself where the receive already stands in tail
/// position.
///
///   receive {
///     #(subject__<type>, _message) -> { let _received = #(ok, _message)  then }
///   } after within -> { let _received = #(error, nil)  then }
///
/// The clause's pattern is the tagged tuple a message of the subject's type
/// is sent as (`send`; contract T9.12), so the receive takes the messages of
/// that TYPE that reach the process: a subject does not choose them
/// (README, "Processes").
fn receive_(
  at: g.Span,
  subject: g.Expression,
  within: Option(g.Expression),
  then: g.Expression,
  scope: Scope,
  expected0: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let expected = expected0
  let construct = case within {
    Some(_) -> "gleam/erlang/process.receive/2"
    None -> "gleam/erlang/process.receive_forever/1"
  }
  let identity = case then {
    g.Variable(name:, ..) -> name == split.received
    _ -> False
  }
  let expected = case identity {
    True -> any
    False -> expected
  }
  let wanted = case identity, within, expected0 {
    True, Some(_), TyResult(ok:, ..) -> ok
    True, None, _ -> expected
    _, _, _ -> any
  }
  let written = {
    use message, builder <- after_subject(
      at,
      construct,
      subject,
      scope,
      wanted,
      builder,
    )
    let received = case within {
      Some(_) -> TyResult(message, TyNil)
      None -> message
    }
    // What the receive's value is used for: `then`, in which `_received`
    // is that value (`received_value`).
    let used = fn(builder: Builder, kind: String, taken) -> #(Int, Builder) {
      let outer = builder.received
      let #(then, builder) =
        expr(
          then,
          scope,
          expected,
          Builder(..builder, received: Some(#(kind, received, taken))),
        )
      #(then, Builder(..builder, received: outer))
    }
    let kind = case within {
      Some(_) -> "ok"
      None -> "message"
    }
    let #(clauses, builder) =
      message_clauses(at, message, builder, fn(taken, builder) {
        used(builder, kind, taken)
      })
    let ty = case clauses {
      [first, ..] ->
        case node_at(builder, first) {
          Ok(frame.Clause(body:, ..)) -> ty_of(builder, body)
          _ -> any
        }
      [] -> any
    }
    case within {
      Some(within) -> {
        let #(within, builder) = expr(within, scope, TyInt, builder)
        let #(after, builder) =
          used(builder, "error", fn(builder) { #(-1, builder) })
        typed(emit(builder, at, frame.Receive(_, clauses, within, after)), ty)
      }
      None -> typed(emit(builder, at, frame.Receive(_, clauses, -1, -1)), ty)
    }
  }
  case written {
    Ok(written) -> written
    Error(Nil) -> gap(builder, at, construct, out_of_scope)
  }
}

/// How a message of a type travels (contract T9.12: a message is a symbol
/// or a tagged tuple, and a tag has one type in a unit).
type Shape {
  /// A custom type of the module with variants: each value is a symbol or
  /// a tagged tuple already. The constructors' symbols and field types.
  Variants(List(#(String, List(Ty))))
  /// Any other type (a record, a tuple, an Int, a Result): the value is
  /// sent as `#(tag, value)`, the tag made from the type (`message_tag`).
  Wrapped(tag: String)
}

fn message_shape(message: Ty, env: Env) -> Shape {
  let variants = case message {
    TyNamed(name:, ..) ->
      dict.to_list(env.constructors)
      |> list.filter(fn(pair) { { pair.1 }.type_ == name && !{ pair.1 }.record })
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(pair) {
        #(names.symbol(pair.0), field_types(pair.1, message))
      })
    _ -> []
  }
  case variants {
    [] -> Wrapped(types.message_tag(message))
    _ -> Variants(variants)
  }
}

/// The clauses of a receive that takes the messages of one type: one clause
/// for each way such a message arrives (`message_shape`). `body` writes a
/// clause's body; it is given what writes the message that was taken (as a
/// value of the message type).
fn message_clauses(
  at: g.Span,
  message: Ty,
  builder: Builder,
  body: fn(fn(Builder) -> #(Int, Builder), Builder) -> #(Int, Builder),
) -> #(List(Int), Builder) {
  let clause = fn(pattern: Int, taken, builder: Builder) {
    let #(result, builder) = body(taken, builder)
    emit(builder, at, frame.Clause(_, [pattern], -1, result))
  }
  case message_shape(message, builder.env) {
    Wrapped(tag:) -> {
      let #(tag_node, builder) = emit(builder, at, frame.Symbol(_, tag))
      let #(variable, builder) = emit(builder, at, frame.Var(_, "_message"))
      let builder = hint(builder, variable, message, Inferred)
      let #(pattern, builder) =
        emit(builder, at, frame.Tuple(_, [tag_node, variable]))
      let builder = hint(builder, pattern, TyTagged(tag, [message]), Inferred)
      let taken = fn(builder) {
        typed(emit(builder, at, frame.Var(_, "_message")), message)
      }
      let #(clause, builder) = clause(pattern, taken, builder)
      #([clause], builder)
    }
    Variants(variants) ->
      each(variants, builder, fn(variant, builder) {
        let #(symbol, fields) = variant
        let named =
          list.index_map(fields, fn(ty, index) {
            #("_m" <> int.to_string(index + 1), ty)
          })
        case named {
          [] -> {
            let #(pattern, builder) = emit(builder, at, frame.Symbol(_, symbol))
            let taken = fn(builder) {
              typed(emit(builder, at, frame.Symbol(_, symbol)), message)
            }
            clause(pattern, taken, builder)
          }
          _ -> {
            let #(tag_node, builder) =
              emit(builder, at, frame.Symbol(_, symbol))
            let #(variables, builder) =
              each(named, builder, fn(field, builder) {
                let #(index, builder) = emit(builder, at, frame.Var(_, field.0))
                #(index, hint(builder, index, field.1, Inferred))
              })
            let #(pattern, builder) =
              emit(builder, at, frame.Tuple(_, [tag_node, ..variables]))
            let builder =
              hint(builder, pattern, TyTagged(symbol, fields), Inferred)
            let taken = fn(builder) {
              let #(tag_node, builder) =
                emit(builder, at, frame.Symbol(_, symbol))
              let #(values, builder) =
                each(named, builder, fn(field: #(String, Ty), builder) {
                  emit(builder, at, frame.Var(_, field.0))
                })
              typed(
                emit(builder, at, frame.Tuple(_, [tag_node, ..values])),
                message,
              )
            }
            clause(pattern, taken, builder)
          }
        }
      })
  }
}

/// A receive's subject does not choose the messages (see above), but it is
/// still an expression of the program: unless it is a plain variable it is
/// evaluated first, in a block that ends with the receive. The subject's
/// type gives the message type the receive is written with (`wanted` is what
/// the place says, when the subject says nothing); with no message type the
/// receive is a gap (T8.10 e).
fn after_subject(
  at: g.Span,
  construct: String,
  subject: g.Expression,
  scope: Scope,
  wanted: Ty,
  builder: Builder,
  receive: fn(Ty, Builder) -> #(Int, Builder),
) -> Result(#(Int, Builder), Nil) {
  let start = builder
  let #(first, subject_type, builder) = case subject {
    g.Variable(name:, ..) -> #(
      None,
      result.unwrap(list.key_find(scope, name), any),
      builder,
    )
    _ -> {
      let #(index, builder) = expr(subject, scope, any, builder)
      #(Some(index), ty_of(builder, index), builder)
    }
  }
  let message = case subject_type {
    TySubject(message:) -> message
    _ -> wanted
  }
  let message = case types.stateable(message) {
    True -> message
    False -> wanted
  }
  case types.stateable(message), first {
    False, _ ->
      Ok(gap(
        start,
        at,
        construct,
        types.reason(subject_type)
          <> ", so the message this receive takes has no type (T8.10 e)",
      ))
    True, None -> Ok(receive(message, builder))
    True, Some(first) -> {
      let #(received, builder) = receive(message, builder)
      Ok(typed(
        emit(builder, at, frame.Block(_, [first, received])),
        ty_of(builder, received),
      ))
    }
  }
}

// ------------------------------------------------------------ gleam_otp
//
// Contract 9.2: until there is a supplement for OTP behaviours, "a sender
// lowers OTP behaviours into processes and receives itself, or sends them as
// gaps". This section does the first for the plain gleam_otp actor and the
// second for everything else. Only existing nodes are used.
//
// Mapped (README, "gleam_otp actors"):
//
//   actor.new(state) |> actor.on_message(handler) |> actor.start
//       -> { let _actor_N = spawn: gleam_otp_actor_loop__g1(state)
//            #(ok, #(started, _actor_N, _actor_N)) }
//   actor.continue(state)        -> #(continue, state)
//   actor.stop()                 -> stop
//   actor.stop_abnormal(reason)  -> #(stop_abnormal, reason)
//
// The three values are this sender's own (gleam_otp's hold a selector and a
// Dynamic reason, which would need the type dynamic). The loop is a helper
// function form (`actor_loop_form`); the handler is called by its name.
// T8.14 says a function with a type variable in its signature is not
// written, so the helper is not generic: one is written for each kind of
// actor the unit starts (a state type, a message type, a handler), named
// `gleam_otp_actor_loop__g<n>`.
//
// Also mapped: a static supervisor whose children are named plain actors
// with a literal state. sup.gleam reads it from the syntax before anything
// is typed and leaves a mark for each child; `static_child` writes the
// contract's static child for it (T9.14b), and `library_process` a
// `send_named` for a send to `process.named_subject(name)` (T9.14c).
//
// Not mapped, each one gap node (its arguments are not sent: the program
// stops at the gap, and as expressions of a block before its last they would
// each need a type, T8.10 e): actor.new_with_initialiser, initialised,
// returning, selecting, with_selector, call, send, actor.named outside a
// static supervisor that was read, and every call of
// gleam/otp/static_supervisor and gleam/otp/supervision that is not part of
// such a supervisor. To map one of them, add a case to `otp_actor` (or a
// function like it for another module) and a test.

/// The calls of `gleam/otp/actor` that are lowered. Error(Nil): not one of
/// them, or not in the plain shape; the caller then writes the gap.
///
/// `actor.continue` and the two stops are `Next(state, message)`; the
/// message type is not in their arguments, so it comes from the place (the
/// handler's declared result).
fn otp_actor(
  at: g.Span,
  name: String,
  arguments: List(g.Expression),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> Result(#(Int, Builder), Nil) {
  let symbol = fn(builder, name) { emit(builder, at, frame.Symbol(_, name)) }
  let from_the_place =
    TyUnknown(
      "the type of gleam/otp/actor."
      <> name
      <> " is decided by the handler it is the result of, and no annotation here gives it",
    )
  case name, arguments {
    "continue", [state] -> {
      let wanted = case expected {
        TyNext(state:, ..) -> state
        _ -> any
      }
      let #(tag, builder) = symbol(builder, "continue")
      let #(state, builder) = expr(state, scope, wanted, builder)
      Ok(typed(emit(builder, at, frame.Tuple(_, [tag, state])), from_the_place))
    }
    "stop", [] -> Ok(typed(symbol(builder, "stop"), from_the_place))
    "stop_abnormal", [reason] -> {
      let #(tag, builder) = symbol(builder, "stop_abnormal")
      let #(reason, builder) = expr(reason, scope, TyString, builder)
      Ok(typed(emit(builder, at, frame.Tuple(_, [tag, reason])), from_the_place))
    }
    "start", [actor] ->
      case plain_actor(actor, scope, builder.env) {
        Ok(PlainActor(state:, handler:)) ->
          Ok(actor_start(at, state, handler, scope, expected, builder))
        Error(Nil) -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// The plain actor: `actor.new(state)`, with or without
/// `actor.on_message(handler)`.
type PlainActor {
  PlainActor(state: g.Expression, handler: Option(g.Expression))
}

/// Reads `actor.new(state) |> actor.on_message(handler)` from the syntax.
/// Anything else (an initialiser, a name, a builder held in a variable) is
/// not the plain actor.
fn plain_actor(
  e: g.Expression,
  scope: Scope,
  env: Env,
) -> Result(PlainActor, Nil) {
  case e {
    g.BinaryOperator(location:, name: g.Pipe, left:, right:) ->
      plain_actor(pipe(location, left, right), scope, env)
    g.Call(function:, arguments:, ..) ->
      case
        library_function(function, scope, env),
        positional(list.map(arguments, expr_field))
      {
        Some(#("gleam/otp/actor", "new")), Ok([state]) ->
          Ok(PlainActor(state:, handler: None))
        Some(#("gleam/otp/actor", "on_message")), Ok([actor, handler]) ->
          result.map(plain_actor(actor, scope, env), fn(actor) {
            PlainActor(..actor, handler: Some(handler))
          })
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The module and name of a called function of another module:
/// `actor.new` under the module's import name, or `new` imported unqualified.
fn library_function(
  function: g.Expression,
  scope: Scope,
  env: Env,
) -> Option(#(String, String)) {
  case function {
    g.FieldAccess(container:, label:, ..) ->
      option.map(imported_module(container, scope, env), fn(module) {
        #(module, label)
      })
    g.Variable(name:, ..) ->
      case local(scope, name), dict.get(env.imported, name) {
        False, Ok(module) -> Some(#(module, name))
        _, _ -> None
      }
    _ -> None
  }
}

/// The name a loop function has in a `fun_ref` until `forms` gives it its
/// own: a text no Gleam function name can be.
fn actor_key(actor: Actor) -> String {
  "\u{1}" <> string.inspect(actor)
}

/// `actor.start` of the plain actor (H21, H18, H8).
///
/// The state is evaluated by the starting process, as `actor.new` does; the
/// new process runs the loop function with it. The spawn is NOT linked: the
/// transpiler writes no link (contract T9.15), so a failure of the actor
/// does not reach the process that started it (README, "gleam_otp actors").
/// The value is `Ok(Started(pid:, data:))`, where `data` is the actor's
/// subject: the actor's own process, since a subject is lowered to its owner.
///
/// The handler is a function of the module, by its name: the loop calls it
/// by name. A handler that is a closure or a variable would be state of the
/// waiting process, and the transpiler writes no closure; such a start is a
/// gap.
///
/// gleam_otp's start also waits until the new process has initialised. For
/// the plain actor the initialiser cannot fail and has no effect, so nothing
/// is waited for here.
///
/// Types: the state's type is the type of `actor.new`'s argument, and the
/// message type is the handler's second parameter, or else the one the
/// place gives (`-> actor.StartResult(Subject(Message))`). With either
/// missing the start is a gap (T8.10 e: the message of the loop's receive
/// would have no type).
fn actor_start(
  at: g.Span,
  state: g.Expression,
  handler: Option(g.Expression),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let env = builder.env
  let wanted_data = case expected {
    TyResult(ok: TyStarted(data:), ..) -> data
    _ -> any
  }
  let wanted_message = case wanted_data {
    TySubject(message:) -> message
    _ -> any
  }
  let named = case handler {
    None -> Ok("")
    Some(g.Variable(name:, ..)) ->
      case local(scope, name), dict.has_key(env.functions, name) {
        False, True -> Ok(name)
        _, _ -> Error(Nil)
      }
    Some(_) -> Error(Nil)
  }
  let #(wanted_state, handled) = case named {
    Ok("") | Error(Nil) -> #(any, any)
    Ok(name) ->
      case signature_of(env, name) {
        #([state, message], _) -> #(state, message)
        _ -> #(any, any)
      }
  }
  let #(state, builder) = expr(state, scope, wanted_state, builder)
  let state_type = ty_of(builder, state)
  let message_type = case types.stateable(handled) {
    True -> handled
    False -> wanted_message
  }
  case named, types.stateable(state_type), types.stateable(message_type) {
    Error(Nil), _, _ ->
      gap(
        start,
        at,
        "gleam/otp/actor.start/1",
        "the handler given to actor.on_message is not a function of this module, by its name: the actor's loop calls its handler by name, because a function value would be state of the waiting process, and the transpiler writes no closure (contract T9.14)",
      )
    Ok(handler), True, True -> {
      let subject = case types.stateable(wanted_data) {
        True -> wanted_data
        False -> TySubject(message_type)
      }
      let started = TyResult(TyStarted(subject), TyStartError)
      let actor = Actor(state_type, message_type, handler)
      let #(function, builder) =
        typed(
          emit(builder, at, frame.FunRef(_, "", actor_key(actor), 1)),
          TyFn([state_type], TyAtoms(["normal"])),
        )
      let builder = Builder(..builder, actors: [actor, ..builder.actors])
      // The new process is the actor's subject: its type is stated as such.
      let #(spawned, builder) =
        typed(
          emit(builder, at, frame.Spawn(_, function, [state], False)),
          subject,
        )
      // A name no Gleam variable has, and no other start in this function.
      let name = "_actor_" <> int.to_string(builder.next)
      let #(bound, builder) = emit(builder, at, frame.Var(_, name))
      let builder = hint(builder, bound, subject, Inferred)
      let #(binding, builder) =
        typed(emit(builder, at, frame.Match(_, bound, spawned)), subject)
      let #(ok, builder) = emit(builder, at, frame.Symbol(_, "ok"))
      let #(tag, builder) = emit(builder, at, frame.Symbol(_, "started"))
      let #(pid, builder) = emit(builder, at, frame.Var(_, name))
      let #(data, builder) = emit(builder, at, frame.Var(_, name))
      let #(record, builder) =
        typed(
          emit(builder, at, frame.Tuple(_, [tag, pid, data])),
          TyStarted(subject),
        )
      let #(value, builder) =
        typed(emit(builder, at, frame.Tuple(_, [ok, record])), started)
      typed(emit(builder, at, frame.Block(_, [binding, value])), started)
    }
    _, state_known, _ ->
      gap(
        start,
        at,
        "gleam/otp/actor.start/1",
        case state_known {
          False ->
            types.reason(state_type) <> ", so the actor's state has no type"
          True ->
            "the actor's message type is not known (the handler is not a function with an annotated signature, and no annotation gives the type of the start's result), so the message the actor's loop receives has no type"
        }
          <> " (T8.10 e)",
      )
  }
}

/// A child of a gleam_otp static supervisor that sup.gleam read (contract
/// T9.14b): a `(:register)` of a `(:spawn)` of the actor's loop function
/// with its literal state. The transpiler writes it into the child list its
/// unit's supervisor has from its start, registered under the name.
///
/// The NAME is the one the unit makes for the handler's message type
/// (`environment`: `let n: Name(M) = process.new_name("literal")`). The
/// child's restart policy and its supervisor's strategy, AS THE GLEAM SOURCE
/// WRITES THEM, are an A4.4 override on the `(:spawn)` (T7.6). The spawn is
/// not linked: the child is under a supervisor, which is what the link of a
/// supervisor's child is for. The node's value is `true`.
fn static_child(
  at: g.Span,
  restart: String,
  strategy: String,
  state: g.Expression,
  handler: g.Expression,
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let env = builder.env
  let no = fn(why: String) {
    gap(
      start,
      at,
      sup.gap_construct,
      "a supervisor is sent only as its static children (contract T9.14b), and a child of this one could not be sent: "
        <> why
        <> " (README, \"A static supervisor\")",
    )
  }
  let named = case handler {
    g.Variable(name:, ..) ->
      case local(scope, name), dict.has_key(env.functions, name) {
        False, True -> Ok(name)
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case named {
    Error(Nil) ->
      no(
        "the handler given to actor.on_message is not a function of this module, by its name",
      )
    Ok(handler) ->
      case signature_of(env, handler) {
        #([state_type, message_type], _) ->
          case
            types.closed(state_type) && types.closed(message_type),
            list.key_find(env.resolver.names, message_type)
          {
            False, _ ->
              no(
                "the handler "
                <> handler
                <> " has no annotated signature that gives the actor's state and message types (T8.10 e)",
              )
            True, Error(Nil) -> no(types.no_name)
            True, Ok(name) -> {
              let #(state, builder) = expr(state, scope, state_type, builder)
              let literal = case node_at(builder, state) {
                Ok(frame.Int(..))
                | Ok(frame.Float(..))
                | Ok(frame.Boolean(..))
                | Ok(frame.Symbol(..)) -> True
                _ -> False
              }
              case literal {
                False ->
                  no(
                    "the state given to actor.new is not a literal: the arguments of a static child are literals",
                  )
                True -> {
                  let actor = Actor(state_type, message_type, handler)
                  let #(function, builder) =
                    typed(
                      emit(builder, at, frame.FunRef(_, "", actor_key(actor), 1)),
                      TyFn([state_type], TyAtoms(["normal"])),
                    )
                  let builder =
                    Builder(..builder, actors: [actor, ..builder.actors])
                  let #(spawned, builder) =
                    typed(
                      emit(builder, at, frame.Spawn(_, function, [state], False)),
                      TySubject(message_type),
                    )
                  let override =
                    frame.Override(
                      node: spawned,
                      requirement: "a4_4",
                      choice: "chosen",
                      params: [#("restart", restart), #("strategy", strategy)],
                      note: "the child specification (supervision.restart) and the strategy of static_supervisor.new",
                    )
                  let builder =
                    Builder(..builder, overrides: [
                      override,
                      ..builder.overrides
                    ])
                  typed(
                    emit(builder, at, frame.Register(_, name, spawned)),
                    TyBool,
                  )
                }
              }
            }
          }
        _ ->
          no(
            "the handler "
            <> handler
            <> " is not a function of two parameters (state, message)",
          )
      }
  }
}

/// The helper function form an actor of one kind runs (see the head of this
/// section): a process function, its receive in tail position (contract
/// T9.13). It is marked with a loop hint (H37): it recurses without bound.
/// Every type in it is `inferred` (contract 8.2): this codex worked it out
/// from the state and message types of the actors the unit starts.
///
///   fn loop(state) {
///     receive { #(subject__<message>, _message) ->
///       case handler(state, _message) {
///         #(continue, _state) -> loop(_state)
///         stop -> normal
///         #(stop_abnormal, _reason) -> fail(_reason)
///       }
///     }
///   }
fn actor_loop_form(env: Env, name: String, actor: Actor) -> Form {
  let Actor(state: state_type, message: message_type, handler:) = actor
  let at = g.Span(0, 0)
  let builder = new_builder(env)
  let next_type = TyNext(state_type, message_type)
  let normal = TyAtoms(["normal"])
  let var = fn(builder, name) { emit(builder, at, frame.Var(_, name)) }
  let bind = fn(builder, name, ty) {
    let #(index, builder) = emit(builder, at, frame.Var(_, name))
    #(index, hint(builder, index, ty, Inferred))
  }
  let symbol = fn(builder, name) { emit(builder, at, frame.Symbol(_, name)) }
  let #(state, builder) = bind(builder, "state", state_type)
  // T8.10 (e), T9.12: one clause for each way a message of the actor's
  // type arrives (`message_clauses`).
  let decided = fn(taken: fn(Builder) -> #(Int, Builder), builder: Builder) {
    case handler {
      // No handler: gleam_otp's default keeps the state.
      "" -> {
        let #(argument, builder) = var(builder, "state")
        typed(emit(builder, at, frame.Call(_, "", name, [argument])), normal)
      }
      _ -> {
        // handler(state, message)
        let #(argument1, builder) = var(builder, "state")
        let #(argument2, builder) = taken(builder)
        let #(next, builder) =
          typed(
            emit(
              builder,
              at,
              frame.Call(_, "", fname(env, handler), [
                argument1,
                argument2,
              ]),
            ),
            next_type,
          )
        // #(continue, _state) -> loop(_state)
        let #(tag, builder) = symbol(builder, "continue")
        let #(new_state, builder) = bind(builder, "_state", state_type)
        let #(pattern, builder) =
          emit(builder, at, frame.Tuple(_, [tag, new_state]))
        let #(argument, builder) = var(builder, "_state")
        let #(again, builder) =
          typed(emit(builder, at, frame.Call(_, "", name, [argument])), normal)
        let #(continue, builder) =
          emit(builder, at, frame.Clause(_, [pattern], -1, again))
        // stop -> normal
        let #(pattern, builder) = symbol(builder, "stop")
        let #(value, builder) = typed(symbol(builder, "normal"), normal)
        let #(stop, builder) =
          emit(builder, at, frame.Clause(_, [pattern], -1, value))
        // #(stop_abnormal, _reason) -> fail(_reason)
        let #(tag, builder) = symbol(builder, "stop_abnormal")
        let #(reason, builder) = bind(builder, "_reason", TyString)
        let #(pattern, builder) =
          emit(builder, at, frame.Tuple(_, [tag, reason]))
        let #(reason, builder) = var(builder, "_reason")
        let #(failed, builder) = emit(builder, at, frame.Fail(_, reason))
        let #(stop_abnormal, builder) =
          emit(builder, at, frame.Clause(_, [pattern], -1, failed))
        typed(
          emit(
            builder,
            at,
            frame.Case(_, next, [continue, stop, stop_abnormal]),
          ),
          normal,
        )
      }
    }
  }
  let #(clauses, builder) = message_clauses(at, message_type, builder, decided)
  let #(received, builder) =
    typed(emit(builder, at, frame.Receive(_, clauses, -1, -1)), normal)
  let #(body, builder) =
    typed(emit(builder, at, frame.LoopHint(_, received)), normal)
  let #(clause, builder) = emit(builder, at, frame.Clause(_, [state], -1, body))
  let #(table, hints) =
    hint_table(builder, TyFn([state_type], normal), Inferred)
  frame.Function(
    name:,
    arity: 1,
    exported: False,
    file: env.file,
    locations: list.reverse(builder.locations),
    nodes: list.reverse(builder.nodes),
    clauses: [clause],
    types: table,
    hints:,
    overrides: [],
  )
}

/// The constructors of other modules whose field labels this codex knows:
/// `actor.Started(pid:, data:)`. `alias` is the module's name in this file.
fn library_constructor(
  alias: String,
  name: String,
  env: Env,
) -> Result(Constructor, Nil) {
  case dict.get(env.imports, alias), name {
    Ok("gleam/otp/actor"), "Started" ->
      Ok(
        Constructor(
          labels: [Some("pid"), Some("data")],
          record: False,
          type_name: "",
          type_: started_type,
          params: ["data"],
          fields: [TyPid, TyVar("data")],
        ),
      )
    _, _ -> Error(Nil)
  }
}

/// Why calls into a module are gaps, for the modules that are.
fn module_note(module: String) -> Option(String) {
  let starts = string.starts_with(module, _)
  case module {
    _ if module == "gleam/erlang/node" -> Some(inter_node)
    _ if module == "gleam/erlang/process" ->
      Some(
        "this function of gleam/erlang/process (selectors, monitors, names, timers, exits) is outside the proof of concept",
      )
    _
      if module == "gleam/otp/static_supervisor"
      || module == "gleam/otp/supervision"
    ->
      Some(
        "a supervisor is sent only as its static children (contract T9.14b), and it is read where it is started by a statement `let assert Ok(_) = ...`, whose value is not used: this call is not part of such a start (README, \"A static supervisor\")",
      )
    _ ->
      case starts("gleam/otp/") {
        True ->
          Some(
            "this part of gleam_otp is not lowered (contract 9.2 leaves OTP behaviours open); see the README, \"gleam_otp actors\"",
          )
        False -> None
      }
  }
}

/// A constructor applied to arguments. Its type is the constructor's type
/// (T8.10 e: a record construction that is not the function's result needs
/// its type stated; a variant with fields is a tuple, which gets the same).
fn construct(
  at: g.Span,
  name: String,
  module: Option(String),
  arguments: List(Argument(g.Expression)),
  scope: Scope,
  expected: Ty,
  builder: Builder,
) -> #(Int, Builder) {
  let env = builder.env
  let start = builder
  let known = case module {
    None -> dict.get(env.constructors, name)
    Some(_) -> Error(Nil)
  }
  // A variant with fields: a tuple, the constructor's symbol first (H8, H5).
  let tagged = fn(arguments, wanted, type_of: fn(List(Ty)) -> Ty) {
    let #(tag, builder) = emit(builder, at, frame.Symbol(_, names.symbol(name)))
    let #(elements, builder) = exprs(arguments, scope, wanted, builder)
    typed(
      emit(builder, at, frame.Tuple(_, [tag, ..elements])),
      type_of(list.map(elements, ty_of(builder, _))),
    )
  }
  case known {
    // The record idiom (H12). Fields are in the order the source gives them.
    Ok(Constructor(labels:, record: True, type_name:, ..) as constructor) ->
      case named(labels, arguments) {
        Ok(fields) -> {
          let by_label = list.zip(labels, field_types(constructor, expected))
          let #(indices, builder) =
            each(fields, builder, fn(field, builder) {
              let wanted =
                result.unwrap(list.key_find(by_label, Some(field.0)), any)
              let wanted = case types.closed(wanted) {
                True -> wanted
                False -> any
              }
              expr(field.1, scope, wanted, builder)
            })
          let given =
            list.map2(fields, indices, fn(field, index) {
              #(Some(field.0), ty_of(builder, index))
            })
          let ty =
            constructed(
              constructor,
              list.map(labels, fn(label) {
                result.unwrap(list.key_find(given, label), any)
              }),
              expected,
              env,
            )
          let fields =
            list.map2(fields, indices, fn(field, index) {
              #(names.ident(field.0), index)
            })
          case types.stateable(ty) {
            True ->
              typed(
                emit(builder, at, frame.Record(_, type_name, fields, -1)),
                ty,
              )
            False ->
              gap(
                start,
                at,
                name,
                types.reason(ty) <> ", so this record has no type (T8.10 e)",
              )
          }
        }
        Error(Nil) -> out_of_order(at, name, arguments, builder)
      }
    Ok(Constructor(labels:, record: False, ..) as constructor) ->
      case in_order(labels, arguments) {
        Ok(arguments) ->
          tagged(
            arguments,
            expectations(field_types(constructor, expected)),
            constructed(constructor, _, expected, env),
          )
        Error(Nil) -> out_of_order(at, name, arguments, builder)
      }
    // A constructor of another module: its fields are known only by
    // position, and its type only for the prelude's Ok and Error.
    Error(Nil) ->
      case positional(arguments) {
        Ok(arguments) -> {
          let undecided = fn(side) {
            TyUnknown(
              "the "
              <> side
              <> " type of this "
              <> name
              <> "(…) is not in the expression: it is decided by where the value is used",
            )
          }
          case name, module, expected {
            "Ok", None, TyResult(ok:, error:) ->
              tagged(arguments, [ok], fn(given) {
                case given {
                  [value] -> TyResult(value, error)
                  _ -> any
                }
              })
            "Error", None, TyResult(ok:, error:) ->
              tagged(arguments, [error], fn(given) {
                case given {
                  [value] -> TyResult(ok, value)
                  _ -> any
                }
              })
            "Ok", None, _ ->
              tagged(arguments, [], fn(given) {
                case given {
                  [value] -> TyResult(value, undecided("error"))
                  _ -> any
                }
              })
            "Error", None, _ ->
              tagged(arguments, [], fn(given) {
                case given {
                  [value] -> TyResult(undecided("ok"), value)
                  _ -> any
                }
              })
            _, _, _ ->
              tagged(arguments, [], fn(_) {
                TyUnknown(
                  "the type of "
                  <> name
                  <> ", a constructor of another module, is not known to this codex",
                )
              })
          }
        }
        Error(Nil) -> out_of_order(at, name, arguments, builder)
      }
  }
}

fn out_of_order(
  at: g.Span,
  name: String,
  arguments: List(Argument(a)),
  builder: Builder,
) -> #(Int, Builder) {
  gap(
    builder,
    at,
    name <> "/" <> int.to_string(list.length(arguments)),
    "labelled arguments that cannot be put in declaration order without changing the order they are evaluated in",
  )
}

// ------------------------------------------------------------ arguments

fn expr_field(field: g.Field(g.Expression)) -> Argument(g.Expression) {
  case field {
    g.LabelledField(label:, item:, ..) -> #(Some(label), item)
    g.ShorthandField(label:, location:) -> #(
      Some(label),
      g.Variable(location, label),
    )
    g.UnlabelledField(item:) -> #(None, item)
  }
}

fn pattern_field(field: g.Field(g.Pattern)) -> Argument(g.Pattern) {
  case field {
    g.LabelledField(label:, item:, ..) -> #(Some(label), item)
    g.ShorthandField(label:, location:) -> #(
      Some(label),
      g.PatternVariable(location, label),
    )
    g.UnlabelledField(item:) -> #(None, item)
  }
}

fn argument(label: Option(String), at: g.Span, item: a) -> g.Field(a) {
  case label {
    Some(label) -> g.LabelledField(label, at, item)
    None -> g.UnlabelledField(item)
  }
}

/// The arguments, when none has a label.
fn positional(arguments: List(Argument(a))) -> Result(List(a), Nil) {
  list.try_map(arguments, fn(argument) {
    case argument {
      #(None, item) -> Ok(item)
      #(Some(_), _) -> Error(Nil)
    }
  })
}

/// The arguments, when they are all there and already in declaration order:
/// each is unlabelled or carries the label declared at its position.
fn in_order(
  labels: List(Option(String)),
  arguments: List(Argument(a)),
) -> Result(List(a), Nil) {
  case labels, arguments {
    [], [] -> Ok([])
    [declared, ..labels], [#(given, item), ..arguments] ->
      case given == None || given == declared {
        True -> result.map(in_order(labels, arguments), list.prepend(_, item))
        False -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

/// Each argument with its field's name, in the order given: an unlabelled
/// argument takes the label declared at its position.
fn named(
  labels: List(Option(String)),
  arguments: List(Argument(a)),
) -> Result(List(#(String, a)), Nil) {
  case labels, arguments {
    _, [] -> Ok([])
    _, [#(Some(label), item), ..arguments] ->
      result.map(
        named(list.drop(labels, 1), arguments),
        list.prepend(_, #(label, item)),
      )
    [Some(label), ..labels], [#(None, item), ..arguments] ->
      result.map(named(labels, arguments), list.prepend(_, #(label, item)))
    _, _ -> Error(Nil)
  }
}

/// For each declared field, the argument given for it: by position for the
/// unlabelled arguments, which come first, then by label.
fn by_position(
  labels: List(Option(String)),
  arguments: List(Argument(a)),
) -> List(Option(a)) {
  case labels, arguments {
    [], _ -> []
    [_, ..labels], [#(None, item), ..arguments] -> [
      Some(item),
      ..by_position(labels, arguments)
    ]
    [declared, ..labels], _ -> [
      list.find(arguments, fn(argument) { argument.0 == declared })
        |> result.map(fn(argument) { argument.1 })
        |> option.from_result,
      ..by_position(labels, arguments)
    ]
  }
}

// ------------------------------------------------------------ operators

/// `a |> f(b)` is `f(a, b)` and `a |> f` is `f(a)`. `a |> f(b, _)` is
/// `{ let _pipe = a  f(b, _pipe) }`, as the Gleam compiler writes it, so that
/// `a` is still evaluated before `b`. Gleam also reads `a |> f(b)` as
/// `f(b)(a)` when `f` does not take `a` first; that reading needs types,
/// which glance does not give.
fn pipe(at: g.Span, left: g.Expression, right: g.Expression) -> g.Expression {
  case right {
    g.Call(function:, arguments:, ..) ->
      g.Call(at, function, [g.UnlabelledField(left), ..arguments])
    g.FnCapture(label:, function:, arguments_before: [], arguments_after:, ..) ->
      g.Call(at, function, [argument(label, at, left), ..arguments_after])
    g.FnCapture(label:, function:, arguments_before:, arguments_after:, ..) ->
      g.Block(at, [
        g.Assignment(at, g.Let, g.PatternVariable(at, "_pipe"), None, left),
        g.Expression(g.Call(
          at,
          function,
          list.flatten([
            arguments_before,
            [argument(label, at, g.Variable(at, "_pipe"))],
            arguments_after,
          ]),
        )),
      ])
    _ -> g.Call(at, right, [g.UnlabelledField(left)])
  }
}

/// A binary operator (H31, Appendix B).
///
/// T8.10 (c), T8.11: both operands need one stated type. Gleam never mixes
/// Int and Float in an operator, and the operator's spelling says which it
/// is: `+ - * / %` and `< > <= >=` take Int, `+. -. *. /.` and
/// `<. >. <=. >=.` take Float, `<>` String, `&&` and `||` Bool. So every
/// operand is written with that type as its place's type, and an operand the
/// codex has no type for is hinted with it: a statement of the language
/// side, read off the source. Both spellings are one `op` on the wire; the
/// operands' stated types carry the difference. `==` and `!=` take two
/// values of one type, whatever it is: each operand takes the other's type
/// when it has none, and with no type on either side the comparison is a
/// gap.
fn binary(
  at: g.Span,
  name: g.BinaryOperator,
  left: g.Expression,
  right: g.Expression,
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let start = builder
  let both = fn(op: String, operand: Ty, result: Ty) {
    let #(left, builder) = expr(left, scope, operand, builder)
    let #(right, builder) = expr(right, scope, operand, builder)
    typed(emit(builder, at, frame.Op(_, op, [left, right])), result)
  }
  case name {
    g.And -> both("andalso", TyBool, TyBool)
    g.Or -> both("orelse", TyBool, TyBool)
    g.LtInt -> both("<", TyInt, TyBool)
    g.LtEqInt -> both("=<", TyInt, TyBool)
    g.GtInt -> both(">", TyInt, TyBool)
    g.GtEqInt -> both(">=", TyInt, TyBool)
    g.LtFloat -> both("<", TyFloat, TyBool)
    g.LtEqFloat -> both("=<", TyFloat, TyBool)
    g.GtFloat -> both(">", TyFloat, TyBool)
    g.GtEqFloat -> both(">=", TyFloat, TyBool)
    g.AddInt -> both("+", TyInt, TyInt)
    g.SubInt -> both("-", TyInt, TyInt)
    g.MultInt -> both("*", TyInt, TyInt)
    g.AddFloat -> both("+", TyFloat, TyFloat)
    g.SubFloat -> both("-", TyFloat, TyFloat)
    g.MultFloat -> both("*", TyFloat, TyFloat)
    g.Concatenate -> both("<>", TyString, TyString)
    g.DivInt -> division(at, "div", TyInt, left, right, scope, builder)
    g.RemainderInt -> division(at, "rem", TyInt, left, right, scope, builder)
    g.DivFloat -> division(at, "/", TyFloat, left, right, scope, builder)
    g.Eq | g.NotEq -> {
      let op = case name {
        g.Eq -> "=="
        _ -> "/="
      }
      let #(left, builder) = expr(left, scope, any, builder)
      let #(right, builder) = expr(right, scope, ty_of(builder, left), builder)
      let right_type = ty_of(builder, right)
      let builder = adopt(#(left, builder), right_type).1
      case types.stateable(ty_of(builder, left)), types.stateable(right_type) {
        True, True ->
          typed(emit(builder, at, frame.Op(_, op, [left, right])), TyBool)
        _, _ ->
          gap(
            start,
            at,
            "operator " <> op,
            "neither operand has a type known to this codex ("
              <> types.reason(right_type)
              <> "), so the operands have no stated type (T8.10 c)",
          )
      }
    }
    // The pipe is rewritten to a call before this is reached.
    g.Pipe -> gap(builder, at, "pipe", out_of_scope)
  }
}

/// `/`, `%` and `/.`, with the guard Gleam's semantics need (T8.15).
///
/// In Gleam `a / 0` is 0, `a % 0` is 0 and `a /. 0.0` is 0.0. Silica's
/// integer division and remainder by zero end the actor, and its float
/// division by zero gives a value that is no number (limitation observed,
/// Appendix B). So the division is sent as
///
///   { let _dividend_N = <left>         only if left is not a variable or literal
///     let _divisor_N = <right>         only if right is not a variable or literal
///     case _divisor_N == 0 { True -> 0   False -> _dividend_N div _divisor_N } }
///
/// Each operand is evaluated once, left first, also when the divisor is
/// zero. A divisor that is a literal other than zero needs no guard. `div`
/// and `rem` cut toward zero, as Gleam's `/` and `%` on Int do.
fn division(
  at: g.Span,
  op: String,
  ty: Ty,
  left: g.Expression,
  right: g.Expression,
  scope: Scope,
  builder: Builder,
) -> #(Int, Builder) {
  let nonzero_literal = case right {
    g.Int(value:, ..) ->
      case parse_int(value) {
        Ok(value) -> value != 0
        Error(Nil) -> False
      }
    g.Float(value:, ..) ->
      case float.parse(float_text(value)) {
        Ok(value) -> value != 0.0
        Error(Nil) -> False
      }
    _ -> False
  }
  case nonzero_literal {
    True -> {
      let #(left, builder) = expr(left, scope, ty, builder)
      let #(right, builder) = expr(right, scope, ty, builder)
      typed(emit(builder, at, frame.Op(_, op, [left, right])), ty)
    }
    False -> {
      let number = int.to_string(builder.next)
      let #(first, left, builder) =
        once(left, "_dividend_" <> number, ty, scope, builder)
      let #(second, right, builder) =
        once(right, "_divisor_" <> number, ty, scope, builder)
      let bindings = list.append(first, second)
      let scope =
        list.append(list.map(bindings, fn(bound) { #(bound.0, ty) }), scope)
      let zero = fn(builder) {
        case ty {
          TyFloat -> emit(builder, at, frame.Float(_, "0.0"))
          _ -> emit(builder, at, frame.Int(_, 0))
        }
      }
      // _divisor == 0
      let #(divisor, builder) = expr(right, scope, ty, builder)
      let #(nothing, builder) = zero(builder)
      let #(test_, builder) =
        typed(emit(builder, at, frame.Op(_, "==", [divisor, nothing])), TyBool)
      // True -> 0
      let #(yes, builder) = emit(builder, at, frame.Boolean(_, True))
      let #(nothing, builder) = zero(builder)
      let #(by_zero, builder) =
        emit(builder, at, frame.Clause(_, [yes], -1, nothing))
      // False -> _dividend div _divisor
      let #(no, builder) = emit(builder, at, frame.Boolean(_, False))
      let #(dividend, builder) = expr(left, scope, ty, builder)
      let #(divisor, builder) = expr(right, scope, ty, builder)
      let #(quotient, builder) =
        typed(emit(builder, at, frame.Op(_, op, [dividend, divisor])), ty)
      let #(otherwise, builder) =
        emit(builder, at, frame.Clause(_, [no], -1, quotient))
      let #(guarded, builder) =
        typed(emit(builder, at, frame.Case(_, test_, [by_zero, otherwise])), ty)
      let bindings = list.map(bindings, fn(bound) { bound.1 })
      case bindings {
        [] -> #(guarded, builder)
        _ ->
          typed(
            emit(builder, at, frame.Block(_, list.append(bindings, [guarded]))),
            ty,
          )
      }
    }
  }
}

/// An operand that must be evaluated exactly once and may be used twice. A
/// local variable or a literal is used as it is. Anything else is bound to
/// a variable of the codex's own first (H18): the match is written here, and
/// the operand becomes that variable.
fn once(
  operand: g.Expression,
  name: String,
  ty: Ty,
  scope: Scope,
  builder: Builder,
) -> #(List(#(String, Int)), g.Expression, Builder) {
  let simple = case operand {
    g.Int(..) | g.Float(..) -> True
    g.Variable(name:, ..) -> local(scope, name)
    _ -> False
  }
  case simple {
    True -> #([], operand, builder)
    False -> {
      let at = operand.location
      let #(value, builder) = expr(operand, scope, ty, builder)
      let #(bound, builder) = emit(builder, at, frame.Var(_, name))
      let builder = hint(builder, bound, ty, Inferred)
      let #(match, builder) =
        typed(emit(builder, at, frame.Match(_, bound, value)), ty)
      #([#(name, match)], g.Variable(at, name), builder)
    }
  }
}

// ------------------------------------------------------------ literals

/// H1. Gleam writes `1_000`, `0xff`, `0o17`, `0b101`; integers beyond 64 bits
/// are a gap.
fn int_literal(at: g.Span, text: String, builder: Builder) -> #(Int, Builder) {
  case parse_int(text) {
    Ok(value)
      if value >= -9_223_372_036_854_775_808
      && value <= 9_223_372_036_854_775_807
    -> emit(builder, at, frame.Int(_, value))
    _ -> gap(builder, at, "integer beyond 64 bits", out_of_scope)
  }
}

fn parse_int(text: String) -> Result(Int, Nil) {
  let text = string.replace(text, "_", "")
  let #(sign, digits) = case text {
    "-" <> rest -> #(-1, rest)
    _ -> #(1, text)
  }
  let value = case digits {
    "0x" <> rest | "0X" <> rest -> int.base_parse(rest, 16)
    "0o" <> rest | "0O" <> rest -> int.base_parse(rest, 8)
    "0b" <> rest | "0B" <> rest -> int.base_parse(rest, 2)
    _ -> int.parse(digits)
  }
  result.map(value, fn(value) { sign * value })
}

/// H2: a float as decimal text. Gleam's `1_000.5` and `1.` are written
/// `1000.5` and `1.0`.
fn float_text(text: String) -> String {
  let text = string.replace(text, "_", "")
  case string.ends_with(text, ".") {
    True -> text <> "0"
    False -> string.replace(text, ".e", ".0e")
  }
}

/// H3. glance keeps a string's escapes as written; the frame carries the text
/// they stand for.
fn text_literal(at: g.Span, text: String, builder: Builder) -> #(Int, Builder) {
  case glexer.unescape_string(text) {
    Ok(text) -> emit(builder, at, frame.Text(_, text))
    Error(Nil) ->
      gap(builder, at, "string with an unknown escape", out_of_scope)
  }
}

// ------------------------------------------------------------ locations

/// The byte offset at which each line of the source starts.
fn line_starts(text: String) -> List(Int) {
  let #(_, starts) =
    list.fold(string.split(text, "\n"), #(0, []), fn(acc, line) {
      #(acc.0 + string.byte_size(line) + 1, [acc.0, ..acc.1])
    })
  list.reverse(starts)
}

/// glance gives byte offsets; the contract wants (line, column) (T9.3). Both
/// count from 1, and the column counts bytes.
fn locate(lines: List(Int), offset: Int) -> #(Int, Int) {
  locate_from(lines, offset, 0, 0)
}

fn locate_from(
  lines: List(Int),
  offset: Int,
  line: Int,
  start: Int,
) -> #(Int, Int) {
  case lines {
    [next, ..rest] if next <= offset -> locate_from(rest, offset, line + 1, next)
    _ -> #(line, offset - start + 1)
  }
}
