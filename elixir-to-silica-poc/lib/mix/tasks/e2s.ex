defmodule Mix.Tasks.E2s do
  @shortdoc "Sends Elixir source to a to-silica transpiler (check mode by default)"
  @moduledoc """
  Parses Elixir source files, maps them to the frames of the to-silica TCP transport contract v1 and sends them to
  a transpiler on 127.0.0.1.

      mix e2s [--port N] [--mode check|transpile] [--resume SESSION] [--dump | --gaps] file.ex ...
      mix e2s [--port N] --release SESSION

  `--port` defaults to 7411, `--mode` to `check`. `--dump` prints the frames and sends nothing; `--gaps` prints
  the gaps the sender would send and sends nothing. `--resume` resumes a transpile session after a dropped
  connection (T6.5). `--release` releases a finished transpile session (contract M7); a session id is the text
  the transpiler gave, such as `intake_1:42`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case E2s.CLI.run(args) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
