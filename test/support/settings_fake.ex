defmodule Ashiato.Settings.Fake do
  @moduledoc """
  In-memory implementation of the `Ashiato.Settings` behaviour: values are stored
  decoded under `{user_id, key}`, so capability gates and callers are drivable without the
  database. It ignores the `:secret` opt — encryption is a property of the repo-backed
  store, not of the data a caller reads.

  It lives in `test/support` rather than inside a test file so that any test — including a
  single-file run of some later card's test — can start it.
  """

  use Agent
  @behaviour Ashiato.Settings

  alias Ashiato.Schemas.Setting

  @doc "Starts the in-memory store; one per test."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  @doc "Reads a stored value, or `default` when the key was never written."
  @spec get(integer(), String.t(), term()) :: term()
  def get(user_id, key, default) do
    Agent.get(__MODULE__, fn store ->
      case Map.fetch(store, {user_id, key}) do
        {:ok, value} -> value
        :error -> default
      end
    end)
  end

  @impl true
  @doc """
  Stores a decoded value and returns a `Ashiato.Schemas.Setting` shaped like the real
  store's reply, so a caller asserting on the returned row sees the value it wrote.
  """
  @spec put(integer(), String.t(), term(), keyword()) :: {:ok, Setting.t()}
  def put(user_id, key, value, _opts) do
    Agent.update(__MODULE__, &Map.put(&1, {user_id, key}, value))

    {:ok, %Setting{user_id: user_id, key: key, value: Jason.encode!(value), secret: false}}
  end

  @impl true
  @doc "Every key of one user, decoded."
  @spec all(integer()) :: %{optional(String.t()) => term()}
  def all(user_id) do
    Agent.get(__MODULE__, fn store ->
      for {{uid, key}, value} <- store, uid == user_id, into: %{}, do: {key, value}
    end)
  end
end
