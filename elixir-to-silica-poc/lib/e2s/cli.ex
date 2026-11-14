defmodule E2s.CLI do
  @moduledoc """
  The command line of elixir-to-silica-poc.

      mix e2s [--port N] [--mode check|transpile] [--resume SESSION] [--dump | --gaps | --split] file.ex ...
      mix e2s [--port N] --release SESSION

  `--dump` prints the frames and sends nothing; `--gaps` prints only the gaps the sender would send (construct,
  note, place) and sends nothing; `--split` prints each module as the sender's split leaves it (every receive in
  tail position: `E2s.Split`), as Elixir source, and sends nothing. The default mode is `check` (contract 6.5), the default port 7411 (T3.1); the
  host is always 127.0.0.1. Exit status: 0 when the session's result is `:ok`, 1 otherwise, 2 on a usage error.

  `--resume SESSION` (transpile mode only, T6.12) sends the same session again on a new connection after a drop:
  the hello names the session and only the frames from the welcome's `resume_from` are sent (T6.5, T6.5a).

  `--release SESSION` sends no source: it releases a finished transpile session (M7, T6.13) and prints the
  transpiler's answer. Exit status: 0 when the session's storage was freed, 1 otherwise. A session id is the text
  the transpiler gave, such as `intake_1:42` (T6.5b).
  """

  @usage "usage: mix e2s [--port N] [--mode check|transpile] [--resume SESSION] [--dump | --gaps | --split] file.ex ...\n       mix e2s [--port N] --release SESSION"

  @doc "The escript entry point."
  def main(args), do: System.halt(run(args))

  @doc "Runs the command line and returns the exit status."
  def run(args) do
    {opts, files, invalid} = OptionParser.parse(args, strict: [port: :integer, mode: :string, dump: :boolean, gaps: :boolean, split: :boolean, release: :string, resume: :string])
    mode = Keyword.get(opts, :mode, "check")
    port = Keyword.get(opts, :port, 7411)

    cond do
      invalid == [] and files == [] and is_binary(opts[:release]) and Keyword.drop(opts, [:port, :release]) == [] ->
        release(port, opts[:release])

      is_binary(opts[:release]) ->
        IO.puts(@usage)
        2

      invalid != [] or files == [] or mode not in ["check", "transpile"] or (opts[:resume] != nil and mode == "check") ->
        IO.puts(@usage)
        2

      true ->
        go(files, String.to_atom(mode), port, opts)
    end
  end

  # M7. The session id is the one the result of the transpile session named.
  defp release(port, session) do
    case E2s.Sender.release("127.0.0.1", port, session) do
      {:ok, %{session: session, freed: true}} ->
        IO.puts("released: session #{session}, freed true")
        0

      {:ok, %{session: session, freed: false}} ->
        IO.puts("released: session #{session}, freed false (the session is unknown or not finished)")
        1

      {:error, :closed_without_reply} ->
        IO.puts("error: the transpiler closed the connection without a released frame; the session may not be freed")
        1

      {:error, why} ->
        IO.puts("error: #{inspect(why)}")
        1
    end
  end

  defp go(files, mode, port, opts) do
    # The parser is the gate: the frames of the whole session exist before anything is connected or sent.
    frames = if opts[:split], do: [], else: E2s.Codex.frames(files, mode, session: Keyword.get(opts, :resume, ""))

    cond do
      opts[:split] ->
        for file <- files, module <- E2s.Codex.split(file), do: IO.puts(Macro.to_string(module))
        0

      opts[:dump] ->
        Enum.each(frames, &IO.inspect(&1, limit: :infinity, printable_limit: :infinity, charlists: :as_lists, width: 120))
        0

      opts[:gaps] ->
        gaps(frames)
        0

      true ->
        report(E2s.Sender.run("127.0.0.1", port, frames), frames)
    end
  rescue
    error in [E2s.Codex.Error, File.Error] ->
      IO.puts("error: " <> Exception.message(error) <> " (nothing was sent)")
      1
  end

  # The gaps this sender sends, one per line. A "missing type" or "type rule" gap is a type or a conversion the
  # codex could not state (contract 8.6); the others are constructs outside the proof of concept.
  defp gaps(frames) do
    gaps = E2s.Codex.gaps(frames)
    for {unit, form, line, construct, note} <- gaps, do: IO.puts("#{unit} #{form} line #{line}: #{construct}: #{note}")
    IO.puts(gap_summary(gaps))
  end

  defp gap_summary(gaps) do
    typing = Enum.count(gaps, fn {_, _, _, construct, _} -> String.starts_with?(construct, ["missing type: ", "type rule: "]) end)
    "gaps sent by this sender: #{length(gaps)} (#{typing} for a type or conversion it could not state, #{length(gaps) - typing} outside the subset)"
  end

  defp report({:ok, %{welcome: welcome, result: result, rejected: rejected, diagnostics: diagnostics, sent: sent}}, frames) do
    IO.puts("session #{welcome.session} (#{welcome.transpiler}): #{sent} of #{length(frames) - 1} frames sent, from seq #{welcome.flow.resume_from}")
    IO.puts(gap_summary(E2s.Codex.gaps(frames)))

    for %{seq: seq, reason: reason, where: where} <- rejected do
      IO.puts("rejected seq #{seq}: #{inspect(reason)} #{where}")
    end

    for %{finding: %{severity: severity, code: code, message: message}, place: %{file: file, line: line}} <- diagnostics do
      IO.puts("#{severity} #{code}: #{message} (#{file}:#{line})")
    end

    case result do
      %{status: status, counts: %{units: units, gaps: gaps, rejected: n}, files: files} ->
        IO.puts("result: #{inspect(status)} (units #{units}, gaps #{gaps}, rejected #{n}, files #{files})")
        if status == :ok, do: 0, else: 1

      :none ->
        IO.puts("the transpiler closed the connection without a result")
        1
    end
  end

  defp report({:refused, %{reason: reason, detail: detail}}, _frames) do
    IO.puts("refused: #{inspect(reason)} (#{detail})")
    1
  end

  defp report({:error, {:no_reply, session}}, _frames) do
    IO.puts("error: the transpiler sent nothing for 30 seconds (T3.5); a transpile session can be resumed with --resume #{session}")
    1
  end

  defp report({:error, why}, _frames) do
    IO.puts("error: #{inspect(why)}")
    1
  end
end
