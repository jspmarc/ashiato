defmodule Ashiato.Settings.Fake do
  @moduledoc """
  In-memory implementation of the `Ashiato.Settings` behaviour: values are stored
  decoded under `{user_id, key}`, so capability gates and callers are drivable without the
  database. It keeps the `:secret` flag but stores the value in the clear — encryption is a
  property of the repo-backed store; what callers observe here is that `all/1` redacts a
  secret and `get/3` returns it.

  It lives in `test/support` rather than inside a test file so that any test — including a
  single-file run of another test — can start it.
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
  @doc "Reads a stored value, or falls back to the built-in defaults then `default`."
  @spec get(integer(), String.t(), term()) :: term()
  def get(user_id, key, default) do
    Agent.get(__MODULE__, fn store ->
      case Map.fetch(store, {user_id, key}) do
        {:ok, {value, _secret?}} -> value
        :error -> Map.get(Ashiato.Settings.defaults(), key, default)
      end
    end)
  end

  @impl true
  @doc """
  Stores a decoded value and returns a `Ashiato.Schemas.Setting` shaped like the real
  store's reply, so a caller asserting on the returned row sees the value it wrote.
  """
  @spec put(integer(), String.t(), term(), keyword()) ::
          {:ok, Setting.t()} | {:error, :not_encodable}
  def put(user_id, key, value, opts) do
    secret? = Keyword.get(opts, :secret, false)

    case Jason.encode(value) do
      {:ok, json} ->
        decoded = Jason.decode!(json)
        Agent.update(__MODULE__, &Map.put(&1, {user_id, key}, {decoded, secret?}))
        {:ok, %Setting{user_id: user_id, key: key, value: json, secret: secret?}}

      {:error, _reason} ->
        {:error, :not_encodable}
    end
  end

  @impl true
  @doc "Every key of one user, decoded."
  @spec all(integer()) :: %{optional(String.t()) => term()}
  def all(user_id) do
    Agent.get(__MODULE__, fn store ->
      for {{uid, key}, {value, secret?}} <- store, uid == user_id, into: %{} do
        # same rule as the real store: a bulk read never spreads a secret
        if secret?, do: {key, :redacted}, else: {key, value}
      end
    end)
  end
end
