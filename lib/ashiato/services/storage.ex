defmodule Ashiato.Storage do
  @moduledoc """
  Behaviour for binary object storage (page images, line crops).

  All access goes through the configured implementation. A key is an **object
  key**, never a filesystem path: the local store joins it under its root.
  `valid_key?/1` rejects keys that could resolve outside the root rather than
  sanitising them.
  """

  @callback put(key :: String.t(), binary()) :: :ok | {:error, term()}
  @callback get(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback presigned_get(key :: String.t(), ttl_seconds :: pos_integer()) ::
              {:ok, String.t()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc """
  The configured implementation, so callers depend on the behaviour and never
  on a concrete module. Swapped by config (e.g. a later S3 card):

      config :ashiato, Ashiato.Storage, impl: Ashiato.Storage.S3

  Defaults to `Ashiato.Storage.Local`, matching the `local` default image store.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || Ashiato.Storage.Local
  end

  @doc """
  Whether `key` is an acceptable object key.

  `Path` has no realpath or containment predicate, so this is a cheap lexical
  prefilter: the key must be relative and carry no `..` segment and no null
  byte. A store still resolves the key against its root and rejects anything
  that escapes it.
  """
  @spec valid_key?(String.t()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) > 0 do
    Path.type(key) == :relative and
      not Enum.member?(Path.split(key), "..") and
      not String.contains?(key, "\0")
  end

  def valid_key?(_), do: false
end
