defmodule Ashiato.Translator.Fake do
  @moduledoc """
  Test double for `Ashiato.Translator` — no test calls a real provider.

  The output is a documented transform of the input (`"[" <> line <> "]"`), so an
  assertion on the returned lines proves the pipeline sent the right text and kept the
  order. `:mismatch` makes the page request answer with a single line, which is the
  input that must trigger the shared per-line fallback. `:replies` answers the
  page's lines positionally, so duplicate input lines can receive differing output, and
  `:gate` blocks the page request until the test releases it, so a test can race the
  provider against a concurrent cache write.

  State lives in an Agent started by the test, never in application env: the VM is
  shared and tests may run concurrently.
  """

  use Agent
  use Ashiato.Translator, name: "fake"

  @gate_timeout 5_000

  @doc """
  Starts the fake.

  ## Options

    * `:mismatch` — when true, a page request for more than one line answers with one
      line, forcing the fallback (default `false`)
    * `:error` — when set, every request returns `{:error, reason}` with it
    * `:replies` — positional line replies, consumed in page order; absent or
      exhausted lines fall back to the deterministic transform
    * `:gate` — pid to coordinate with: the page request sends
      `{:translator_fake_waiting, self()}` to it and then waits up to 5 s for
      `:translator_fake_release` before answering
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    state = %{
      mismatch: Keyword.get(opts, :mismatch, false),
      error: Keyword.get(opts, :error),
      replies: Keyword.get(opts, :replies),
      gate: Keyword.get(opts, :gate),
      calls: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc """
  Records the request and answers with the deterministic translation of its lines.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, _opts) do
    {reply, gate} =
      Agent.get_and_update(__MODULE__, fn state ->
        {reply, replies} = answer(state, lines)

        {{reply, state.gate}, %{state | replies: replies, calls: state.calls ++ [{:page, lines}]}}
      end)

    if gate, do: wait_for_gate(gate)

    reply
  end

  @doc """
  Every request the fake received, oldest first, as `{:page, lines}`.
  """
  @spec calls() :: [{:page, [String.t()]}]
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  defp answer(%{error: reason} = state, _lines) when not is_nil(reason),
    do: {{:error, reason}, state.replies}

  defp answer(%{mismatch: true} = state, [line | _rest]),
    do: {{:ok, [translate(line)]}, state.replies}

  defp answer(%{replies: replies}, lines) when is_list(replies) do
    {taken, rest} = Enum.split(replies, length(lines))

    {{:ok, taken ++ Enum.map(Enum.drop(lines, length(taken)), &translate/1)}, rest}
  end

  defp answer(state, lines), do: {{:ok, Enum.map(lines, &translate/1)}, state.replies}

  defp wait_for_gate(gate) do
    send(gate, {:translator_fake_waiting, self()})

    receive do
      :translator_fake_release -> :ok
    after
      @gate_timeout -> :timeout
    end
  end

  defp translate(line), do: "[" <> line <> "]"
end
