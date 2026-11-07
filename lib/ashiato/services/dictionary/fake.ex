defmodule Ashiato.Dictionary.Fake do
  @moduledoc """
  Canned `Ashiato.Dictionary` service for tests: canned entries, a canned
  `dict_version`, and a counter of raw dictionary lookups.

  Start one per test with `start_supervised!({Ashiato.Dictionary.Fake, opts})`,
  where `opts` accepts `:entries` (`%{term => entry}`) and `:version`
  (defaults `"test-dict-1"`).

  `calls/0` counts lookups. `requests/0` records the exact arguments sent
  to `lookup/1` and `lookup_many/1`.
  `dict_version/0` is cheap metadata used to build the cache key, so it is not
  counted. That is the counter the façade's "a cache hit makes zero lookup
  calls" guarantee is measured against. `set_version/1` simulates a new dictionary
  release bump: the façade must then ignore the old rows, not rewrite them.
  """

  @behaviour Ashiato.Dictionary

  use Agent

  @impl true
  @doc "Canned single lookup; counts one call."
  @spec lookup(String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(term) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = count_call(state)
      state = put_in(state.requests, [{:lookup, term} | state.requests])

      case Map.fetch(state.entries, term) do
        {:ok, entry} -> {{:ok, entry}, state}
        :error -> {{:error, :not_found}, state}
      end
    end)
  end

  @impl true
  @doc "Canned batch lookup; counts one call. Unknown terms come back as an error."
  @spec lookup_many([String.t()]) :: {:ok, %{String.t() => map()}} | {:error, :not_found}
  def lookup_many(terms) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = count_call(state)
      state = put_in(state.requests, [{:lookup_many, terms} | state.requests])
      entries = Map.take(state.entries, terms)
      missing = terms -- Map.keys(entries)

      if missing == [] do
        {{:ok, entries}, state}
      else
        {{:error, :not_found}, state}
      end
    end)
  end

  @impl true
  @doc """
  The canned dictionary release, which `set_version/1` replaces. Each call is counted:
  the memo in `Ashiato.Dictionary` is what keeps a cache hit from asking for it.
  """
  @spec dict_version() :: {:ok, String.t()}
  def dict_version do
    Agent.get_and_update(__MODULE__, fn state ->
      {{:ok, state.version}, %{state | version_calls: state.version_calls + 1}}
    end)
  end

  @doc "How many `dict_version/0` calls were made (the memo is meant to keep this at one)."
  @spec version_calls() :: non_neg_integer()
  def version_calls, do: Agent.get(__MODULE__, & &1.version_calls)

  @doc "How many raw dictionary lookups the façade has made so far."
  @spec calls() :: non_neg_integer()
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Replaces the canned `dict_version`, simulating a new dictionary release."
  @spec set_version(String.t()) :: :ok
  def set_version(version), do: Agent.update(__MODULE__, &%{&1 | version: version})

  @doc """
  Starts the Agent for per-test use.

  Accepts `:entries` (`%{term => entry}`) and `:version` (defaults `"test-dict-1"`).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    state = %{
      version: Keyword.get(opts, :version, "test-dict-1"),
      entries: Keyword.get(opts, :entries, %{}),
      calls: 0,
      version_calls: 0,
      requests: []
    }

    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  @doc "Records every `lookup/1` and `lookup_many/1` call as `{:lookup, term}` or `{:lookup_many, terms}`."
  @spec requests() :: [{:lookup, String.t()} | {:lookup_many, [String.t()]}]
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  @spec count_call(%{calls: non_neg_integer()}) :: %{calls: non_neg_integer()}
  defp count_call(state), do: %{state | calls: state.calls + 1}
end
