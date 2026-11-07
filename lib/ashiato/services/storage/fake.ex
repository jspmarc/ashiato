defmodule Ashiato.Storage.Fake do
  @moduledoc """
  In-process `Ashiato.Storage` double: objects live in a map, calls are
  recorded. State is an `Agent` started per test, so tests never touch the
  filesystem or a real service:

      start_supervised!(Ashiato.Storage.Fake)
      :ok = Ashiato.Storage.Fake.put("pages/1.jpg", <<1>>)
      assert [{:put, "pages/1.jpg"}] = Ashiato.Storage.Fake.calls()
  """

  @behaviour Ashiato.Storage

  use Agent

  @doc """
  Starts the fake as the singleton `Ashiato.Storage.Fake`; one per test via
  `start_supervised!/1`, which also guarantees fresh state between tests.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{objects: %{}, calls: []} end, name: __MODULE__)
  end

  @impl true
  @doc "Stores `binary` in the in-process map and records the call."
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, binary) do
    with :ok <- check(key) do
      record({:put, key})

      Agent.update(__MODULE__, fn state ->
        %{state | objects: Map.put(state.objects, key, binary)}
      end)

      :ok
    end
  end

  @impl true
  @doc "Reads a stored binary; an unset key is `{:error, :enoent}`, like the local store."
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    with :ok <- check(key) do
      record({:get, key})

      Agent.get(__MODULE__, fn state ->
        case Map.fetch(state.objects, key) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, :enoent}
        end
      end)
    end
  end

  @doc """
  Same contract as the real store's pre-signature, but the URL is a marker the
  OCR fake can consume; there is no filesystem to point at.
  """
  @impl true
  @spec presigned_get(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_get(key, ttl_seconds) do
    with :ok <- check(key) do
      record({:presigned_get, key, ttl_seconds})
      {:ok, "fake://" <> key}
    end
  end

  @impl true
  @doc "Deletes a key. Idempotent, so wave-3 tests can call it twice."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    with :ok <- check(key) do
      record({:delete, key})

      Agent.update(__MODULE__, fn state ->
        %{state | objects: Map.delete(state.objects, key)}
      end)

      :ok
    end
  end

  @doc "Recorded calls, oldest first."
  @spec calls() :: [tuple()]
  def calls do
    Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
  end

  @doc "The stored objects as `%{key => binary}`."
  @spec objects() :: %{String.t() => binary()}
  def objects do
    Agent.get(__MODULE__, fn state -> state.objects end)
  end

  # the fake mirrors the behaviour's contract, so a bad key fails here the same
  # way it fails as {:error, :invalid_key} in the real store
  defp check(key) do
    if Ashiato.Storage.valid_key?(key), do: :ok, else: {:error, :invalid_key}
  end

  defp record(call) do
    Agent.update(__MODULE__, fn state -> %{state | calls: [call | state.calls]} end)
  end
end
