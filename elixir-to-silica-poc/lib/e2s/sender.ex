defmodule E2s.Sender do
  @moduledoc """
  The TCP sender of elixir-to-silica-poc. It speaks the to-silica TCP transport contract, version 1: every frame
  is a 4-byte big-endian length and one ETF term (T4.1, T4.2: `:gen_tcp`'s `packet: 4` and
  `:erlang.term_to_binary/1`); the hello first, nothing more until the welcome (T6.1); M2..M5 only while holding
  credit (T6.2); then everything the transpiler answers is read until `{:result, ...}` (T3.4).

  Replies are read **while** sending (T6.3, T6.11a): before each frame the sender takes every reply that has
  already arrived (`{:credit, n}`, `{:stored, next}`, `{:rejected, …}`), and when its credit is used up it waits
  for the transpiler's `{:stored, next}` and `{:credit, 32}`. It never sends without credit, and it does not leave
  replies unread until the end, so a session of any length goes through the transpiler's window (64 as built).

  If no reply comes for `@patience` milliseconds the sender gives up with `{:error, {:no_reply, session}}`
  (T3.5); a transpile session can then be resumed on a new connection (T6.5, `resume` in the frames' hello).
  """

  @patience 30_000

  # The atoms a transpiler may answer with (contract 5.3, 5.4, 6.4). Replies are decoded with [:safe], which only
  # accepts atoms this VM already knows; naming them here puts them in the atom table when this module is loaded.
  @reply_atoms [
    :welcome, :refused, :credit, :stored, :rejected, :progress, :diagnostic, :result, :released,
    :session, :contract, :transpiler, :flow, :resume_from, :max_frame, :reason, :detail, :seq, :where,
    :stage, :unit_name, :finding, :severity, :code, :message, :place, :file, :line, :column,
    :status, :counts, :units, :gaps, :files, :freed,
    :ok, :partial, :failed, :error, :warning, :note,
    :resolve, :hints, :lower, :mechanics, :print, :write,
    :session_mismatch, :unknown_session, :busy, :choices, :bad_hello,
    :truncated, :trailing_bytes, :bad_tag, :too_large, :too_deep, :too_long, :out_of_range, :bad_utf8,
    :unknown_atom, :bad_variant, :missing_field, :duplicate_field, :unknown_field, :unsupported, :bad_version,
    :seq_gap, :no_credit, :unit_order, :bad_unit_name, :bad_index, :bad_choice, :profile, :low_level, :bad_hint
  ]

  @doc false
  def reply_atoms, do: @reply_atoms

  @doc """
  Sends one session: `[hello | frames]`. When the hello names a session (a resume, T6.5), the frames below the
  welcome's `resume_from` are not sent again; a session whose `(:end)` was already stored gets `credit` 0 and
  nothing is sent: the result follows (T6.5a).

  Returns `{:ok, %{welcome: map, result: map | :none, rejected: [map], diagnostics: [map], stored: integer,
  sent: integer}}`, `{:refused, map}` or `{:error, term}`.
  """
  def run(host, port, [hello | frames]) do
    case :gen_tcp.connect(to_charlist(host), port, [:binary, packet: 4, active: false], 5000) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, :erlang.term_to_binary(hello))

        reply =
          case recv(socket, @patience) do
            {:welcome, %{flow: %{credit: credit, resume_from: from}} = welcome} ->
              acc = %{welcome: welcome, result: :none, rejected: [], diagnostics: [], stored: 0, sent: 0}
              send_frames(socket, drop_resent(frames, from), credit, acc)

            {:refused, why} ->
              {:refused, why}

            other ->
              {:error, {:expected_welcome, other}}
          end

        :gen_tcp.close(socket)
        reply

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  @doc """
  Releases a finished transpile session (M7, T6.13): on a new connection, `{:release, %{session: session}}` is the
  first and only frame; the transpiler answers `{:released, %{session: session, freed: boolean}}` and closes.
  Release a session only after its output is exported (T6.14). `session` is the id a result named, text such as
  `"intake_1:42"` (T6.5b: opaque).

  Returns `{:ok, %{session: binary, freed: boolean}}`, or `{:error, reason}`: `{:connect, reason}` when nothing
  listens, `:closed_without_reply` when the transpiler closed the connection and sent no `released` frame,
  `{:unexpected_reply, term}` for any other frame.
  """
  def release(host, port, session) when is_binary(session) do
    case :gen_tcp.connect(to_charlist(host), port, [:binary, packet: 4, active: false], 5000) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, :erlang.term_to_binary({:release, %{session: session}}))

        reply =
          case recv(socket, @patience) do
            {:released, %{session: _, freed: freed} = released} when is_boolean(freed) -> {:ok, released}
            {:error, :closed} -> {:error, :closed_without_reply}
            {:error, _} = error -> error
            other -> {:error, {:unexpected_reply, other}}
          end

        :gen_tcp.close(socket)
        reply

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # T6.5: on a resume, frames below resume_from need not be sent again. (A new session starts at 0.)
  defp drop_resent(frames, from), do: for({_, %{seq: seq}} = frame <- frames, seq >= from, do: frame)

  defp send_frames(socket, [], _credit, acc), do: finish(socket, acc)

  # Before each frame: take what the transpiler has already sent (wait 0); with no credit left, wait for more
  # (T6.2: no frame without credit; T6.3: the transpiler sends (:stored, n) then (:credit, 32) each half window).
  defp send_frames(socket, [frame | rest] = frames, credit, acc) do
    case recv(socket, if(credit == 0, do: @patience, else: 0)) do
      {:error, :timeout} when credit > 0 ->
        case :gen_tcp.send(socket, :erlang.term_to_binary(frame)) do
          :ok -> send_frames(socket, rest, credit - 1, %{acc | sent: acc.sent + 1})
          {:error, reason} -> {:error, {:send, reason}}
        end

      {:credit, n} ->
        send_frames(socket, frames, credit + n, acc)

      # The transpiler ended the session before every frame was sent.
      {:result, result} ->
        {:ok, done(%{acc | result: result})}

      {:error, :timeout} ->
        {:error, {:no_reply, acc.welcome.session}}

      {:error, _} = error ->
        error

      reply ->
        send_frames(socket, frames, credit, note(reply, acc))
    end
  end

  defp finish(socket, acc) do
    case recv(socket, @patience) do
      {:result, result} -> {:ok, done(%{acc | result: result})}
      {:error, :closed} -> {:ok, done(acc)}
      {:error, :timeout} -> {:error, {:no_reply, acc.welcome.session}}
      {:error, _} = error -> error
      reply -> finish(socket, note(reply, acc))
    end
  end

  defp note({:rejected, r}, acc), do: %{acc | rejected: [r | acc.rejected]}
  defp note({:diagnostic, d}, acc), do: %{acc | diagnostics: [d | acc.diagnostics]}
  defp note({:stored, next}, acc), do: %{acc | stored: next}
  defp note(_credit_or_progress, acc), do: acc

  defp done(acc), do: %{acc | rejected: Enum.reverse(acc.rejected), diagnostics: Enum.reverse(acc.diagnostics)}

  defp recv(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, bytes} ->
        try do
          :erlang.binary_to_term(bytes, [:safe])
        rescue
          ArgumentError -> {:error, {:bad_reply, bytes}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
