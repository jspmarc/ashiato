defmodule Ashiato.Translator.Fake do
  @moduledoc """
  Test double: deterministic output, recorded calls, configurable line-count
  mismatch. Start one per test with `start_supervised!(Ashiato.Translator.Fake)`
  and point `impl/0` at this module; tests never touch a real provider.
  """
  use Ashiato.Translator

  @doc """
  Starts the recording agent, named after this module (one fake per test; tests
  run sequentially). Options:

    * `:page_count_mismatch` — when `true`, a page request for more than one line
      returns one line too few, which forces the shared per-line fallback. Single-
      line requests are always aligned, so the fallback terminates.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{calls: [], page_count_mismatch?: Keyword.get(opts, :page_count_mismatch, false)} end,
      name: __MODULE__
    )
  end

  @doc "Every recorded page request, oldest first, as `%{lines: ..., opts: ...}`."
  @spec calls() :: [%{lines: [String.t()], opts: keyword()}]
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc """
  The deterministic transform: each line `l` becomes `"[<target_lang>] " <> l`,
  with `:target_lang` taken from `opts`.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      result =
        if state.page_count_mismatch? and length(lines) > 1 do
          {:ok, lines |> Enum.drop(-1) |> Enum.map(&render(&1, opts))}
        else
          {:ok, Enum.map(lines, &render(&1, opts))}
        end

      {result, %{state | calls: state.calls ++ [%{lines: lines, opts: opts}]}}
    end)
  end

  defp render(line, opts) do
    "[" <> Keyword.get(opts, :target_lang, "?") <> "] " <> line
  end
end
