defmodule Ashiato.Translator.Fake do
  @moduledoc """
  Test double for `Ashiato.Translator` — no test calls a real provider.

  The output is a documented transform of the input (`"[" <> line <> "]"`), so an
  assertion on the returned lines proves the pipeline sent the right text and kept the
  order. `:mismatch` makes the page request answer with a single line, which is the
  input that must trigger the shared per-line fallback.

  State lives in an Agent started by the test, never in application env: the VM is
  shared and wave-2 cards run in parallel.
  """

  use Agent
  use Ashiato.Translator

  @doc """
  Starts the fake.

  ## Options

    * `:mismatch` — when true, a page request for more than one line answers with one
      line, forcing the fallback (default `false`)
    * `:error` — when set, every request returns `{:error, reason}` with it
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    state = %{
      mismatch: Keyword.get(opts, :mismatch, false),
      error: Keyword.get(opts, :error),
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc """
  Records the request and answers with the deterministic translation of its lines.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      {reply(state, lines), %{state | calls: state.calls ++ [{:page, lines}]}}
    end)
  end

  @doc """
  Every request the fake received, oldest first, as `{:page, lines}`.
  """
  @spec calls() :: [{:page, [String.t()]}]
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  defp reply(%{error: reason}, _lines) when not is_nil(reason), do: {:error, reason}
  defp reply(%{mismatch: true}, [line | _rest]), do: {:ok, [translate(line)]}
  defp reply(_state, lines), do: {:ok, Enum.map(lines, &translate/1)}

  defp translate(line), do: "[" <> line <> "]"
end
